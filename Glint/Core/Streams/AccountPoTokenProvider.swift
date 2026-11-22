import Foundation
import UIKit
import WebKit

/// Signed in: stream tokens minted inside a real, signed-in youtube.com page.
///
/// Since November 2026 YouTube's stream protection holds signed-in SABR streams at
/// "pending" for tokens from `PoTokenProvider` (a blank page with no cookies and an
/// anonymous BotGuard challenge). This loads youtube.com in a hidden web view with the
/// account's cookies, takes the visitor data and data sync id from that page's `ytcfg`
/// (what yt-dlp reads from the signed-in page), fetches the BotGuard challenge from inside
/// the page with the session attached, and mints there — as close to the website as Glint
/// gets. Anything that fails returns nil and the usual tokens are used.
@MainActor
final class AccountPoTokenProvider: NSObject, WKNavigationDelegate {
    static let shared = AccountPoTokenProvider()

    /// What the signed-in page says about this session.
    struct Session: Sendable, Equatable {
        var visitorData: String
        var dataSyncId: String?
    }

    enum PageError: LocalizedError {
        case step(String)
        var errorDescription: String? { if case .step(let s) = self { return s }; return nil }
    }

    private var webView: WKWebView?
    private var pageLoaded: CheckedContinuation<Void, Error>?
    private var session: Session?
    private var account: AuthContext?
    private var minterExpiry = Date.distantPast
    private var building: Task<Session, Error>?
    private var tokens: [String: (token: String, expires: Date)] = [:]
    /// After a failure, don't reload the page on every video.
    private var failedAt = Date.distantPast
    private(set) var lastError: String?

    /// The signed-in page's session (building the page and minter if needed), or nil.
    func currentSession() async -> Session? {
        guard let auth = InnerTube.shared.auth, auth.isValid else { return nil }
        if let session, account == auth, minterExpiry > Date(), webView != nil { return session }
        if Date().timeIntervalSince(failedAt) < 10 * 60 { return nil }
        if let building { return try? await building.value }
        let task = Task { try await self.build(auth) }
        building = task
        defer { building = nil }
        do {
            return try await task.value
        } catch {
            lastError = error.localizedDescription
            failedAt = Date()
            teardown()
            return nil
        }
    }

    /// A token for `binding` minted in the signed-in page (`fresh` skips the cache).
    func token(for binding: String, fresh: Bool = false) async -> String? {
        guard await currentSession() != nil, let webView else { return nil }
        if !fresh, let t = tokens[binding], t.expires > Date() { return t.token }
        let value = try? await webView.callAsyncJavaScript("""
            const r = await window.__glintMint(new TextEncoder().encode(binding));
            if (!(r instanceof Uint8Array)) throw new Error('mint returned ' + typeof r);
            let s = ''; for (const b of r) s += String.fromCharCode(b);
            return btoa(s).replace(/\\+/g, '-').replace(/\\//g, '_');
            """, arguments: ["binding": binding], in: nil, contentWorld: .page)
        guard let token = value as? String, !token.isEmpty else { return nil }
        tokens[binding] = (token, minterExpiry)
        return token
    }

    func reset() {
        teardown()
        failedAt = .distantPast
    }

    private func teardown() {
        webView?.removeFromSuperview()
        webView = nil
        session = nil
        account = nil
        tokens = [:]
        minterExpiry = .distantPast
    }

    // MARK: Building

