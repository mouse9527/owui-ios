import SwiftUI
import WebKit

/// The chat UI is the official OWUI web app. Native hooks: reading `localStorage.token` so voice
/// calls act as the same signed-in user, and (AC8) handing the page's "Voice mode" button to the
/// native call.
struct ChatWebView: UIViewRepresentable {
    let server: URL
    /// Set to a path under the server (e.g. `c/<chat id>`) to navigate there; reset to nil once loaded.
    @Binding var openPath: String?
    var takeOverVoiceButton = true
    let onToken: @MainActor (String?) -> Void
    var onVoiceButton: @MainActor (VoiceButtonRequest) -> Void = { _ in }

    /// What the page reported when its voice button was tapped.
    struct VoiceButtonRequest {
        /// From the URL `/c/<id>`; nil on a new chat.
        let chatID: String?
        /// `sessionStorage.selectedModels`, the models selected in the page right now.
        let models: [String]
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(server: server, onToken: onToken, onVoiceButton: onVoiceButton)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let controller = configuration.userContentController
        Self.userScripts(takeOver: takeOverVoiceButton).forEach(controller.addUserScript)
        controller.add(context.coordinator, name: Coordinator.messageName)
        controller.add(context.coordinator, name: Coordinator.voiceMessageName)
        if Self.voiceButtonScript == nil {
            Log.call.error("voice-button.js missing from bundle; the web voice button stays as is")
        }
        context.coordinator.takeOverVoiceButton = takeOverVoiceButton

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        #if DEBUG
        webView.isInspectable = true
        #endif
        webView.load(URLRequest(url: server))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onToken = onToken
        context.coordinator.onVoiceButton = onVoiceButton
        if context.coordinator.takeOverVoiceButton != takeOverVoiceButton {
            context.coordinator.takeOverVoiceButton = takeOverVoiceButton
            // The document-start flag only covers future loads; update the current page too.
            webView.evaluateJavaScript(Self.takeOverFlag(takeOverVoiceButton))
            let controller = webView.configuration.userContentController
            controller.removeAllUserScripts()
            Self.userScripts(takeOver: takeOverVoiceButton).forEach(controller.addUserScript)
        }
        if context.coordinator.server != server {
            context.coordinator.server = server
            webView.load(URLRequest(url: server))
        }
        if let path = openPath {
            webView.load(URLRequest(url: server.appending(path: path)))
            DispatchQueue.main.async { openPath = nil }
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: Coordinator.messageName)
        controller.removeScriptMessageHandler(forName: Coordinator.voiceMessageName)
    }

    private static func takeOverFlag(_ enabled: Bool) -> String {
        "window.__owuiNativeVoice = \(enabled);"
    }

    /// `App/Web/Scripts/voice-button.js`, bundled as a resource.
    private static let voiceButtonScript: String? = Bundle.main
        .url(forResource: "voice-button", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    private static func userScripts(takeOver: Bool) -> [WKUserScript] {
        [tokenObserver, takeOverFlag(takeOver), voiceButtonScript].compactMap { $0 }.map {
            WKUserScript(source: $0, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        }
    }

    /// Reports the token on load and whenever the page itself sets or removes it (sign-in, sign-out).
    /// `storage` events only fire for other documents, so the setters are wrapped instead.
    private static let tokenObserver = """
    (() => {
      const post = () => {
        try {
          window.webkit.messageHandlers.\(Coordinator.messageName).postMessage(localStorage.getItem('token'));
        } catch (_) {}
      };
      const proto = Storage.prototype;
      const set = proto.setItem, remove = proto.removeItem, clear = proto.clear;
      proto.setItem = function (key, value) {
        set.call(this, key, value);
        if (this === localStorage && key === 'token') post();
      };
      proto.removeItem = function (key) {
        remove.call(this, key);
        if (this === localStorage && key === 'token') post();
      };
      proto.clear = function () {
        clear.call(this);
        if (this === localStorage) post();
      };
      post();
    })();
    """

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        static let messageName = "owuiToken"
        static let voiceMessageName = "owuiVoice"

        var server: URL
        var onToken: @MainActor (String?) -> Void
        var onVoiceButton: @MainActor (VoiceButtonRequest) -> Void
        var takeOverVoiceButton = true

        init(server: URL, onToken: @escaping @MainActor (String?) -> Void, onVoiceButton: @escaping @MainActor (VoiceButtonRequest) -> Void) {
            self.server = server
            self.onToken = onToken
            self.onVoiceButton = onVoiceButton
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            // Only trust the configured origin; any other page the user navigates to gets ignored.
            guard message.frameInfo.isMainFrame, Self.sameOrigin(message.frameInfo.request.url, server) else { return }
            switch message.name {
            case Self.voiceMessageName:
                guard takeOverVoiceButton, let body = message.body as? [String: Any] else { return }
                let request = VoiceButtonRequest(
                    chatID: (body["chatId"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                    models: (body["models"] as? [Any])?.compactMap { $0 as? String } ?? []
                )
                Log.call.info("web voice button: chat=\(request.chatID != nil), models=\(request.models.count)")
                onVoiceButton(request)
            default:
                let token = (message.body as? String).flatMap { $0.isEmpty ? nil : $0 }
                onToken(token)
            }
        }

        // Links to other sites (tool results, sources) open in Safari rather than replacing the chat.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor action: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard let url = action.request.url, action.targetFrame?.isMainFrame != false else { return .allow }
            if Self.sameOrigin(url, server) || ["about", "blob", "data"].contains(url.scheme) { return .allow }
            if action.navigationType == .linkActivated {
                await UIApplication.shared.open(url)
                return .cancel
            }
            return .allow
        }

        // `target=_blank` links.
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for action: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = action.request.url {
                if Self.sameOrigin(url, server) {
                    webView.load(action.request)
                } else {
                    UIApplication.shared.open(url)
                }
            }
            return nil
        }

        // Microphone / camera for the web page's own voice input; the origin is the user's server.
        func webView(
            _ webView: WKWebView,
            decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
            initiatedBy frame: WKFrameInfo,
            type: WKMediaCaptureType
        ) async -> WKPermissionDecision {
            Self.sameOrigin(frame.request.url, server) ? .prompt : .deny
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            webView.reload()
        }

        private static func sameOrigin(_ a: URL?, _ b: URL) -> Bool {
            guard let a else { return false }
            return a.scheme?.lowercased() == b.scheme?.lowercased()
                && a.host?.lowercased() == b.host?.lowercased()
                && (a.port ?? defaultPort(a)) == (b.port ?? defaultPort(b))
        }

        private static func defaultPort(_ url: URL) -> Int {
            url.scheme?.lowercased() == "http" ? 80 : 443
        }
    }
}
