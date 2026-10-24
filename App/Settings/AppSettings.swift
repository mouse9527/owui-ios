import Foundation
import Observation

/// User-entered configuration. Nothing here is compiled in: the server URL and model come from Settings,
/// and the token is read from the signed-in web page and kept in the Keychain.
@MainActor
@Observable
final class AppSettings {
    /// One instance for the app UI and App Intents (which start calls without a SwiftUI scene).
    static let shared = AppSettings()

    private enum Key {
        static let server = "serverURL"
        static let model = "defaultModelID"
        static let delegation = "callDelegationMode"
        static let takeOverVoiceButton = "takeOverWebVoiceButton"
    }

    private let defaults: UserDefaults

    var serverURL: URL? {
        didSet {
            defaults.set(serverURL?.absoluteString, forKey: Key.server)
            if oldValue != serverURL {
                defaultModelID = nil
                token = serverURL.flatMap { TokenStore.load(for: $0) }
            }
        }
    }

    var defaultModelID: String? {
        didSet { defaults.set(defaultModelID, forKey: Key.model) }
    }

    var delegationMode: DelegationMode {
        didSet { defaults.set(delegationMode.rawValue, forKey: Key.delegation) }
    }

    /// AC8: the web page's "Voice mode" button starts the native call instead of the web call.
    var takeOverVoiceButton: Bool {
        didSet { defaults.set(takeOverVoiceButton, forKey: Key.takeOverVoiceButton) }
    }

    /// Token of the user signed in to the web page, if any.
    private(set) var token: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let server = defaults.string(forKey: Key.server).flatMap(ServerAddress.normalize)
        serverURL = server
        defaultModelID = defaults.string(forKey: Key.model)
        delegationMode = defaults.string(forKey: Key.delegation).flatMap(DelegationMode.init) ?? .socket
        takeOverVoiceButton = defaults.object(forKey: Key.takeOverVoiceButton) as? Bool ?? true
        token = server.flatMap { TokenStore.load(for: $0) }
    }

    /// Called by the web view whenever `localStorage.token` changes on the configured server.
    func updateToken(_ newToken: String?, for server: URL) {
        guard server == serverURL, newToken != token else { return }
        if let newToken {
            TokenStore.save(newToken, for: server)
        } else {
            TokenStore.delete(for: server)
        }
        token = newToken
    }
}

enum ServerAddress {
    /// Accepts `host`, `host:port` or a full http(s) URL and returns the site root without a trailing slash.
    static func normalize(_ input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil
        else { return nil }
        components.scheme = scheme
        components.path = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.query = nil
        components.fragment = nil
        return components.url
    }
}
