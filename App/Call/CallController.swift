import ActivityKit
import AVFoundation
import Foundation
import Observation

/// Owns the current voice call: checks preconditions, starts recording and the Live Activity,
/// then runs a fresh `BridgeCall` in the background. Shared by the in-app button and the App Intents.
@MainActor
@Observable
final class CallController {
    static let shared = CallController()

    /// Where a call was started from; shown in Diagnostics to tell background-start problems
    /// (Action button) apart from Live Activity problems (in-app button, app in foreground).
    enum Source: String {
        case app = "App 内按钮"
        case intent = "操作按钮 / 快捷指令"
        case webButton = "网页语音按钮"
    }

    /// AC8: continue the chat open in the web view with its model, instead of a new chat.
    struct Target {
        var chatID: String?
        var modelID: String?
    }

    private(set) var call: BridgeCall?
    private(set) var lastError: String?
    /// The chat of the last call, so the web view can open it afterwards.
    private(set) var lastChatID: String?
    /// True from `begin` until the call ends, including while the network setup runs.
    private(set) var isStarting = false

    /// Only the id is kept: `Activity` is not Sendable, so it is looked up where it is used.
    private var activityID: String?
    private var modelName = ""
    private var audio: CallAudio?
    private var setup: Task<Void, Never>?
    /// Activity updates and ends are applied in order.
    private var activityQueue: Task<Void, Never>?
    /// Bumped by `end()`, so a `begin` still awaiting the permission check stops there.
    private var generation = 0

    var isActive: Bool {
        if isStarting { return true }
        guard let phase = call?.phase else { return false }
        return phase != .idle && !phase.isFailed
    }

    var phase: CallPhase {
        switch call?.phase {
        case .connecting, .idle, nil: .connecting
        case .listening: .listening
        case .thinking: .thinking
        case .speaking: .speaking
        case .failed: .failed
        }
    }

    func toggle(settings: AppSettings, source: Source) async throws {
        if isActive { end() } else { try await begin(settings: settings, source: source) }
    }

    /// Starts recording and the Live Activity, then returns; the network setup and the call itself
    /// run in a task. An `AudioRecordingIntent` must start a Live Activity when recording begins,
    /// and its `perform()` must not wait for the whole call (device test 1: shortcut timed out).
    func begin(settings: AppSettings, source: Source, target: Target = .init()) async throws {
        guard !isActive else { return }
        lastError = nil
        isStarting = true
        generation += 1
        let generation = generation
        Log.call.info("begin from \(source.rawValue, privacy: .public)")
        Diagnostics.shared.record("call", "开始通话（\(source.rawValue)）")
        do {
            guard await AVAudioApplication.requestRecordPermission() else { throw CallError.microphone }
            guard generation == self.generation else { return }
            let audio = CallAudio()
            try audio.start()
            self.audio = audio
            modelName = target.modelID ?? settings.defaultModelID ?? ""
            startActivity(source: source)
        } catch {
            fail(error.localizedDescription)
            throw error
        }
        setup = Task { await run(settings: settings, target: target) }
    }

    func end() {
        Log.call.info("end")
        generation += 1
        setup?.cancel()
        setup = nil
        isStarting = false
        if let call {
            lastChatID = call.chatID ?? lastChatID
            call.onChange = nil
            self.call = nil
            call.end()
        } else {
            audio?.stop()
        }
        audio = nil
        enqueueActivity { await self.endActivity(phase: nil, detail: nil) }
    }

    func toggleMute() {
        call?.toggleMute()
    }

    func stopBackend() async {
        await call?.stopBackend()
    }

    // MARK: Private

    /// The web page's voice button (AC8). During a call it only brings the call controls back.
    func beginFromWeb(settings: AppSettings, chatID: String?, models: [String]) async {
        guard !isActive else {
            Diagnostics.shared.record("call", "网页语音按钮：已在通话中")
            return
        }
        guard models.count <= 1 else {
            lastError = "只能选一个模型才能语音通话。"
            return
        }
        try? await begin(settings: settings, source: .webButton, target: .init(chatID: chatID, modelID: models.first))
    }

    private func run(settings: AppSettings, target: Target) async {
        guard let audio else { return }
        do {
            let configuration = try await configuration(from: settings, target: target)
            guard !Task.isCancelled, isStarting else { return }
            modelName = configuration.model.name
            let call = BridgeCall(audio: audio)
            call.onChange = { [weak self, weak call] in
                guard let self, let call, self.call === call else { return }
                self.callChanged(call)
            }
            self.call = call
            isStarting = false
            enqueueActivity { await self.updateActivity() }
            await call.start(configuration)
        } catch {
            guard !Task.isCancelled else { return }
            fail(error.localizedDescription)
        }
    }

    /// Model: the one selected in the page, else the chat's saved model, else the Settings default.
    private func configuration(from settings: AppSettings, target: Target) async throws -> BridgeCall.Configuration {
        guard let server = settings.serverURL else { throw CallError.noServer }
        guard let token = settings.token else { throw OWUIError.notSignedIn }
        let client = OWUIClient(server: server, token: token)
        var modelID = target.modelID
        if modelID == nil, let chatID = target.chatID {
            let models = try? await client.chat(chatID)["chat"]["models"].array.compactMap(\.string)
            if models?.count == 1 { modelID = models?.first }
        }
        guard let modelID = modelID ?? settings.defaultModelID else { throw CallError.noModel }
        guard let model = try await client.models().first(where: { $0.id == modelID }) else { throw CallError.noModel }
        guard !model.direct else { throw CallError.directModel }
        Log.call.info("model from \(target.modelID != nil ? "page" : (modelID == settings.defaultModelID ? "settings" : "chat"), privacy: .public), existing chat=\(target.chatID != nil)")
        return .init(client: client, model: model, delegation: settings.delegationMode, chatID: target.chatID)
    }

