import SwiftUI
import WebKit

/// The chat UI is the official OWUI web app. The only native hook is reading `localStorage.token`
/// so voice calls can act as the same signed-in user without a second login.
struct ChatWebView: UIViewRepresentable {
    let server: URL
    let onToken: @MainActor (String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(server: server, onToken: onToken) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(
            source: Self.tokenObserver,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        controller.add(context.coordinator, name: Coordinator.messageName)

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
        guard context.coordinator.server != server else { return }
        context.coordinator.server = server
        webView.load(URLRequest(url: server))
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.messageName)
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

        var server: URL
        var onToken: @MainActor (String?) -> Void

        init(server: URL, onToken: @escaping @MainActor (String?) -> Void) {
            self.server = server
            self.onToken = onToken
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            // Only trust the configured origin; any other page the user navigates to gets ignored.
            guard message.frameInfo.isMainFrame, Self.sameOrigin(message.frameInfo.request.url, server) else { return }
            let token = (message.body as? String).flatMap { $0.isEmpty ? nil : $0 }
            onToken(token)
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
