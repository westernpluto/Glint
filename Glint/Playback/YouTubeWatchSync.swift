import Foundation
import UIKit

/// The playback-tracking URLs of an authenticated player response.
struct PlaybackTracking: Sendable, Hashable {
    var playback: URL     // videostatsPlaybackUrl: "started watching" (adds to history)
    var watchtime: URL    // videostatsWatchtimeUrl: watched ranges + position (resume point)

    init?(_ json: JSON) {
        guard let p = json.at("playbackTracking.videostatsPlaybackUrl.baseUrl").string.flatMap(URL.init(string:)),
              let w = json.at("playbackTracking.videostatsWatchtimeUrl.baseUrl").string.flatMap(URL.init(string:))
        else { return nil }
        playback = p
        watchtime = w
    }
}

/// Reports what you watch in Glint to your YouTube account, like the website does: one
/// "playback" ping when a video starts (it lands in your history), then "watchtime" pings
/// with the ranges watched and the current position (the resume point on your other devices).
/// Only for streams whose player request carried the account (signed-in web clients).
/// Parameters as in yt-dlp's `--mark-watched` and the web player.
@MainActor
final class YouTubeWatchSync {
    static let shared = YouTubeWatchSync()

    /// One line per noteworthy event (Playback info).
    var trace: ((String) -> Void)?

    private var videoId: String?
    private var tracking: PlaybackTracking?
    private var cpn = ""
    private var started = Date()
    private var sentPlayback = false
    private var segmentStart: Double = 0
    private var lastPosition: Double = 0
    private var lastPing = Date.distantPast
    private var reportedOK = false
    private var lastSent: (position: Double, playing: Bool)?
    private var lastFailureNote = Date.distantPast

    /// A stream is about to play. Same video again (refresh, quality change) keeps the session.
    func begin(videoId: String, tracking: PlaybackTracking?, at position: Double) {
        if videoId == self.videoId {
            if let tracking { self.tracking = tracking }
            return
        }
        self.videoId = videoId
        self.tracking = tracking
        cpn = Self.makeCPN()
        started = Date()
        sentPlayback = false
        segmentStart = position
        lastPosition = position
        lastPing = .distantPast
        reportedOK = false
        lastSent = nil
    }

    /// Called every ~10 s while playing and on pause / close / end.
    func report(position: Double, length: Double, playing: Bool, force: Bool = false) {
        guard let videoId, let tracking, InnerTube.shared.isSignedIn else { return }
        if !sentPlayback {
            sentPlayback = true
            segmentStart = position
            lastPosition = position
            send(tracking.playback, videoId: videoId, params: ["cmt": Self.fmt(position), "len": Self.fmt(length)])
            return
        }
        // Nothing new to say (paused in the same place, already reported): don't send again.
        if let last = lastSent, last.playing == playing, abs(last.position - position) < 1,
           !playing || Date().timeIntervalSince(lastPing) < 10 { return }
        guard force || !playing || Date().timeIntervalSince(lastPing) >= 10 else { return }
        // A jump (seek) closes the range watched so far and starts a new one.
        let expected = lastPosition + Date().timeIntervalSince(lastPing == .distantPast ? started : lastPing) + 3
        if position < lastPosition - 2 || position > expected {
            segmentStart = position
        }
        let st = min(segmentStart, position)
        send(tracking.watchtime, videoId: videoId, params: [
            "st": Self.fmt(st), "et": Self.fmt(position), "cmt": Self.fmt(position),
            "len": Self.fmt(length), "state": playing ? "playing" : "paused",
        ])
        segmentStart = position
        lastPosition = position
        lastPing = Date()
        lastSent = (position, playing)
    }

    private func send(_ base: URL, videoId: String, params: [String: String]) {
        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false),
              let auth = InnerTube.shared.auth, auth.isValid else { return }
        var items = comps.queryItems ?? []
        let fixed: [String: String] = [
            "ver": "2", "cpn": cpn, "el": "detailpage", "fs": "0", "volume": "100", "muted": "0",
            "rt": Self.fmt(Date().timeIntervalSince(started)), "lact": String(Int.random(in: 500...4000)),
        ]
        let all = fixed.merging(params) { $1 }
        items.removeAll { all[$0.name] != nil }
        items += all.map { URLQueryItem(name: $0.key, value: $0.value) }
        comps.queryItems = items
        guard let url = comps.url else { return }

        let origin = "https://www.youtube.com"
        var req = URLRequest(url: url)
        req.setValue(ClientProfile.web.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(auth.cookieHeader(forHost: url.host ?? "www.youtube.com"), forHTTPHeaderField: "Cookie")
        if let a = auth.authorization(origin: origin) { req.setValue(a, forHTTPHeaderField: "Authorization") }
        req.setValue(String(auth.authUser), forHTTPHeaderField: "X-Goog-AuthUser")
        req.setValue(origin, forHTTPHeaderField: "Origin")
        req.setValue(origin + "/", forHTTPHeaderField: "Referer")
        req.timeoutInterval = 15

        let kind = base == tracking?.playback ? "playback" : "watchtime"
        // Finish even if the app is about to be suspended (pausing, then leaving the app, is
        // exactly when the last report goes out); otherwise it fails when the app wakes up.
        let bg = UIApplication.shared.beginBackgroundTask(withName: "YouTube watch report")
        Task { [weak self] in
            var problem: String?
            do {
                let (_, resp) = try await InnerTube.shared.session.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if !(200..<300).contains(code) { problem = "HTTP \(code)" }
            } catch {
                problem = (error as? URLError).map { "\($0.code.rawValue) \($0.localizedDescription)" } ?? error.localizedDescription
            }
            await MainActor.run {
                defer { if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) } }
                guard let self else { return }
                if let problem {
                    // At most one line a minute: a dead connection shouldn't flood the log.
                    if Date().timeIntervalSince(self.lastFailureNote) > 60 {
                        self.lastFailureNote = Date()
                        self.trace?("YouTube \(kind) report failed: \(problem)")
                    }
                    self.lastSent = nil   // try again with the next report
                } else if !self.reportedOK {
                    self.reportedOK = true
                    self.trace?("Watch progress syncing to your YouTube account")
                }
            }
        }
    }

    private static func fmt(_ t: Double) -> String { String(format: "%.3f", max(0, t)) }

    /// Client playback nonce: 16 characters from the web player's alphabet.
    private static func makeCPN() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        return String((0..<16).map { _ in alphabet[Int.random(in: 0..<64)] })
    }
}
