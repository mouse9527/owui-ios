import Foundation
import Observation

/// Native port of the web client's `RealtimeCall` (`src/lib/utils/realtime.ts`, OWUI v0.12.2).
///
/// The voice model hears and speaks; anything substantive is delegated to the chat model, whose
/// answer is sent back with `bridge.result` and then read out. Every transcript and spoken reply is
/// saved to one chat per call (Owner decision 2), so the call can be reviewed in the web UI.
@MainActor
@Observable
final class BridgeCall {
    enum Phase: Equatable {
        case idle, connecting, listening, thinking, speaking
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var muted = false
    private(set) var awaitingApproval = false
    /// Created when the first transcript is saved (AC10: no empty chats), or given up front.
    private(set) var chatID: String?
    private var creatingChat: Task<String, Error>?
    var onChange: (() -> Void)?

    struct Configuration {
        let client: OWUIClient
        let model: OWUIModel
        let delegation: DelegationMode
        /// Continue an existing chat instead of creating one on the first transcript.
        var chatID: String? = nil
    }

    // Connection
    private var configuration: Configuration?
    private var ws: URLSessionWebSocketTask?
    private var session = 0
    private var connected = false
    private var lastPong = Date.distantPast
    private var heartbeat: Task<Void, Never>?
    /// Started by `CallController` before this call exists, so recording begins inside the intent.
    private let audio: CallAudio
    private var delegator: Delegator?
    private var preparing: Task<Void, Never>?
    private var features: JSON = [:]
    private var callStarted = Date()
    private var readyTimeout: Task<Void, Never>?
    private var receivedMessages = 0
    private var voiceModel = ""
    private let callID = UUID().uuidString.lowercased()

    // Turn state (names follow realtime.ts)
    private var receivingSpeech = ""
    private var savingHistory = 0
    private var activeResponse = ""
    private var responseRequested = false
    private var cancelRequested = false
    private var commands: [JSON] = []
    private var chatContext = ""
    private var interrupted: Set<String> = []
    private var speakingResponses: Set<String> = []
    private var responses: [String: Response] = [:]
    private var inputs: [String: Input] = [:]
    private var calls: [String: VoiceTurn] = [:]
    private var pending: VoiceTurn?
    private var delegation: Task<Void, Never>?

    // Chat history kept locally: the branch this call appends to.
    private var history: [HistoryMessage] = []

    private struct Input {
        let text: String
        var userID: String?
    }

    private final class Response {
        let id: String
        let inputID: String?
        let callID: String?
        let status: String?
        var speech: [(itemID: String, text: String)] = []
        var audioItems: Set<CallAudio.PlaybackItem> = []
        var delegated = false
        var done = false
        var messageID: String?

        init(id: String, metadata: JSON) {
            self.id = id
            inputID = metadata["input_item_id"].string
            callID = metadata["call_id"].string
            status = metadata["status"].string
        }

        func setSpeech(_ itemID: String, _ text: String, append: Bool) {
            if let index = speech.firstIndex(where: { $0.itemID == itemID }) {
                speech[index].text = append ? speech[index].text + text : text
            } else {
                speech.append((itemID, text))
            }
        }
    }

    private final class VoiceTurn {
        let callID: String
        let inputID: String
        let assistantID = UUID().uuidString.lowercased()
        var userID = ""
        var finished = false
        var approval = false

        init(callID: String, inputID: String) {
            self.callID = callID
            self.inputID = inputID
        }
    }

    private struct HistoryMessage {
        let id: String
        let role: String
        var content: String
        var spoken: Bool
    }

    // MARK: Lifecycle

    init(audio: CallAudio) {
        self.audio = audio
    }

    func start(_ configuration: Configuration) async {
        guard phase == .idle || phase.isFailed else { return }
        self.configuration = configuration
        session += 1
        let session = session
        callStarted = Date()
        setPhase(.connecting)
        // Audio is already recording (CallController.begin); frames are dropped until bridge.ready.
        audio.onInterruption = { [weak self] message in self?.fail(message) }
        audio.onCapture = { [weak self] pcm in self?.sendAudio(pcm) }
        // Queued results wait for playback to finish (web: AudioWorklet `playback` reports).
        audio.onPlaybackIdle = { [weak self] in
            guard let self else { return }
            if activeResponse.isEmpty, !responseRequested { speakingResponses.removeAll() }
            updatePhase()
            flush()
        }
        chatID = configuration.chatID
        // The realtime WebSocket needs only the token and model, so it opens right away. Chat-model
        // features and the Socket.IO session are needed only for delegation and are prepared in
        // parallel; a slow socket no longer holds the call at 连接中 (device test 4).
        preparing = Task { [weak self] in await self?.prepareDelegation(configuration, session: session) }
        do {
            try openSocket(client: configuration.client, model: configuration.model)
        } catch {
            stage("realtime", "打开失败：\(describeNetworkError(error))", error: true)
            if session == self.session { fail(error.localizedDescription) }
        }
    }

