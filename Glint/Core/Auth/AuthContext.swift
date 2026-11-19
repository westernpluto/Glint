import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// The cookies of one signed-in Google account, as captured from the sign-in web view.
struct StoredCookie: Codable, Hashable {
    var name: String
    var value: String
    var domain: String
    var path: String
    var expires: Date?
}

struct AuthContext: Hashable {
    var cookies: [StoredCookie]
    /// Index of the YouTube channel/brand account within the Google session.
    var authUser: Int = 0
    var pageId: String?

    func cookieHeader(forHost host: String) -> String {
        let h = host.lowercased()
        var seen = Set<String>()
        var parts: [String] = []
        // Prefer the most specific domain for duplicate names.
        let sorted = cookies.sorted { $0.domain.count > $1.domain.count }
        for c in sorted {
            let d = c.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard h == d || h.hasSuffix("." + d) else { continue }
            if let e = c.expires, e < Date() { continue }
            if seen.insert(c.name).inserted { parts.append("\(c.name)=\(c.value)") }
        }
        return parts.joined(separator: "; ")
    }

    private func value(_ name: String) -> String? {
        cookies.first { $0.name == name && ($0.domain.contains("youtube.com")) }?.value
            ?? cookies.first { $0.name == name }?.value
    }

    /// Applies `Set-Cookie` updates (Google rotates session cookies). Returns true if anything changed.
    mutating func merge(_ updates: [StoredCookie]) -> Bool {
        var changed = false
        for u in updates {
            let d = u.domain.lowercased()
            guard d.contains("youtube.com") || d.contains("google.com") else { continue }
            if let i = cookies.firstIndex(where: { $0.name == u.name && $0.domain.lowercased() == d && $0.path == u.path }) {
                if cookies[i].value != u.value || cookies[i].expires != u.expires {
                    cookies[i] = u
                    changed = true
                }
            } else {
                cookies.append(u)
                changed = true
            }
        }
        // Drop cookies the server expired (but never the core session identifiers).
        let now = Date()
        let before = cookies.count
        cookies.removeAll { c in
            guard let e = c.expires, e < now else { return false }
            return !["SAPISID", "__Secure-1PAPISID", "__Secure-3PAPISID", "SID", "HSID", "SSID"].contains(c.name)
        }
        return changed || cookies.count != before
    }

    var isValid: Bool { value("SAPISID") != nil || value("__Secure-3PAPISID") != nil }

    /// `Authorization` header expected by InnerTube for cookie sessions.
    func authorization(origin: String, now: Date = Date()) -> String? {
        let ts = String(Int(now.timeIntervalSince1970))
        var parts: [String] = []
        if let s = value("SAPISID") ?? value("__Secure-3PAPISID") {
            parts.append("SAPISIDHASH \(ts)_\(Hashing.sha1Hex("\(ts) \(s) \(origin)"))")
        }
        if let s = value("__Secure-1PAPISID") {
            parts.append("SAPISID1PHASH \(ts)_\(Hashing.sha1Hex("\(ts) \(s) \(origin)"))")
        }
        if let s = value("__Secure-3PAPISID") {
            parts.append("SAPISID3PHASH \(ts)_\(Hashing.sha1Hex("\(ts) \(s) \(origin)"))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

enum Hashing {
    static func sha1Hex(_ s: String) -> String {
        #if canImport(CryptoKit)
        return Insecure.SHA1.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
        #else
        return ""
        #endif
    }

    static func sha256Hex(_ s: String) -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
        #else
        return ""
        #endif
    }
}
