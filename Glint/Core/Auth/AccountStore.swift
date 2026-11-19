import Foundation
import Observation
import Security

struct Account: Codable, Identifiable, Hashable {
    var id = UUID()
    var info: AccountInfo
    var cookies: [StoredCookie]
    var authUser: Int = 0

    var auth: AuthContext { AuthContext(cookies: cookies, authUser: authUser) }
}

/// Signed-in Google accounts. Cookies live in the Keychain, never in UserDefaults.
@MainActor
@Observable
final class AccountStore {
    static let shared = AccountStore()

    private(set) var accounts: [Account] = []
    private(set) var activeID: UUID?
    /// Bumped whenever the active identity changes so feeds can reload.
    private(set) var generation = 0

    var active: Account? { accounts.first { $0.id == activeID } }
    var isSignedIn: Bool { active != nil }

    private init() {
        accounts = Keychain.load()
        if let s = UserDefaults.standard.string(forKey: "activeAccount"), let id = UUID(uuidString: s),
           accounts.contains(where: { $0.id == id }) {
            activeID = id
        } else {
            activeID = accounts.first?.id
        }
        apply()
        InnerTube.shared.onAuthCookiesChanged = { auth in
            Task { @MainActor in AccountStore.shared.sessionRotated(auth) }
        }
    }

    /// Persists rotated cookies for the active account without reloading anything.
    private func sessionRotated(_ auth: AuthContext) {
        guard let i = accounts.firstIndex(where: { $0.id == activeID }) else { return }
        accounts[i].cookies = auth.cookies
        persist()
    }

    /// Adds (or refreshes) an account from freshly captured sign-in cookies.
    func add(cookies: [StoredCookie]) async throws {
        let auth = AuthContext(cookies: cookies)
        guard auth.isValid else { throw InnerTubeError.notSignedIn }

        let previous = InnerTube.shared.auth
        InnerTube.shared.auth = auth
        let info: AccountInfo
        do {
            info = try await YouTubeService.shared.accountInfo()
        } catch {
            InnerTube.shared.auth = previous
            throw error
        }

        if let i = accounts.firstIndex(where: { $0.info.name == info.name && $0.info.handle == info.handle }) {
            accounts[i].cookies = cookies
            accounts[i].info = info
            activeID = accounts[i].id
        } else {
            let a = Account(info: info, cookies: cookies)
            accounts.append(a)
            activeID = a.id
        }
        persist()
        apply()
    }

    func switchTo(_ id: UUID?) {
        activeID = id
        persist()
        apply()
    }

    func remove(_ id: UUID) {
        accounts.removeAll { $0.id == id }
        if activeID == id { activeID = accounts.first?.id }
        persist()
        apply()
    }

    /// Refreshes names/avatars (and detects expired sessions).
    func refreshActive() async {
        guard let a = active else { return }
        if let info = try? await YouTubeService.shared.accountInfo(),
           let i = accounts.firstIndex(where: { $0.id == a.id }) {
            accounts[i].info = info
            persist()
        }
    }

    private func apply() {
        InnerTube.shared.auth = active?.auth
        generation += 1
    }

    private func persist() {
        Keychain.save(accounts)
        UserDefaults.standard.set(activeID?.uuidString, forKey: "activeAccount")
    }
}

enum Keychain {
    private static let service = "com.glint.accounts"
    private static let key = "accounts.v1"

    static func load() -> [Account] {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return [] }
        return (try? JSONDecoder().decode([Account].self, from: data)) ?? []
    }

    static func save(_ accounts: [Account]) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(base as CFDictionary)
        guard !accounts.isEmpty, let data = try? JSONEncoder().encode(accounts) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}
