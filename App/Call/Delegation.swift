import Foundation
import SocketIO

/// One spoken request handed to the chat model.
struct DelegationRequest: Sendable {
    let chatID: String
    let model: OWUIModel
    let features: JSON
    let text: String
    /// Already saved by the call (every transcript is recorded); the backend reuses it.
    let userMessage: JSON
    let userMessageID: String
    let assistantMessageID: String
}

/// How a delegated turn ended, mirroring `getBridgeTurnState` in the web client.
enum TurnState: Equatable, Sendable {
    case working
    /// A tool call needs approval or `ask_user` is waiting; the user has to answer in chat.
    case approval
    case completed(String)
    case failed
    case cancelled

    /// `realtime.ts` getBridgeTurnState + `Chat.svelte` visibleMessageText.
    init(message: JSON) {
        if message.isNull { self = .working; return }
        if !message["error"].isNull { self = .failed; return }
        let output = message["output"].array
        let answered = Set(output.filter { $0["type"].string == "function_call_output" }.compactMap { $0["call_id"].string })
        let pending = output.filter {
            $0["type"].string == "function_call"
                && !answered.contains($0["call_id"].string ?? $0["id"].string ?? "")
                && !["rejected", "cancelled", "failed"].contains($0["status"].string ?? "")
        }
        if pending.contains(where: { ["pending", "queued", "requires_approval"].contains($0["status"].string ?? "") || $0["name"].string == "ask_user" }) {
            self = .approval
        } else if !pending.isEmpty || message["done"].bool != true {
            self = .working
        } else {
            self = .completed(Self.visibleText(message))
        }
    }

