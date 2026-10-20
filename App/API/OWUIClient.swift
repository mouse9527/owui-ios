import Foundation

struct OWUIModel: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    /// Default tools configured on the model. The web client merges these in the browser
    /// (`Chat.svelte`), so native delegation must send them as `tool_ids` itself.
    let toolIds: [String]

    private enum CodingKeys: String, CodingKey { case id, name, info }
    private struct Info: Decodable { let meta: Meta? }
    private struct Meta: Decodable { let toolIds: [String]? }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
        let info = try? container.decodeIfPresent(Info.self, forKey: .info)
        toolIds = info?.meta?.toolIds ?? []
    }
}

enum OWUIError: LocalizedError {
    case notSignedIn
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: "请先在聊天页登录。"
        case .http(401): "登录已过期，请在聊天页重新登录。"
        case .http(let code): "服务器返回 \(code)。"
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

    func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        var request = URLRequest(url: server.appending(path: path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw OWUIError.http(status) }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