    /// Features for the chat request and the delegation path (Socket.IO, else HTTP).
    private func prepareDelegation(_ configuration: Configuration, session: Int) async {
        let client = configuration.client
        do {
            let started = Date()
            features = try await client.features(for: configuration.model)
            guard session == self.session else { return }
            stage("features", "完成 \(elapsed(started))")
        } catch {
            guard session == self.session else { return }
            // Without features the chat model still answers, minus builtin tools like web search.
            stage("features", "失败：\(describeNetworkError(error))，委派不带内置工具开关", error: true)
        }
        guard configuration.delegation == .socket else {
            delegator = HTTPDelegator(client: client)
            return
        }
        let socket = SocketDelegator(client: client)
        delegator = socket
        let started = Date()
        stage("socket.io", "连接中")
        do {
            try await socket.connect()
            guard session == self.session else { return }
            stage("socket.io", "已连接 \(elapsed(started))")
        } catch {
            // end() closes this socket while it connects: that is not a failure to fall back from.
            guard session == self.session else { return }
            // Socket unreachable: keep the call usable with model tools only.
            stage("socket.io", "\(elapsed(started)) 后失败（\(socket.lastFailure ?? error.localizedDescription)），降级为 HTTP", error: true)
            socket.close()
            delegator = HTTPDelegator(client: client)
        }
    }

    /// Diagnostics line for one setup stage, timed from the start of the call.
    private func stage(_ name: String, _ message: String, error: Bool = false) {
        let line = "[\(name)] \(message)（通话开始后 \(elapsed(callStarted))）"
        if error { Log.call.error("\(line, privacy: .public)") } else { Log.call.info("\(line, privacy: .public)") }
        Diagnostics.shared.record("call", line, error: error)
    }

    private func elapsed(_ since: Date) -> String {
        String(format: "%.1fs", Date().timeIntervalSince(since))
    }

    func end() {
        if connected {
            stopSpeaking()
            for response in responses.values where !response.done { saveSpeech(response) }
        }
        session += 1
        heartbeat?.cancel()
        readyTimeout?.cancel()
        preparing?.cancel()
        delegation?.cancel()
        ws?.cancel(with: .normalClosure, reason: nil)
        ws = nil
        audio.stop()
        delegator?.close()
        delegator = nil
        connected = false
        receivingSpeech = ""
        activeResponse = ""
        responseRequested = false
        cancelRequested = false
        commands.removeAll()
        responses.removeAll()
        inputs.removeAll()
        calls.removeAll()
        pending = nil
        interrupted.removeAll()
        speakingResponses.removeAll()
        if !phase.isFailed { setPhase(.idle) }
    }

    func toggleMute() {
        muted.toggle()
        audio.isMuted = muted
        if muted {
            receivingSpeech = ""
            audio.setPaused(false)
            send(["type": "input_audio_buffer.clear"])
            flush()
        }
        onChange?()
    }

    /// Stops the chat model's running turn (web: "stop backend").
    func stopBackend() async {
        guard let turn = pending, !turn.finished else { return }
        turn.finished = true
        await delegator?.stop(assistantMessageID: turn.assistantID)
        result(turn, status: "cancelled", answer: "The backend request was cancelled. Completed actions have not been undone.")
    }

    // MARK: WebSocket