    private func build(_ auth: AuthContext) async throws -> Session {
        teardown()
        let wv = try await loadSignedInPage(auth)

        // 1. The page's own session data.
        let cfg = try await wv.callAsyncJavaScript("""
            const c = window.ytcfg;
            if (!c || !c.get) throw new Error('No ytcfg on the page');
            return JSON.stringify({
                visitor: c.get('VISITOR_DATA') || (c.get('INNERTUBE_CONTEXT') || {}).client?.visitorData || null,
                datasync: c.get('DATASYNC_ID') || null,
                loggedIn: !!c.get('LOGGED_IN'),
            });
            """, arguments: [:], in: nil, contentWorld: .page) as? String
        guard let cfgData = cfg?.data(using: .utf8),
              let info = try? JSONSerialization.jsonObject(with: cfgData) as? [String: Any],
              let visitor = info["visitor"] as? String, !visitor.isEmpty
        else { throw PageError.step("The signed-in page had no visitor data") }
        guard info["loggedIn"] as? Bool == true else { throw PageError.step("The page isn't signed in") }
        let datasync = info["datasync"] as? String

        // 2. The BotGuard challenge, asked for from inside the page with the session attached.
        let authHeader = auth.authorization(origin: "https://www.youtube.com") ?? ""
        let challengeText = try await wv.callAsyncJavaScript("""
            const c = window.ytcfg;
            const r = await fetch('/youtubei/v1/att/get?prettyPrint=false', {
                method: 'POST', credentials: 'include',
                headers: {
                    'Content-Type': 'application/json',
                    'X-Goog-Visitor-Id': c.get('VISITOR_DATA') || '',
                    'X-Youtube-Client-Name': String(c.get('INNERTUBE_CONTEXT_CLIENT_NAME') || 1),
                    'X-Youtube-Client-Version': c.get('INNERTUBE_CONTEXT_CLIENT_VERSION') || '',
                    'X-Goog-AuthUser': authUser,
                    'X-Origin': location.origin,
                    'Authorization': authorization,
                },
                body: JSON.stringify({ context: c.get('INNERTUBE_CONTEXT'), engagementType: 'ENGAGEMENT_TYPE_UNBOUND' }),
            });
            if (!r.ok) throw new Error('att/get ' + r.status);
            const j = await r.json();
            if (!j.bgChallenge) throw new Error('No bgChallenge');
            return JSON.stringify(j.bgChallenge);
            """, arguments: ["authorization": authHeader, "authUser": String(auth.authUser)],
            in: nil, contentWorld: .page) as? String
        guard let challengeData = challengeText?.data(using: .utf8),
              let ch = try? JSON.parse(challengeData),
              let program = ch["program"].string, let globalName = ch["globalName"].string,
              let path = ch.at("interpreterUrl.privateDoNotAccessOrElseTrustedResourceUrlWrappedValue").string,
              let interpreterURL = URL(string: path.hasPrefix("//") ? "https:" + path : path)
        else { throw PageError.step("No BotGuard challenge from the signed-in page") }
        var ireq = URLRequest(url: interpreterURL)
        ireq.setValue(ClientProfile.web.userAgent, forHTTPHeaderField: "User-Agent")
        let (idata, _) = try await InnerTube.shared.session.data(for: ireq)
        let interpreter = String(decoding: idata, as: UTF8.self)

        // 3. Run it, trade the snapshot for an integrity token (from the page, as the site
        //    does), and keep the minter.
        let lifetime = try await wv.callAsyncJavaScript("""
            (0, eval)(interpreter);
            const vm = globalThis[globalName];
            if (!vm || !vm.a) throw new Error('BotGuard unavailable');
            let fns; const ready = new Promise(r => fns = r);
            vm.a(program, (a, b, c, d) => fns({ a, b, c, d }), true, undefined, () => {}, [[], []]);
            const f = await ready;
            const signal = [];
            const snapshot = await new Promise((resolve, reject) => {
                setTimeout(() => reject(new Error('BotGuard snapshot timed out')), 10000);
                f.a(resolve, [undefined, undefined, signal, undefined]);
            });
            const r = await fetch(jnn + 'GenerateIT', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json+protobuf', 'x-goog-api-key': apiKey,
                           'x-user-agent': 'grpc-web-javascript/0.1' },
                body: JSON.stringify([requestKey, snapshot]),
            });
            if (!r.ok) throw new Error('GenerateIT ' + r.status);
            const it = await r.json();
            if (!it[0]) throw new Error('No integrity token');
            const b64 = it[0].replace(/-/g, '+').replace(/_/g, '/').replace(/\\./g, '=');
            const bytes = Uint8Array.from(atob(b64), c => c.charCodeAt(0));
            if (!signal[0]) throw new Error('No minter factory');
            const mint = await signal[0](bytes);
            if (typeof mint !== 'function') throw new Error('Minter unavailable');
            window.__glintMint = mint;
            return it[1] || 0;
            """, arguments: ["interpreter": interpreter, "program": program, "globalName": globalName,
                             "jnn": PoTokenProvider.jnn, "apiKey": PoTokenProvider.apiKey,
                             "requestKey": PoTokenProvider.requestKey],
            in: nil, contentWorld: .page)
        let ttl = (lifetime as? NSNumber)?.doubleValue ?? 0
        minterExpiry = Date().addingTimeInterval(max(min(ttl > 0 ? ttl : 6 * 3600, 6 * 3600) - 300, 60))
        let s = Session(visitorData: visitor, dataSyncId: datasync)
        session = s
        account = auth
        lastError = nil
        return s
    }

    private func loadSignedInPage(_ auth: AuthContext) async throws -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = .all
        let store = config.websiteDataStore.httpCookieStore
        for c in auth.cookies {
            var props: [HTTPCookiePropertyKey: Any] = [
                .name: c.name, .value: c.value, .domain: c.domain, .path: c.path.isEmpty ? "/" : c.path,
            ]
            if let e = c.expires { props[.expires] = e }
            if c.name.hasPrefix("__Secure-") || c.name.hasPrefix("__Host-") || c.name.contains("SID") { props[.secure] = "TRUE" }
            if let cookie = HTTPCookie(properties: props) { await store.setCookie(cookie) }
        }
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        wv.customUserAgent = ClientProfile.web.userAgent
        wv.navigationDelegate = self
        wv.isUserInteractionEnabled = false
        wv.alpha = 0.01
        if let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first {
            window.insertSubview(wv, at: 0)
        }
        webView = wv
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            pageLoaded = c
            // A light signed-in page that still carries the full ytcfg.
            wv.load(URLRequest(url: URL(string: "https://www.youtube.com/feed/you")!))
        }
        return wv
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
        teardown()
    }
}
