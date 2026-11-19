import Foundation
import JavaScriptCore

/// Web clients (MWEB, …) get stream links that only work once two challenges from YouTube's
/// player JavaScript are solved: the `s` signature of a `signatureCipher`, and the `n`
/// parameter (left unsolved, YouTube throttles or refuses the stream).
///
/// This runs yt-dlp's own challenge solver (EJS, github.com/yt-dlp/ejs, bundled in
/// Resources/JS: `yt.solver.lib.min.js` = meriyah + astring, `yt.solver.core.js`) in
/// JavaScriptCore against the current player script, exactly as yt-dlp does with deno/node.
final class JSChallengeSolver: @unchecked Sendable {
    static let shared = JSChallengeSolver()

    struct Player: Sendable {
        var id: String
        /// `signatureTimestamp`: tells the player API which player version the links are for.
        var sts: Int
        var code: String
    }

    struct Solutions: Sendable {
        var n: [String: String] = [:]
        var sig: [String: String] = [:]
    }

    enum SolverError: LocalizedError {
        case noPlayer, script(String)
        var errorDescription: String? {
            switch self {
            case .noPlayer: return "Couldn't load YouTube's player script."
            case .script(let m): return "Challenge solver: \(m)"
            }
        }
    }

    private let queue = DispatchQueue(label: "com.glint.jsc", qos: .userInitiated)
    private var context: JSContext?            // queue only
    private var preprocessed: [String: String] = [:]  // player id → EJS preprocessed player (queue only)

    private let lock = NSLock()
    private var current: (player: Player, at: Date)?
    private var loading: Task<Player, Error>?
    private let playerLifetime: TimeInterval = 6 * 60 * 60

    // MARK: Player script

    /// The current player script (cached in memory for a few hours and on disk by id).
    func player(session: URLSession) async throws -> Player {
        let task: Task<Player, Error>? = lock.withLock {
            if let c = current, Date().timeIntervalSince(c.at) < playerLifetime { return nil }
            if let loading { return loading }
            let t = Task { try await Self.fetchPlayer(session: session) }
            loading = t
            return t
        }
        guard let task else {
            if let p = lock.withLock({ current?.player }) { return p }
            return try await player(session: session)
        }
        do {
            let p = try await task.value
            lock.withLock {
                current = (p, Date())
                loading = nil
            }
            return p
        } catch {
            lock.withLock { loading = nil }
            throw error
        }
    }

    private static func fetchPlayer(session: URLSession) async throws -> Player {
        // Same source yt-dlp uses for the current player version.
        let iframe = try await text(URL(string: "https://www.youtube.com/iframe_api")!, session: session)
        guard let id = firstMatch(#"player\\?/([0-9a-fA-F]{8})\\?/"#, in: iframe) else { throw SolverError.noPlayer }

        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("player-js", isDirectory: true)
        let file = cacheDir.appendingPathComponent("\(id).js")
        let code: String
        if let cached = try? String(contentsOf: file, encoding: .utf8), cached.count > 100_000 {
            code = cached
        } else {
            code = try await text(URL(string: "https://www.youtube.com/s/player/\(id)/player_ias.vflset/en_US/base.js")!, session: session)
            try? FileManager.default.removeItem(at: cacheDir)   // keep only the current player
            try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            try? code.write(to: file, atomically: true, encoding: .utf8)
        }
        guard let sts = firstMatch(#"(?:signatureTimestamp|sts)\s*:\s*([0-9]{5})"#, in: code).flatMap({ Int($0) })
        else { throw SolverError.noPlayer }
        return Player(id: id, sts: sts, code: code)
    }

    private static func preprocessedFile(_ id: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("player-js", isDirectory: true)
            .appendingPathComponent("\(id).preprocessed.js")
    }

    /// Loads the player script and does the first (slow) solve ahead of time.
    func prewarm(session: URLSession) async {
        guard let p = try? await player(session: session) else { return }
        _ = try? await solve(n: ["glintPrewarm0123"], sig: [], player: p)
    }

    private static func text(_ url: URL, session: URLSession) async throws -> String {
        var req = URLRequest(url: url)
        req.setValue(ClientProfile.web.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw InnerTubeError.http(code) }
        return String(decoding: data, as: UTF8.self)
    }

    private static func firstMatch(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    // MARK: Solving

    func solve(n: [String], sig: [String], player: Player) async throws -> Solutions {
        let n = Array(Set(n)), sig = Array(Set(sig))
        if n.isEmpty && sig.isEmpty { return Solutions() }
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                cont.resume(with: Result { try self.solveOnQueue(n: n, sig: sig, player: player) })
            }
        }
    }

    private func solveOnQueue(n: [String], sig: [String], player: Player) throws -> Solutions {
        let ctx = try loadedContext()
        var requests: [[String: Any]] = []
        if !n.isEmpty { requests.append(["type": "n", "challenges": n]) }
        if !sig.isEmpty { requests.append(["type": "sig", "challenges": sig]) }

        var input: [String: Any] = ["requests": requests]
        if preprocessed[player.id] == nil, let saved = try? String(contentsOf: Self.preprocessedFile(player.id), encoding: .utf8),
           saved.count > 100_000 {
            preprocessed = [player.id: saved]
        }
        if let pre = preprocessed[player.id] {
            input["type"] = "preprocessed"
            input["preprocessed_player"] = pre
        } else {
            input["type"] = "player"
            input["player"] = player.code
            input["output_preprocessed"] = true
        }
        let inputJSON = String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)

        ctx.exception = nil
        ctx.setObject(inputJSON, forKeyedSubscript: "__glintInput" as NSString)
        let out = ctx.evaluateScript("JSON.stringify(jsc(JSON.parse(__glintInput)))")
        ctx.setObject(nil, forKeyedSubscript: "__glintInput" as NSString)
        if let e = ctx.exception { throw SolverError.script(e.toString() ?? "exception") }
        guard let text = out?.toString(), let data = text.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SolverError.script("no output")
        }
        if obj["type"] as? String == "error" { throw SolverError.script(obj["error"] as? String ?? "error") }
        if let pre = obj["preprocessed_player"] as? String {
            preprocessed = [player.id: pre]   // one player at a time
            // Saved next to the player script (cleared with it when YouTube ships a new one):
            // later launches skip the slow first parse.
            try? pre.write(to: Self.preprocessedFile(player.id), atomically: true, encoding: .utf8)
        }

        var result = Solutions()
        let responses = obj["responses"] as? [[String: Any]] ?? []
        for (req, resp) in zip(requests, responses) where resp["type"] as? String == "result" {
            let data = resp["data"] as? [String: String] ?? [:]
            if req["type"] as? String == "n" { result.n = data } else { result.sig = data }
        }
        return result
    }

    private func loadedContext() throws -> JSContext {
        if let context { return context }
        let ctx: JSContext = JSContext()
        guard let libURL = Bundle.main.url(forResource: "yt.solver.lib.min", withExtension: "js"),
              let coreURL = Bundle.main.url(forResource: "yt.solver.core", withExtension: "js"),
              let lib = try? String(contentsOf: libURL, encoding: .utf8),
              let core = try? String(contentsOf: coreURL, encoding: .utf8)
        else { throw SolverError.script("solver scripts missing") }
        ctx.name = "Glint challenge solver"
        ctx.evaluateScript(lib + "\nObject.assign(globalThis, lib);\n" + core + "\nglobalThis.jsc = jsc;")
        if let e = ctx.exception { throw SolverError.script(e.toString() ?? "load failed") }
        context = ctx
        return ctx
    }
}
