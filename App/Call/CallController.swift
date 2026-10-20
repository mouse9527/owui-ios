import ActivityKit
import AVFoundation
import Foundation
import Observation

/// Owns the current voice call: checks preconditions, starts a fresh `BridgeCall` per call and
/// mirrors its state to the Live Activity. Shared by the in-app button and the App Intents.
@MainActor
@Observable
final class CallController {
    static let shared = CallController()

    private(set) var call: BridgeCall?
    private(set) var lastError: String?
    /// The chat of the last call, so the web view can open it afterwards.
    private(set) var lastChatID: String?

    /// Only the id is kept: `Activity` is not Sendable, so it is looked up where it is used.
    private var activityID: String?
    private var modelName = ""

    var isActive: Bool {
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

    func toggle(settings: AppSettings) async {
        if isActive { end() } else { await start(settings: settings) }
    }

    func start(settings: AppSettings) async {
        guard !isActive else { return }
        lastError = nil
        do {
            // From the Action button the app is in the background: no permission prompt can appear,
            // and the system expects the Live Activity and recording to start promptly. So check
            // the microphone and show the activity before any network round trip.
            guard await AVAudioApplication.requestRecordPermission() else { throw CallError.microphone }
            modelName = ""
            startActivity()
            let configuration = try await configuration(from: settings)
            modelName = configuration.model.name
            let call = BridgeCall()
            call.onChange = { [weak self, weak call] in
                guard let self, let call, self.call === call else { return }
                self.callChanged(call)
            }
            self.call = call
            await updateActivity()
            await call.start(configuration)
        } catch {
            lastError = error.localizedDescription
            await endActivity(phase: .failed, detail: lastError)
        }
    }

    func end() {
        guard let call else { return }
        lastChatID = call.chatID ?? lastChatID
        call.onChange = nil
        self.call = nil
        call.end()
        Task { await endActivity(phase: nil, detail: nil) }
    }

    func toggleMute() {
        call?.toggleMute()
    }

    func stopBackend() async {
        await call?.stopBackend()
    }

    // MARK: Private

    private func configuration(from settings: AppSettings) async throws -> BridgeCall.Configuration {
        guard let server = settings.serverURL else { throw CallError.noServer }
        guard let token = settings.token else { throw OWUIError.notSignedIn }
        guard let modelID = settings.defaultModelID else { throw CallError.noModel }
        let client = OWUIClient(server: server, token: token)
        guard let model = try await client.models().first(where: { $0.id == modelID }) else { throw CallError.noModel }
        guard !model.direct else { throw CallError.directModel }
        return .init(client: client, model: model, delegation: settings.delegationMode)
    }

    private func callChanged(_ call: BridgeCall) {
        if case .failed(let message) = call.phase {
            lastError = message
            lastChatID = call.chatID ?? lastChatID
            self.call = nil
            Task { await endActivity(phase: .failed, detail: message) }
            return
        }
        if call.chatID != nil { lastChatID = call.chatID }
        Task { await updateActivity() }
    }

    private var state: CallActivityAttributes.ContentState {
        .init(phase: phase, muted: call?.muted ?? false, detail: call?.awaitingApproval == true ? "请到聊天里确认" : nil, modelName: modelName)
    }

    private func startActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let stale = Activity<CallActivityAttributes>.activities.map(\.id)
        Task { await Self.end(ids: stale, content: nil, policy: .immediate) }
        activityID = (try? Activity.request(
            attributes: CallActivityAttributes(),
            content: .init(state: state, staleDate: nil)
        ))?.id
    }

    private func updateActivity() async {
        guard let activityID else { return }
        let content = ActivityContent(state: state, staleDate: nil)
        await Self.update(id: activityID, content: content)
    }

    private func endActivity(phase: CallPhase?, detail: String?) async {
        guard let activityID else { return }
        self.activityID = nil
        if let phase {
            // Leave a failure visible briefly on the Lock Screen.
            let final = CallActivityAttributes.ContentState(phase: phase, muted: false, detail: detail, modelName: modelName)
            await Self.end(ids: [activityID], content: .init(state: final, staleDate: nil), policy: .after(.now + 30))
        } else {
            await Self.end(ids: [activityID], content: nil, policy: .immediate)
        }
    }

    nonisolated private static func update(id: String, content: ActivityContent<CallActivityAttributes.ContentState>) async {
        await Activity<CallActivityAttributes>.activities.first { $0.id == id }?.update(content)
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
        case .microphone: "没有麦克风权限。请在系统设置里允许。"
        }
    }
}
