import Foundation

struct OWUIModel: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    /// Default tools configured on the model. The web client merges these in the browser
    /// (`Chat.svelte`), so native delegation must send them as `tool_ids` itself.
    let toolIds: [String]
    let capabilities: [String: Bool]
    let defaultFeatureIds: [String]
    /// Direct (browser-side) connections cannot be used by Bridge calls.
    let direct: Bool

    private enum CodingKeys: String, CodingKey { case id, name, info, direct }
    private struct Info: Decodable { let meta: Meta? }
    private struct Meta: Decodable {
        let toolIds: [String]?
        let capabilities: [String: Bool]?
        let defaultFeatureIds: [String]?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
        let meta = (try? container.decodeIfPresent(Info.self, forKey: .info))?.meta
        toolIds = meta?.toolIds ?? []
        capabilities = meta?.capabilities ?? [:]
        defaultFeatureIds = meta?.defaultFeatureIds ?? []
        direct = (try? container.decodeIfPresent(Bool.self, forKey: .direct)) ?? false
    }
}

enum OWUIError: LocalizedError {
    case notSignedIn
    case http(Int)
    case missing(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: "请先在聊天页登录。"
        case .http(401): "登录已过期，请在聊天页重新登录。"
        case .http(let code): "服务器返回 \(code)。"
        case .missing(let what): "服务器响应缺少\(what)。"
        }
    }
}

/// Plain HTTP calls to OWUI as the signed-in user.
struct OWUIClient: Sendable {
    let server: URL
    let token: String

    func models() async throws -> [OWUIModel] {
        struct Response: Decodable { let data: [OWUIModel] }
        return try await get("api/models", as: Response.self).data
    }

    /// The chat `features` the web client would send for this model (`Chat.svelte` getFeatures,
    /// webSearchActive and defaultFeatureIds). Builtin web search needs `web_search` here as well
    /// as a socket `session_id`.
    func features(for model: OWUIModel) async throws -> JSON {
        async let configTask = get("api/config", as: JSON.self)
        async let userTask = get("api/v1/auths/", as: JSON.self)
        async let settingsTask = get("api/v1/users/user/settings", as: JSON.self)
        let (config, user, rawSettings) = try await (configTask, userTask, settingsTask)
        let settings = rawSettings["ui"].isNull ? rawSettings : rawSettings["ui"]
        let enabled = config["features"]
        let admin = user["role"].string == "admin"
        let permissions = user["permissions"]["features"]

        func allowed(_ feature: String) -> Bool { admin || permissions[feature].bool == true }
        func modelDefault(_ feature: String) -> Bool {
            model.capabilities[feature] == true && model.defaultFeatureIds.contains(feature)
        }

        let webSearch = enabled["enable_web_search"].bool == true && allowed("web_search")
            && (modelDefault("web_search") || (model.capabilities["web_search"] == true && settings["webSearch"].string == "always"))
        var features: [String: JSON] = [
            "voice": true,
            "web_search": .bool(webSearch),
            "image_generation": .bool(enabled["enable_image_generation"].bool == true && allowed("image_generation") && modelDefault("image_generation")),
            "code_interpreter": .bool(enabled["enable_code_interpreter"].bool == true && allowed("code_interpreter") && modelDefault("code_interpreter")),
        ]
        if settings["memory"].bool ?? enabled["enable_memories"].bool ?? false { features["memory"] = true }
        return .object(features)
    }

    // MARK: Chats

    func createChat(title: String, modelID: String) async throws -> String {
        let body: JSON = [
            "chat": [
                "title": .string(title),
                "models": [.string(modelID)],
                "history": ["messages": [:], "currentId": nil],
                "messages": [],
            ],
            "folder_id": nil,
        ]
        guard let id = try await post("api/v1/chats/new", body: body)["id"].string else { throw OWUIError.missing("聊天 id") }
        return id
    }

    func chat(_ chatID: String) async throws -> JSON {
        try await get("api/v1/chats/\(chatID)", as: JSON.self)
    }

    /// Adds messages to the chat history. The server merges by id and rebuilds `childrenIds`
    /// from `parentId` (`Chats.merge_history`), so a running backend turn is not overwritten.
    func addMessages(_ messages: [String: JSON], currentID: String, chatID: String) async throws {
        _ = try await post("api/v1/chats/\(chatID)", body: [
            "chat": ["history": ["currentId": .string(currentID), "messages": .object(messages)]],
        ])
    }

    func saveVoice(_ voice: JSON, messageID: String, chatID: String) async throws {
        _ = try await post("api/v1/chats/\(chatID)/messages/\(messageID)", body: ["voice": voice])
    }

    func stopTask(_ taskID: String) async throws {
        _ = try await post("api/tasks/stop/\(taskID)", body: [:])
    }

    // MARK: Transport

    func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await send(request(path)))
    }

    @discardableResult
    func post(_ path: String, body: JSON, timeout: TimeInterval = 30) async throws -> JSON {
        var request = request(path)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let data = try await send(request)
        return data.isEmpty ? .null : try JSONDecoder().decode(JSON.self, from: data)
    }

    private func request(_ path: String) -> URLRequest {
        var request = URLRequest(url: server.appending(path: path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw OWUIError.http(status) }
        return data
    }
}
