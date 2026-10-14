import SwiftUI
import WebKit

/// Logs into Discord in an in-app web view and reads the account token the moment the web client
/// uses it, so you don't have to dig it out of developer tools. This is exactly what desktop tools
/// like Kizzy do. It still uses the account token, so the same Terms-of-Service caveat applies.
///
/// A fresh (non-persistent) data store is used, so the login isn't kept around after the token is
/// captured. Only the token is saved, in the Keychain.
struct DiscordLoginView: View {
    let onToken: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var captured = false

    var body: some View {
        NavigationStack {
            DiscordWebView { token in
                guard !captured else { return }
                captured = true
                onToken(token)
                dismiss()
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("Log in to Discord")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .safeAreaInset(edge: .top) {
                Text("Log in with your Discord account. colon3 reads your token once the page loads it, then closes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
        }
    }
}

private struct DiscordWebView: UIViewRepresentable {
    let onToken: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onToken: onToken) }

    func makeUIView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "token")
        // Hook the two ways the web client sends its auth header, before any page script runs.
        controller.addUserScript(WKUserScript(source: Self.hookScript, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false))

        let config = WKWebViewConfiguration()
        config.userContentController = controller
        config.websiteDataStore = .nonPersistent()  // fresh login, nothing kept afterwards

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: URL(string: "https://discord.com/login")!))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let onToken: (String) -> Void
        init(onToken: @escaping (String) -> Void) { self.onToken = onToken }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "token",
                  let token = message.body as? String,
                  token.count > 20, !token.lowercased().contains("undefined") else { return }
            onToken(token)
        }
    }

    /// Discord puts the token in the `Authorization` header on its API calls. We wrap both
    /// `XMLHttpRequest.setRequestHeader` and `fetch`, and also poll the webpack store as a
    /// fallback, then hand the first token we see to native code.
    private static let hookScript = """
    (function () {
      function send(t) {
        try {
          if (t && String(t).length > 20 && !String(t).includes('undefined')) {
            window.webkit.messageHandlers.token.postMessage(String(t));
          }
        } catch (e) {}
      }
      const origSet = XMLHttpRequest.prototype.setRequestHeader;
      XMLHttpRequest.prototype.setRequestHeader = function (name, value) {
        try { if (String(name).toLowerCase() === 'authorization') send(value); } catch (e) {}
        return origSet.apply(this, arguments);
      };
      const origFetch = window.fetch;
      window.fetch = function (input, init) {
        try {
          const h = init && init.headers;
          if (h) {
            const auth = (h.get && h.get('Authorization')) || h['Authorization'] || h['authorization'];
            if (auth) send(auth);
          }
        } catch (e) {}
        return origFetch.apply(this, arguments);
      };
      function fromStore() {
        try {
          let token;
          (webpackChunkdiscord_app = window.webpackChunkdiscord_app || []).push([[Math.random()], {}, (req) => {
            for (const m of Object.values(req.c)) {
              const g = m?.exports?.default?.getToken;
              if (typeof g === 'function') { token = g(); break; }
            }
          }]);
          if (token) send(token);
        } catch (e) {}
      }
      const timer = setInterval(fromStore, 1500);
      setTimeout(() => clearInterval(timer), 120000);
    })();
    """
}