    private func openSocket(client: OWUIClient, model: OWUIModel) throws {
        guard var components = URLComponents(url: client.server.appending(path: "api/v1/audio/realtime"), resolvingAgainstBaseURL: false) else {
            throw OWUIError.missing("地址")
        }
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        let task = callURLSession.webSocketTask(with: components.url!)
        task.maximumMessageSize = 4 << 20
        ws = task
        task.resume()
        stage("realtime", "连接中")
        var auth: [String: JSON] = ["type": "auth", "token": .string(client.token), "model_id": .string(model.id)]
        if let chatID { auth["chat_id"] = .string(chatID) }
        let session = session
        if let data = try? JSONEncoder().encode(JSON.object(auth)), let text = String(data: data, encoding: .utf8) {
            task.send(.string(text)) { [weak self] error in
                Task { @MainActor in
                    guard let self, session == self.session else { return }
                    if let error { self.stage("realtime", "发送 auth 失败：\(describeNetworkError(error))", error: true) }
                    else { self.stage("realtime", "auth 已发出（WebSocket 已握手）") }
                }
            }
        }
        receive(session: session)

        // Without bridge.ready the call cannot work; fail visibly instead of staying at 连接中.
        readyTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, !Task.isCancelled, session == self.session, !self.connected else { return }
            let state = self.ws.map { "\($0.state.rawValue)" } ?? "nil"
            self.stage("realtime", "15 s 内没有收到 bridge.ready（task.state=\(state)，收到消息 \(self.receivedMessages) 条）", error: true)
            self.fail("语音连接超时：15 秒内服务器没有就绪。")
        }