    private func fail(_ message: String) {
        Log.call.error("call failed before start: \(message, privacy: .public)")
        Diagnostics.shared.record("call", message, error: true)
        lastError = message
        isStarting = false
        if call == nil {
            audio?.stop()
            audio = nil
        }
        enqueueActivity { await self.endActivity(phase: .failed, detail: message) }
    }

    private func callChanged(_ call: BridgeCall) {
        if case .failed(let message) = call.phase {
            lastError = message
            lastChatID = call.chatID ?? lastChatID
            self.call = nil
            audio = nil
            enqueueActivity { await self.endActivity(phase: .failed, detail: message) }
            return
        }
        if call.chatID != nil { lastChatID = call.chatID }
        enqueueActivity { await self.updateActivity() }
    }

    // MARK: Live Activity

    private var state: CallActivityAttributes.ContentState {
        .init(phase: phase, muted: call?.muted ?? false, detail: call?.awaitingApproval == true ? "请到聊天里确认" : nil, modelName: modelName)
    }

    private func enqueueActivity(_ work: @escaping @MainActor () async -> Void) {
        let previous = activityQueue
        activityQueue = Task {
            await previous?.value
            await work()
        }
    }

    /// Synchronous on purpose: it must happen inside the intent's `perform()`, right after recording starts.
    private func startActivity(source: Source) {
        let enabled = ActivityAuthorizationInfo().areActivitiesEnabled
        let existing = Activity<CallActivityAttributes>.activities
        Log.activity.info("request: areActivitiesEnabled=\(enabled), existing=\(existing.count), source=\(source.rawValue, privacy: .public)")
        if !enabled {
            Diagnostics.shared.record("activity", "areActivitiesEnabled=false（系统设置里关了实时活动，或系统暂不允许）", error: true)
        }
        let stale = existing.map(\.id)
        if !stale.isEmpty {
            enqueueActivity { await Self.end(ids: stale, content: nil, policy: .immediate) }
        }
        do {
            let activity = try Activity.request(
                attributes: CallActivityAttributes(),
                content: .init(state: state, staleDate: nil)
            )
            activityID = activity.id
            Log.activity.info("request ok id=\(activity.id, privacy: .public) state=\(String(describing: activity.activityState), privacy: .public)")
            Diagnostics.shared.record("activity", "已请求实时活动（\(source.rawValue)），状态 \(activity.activityState)")
        } catch {
            activityID = nil
            let message = describeActivityError(error)
            Log.activity.error("request failed: \(message, privacy: .public)")
            Diagnostics.shared.record("activity", "请求实时活动失败（\(source.rawValue)）：\(message)", error: true)
        }
    }

    private func updateActivity() async {
        guard let activityID else { return }
        let content = ActivityContent(state: state, staleDate: nil)
        if await !Self.update(id: activityID, content: content) {
            Log.activity.error("update: activity \(activityID, privacy: .public) no longer exists")
            Diagnostics.shared.record("activity", "更新时找不到实时活动（可能被系统结束）", error: true)
            self.activityID = nil
        }
    }

    private func endActivity(phase: CallPhase?, detail: String?) async {
        guard let activityID else { return }
        self.activityID = nil
        Log.activity.info("end id=\(activityID, privacy: .public) phase=\(phase?.rawValue ?? "none", privacy: .public)")
        if let phase {
            // Leave a failure visible briefly on the Lock Screen.
            let final = CallActivityAttributes.ContentState(phase: phase, muted: false, detail: detail, modelName: modelName)
            await Self.end(ids: [activityID], content: .init(state: final, staleDate: nil), policy: .after(.now + 30))
        } else {
            await Self.end(ids: [activityID], content: nil, policy: .immediate)
        }
    }

    /// Returns false if the activity no longer exists.
    nonisolated private static func update(id: String, content: ActivityContent<CallActivityAttributes.ContentState>) async -> Bool {
        guard let activity = Activity<CallActivityAttributes>.activities.first(where: { $0.id == id }) else { return false }
        await activity.update(content)
        return true
    }

    nonisolated private static func end(
        ids: [String],
        content: ActivityContent<CallActivityAttributes.ContentState>?,
        policy: ActivityUIDismissalPolicy
    ) async {
        for activity in Activity<CallActivityAttributes>.activities where ids.contains(activity.id) {
            await activity.end(content, dismissalPolicy: policy)
        }
    }
}

enum CallError: LocalizedError {
    case noServer, noModel, directModel, microphone

    var errorDescription: String? {
        switch self {
        case .noServer: "先在设置里填写服务器地址。"
        case .noModel: "先在设置里选择语音通话的模型。"
        case .directModel: "这个模型是直连模型，不能用于语音通话。"
        case .microphone: "没有麦克风权限。请先在 App 里点一次通话按钮并允许麦克风。"
        }
    }
}
