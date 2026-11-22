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
        /// The desktop web client version the page runs (for requests that pose as it).
        var clientVersion: String?
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

    override init() {
        super.init()
        // Never left running in the background: a long-lived youtube.com page renews the
        // sign-in cookies on its own, and the app holding the old ones then gets signed out.
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.syncCookiesBack(); self.teardown() }
            }
        }
    }

    /// Copies the page's YouTube / Google cookies into the app's sign-in.
    private func syncCookiesBack() async {
        guard let store = webView?.configuration.websiteDataStore.httpCookieStore else { return }
        let cookies = await store.allCookies()
        let updates = cookies.filter { $0.domain.contains("youtube.com") || $0.domain.contains("google.com") }
            .map { StoredCookie(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path, expires: $0.expiresDate) }
        InnerTube.shared.mergeCookies(updates)
    }

    /// Blocks the page's own sign-in cookie renewal (only the app's requests keep the session).
    private static func noRotationRules() async -> WKContentRuleList? {
        let rules = """
            [{"trigger":{"url-filter":"RotateCookies"},"action":{"type":"block"}},
             {"trigger":{"url-filter":"accounts\\.google\\.com/.*(CheckCookie|SetSID|SetOSID)"},"action":{"type":"block"}},
             {"trigger":{"url-filter":"accounts\\.youtube\\.com/"},"action":{"type":"block"}}]
            """
        return try? await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "glint-no-cookie-rotation", encodedContentRuleList: rules)
    }

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

    private(set) var lastPlayerError: String?

    /// The player response as the website gets it when you open a video: the page's own
    /// youtubei/v1/player request (its ytcfg context, cookies, SAPISIDHASH, a page-minted video
    /// token), else the one embedded in the fetched watch page. `sts` keeps the formats in
    /// step with Glint's challenge solver.
    func pagePlayerResponse(videoId: String, sts: Int?) async -> Data? {
        guard await currentSession() != nil, let webView, let auth = InnerTube.shared.auth else { return nil }
        lastPlayerError = nil
        defer { Task { await self.syncCookiesBack() } }
        do {
            let text = try await run("Player request", webView, """
                const c = window.ytcfg;
                const tok = await window.__glintMint(new TextEncoder().encode(id));
                let t = ''; for (const b of tok) t += String.fromCharCode(b);
                const potoken = btoa(t).replace(/\\+/g, '-').replace(/\\//g, '_');
                const body = {
                    context: c.get('INNERTUBE_CONTEXT'),
                    videoId: id, racyCheckOk: true, contentCheckOk: true,
                    playbackContext: { contentPlaybackContext: {
                        html5Preference: 'HTML5_PREF_WANTS',
                        signatureTimestamp: sts || c.get('STS'),
                    } },
                    serviceIntegrityDimensions: { poToken: potoken },
                };
                const r = await fetch('/youtubei/v1/player?prettyPrint=false', {
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
                    body: JSON.stringify(body),
                });
                if (!r.ok) throw new Error('player ' + r.status);
                return await r.text();
                """, ["id": videoId, "sts": sts ?? 0,
                      "authorization": auth.authorization(origin: "https://www.youtube.com") ?? "",
                      "authUser": String(auth.authUser)]) as? String
            if let text, !text.isEmpty { return text.data(using: .utf8) }
        } catch {
            lastPlayerError = error.localizedDescription
        }
        // Second try: the watch page's embedded player response.
        do {
            let text = try await run("Watch page", webView, """
                const r = await fetch('/watch?v=' + encodeURIComponent(id) + '&bpctr=9999999999&has_verified=1',
                                      { credentials: 'include' });
                if (!r.ok) throw new Error('watch page ' + r.status);
                const html = await r.text();
                const key = 'ytInitialPlayerResponse';
                let i = html.indexOf(key + ' = ');
                if (i < 0) i = html.indexOf(key + '=');
                if (i < 0) throw new Error('no ' + key + ' in ' + html.length + ' bytes');
                i = html.indexOf('{', i);
                let depth = 0, inStr = false, esc = false;
                for (let j = i; j < html.length; j++) {
                    const ch = html[j];
                    if (inStr) {
                        if (esc) esc = false; else if (ch === '\\\\') esc = true; else if (ch === '"') inStr = false;
                    } else if (ch === '"') inStr = true;
                    else if (ch === '{') depth++;
                    else if (ch === '}') { depth--; if (depth === 0) return html.slice(i, j + 1); }
                }
                throw new Error('unterminated player response');
                """, ["id": videoId]) as? String
            if let text { return text.data(using: .utf8) }
        } catch {
            lastPlayerError = [lastPlayerError, error.localizedDescription].compactMap { $0 }.joined(separator: "; ")
        }
        return nil
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

    /// Runs a step's script; failures say which step and carry WebKit's exception message
    /// (its error only says "A JavaScript exception occurred").
    private func run(_ step: String, _ wv: WKWebView, _ script: String, _ args: [String: Any] = [:]) async throws -> Any? {
        do {
            return try await wv.callAsyncJavaScript(script, arguments: args, in: nil, contentWorld: .page)
        } catch {
            let info = (error as NSError).userInfo
            let message = info["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
            let page = wv.url?.host.map { " on \($0)\(wv.url?.path ?? "")" } ?? ""
            throw PageError.step("\(step): \(message)\(page)")
        }
    }

    private func build(_ auth: AuthContext) async throws -> Session {
        teardown()
        let wv = try await loadSignedInPage(auth)

        // 1. The page's own session data (YouTube fills ytcfg in with script: wait for it).
        let cfg = try await run("Reading the page", wv, """
            for (let i = 0; i < 50; i++) {
                if (window.ytcfg && ytcfg.get && ytcfg.get('VISITOR_DATA')) break;
                await new Promise(r => setTimeout(r, 200));
            }
            const c = window.ytcfg;
            if (!c || !c.get) throw new Error('No ytcfg (page: ' + location.href + ')');
            return JSON.stringify({
                visitor: c.get('VISITOR_DATA') || (c.get('INNERTUBE_CONTEXT') || {}).client?.visitorData || null,
                datasync: c.get('DATASYNC_ID') || null,
                version: c.get('INNERTUBE_CONTEXT_CLIENT_VERSION') || null,
                loggedIn: !!c.get('LOGGED_IN'),
            });
            """) as? String
        guard let cfgData = cfg?.data(using: .utf8),
              let info = try? JSONSerialization.jsonObject(with: cfgData) as? [String: Any],
              let visitor = info["visitor"] as? String, !visitor.isEmpty
        else { throw PageError.step("The signed-in page had no visitor data") }
        guard info["loggedIn"] as? Bool == true else {
            throw PageError.step("The page isn't signed in (\(wv.url?.host ?? "?")\(wv.url?.path ?? ""))")
        }
        let datasync = info["datasync"] as? String

        // 2. The BotGuard challenge, asked for from inside the page with the session attached.
        let authHeader = auth.authorization(origin: "https://www.youtube.com") ?? ""
        let challengeText = try await run("BotGuard challenge", wv, """
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
            """, ["authorization": authHeader, "authUser": String(auth.authUser)]) as? String
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
        // The interpreter goes in through WebKit (global scope, outside the page's content
        // security policy, which can forbid eval()).
        do {
            _ = try await wv.evaluateJavaScript(interpreter + "\n;true", in: nil, contentWorld: .page)
        } catch {
            let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
            throw PageError.step("Loading BotGuard: \(message)")
        }
        let lifetime = try await run("Minting", wv, """
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
            """, ["program": program, "globalName": globalName,
                  "jnn": PoTokenProvider.jnn, "apiKey": PoTokenProvider.apiKey,
                  "requestKey": PoTokenProvider.requestKey])
        let ttl = (lifetime as? NSNumber)?.doubleValue ?? 0
        minterExpiry = Date().addingTimeInterval(max(min(ttl > 0 ? ttl : 6 * 3600, 6 * 3600) - 300, 60))
        await syncCookiesBack()
        let s = Session(visitorData: visitor, dataSyncId: datasync, clientVersion: info["version"] as? String)
        session = s
        account = auth
        lastError = nil
        return s
    }

    private func loadSignedInPage(_ auth: AuthContext) async throws -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = .all
        guard let rules = await Self.noRotationRules() else {
            throw PageError.step("Couldn't set up cookie protection")   // never without it
        }
        config.userContentController.add(rules)
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
