import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum InnerTubeError: LocalizedError, Equatable {
    case http(Int)
    case unplayable(String)
    case notSignedIn
    case empty

    var errorDescription: String? {
        switch self {
        case .http(let code): return "YouTube returned an error (\(code))."
        case .unplayable(let reason): return reason
        case .notSignedIn: return "Sign in to see this."
        case .empty: return "Nothing here yet."
        }
    }
}

/// Low-level InnerTube transport. Thread safe.
final class InnerTube: @unchecked Sendable {
    static let shared = InnerTube()

    private let lock = NSLock()
    private var _auth: AuthContext?
    private var _visitorData: String?

    var hl: String = Locale.current.language.languageCode?.identifier ?? "en"
    var gl: String = Locale.current.region?.identifier ?? "US"

    let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.timeoutIntervalForRequest = 20
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    var auth: AuthContext? {
        get { lock.lock(); defer { lock.unlock() }; return _auth }
        set { lock.lock(); _auth = newValue; _dataSyncId = nil; _accountVisitorData = nil; lock.unlock() }
    }

    /// The signed-in session's visitor id (from signed-in responses).
    private var _accountVisitorData: String?
    var accountVisitorData: String? { lock.withLock { _accountVisitorData } }

    /// The visitor id to mint stream tokens for and send with signed-in requests: the
    /// account's when signed in (fetched with one light request if needed), else the anonymous one.
    func streamVisitorData(signedIn: Bool) async -> String? {
        guard signedIn, isSignedIn else { return visitorData }
        if accountVisitorData == nil { _ = await ensureDataSyncId() }
        if accountVisitorData == nil { _ = try? await call("account/account_menu", client: .web, body: [:]) }
        return accountVisitorData ?? visitorData
    }

    /// The signed-in account's data sync id (`responseContext.mainAppWebResponseContext.datasyncId`),
    /// from any signed-in response. Signed in, stream tokens must be bound to it.
    private var _dataSyncId: String?
    var dataSyncId: String? { lock.withLock { _dataSyncId } }

    /// The data sync id, asking for it (one light signed-in request) if no response carried it yet.
    func ensureDataSyncId() async -> String? {
        if let id = dataSyncId { return id }
        guard isSignedIn else { return nil }
        _ = try? await call("account/account_menu", client: .web, body: [:])
        if let id = dataSyncId { return id }
        _ = try? await call("browse", client: .web, body: ["browseId": "FEwhat_to_watch"])
        return dataSyncId
    }

    var visitorData: String? {
        get { lock.lock(); defer { lock.unlock() }; return _visitorData }
        set { lock.lock(); _visitorData = newValue; lock.unlock() }
    }

    var isSignedIn: Bool { auth?.isValid == true }

    /// Called (off the main thread) when the server rotated the signed-in session's cookies.
    var onAuthCookiesChanged: (@Sendable (AuthContext) -> Void)?

    /// POST `youtubei/v1/<endpoint>` with the given client.
    func call(_ endpoint: String,
              client: ClientProfile = .web,
              body: [String: Any],
              authenticated: Bool = true) async throws -> JSON {
        var url = URLComponents(string: "https://\(client.host)/youtubei/v1/\(endpoint)")!
        url.queryItems = [URLQueryItem(name: "prettyPrint", value: "false")]
        var req = URLRequest(url: url.url!)
        req.httpMethod = "POST"

        // Cookie auth only works for the browser clients.
        let browserClient = client.clientName.hasPrefix("WEB") || client.clientName == "MWEB"
        let usedAuth = (authenticated && browserClient) ? auth : nil
        // Signed in: the account's own visitor id (the one its cookies belong to), not the
        // anonymous one; a mismatch leaves YouTube's stream protection "pending" forever.
        let visitor = usedAuth?.isValid == true ? (accountVisitorData ?? visitorData) : visitorData

        var payload = body
        payload["context"] = client.context(visitorData: visitor, hl: hl, gl: gl)
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(String(client.clientId), forHTTPHeaderField: "X-YouTube-Client-Name")
        req.setValue(client.clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        req.setValue(client.origin, forHTTPHeaderField: "Origin")
        req.setValue(client.origin, forHTTPHeaderField: "X-Origin")
        if let v = visitor { req.setValue(v, forHTTPHeaderField: "X-Goog-Visitor-Id") }

        if let auth = usedAuth, auth.isValid {
            req.setValue(auth.cookieHeader(forHost: client.host), forHTTPHeaderField: "Cookie")
            if let a = auth.authorization(origin: client.origin) {
                req.setValue(a, forHTTPHeaderField: "Authorization")
            }
            req.setValue(String(auth.authUser), forHTTPHeaderField: "X-Goog-AuthUser")
            if let p = auth.pageId { req.setValue(p, forHTTPHeaderField: "X-Goog-PageId") }
        }

        let (data, resp) = try await session.data(for: req)
        if let used = usedAuth, let http = resp as? HTTPURLResponse { absorbCookies(http, url: req.url!, used: used) }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw InnerTubeError.http(code) }
        let json = try JSON.parse(data)
        if visitorData == nil, let v = json.at("responseContext.visitorData").string {
            visitorData = v
        }
        if let used = usedAuth, let id = json.at("responseContext.mainAppWebResponseContext.datasyncId").string, !id.isEmpty {
            lock.withLock { if _auth == used { _dataSyncId = id } }
        }
        if let used = usedAuth, used.isValid, let v = json.at("responseContext.visitorData").string, !v.isEmpty {
            lock.withLock { if _auth == used, _accountVisitorData == nil { _accountVisitorData = v } }
        }
        return json
    }

    private func absorbCookies(_ http: HTTPURLResponse, url: URL, used: AuthContext) {
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let k = k as? String, let v = v as? String { headers[k] = v }
        }
        guard headers.keys.contains(where: { $0.lowercased() == "set-cookie" }) else { return }
        let updates = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url).map {
            StoredCookie(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path, expires: $0.expiresDate)
        }
        guard !updates.isEmpty else { return }
        let merged: AuthContext? = lock.withLock {
            // Ignore if the user switched accounts while this request was in flight.
            guard var current = _auth, current == used else { return nil }
            guard current.merge(updates) else { return nil }
            _auth = current
            return current
        }
        if let merged { onAuthCookiesChanged?(merged) }
    }

    /// Fetches a fresh visitor id so logged-out requests look like a normal browser.
    func warmUp() async {
        guard visitorData == nil else { return }
        _ = try? await call("visitor_id", body: [:], authenticated: false)
        if visitorData == nil {
            _ = try? await call("browse", body: ["browseId": "FEwhat_to_watch"], authenticated: false)
        }
    }
}
