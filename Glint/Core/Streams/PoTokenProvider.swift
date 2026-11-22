import Foundation
import UIKit
import WebKit

/// Mints YouTube "proof of origin" (PO) tokens the way yt-dlp's add-on providers do
/// (bgutil-ytdlp-pot-provider / BgUtils): YouTube's BotGuard program runs in a hidden
/// WKWebView (a real browser, unlike the jsdom those providers fake), its snapshot is traded
/// for an integrity token, and the minter it hands back turns a content binding (the visitor
/// id) into a token. Streams fetched with `&pot=<token>` aren't cut off partway for clients
/// that require one (MWEB and the other web clients).
@MainActor
final class PoTokenProvider: NSObject, WKNavigationDelegate {
    static let shared = PoTokenProvider()

    /// The web BotGuard request key (same as bgutil's).
    private static let requestKey = "O43z0dpjhgX20SCx4KAo"
    private static let apiKey = "AIzaSyDyT5W0Jh49F30Pqqtyfdf7pDLFKLJoAnw"
    private static let jnn = "https://jnn-pa.googleapis.com/$rpc/google.internal.waa.v1.Waa/"
    /// yt-dlp caches web tokens 6 hours (the integrity token usually says 12).
    private static let maxLifetime: TimeInterval = 6 * 60 * 60

    enum PoTokenError: LocalizedError {
        case step(String)
        var errorDescription: String? { if case .step(let s) = self { return s }; return nil }
    }

    private var webView: WKWebView?
    private var pageLoaded: CheckedContinuation<Void, Error>?
    private var minterExpiry = Date.distantPast
    private var minterTask: Task<Void, Error>?
    private var tokens: [String: (token: String, expires: Date)] = [:]

    /// A token for `binding` (normally the visitor id), from cache when still fresh.
    func token(for binding: String, visitorData: String?, fresh: Bool = false) async throws -> String {
        if !fresh, let t = tokens[binding], t.expires > Date() { return t.token }
        try await ensureMinter(visitorData: visitorData)
        let value = try await webView?.callAsyncJavaScript("""
            const r = await window.__glintMint(new TextEncoder().encode(binding));
            if (!(r instanceof Uint8Array)) throw new Error('mint returned ' + typeof r);
            let s = ''; for (const b of r) s += String.fromCharCode(b);
            return btoa(s).replace(/\\+/g, '-').replace(/\\//g, '_');
            """, arguments: ["binding": binding], in: nil, contentWorld: .page)
        guard let token = value as? String, !token.isEmpty else { throw PoTokenError.step("Empty PO token") }
        tokens = tokens.filter { $0.value.expires > Date() }
        tokens[binding] = (token, minterExpiry)
        return token
    }

    /// Forget everything (e.g. tokens stopped working).
    func reset() {
        tokens = [:]
        minterExpiry = .distantPast
    }

    private func ensureMinter(visitorData: String?) async throws {
        if minterExpiry > Date(), webView != nil { return }
        if let minterTask { return try await minterTask.value }
        let task = Task { try await self.makeMinter(visitorData: visitorData) }
        minterTask = task
        defer { minterTask = nil }
        try await task.value
    }

    private func makeMinter(visitorData: String?) async throws {
        try await loadPage()
        guard let webView else { throw PoTokenError.step("No web view") }

        // 1. The BotGuard challenge and its interpreter.
        let challenge = try await Self.fetchChallenge(visitorData: visitorData)
        let interpreter = try await Self.fetchText(challenge.interpreterURL)

        // 2. Run the program and take a snapshot; the page keeps the minter factory.
        let snapshot = try await webView.callAsyncJavaScript("""
            (0, eval)(interpreter);
            const vm = globalThis[globalName];
            if (!vm || !vm.a) throw new Error('BotGuard unavailable');
            let fns; const ready = new Promise(r => fns = r);
            vm.a(program, (a, b, c, d) => fns({ a, b, c, d }), true, undefined, () => {}, [[], []]);
            const f = await ready;
            window.__glintSignal = [];
            return await new Promise((resolve, reject) => {
                setTimeout(() => reject(new Error('BotGuard snapshot timed out')), 10000);
                f.a(resolve, [undefined, undefined, window.__glintSignal, undefined]);
            });
            """, arguments: ["interpreter": interpreter, "program": challenge.program, "globalName": challenge.globalName],
            in: nil, contentWorld: .page)
        guard let botguardResponse = snapshot as? String, !botguardResponse.isEmpty else {
            throw PoTokenError.step("BotGuard gave no snapshot")
        }

        // 3. Integrity token.
        let (integrityToken, ttl) = try await Self.generateIT(botguardResponse)

        // 4. The minter.
        _ = try await webView.callAsyncJavaScript("""
            const b64 = it.replace(/-/g, '+').replace(/_/g, '/').replace(/\\./g, '=');
            const bytes = Uint8Array.from(atob(b64), c => c.charCodeAt(0));
            const getMinter = window.__glintSignal && window.__glintSignal[0];
            if (!getMinter) throw new Error('No minter factory');
            const mint = await getMinter(bytes);
            if (typeof mint !== 'function') throw new Error('Minter unavailable');
            window.__glintMint = mint;
            return true;
            """, arguments: ["it": integrityToken], in: nil, contentWorld: .page)

        let lifetime = min(ttl > 0 ? ttl : Self.maxLifetime, Self.maxLifetime) - 5 * 60
        minterExpiry = Date().addingTimeInterval(max(lifetime, 60))
        tokens = [:]
    }

