import Foundation

// Owner decision 2 (2026-10-20): every turn of a call is saved to its chat, as the web client does,
// including small talk the voice model answers by itself.

/// How a voice turn is handed to the chat model.
///
/// OWUI injects builtin tools (web search, memory, knowledge, …) and can ask for approval or input
/// only when the request carries a Socket.IO `session_id`. Owner decision 1 (2026-10-20): native
/// calls use the socket like the web client; plain HTTP stays as a fallback.
enum DelegationMode: String, CaseIterable, Identifiable {
    /// Socket.IO session + `session_id`: the model's tools plus builtin tools; result via `chat:completion`.
    case socket
    /// Synchronous HTTP without `session_id`: only the model's configured tools (MCP etc.).
    case httpFallback

    var id: String { rawValue }

    var title: String {
        switch self {
        case .socket: "完整（含内置工具）"
        case .httpFallback: "降级（仅模型工具）"
        }
    }
}