        lastPong = Date()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self else { return }
                if self.connected {
                    if Date().timeIntervalSince(self.lastPong) > 45 { self.fail("语音连接没有响应。") }
                    else { self.send(["type": "bridge.ping"]) }
                }
            }
        }
    }

    private func receive(session: Int) {
        ws?.receive { [weak self] result in
            Task { @MainActor in
                guard let self, session == self.session else { return }
                switch result {
                case .success(.string(let text)):
                    self.receivedMessages += 1
                    if self.receivedMessages == 1 { self.stage("realtime", "收到首条消息") }
                    guard let event = try? JSONDecoder().decode(JSON.self, from: Data(text.utf8)) else {
                        self.fail("语音事件无效，通话已结束。")
                        return
                    }
                    self.event(event)
                    self.receive(session: session)
                case .success:
                    self.receive(session: session)
                case .failure(let error):
                    let close = self.ws.map { "close code \($0.closeCode.rawValue)" } ?? ""
                    self.stage("realtime", "连接断开：\(describeNetworkError(error)) \(close)", error: true)
                    self.fail("语音连接已断开。")
                }
            }
        }
    }

    private func send(_ event: JSON) {
        guard let ws, let data = try? JSONEncoder().encode(event), let text = String(data: data, encoding: .utf8) else { return }
        ws.send(.string(text)) { _ in }
    }

    private func sendAudio(_ pcm: Data) {
        guard connected, !muted else { return }
        send(["type": "input_audio_buffer.append", "audio": .string(pcm.base64EncodedString())])
    }

    // MARK: Events

    private func event(_ event: JSON) {
        let type = event["type"].string ?? ""
        switch type {
        case "bridge.error":
            stage("realtime", "服务器报错：\(event["message"].string ?? "")", error: true)
            fail(event["message"].string ?? "语音通话出错。")
            return
        case "bridge.pong":
            lastPong = Date()
            return
        case "bridge.ready":
            readyTimeout?.cancel()
            stage("realtime", "bridge.ready")
            guard event["sample_rate"] == 24000 else { fail("采样率不对。"); return }
            voiceModel = event["model"].string ?? ""
            connected = true
            audio.isCapturing = true
            syncContext()

        case "input_audio_buffer.speech_started":
            guard !muted else { return }
            receivingSpeech = event["item_id"].string ?? ""
            // VAD is provisional: keep the queued audio so a noise-only turn can resume it.
            audio.setPaused(true)

        case "conversation.item.input_audio_transcription.completed",
             "conversation.item.input_audio_transcription.failed":
            transcription(event, failed: type.hasSuffix(".failed"))

        case "response.created":
            let response = Response(id: event["response"]["id"].string ?? "", metadata: event["response"]["metadata"])
            responseRequested = false
            activeResponse = response.id
            if cancelRequested {
                cancelRequested = false
                interrupted.insert(response.id)
                send(["type": "response.cancel", "response_id": .string(response.id)])
            }
            responses[response.id] = response

        case "response.output_audio.delta":
            guard let responseID = event["response_id"].string, !interrupted.contains(responseID),
                  let pcm = event["delta"].string.flatMap({ Data(base64Encoded: $0) }), pcm.count % 2 == 0 else { return }
            let item = CallAudio.PlaybackItem(
                responseID: responseID,
                itemID: event["item_id"].string ?? "",
                contentIndex: Int(event["content_index"].number ?? 0)
            )
            responses[responseID]?.audioItems.insert(item)
            speakingResponses.insert(responseID)
            audio.enqueue(pcm, for: item)

        case "response.output_audio_transcript.delta":
            responses[event["response_id"].string ?? ""]?.setSpeech(event["item_id"].string ?? "", event["delta"].string ?? "", append: true)

        case "response.output_audio_transcript.done":
            responses[event["response_id"].string ?? ""]?.setSpeech(event["item_id"].string ?? "", event["transcript"].string ?? "", append: false)

        case "response.output_item.done":
            let item = event["item"]
            if item["type"].string == "function_call", item["status"].string == "completed" {
                functionCall(item, responseID: event["response_id"].string ?? "")
            }

        case "response.done":
            let id = event["response"]["id"].string ?? ""
            if activeResponse == id { activeResponse = "" }
            responseRequested = false
            if let response = responses[id] {
                response.done = true
                saveSpeech(response)
            }
            flush()

        default:
            break
        }
        updatePhase()
    }

    private func transcription(_ event: JSON, failed: Bool) {
        let itemID = event["item_id"].string ?? ""
        if receivingSpeech == itemID { receivingSpeech = "" }
        guard inputs[itemID] == nil else { return }
        let text = failed ? "" : (event["transcript"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { stopSpeaking() }
        if receivingSpeech.isEmpty { audio.setPaused(false) }
        guard !text.isEmpty else {
            // Empty VAD segments are not requests and must not produce replies.
            flush()
            return
        }
        inputs[itemID] = Input(text: text)
        savingHistory += 1
        let session = session
        Task {
            defer { savingHistory -= 1 }
            guard let userID = try? await addMessage(role: "user", content: text, voice: [
                "call_id": .string(callID), "input_item_id": .string(itemID), "model": .string(voiceModel),
            ]) else {
                if session == self.session { fail("没能保存这句话。") }
                return
            }
            guard session == self.session else { return }
            inputs[itemID]?.userID = userID
            enqueue(["type": "bridge.respond", "item_id": .string(itemID)])
        }
    }

    private func functionCall(_ item: JSON, responseID: String) {
        guard let response = responses[responseID], item["name"].string == "generate_chat_completion",
              let callID = item["call_id"].string, calls[callID] == nil else { return }
        guard let inputID = response.inputID, let input = inputs[inputID], let userID = input.userID,
              let configuration, let chatID else {
            fail("委派缺少对应的语音输入。")
            return
        }
        response.delegated = true
        if calls.values.contains(where: { $0.inputID == inputID }) {
            send(["type": "bridge.result", "call_id": .string(callID), "status": "cancelled", "answer": "This input has already been delegated."])
            return
        }
        let turn = VoiceTurn(callID: callID, inputID: inputID)
        turn.userID = userID
        calls[callID] = turn
        // A replacement delegation suppresses any old result still waiting to be spoken.
        commands.removeAll { !$0["call_id"].isNull }

        let previous = pending
        let session = session
        delegation = Task { [weak self] in
            guard let self else { return }
            if let previous, !previous.finished {
                previous.finished = true
                await delegator?.stop(assistantMessageID: previous.assistantID)
                result(previous, status: "cancelled", answer: "Superseded by a new request.", speak: false)
            }
            await preparing?.value
            guard session == self.session, let delegator else { return }
            pending = turn
            updatePhase()
            history.append(HistoryMessage(id: turn.assistantID, role: "assistant", content: "", spoken: false))
            let request = DelegationRequest(
                chatID: chatID,
                model: configuration.model,
                features: features,
                text: input.text,
                userMessage: userMessageJSON(id: userID),
                userMessageID: userID,
                assistantMessageID: turn.assistantID
            )
            do {
                let state = try await delegator.run(request) { [weak self] in
                    guard let self, !turn.approval, !turn.finished else { return }
                    turn.approval = true
                    awaitingApproval = true
                    // Approvals are answered in the chat UI, not by voice (Issue #1).
                    enqueue(["type": "bridge.status", "status": "approval"])
                    updatePhase()
                }
                guard session == self.session, !turn.finished else { return }
                switch state {
                case .completed(let text):
                    updateHistory(turn.assistantID, content: text)
                    result(turn, status: "completed", answer: text)
                case .cancelled:
                    result(turn, status: "cancelled", answer: "The backend request was cancelled.")
                default:
                    result(turn, status: "failed", answer: "The backend request did not complete successfully.")
                }
                saveSpeech(response)
            } catch {
                guard session == self.session, !turn.finished else { return }
                result(turn, status: "failed", answer: "The backend request did not complete successfully.")
            }
        }
    }

    private func result(_ turn: VoiceTurn, status: String, answer: String, speak: Bool = true) {
        turn.finished = true
        send([
            "type": "bridge.result",
            "call_id": .string(turn.callID),
            "status": .string(status),
            "answer": .string(answer.count <= 100_000 ? answer : "The complete answer is ready in chat. It is too long to read in this call."),
        ])
        commands.removeAll { $0["type"].string == "bridge.status" }
        if speak { enqueue(["type": "bridge.respond", "call_id": .string(turn.callID)]) }
        if pending === turn {
            pending = nil
            awaitingApproval = false
        }
        updatePhase()
    }

    // MARK: Response scheduling (one response at a time, after speech and saves settle)

    private func enqueue(_ command: JSON) {
        if command["type"].string == "bridge.status",
           commands.contains(where: { $0["type"] == command["type"] && $0["status"] == command["status"] }) { return }
        if command["type"].string == "bridge.respond", !command["item_id"].isNull {
            let index = commands.firstIndex { $0["item_id"].isNull } ?? commands.count
            commands.insert(command, at: index)
        } else {
            commands.append(command)
        }
        flush()
    }

    private func flush() {
        guard connected, receivingSpeech.isEmpty, savingHistory == 0, activeResponse.isEmpty,
              !responseRequested, !audio.hasQueuedAudio, !commands.isEmpty else { return }
        let command = commands.removeFirst()
        syncContext()
        responseRequested = true
        send(command)
    }

    /// Barge-in: cancel the active response, drop queued audio and truncate what was not heard.
    private func stopSpeaking() {
        if responseRequested { cancelRequested = true }
        var stopped = speakingResponses.subtracting(interrupted)
        if !activeResponse.isEmpty, !interrupted.contains(activeResponse) {
            stopped.insert(activeResponse)
            send(["type": "response.cancel", "response_id": .string(activeResponse)])
        }
        for id in stopped {
            interrupted.insert(id)
            if let response = responses[id], response.done { saveSpeech(response) }
        }
        speakingResponses.removeAll()
        let heard = audio.clear()
        for id in stopped {
            for item in responses[id]?.audioItems ?? [] {
                let played = heard.first { $0.item == item }?.playedMs ?? 0
                send([
                    "type": "conversation.item.truncate",
                    "item_id": .string(item.itemID),
                    "content_index": .number(Double(item.contentIndex)),
                    "audio_end_ms": .number(Double(played)),
                ])
            }
        }
        commands.removeAll { $0["type"].string == "bridge.status" }
        updatePhase()
    }

    /// Replaces the voice model's chat snapshot (`bridge.context`) when it changed.
    private func syncContext() {
        guard connected else { return }
        var budget = 64_000
        var messages: [JSON] = []
        for message in history.suffix(100).reversed() {
            guard budget > 0 else { break }
            var content = message.content
            if message.role == "assistant" {
                let source = message.spoken ? "Historical voice transcript, not current task status" : "Chat model"
                content = "[\(source); message_id=\(message.id)]\n" + content
            }
            content = String(content.prefix(min(32_000, budget)))
            budget -= content.count
            if !content.isEmpty { messages.append(["role": .string(message.role), "content": .string(content)]) }
        }
        messages.reverse()
        let snapshot = (try? String(data: JSONEncoder().encode(messages), encoding: .utf8)) ?? ""
        guard snapshot != chatContext else { return }
        chatContext = snapshot
        send(["type": "bridge.context", "messages": .array(messages)])
    }

    // MARK: Chat history

    private func userMessageJSON(id: String) -> JSON {
        guard let index = history.firstIndex(where: { $0.id == id }) else { return .null }
        let message = history[index]
        let parent = index > 0 ? JSON.string(history[index - 1].id) : .null
        return [
            "id": .string(id), "parentId": parent, "childrenIds": [], "role": "user",
            "content": .string(message.content), "timestamp": .number(Date().timeIntervalSince1970.rounded()),
            "models": [.string(configuration?.model.id ?? "")],
        ]
    }

    /// The call's chat, created on first use: a call where nobody speaks leaves no chat behind.
    private func ensureChat() async throws -> String {
        if let chatID { return chatID }
        guard let configuration else { throw OWUIError.missing("聊天") }
        if let creatingChat { return try await creatingChat.value }
        let task = Task { try await configuration.client.createChat(title: "语音通话", modelID: configuration.model.id) }
        creatingChat = task
        do {
            let id = try await task.value
            chatID = id
            Log.call.info("chat created on first transcript")
            onChange?()
            return id
        } catch {
            creatingChat = nil  // retry on the next transcript
            throw error
        }
    }

    /// Appends a finished message to the end of this call's branch and saves it.
    private func addMessage(role: String, content: String, voice: JSON) async throws -> String {
        guard let configuration else { throw OWUIError.missing("聊天") }
        // Place the message on the branch before any await, so order follows call order even while
        // the chat is still being created for the first transcript.
        let id = UUID().uuidString.lowercased()
        var message: [String: JSON] = [
            "id": .string(id),
            "parentId": history.last.map { .string($0.id) } ?? .null,
            "childrenIds": [],
            "role": .string(role),
            "content": .string(content),
            "done": true,
            "timestamp": .number(Date().timeIntervalSince1970.rounded()),
            "meta": ["voice": voice],
        ]
        if role == "assistant" {
            message["model"] = .string(voiceModel)
            message["modelName"] = .string(voiceModel)
            message["modelIdx"] = 0
        }
        history.append(HistoryMessage(id: id, role: role, content: content, spoken: role == "assistant"))
        let chatID = try await ensureChat()
        try await configuration.client.addMessages([id: .object(message)], currentID: id, chatID: chatID)
        return id
    }

    private func updateHistory(_ id: String, content: String) {
        if let index = history.firstIndex(where: { $0.id == id }) { history[index].content = content }
    }

    /// Saves what the voice model said: on the delegated answer's message, or as its own assistant message.
    private func saveSpeech(_ response: Response) {
        guard !response.speech.isEmpty, let configuration, let chatID else { return }
        let turn = response.callID.flatMap { calls[$0] }
            ?? calls.values.first { $0.inputID == response.inputID }
        if response.delegated && turn?.finished != true { return }
        let speech: [JSON] = response.speech.map {
            ["item_id": .string($0.itemID), "transcript": .string($0.text), "response_id": .string(response.id),
             "model": .string(voiceModel), "interrupted": .bool(interrupted.contains(response.id))]
        }
        let voice: JSON = [
            "call_id": .string(callID),
            "input_item_id": (response.inputID ?? turn?.inputID).map(JSON.string) ?? .null,
            "function_call_id": turn.map { .string($0.callID) } ?? .null,
            "model": .string(voiceModel),
            "speech": .array(speech),
        ]
        let text = response.speech.map(\.text).joined(separator: "\n")
        savingHistory += 1
        Task {
            defer {
                savingHistory -= 1
                flush()
            }
            do {
                if let turn, response.delegated || response.callID != nil {
                    try await configuration.client.saveVoice(voice, messageID: turn.assistantID, chatID: chatID)
                } else if let id = response.messageID {
                    try await configuration.client.saveVoice(voice, messageID: id, chatID: chatID)
                } else if response.status == nil {
                    // Small talk the voice model answered itself: its own assistant message.
                    response.messageID = try await addMessage(role: "assistant", content: text, voice: voice)
                }
            } catch {
                // Saving history is best effort; the call goes on.
            }
        }
    }

    // MARK: Phase

    private func updatePhase() {
        guard !phase.isFailed, phase != .idle || connected else { return }
        let next: Phase
        if !connected { next = .connecting }
        else if audio.isPlaying || !activeResponse.isEmpty && !speakingResponses.isEmpty { next = .speaking }
        else if pending != nil { next = .thinking }
        else { next = .listening }
        setPhase(next)
    }

    private func setPhase(_ next: Phase) {
        guard phase != next else { return }
        phase = next
        onChange?()
    }

    private func fail(_ message: String) {
        guard !phase.isFailed else { return }
        Log.call.error("call failed: \(message, privacy: .public)")
        Diagnostics.shared.record("call", message, error: true)
        phase = .failed(message)
        end()
        onChange?()
    }
}

extension BridgeCall.Phase {
    var isFailed: Bool { if case .failed = self { true } else { false } }
}

extension JSON {
    var number: Double? { if case .number(let value) = self { value } else { nil } }
}