    // MARK: Web view

    private func loadPage() async throws {
        if webView != nil { return }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = .all
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        wv.customUserAgent = ClientProfile.web.userAgent
        wv.navigationDelegate = self
        wv.isUserInteractionEnabled = false
        wv.alpha = 0.01
        // In a window so timers aren't throttled; 1×1 and practically transparent.
        if let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first {
            window.insertSubview(wv, at: 0)
        }
        webView = wv
        do {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                pageLoaded = c
                // A blank page with youtube.com as its origin, like the providers' fake DOM.
                wv.loadHTMLString("<!DOCTYPE html><html lang=\"en\"><head><title></title></head><body></body></html>",
                                  baseURL: URL(string: "https://www.youtube.com/"))
            }
        } catch {
            wv.removeFromSuperview()
            webView = nil
            throw error
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded?.resume()
        pageLoaded = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        pageLoaded?.resume(throwing: error)
        pageLoaded = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        pageLoaded?.resume(throwing: error)
        pageLoaded = nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The minter lived in that process.
        self.webView?.removeFromSuperview()
        self.webView = nil
        reset()
    }

    // MARK: Network

    private struct Challenge {
        var program: String
        var globalName: String
        var interpreterURL: URL
    }

    private static var session: URLSession { InnerTube.shared.session }

    private static func fetchChallenge(visitorData: String?) async throws -> Challenge {
        var req = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/att/get?prettyPrint=false")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(ClientProfile.web.userAgent, forHTTPHeaderField: "User-Agent")
        var client: [String: Any] = ["clientName": ClientProfile.web.clientName,
                                     "clientVersion": ClientProfile.web.clientVersion,
                                     "hl": "en", "gl": "US"]
        if let visitorData {
            client["visitorData"] = visitorData
            req.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "context": ["client": client],
            "engagementType": "ENGAGEMENT_TYPE_UNBOUND",
        ])
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw PoTokenError.step("Challenge request failed (\(code))") }
        let c = try JSON.parse(data)["bgChallenge"]
        guard let program = c["program"].string, let globalName = c["globalName"].string,
              let path = c.at("interpreterUrl.privateDoNotAccessOrElseTrustedResourceUrlWrappedValue").string,
              let url = URL(string: path.hasPrefix("//") ? "https:" + path : path)
        else { throw PoTokenError.step("No BotGuard challenge") }
        return Challenge(program: program, globalName: globalName, interpreterURL: url)
    }

    private static func generateIT(_ botguardResponse: String) async throws -> (String, TimeInterval) {
        var req = URLRequest(url: URL(string: jnn + "GenerateIT")!)
        req.httpMethod = "POST"
        req.setValue("application/json+protobuf", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
        req.setValue("grpc-web-javascript/0.1", forHTTPHeaderField: "X-User-Agent")
        req.setValue(ClientProfile.web.userAgent, forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: [requestKey, botguardResponse])
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw PoTokenError.step("Integrity token request failed (\(code))") }
        let j = try JSON.parse(data)
        guard let token = j[0].string, !token.isEmpty else { throw PoTokenError.step("No integrity token") }
        return (token, TimeInterval(j[1].int ?? 0))
    }

    private static func fetchText(_ url: URL) async throws -> String {
        var req = URLRequest(url: url)
        req.setValue(ClientProfile.web.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw PoTokenError.step("Interpreter download failed (\(code))") }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Content binding

    /// yt-dlp binds unauthenticated GVS tokens to the visitor id: the 11 characters at
    /// bytes 2…12 of the (base64url protobuf) visitor data. Falls back to the visitor data.
    nonisolated static func contentBinding(visitorData: String) -> String {
        var s = (visitorData.removingPercentEncoding ?? visitorData)
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        if let d = Data(base64Encoded: s), d.count >= 13,
           let id = String(data: d.subdata(in: 2..<13), encoding: .ascii),
           id.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil {
            return id
        }
        return visitorData
    }
}
