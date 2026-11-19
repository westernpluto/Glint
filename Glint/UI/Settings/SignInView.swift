import SwiftUI
import WebKit

/// Google sign-in in an isolated, non-persistent web session so every account
/// added gets its own independent cookie jar.
struct SignInView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AccountStore.self) private var accounts
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ZStack {
                SignInWebView { cookies in
                    guard !working else { return }
                    working = true
                    Task {
                        do {
                            try await accounts.add(cookies: cookies)
                            dismiss()
                        } catch {
                            self.error = "Couldn't finish signing in. Please try again."
                            working = false
                        }
                    }
                }
                if working {
                    ProgressView("Signing in…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .navigationTitle("Sign in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .alert("Sign in", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
    }
}

private struct SignInWebView: UIViewRepresentable {
    var onCookies: ([StoredCookie]) -> Void

    static let startURL = URL(string:
        "https://accounts.google.com/ServiceLogin?service=youtube&uilel=3&passive=true&hl=en&continue=https%3A%2F%2Fwww.youtube.com%2Fsignin%3Faction_handle_signin%3Dtrue%26app%3Dm%26hl%3Den%26next%3Dhttps%253A%252F%252Fm.youtube.com%252F")!

    func makeCoordinator() -> Coordinator { Coordinator(onCookies: onCookies) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        web.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"
        web.navigationDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        web.load(URLRequest(url: Self.startURL))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onCookies: ([StoredCookie]) -> Void
        private var delivered = false
        init(onCookies: @escaping ([StoredCookie]) -> Void) { self.onCookies = onCookies }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !delivered, let host = webView.url?.host, host.hasSuffix("youtube.com") else { return }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let relevant = cookies.filter { $0.domain.contains("youtube.com") || $0.domain.contains("google.com") }
                guard relevant.contains(where: { $0.name == "SAPISID" || $0.name == "__Secure-3PAPISID" }) else { return }
                self.delivered = true
                let stored = relevant.map {
                    StoredCookie(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path, expires: $0.expiresDate)
                }
                DispatchQueue.main.async { self.onCookies(stored) }
            }
        }
    }
}
