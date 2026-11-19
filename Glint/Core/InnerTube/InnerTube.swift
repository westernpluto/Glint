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
        set { lock.lock(); _auth = newValue; lock.unlock() }
    }

    var visitorData: String? {
        get { lock.lock(); defer { lock.unlock() }; return _visitorData }
        set { lock.lock(); _visitorData = newValue; lock.unlock() }
    }

    var isSignedIn: Bool { auth?.isValid == true }

    /// POST `youtubei/v1/<endpoint>` with the given client.
    func call(_ endpoint: String,
              client: ClientProfile = .web,
              body: [String: Any],
              authenticated: Bool = true) async throws -> JSON {
        var url = URLComponents(string: "https://\(client.host)/youtubei/v1/\(endpoint)")!
        url.queryItems = [URLQueryItem(name: "prettyPrint", value: "false")]
        var req = URLRequest(url: url.url!)
        req.httpMethod = "POST"

        var payload = body
        payload["context"] = client.context(visitorData: visitorData, hl: hl, gl: gl)
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(String(client.clientId), forHTTPHeaderField: "X-YouTube-Client-Name")
        req.setValue(client.clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        req.setValue(client.origin, forHTTPHeaderField: "Origin")
        req.setValue(client.origin, forHTTPHeaderField: "X-Origin")
        if let v = visitorData { req.setValue(v, forHTTPHeaderField: "X-Goog-Visitor-Id") }

        // Cookie auth only works for the browser clients.
        let browserClient = client.clientName.hasPrefix("WEB")
        if authenticated, browserClient, let auth, auth.isValid {
            req.setValue(auth.cookieHeader(forHost: client.host), forHTTPHeaderField: "Cookie")
            if let a = auth.authorization(origin: client.origin) {
                req.setValue(a, forHTTPHeaderField: "Authorization")
            }
            req.setValue(String(auth.authUser), forHTTPHeaderField: "X-Goog-AuthUser")
            if let p = auth.pageId { req.setValue(p, forHTTPHeaderField: "X-Goog-PageId") }
        }

        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw InnerTubeError.http(code) }
        let json = try JSON.parse(data)
        if visitorData == nil, let v = json.at("responseContext.visitorData").string {
            visitorData = v
        }
        return json
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