    static func visibleText(_ message: JSON) -> String {
        let text = message["output"].array
            .filter { $0["type"].string == "message" }
            .flatMap { $0["content"].array }
            .filter { $0["type"].string == "output_text" }
            .compactMap { $0["text"].string }
            .joined()
        if !text.isEmpty { return text }
        // removeAllDetails: drop <details>…</details> blocks (reasoning, tool status).
        let content = message["content"].string ?? ""
        return content.replacingOccurrences(of: "<details[^>]*>[\\s\\S]*?</details>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
protocol Delegator: AnyObject {
    /// Submits the turn and returns once the chat model is no longer working.
    /// `onApproval` fires when the turn pauses for approval / ask_user (the call keeps waiting).
    func run(_ request: DelegationRequest, onApproval: @escaping @MainActor () -> Void) async throws -> TurnState
    /// Stops the running backend task, if any.
    func stop(assistantMessageID: String) async
    func close()
}

/// Request body shared by both paths; matches the web `/api/chat/completions` submission.
private func completionBody(_ request: DelegationRequest, sessionID: String?) -> JSON {
    var body: [String: JSON] = [
        "stream": true,
        "model": .string(request.model.id),
        "messages": [["role": "user", "content": .string(request.text)]],
        "params": [:],
        "tool_ids": .array(request.model.toolIds.map(JSON.string)),
        "features": request.features,
        "variables": [:],
        "chat_id": .string(request.chatID),
        "id": .string(request.assistantMessageID),
        "parent_id": request.userMessage["parentId"],
        "user_message": request.userMessage,
        "background_tasks": ["title_generation": true, "tags_generation": true, "follow_up_generation": false],
    ]
    if let sessionID { body["session_id"] = .string(sessionID) }
    return .object(body)
}

private func message(_ request: DelegationRequest, client: OWUIClient) async throws -> JSON {
    try await client.chat(request.chatID)["chat"]["history"]["messages"][request.assistantMessageID]
}

// MARK: - Socket.IO (default)

/// Joins the user's Socket.IO session so OWUI treats the call like the web client: builtin tools
/// (web search, memory, …) are injected and the turn runs as a background task (§0.8).
@MainActor
final class SocketDelegator: Delegator {
    private let client: OWUIClient
    private let manager: SocketManager
    private let socket: SocketIOClient
    private var waiters: [String: CheckedContinuation<Void, Never>] = [:]
    private var timedOut: Set<String> = []
    private var updates: [String: @MainActor (JSON) -> Void] = [:]
    private var taskIDs: [String: [String]] = [:]

    init(client: OWUIClient) {
        self.client = client
        manager = SocketManager(socketURL: client.server, config: [
            .path("/ws/socket.io/"),
            .forceWebsockets(true),
            .reconnects(true),
            .reconnectWait(1),
            .reconnectWaitMax(5),
            .compress,
        ])
        socket = manager.defaultSocket
        socket.on("events") { [weak self] items, ack in
            let event = JSON(any: items.first)
            MainActor.assumeIsolated { self?.handle(event, ack: ack) }
        }
    }

    func connect() async throws {
        if socket.status == .connected, socket.sid != nil { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            socket.once(clientEvent: .connect) { _, _ in
                guard !resumed else { return }
                resumed = true
                continuation.resume()
            }
            socket.connect(withPayload: ["token": client.token], timeoutAfter: 15) {
                guard !resumed else { return }
                resumed = true
                continuation.resume(throwing: DelegationError.socketUnavailable)
            }
        }
    }

    func run(_ request: DelegationRequest, onApproval: @escaping @MainActor () -> Void) async throws -> TurnState {
        try await connect()
        guard let sid = socket.sid else { throw DelegationError.socketUnavailable }
        let id = request.assistantMessageID
        updates[id] = { data in
            if TurnState(message: data) == .approval { onApproval() }
        }
        defer {
            updates[id] = nil
            taskIDs[id] = nil
        }
        let response = try await client.post("api/chat/completions", body: completionBody(request, sessionID: sid))
        guard response["status"].bool == true else { throw DelegationError.rejected }
        taskIDs[id] = response["task_ids"].array.compactMap(\.string)

        // Wait for `chat:completion done`, re-checking the saved message in case an event was missed
        // (socket reconnect, app suspended); approvals pause here until answered in chat.
        while true {
            let woke = await waitForEvent(id, timeout: 20)
            if Task.isCancelled { return .cancelled }
            let state = TurnState(message: try await message(request, client: client))
            switch state {
            case .working:
                continue
            case .approval:
                onApproval()
                if !woke { continue }
            default:
                return state
            }
        }
    }

    func stop(assistantMessageID: String) async {
        for task in taskIDs[assistantMessageID] ?? [] {
            try? await client.stopTask(task)
        }
    }

    func close() {
        waiters.values.forEach { $0.resume() }
        waiters.removeAll()
        socket.removeAllHandlers()
        manager.disconnect()
    }

    /// Returns true if a completion event arrived, false on timeout.
    private func waitForEvent(_ id: String, timeout: TimeInterval) async -> Bool {
        let timer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            self?.timedOut.insert(id)
            self?.waiters.removeValue(forKey: id)?.resume()
        }
        await withCheckedContinuation { waiters[id] = $0 }
        timer.cancel()
        return timedOut.remove(id) == nil
    }

    private func handle(_ event: JSON, ack: SocketAckEmitter) {
        let type = event["data"]["type"].string ?? ""
        // `sio.call` from the backend (direct tools, live ask_user / confirmations). Saved chats pause
        // approvals in the database instead, so anything reaching us here is answered as cancelled
        // rather than leaving the backend to time out (60–240 s).
        if ack.expected {
            ack.with(["status": "cancelled", "answers": [String: Any](), "error": "Not available in a voice call."])
            return
        }
        guard let id = event["message_id"].string, waiters[id] != nil || updates[id] != nil else { return }
        let data = event["data"]["data"]
        switch type {
        case "chat:completion":
            if data["done"].bool == true || data["error"].isNull == false {
                waiters.removeValue(forKey: id)?.resume()
            } else {
                updates[id]?(["output": data["output"], "done": false])
            }
        case "chat:message:error", "chat:tasks:cancel":
            waiters.removeValue(forKey: id)?.resume()
        default:
            break
        }
    }
}

// MARK: - HTTP fallback

/// Synchronous `/api/chat/completions` without `session_id` (§0.3): only the model's configured
/// tools; the request returns when the whole tool loop is done.
@MainActor
final class HTTPDelegator: Delegator {
    private let client: OWUIClient
    private var running: [String: Task<JSON, Error>] = [:]

    init(client: OWUIClient) {
        self.client = client
    }

    func run(_ request: DelegationRequest, onApproval: @escaping @MainActor () -> Void) async throws -> TurnState {
        let client = client
        let task = Task { try await client.post("api/chat/completions", body: completionBody(request, sessionID: nil), timeout: 600) }
        running[request.assistantMessageID] = task
        defer { running[request.assistantMessageID] = nil }
        _ = try await task.value
        let state = TurnState(message: try await message(request, client: client))
        if state == .approval { onApproval() }
        return state
    }

    func stop(assistantMessageID: String) async {
        running[assistantMessageID]?.cancel()
    }

    func close() {
        running.values.forEach { $0.cancel() }
        running.removeAll()
    }
}

enum DelegationError: LocalizedError {
    case socketUnavailable
    case rejected

    var errorDescription: String? {
        switch self {
        case .socketUnavailable: "实时通道连不上。"
        case .rejected: "聊天模型没有接受这次请求。"
        }
    }
}
