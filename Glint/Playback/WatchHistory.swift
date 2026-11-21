import Foundation
import Observation

/// What you've watched: resume points (with progress for thumbnails) and a recently-watched
/// list, kept separately for each signed-in account (and once for signed out). Signed in,
/// progress also comes from YouTube's resume bars (`mergeRemote`) and goes back to YouTube
/// through `YouTubeWatchSync`.
@MainActor
@Observable
final class WatchHistory {
    static let shared = WatchHistory()

    private struct Point: Codable { var time: Double; var duration: Double; var updated: Double }

    /// Not observed directly: positions are saved every few seconds during playback and
    /// every visible thumbnail reads them. Views observe `revision`, which only moves
    /// when a progress bar would visibly change.
    @ObservationIgnored private var points: [String: Point]
    private var revision = 0
    private(set) var recent: [VideoItem]

    @ObservationIgnored private let d = UserDefaults.standard
    /// "guest" or the account's id.
    @ObservationIgnored private(set) var profile: String
    private var pointsKey: String { "watchHistory.points.v2.\(profile)" }
    private var recentKey: String { "watchHistory.recent.v2.\(profile)" }

    private init() {
        // Same rule AccountStore uses for the active account, without touching it here.
        profile = UserDefaults.standard.string(forKey: "activeAccount") ?? "guest"
        points = [:]
        recent = []
        migrateSharedHistory()
        load()
    }

    /// History from before it was per account goes to whoever is active now.
    private func migrateSharedHistory() {
        let oldPoints = "watchHistory.points.v1", oldRecent = "watchHistory.recent.v1"
        guard d.object(forKey: oldPoints) != nil || d.object(forKey: oldRecent) != nil else { return }
        if d.object(forKey: pointsKey) == nil, let v = d.data(forKey: oldPoints) { d.set(v, forKey: pointsKey) }
        if d.object(forKey: recentKey) == nil, let v = d.data(forKey: oldRecent) { d.set(v, forKey: recentKey) }
        d.removeObject(forKey: oldPoints)
        d.removeObject(forKey: oldRecent)
    }

    private func load() {
        points = d.data(forKey: pointsKey).flatMap { try? JSONDecoder().decode([String: Point].self, from: $0) } ?? [:]
        recent = d.data(forKey: recentKey).flatMap { try? JSONDecoder().decode([VideoItem].self, from: $0) } ?? []
        revision += 1
    }

    /// Switches to an account's history (nil: signed out).
    func useProfile(_ accountID: UUID?) {
        let next = accountID?.uuidString ?? "guest"
        guard next != profile else { return }
        profile = next
        load()
    }

    /// A removed account's history leaves the device with it.
    func deleteProfile(_ accountID: UUID) {
        let id = accountID.uuidString
        d.removeObject(forKey: "watchHistory.points.v2.\(id)")
        d.removeObject(forKey: "watchHistory.recent.v2.\(id)")
        if profile == id { points = [:]; recent = []; revision += 1 }
    }

    /// Resume progress YouTube shows on feed / history / search thumbnails (watched elsewhere,
    /// or here before). Fresh local progress wins; "watched to the end" clears the point.
    func mergeRemote(_ items: [(id: String, percent: Double, duration: Double)]) {
        guard profile != "guest", !items.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        var changed = false
        for it in items where it.duration >= 300 {
            let local = points[it.id]
            if let local, now - local.updated < 15 * 60 { continue }   // just watched here
            if it.percent >= 97 {
                if local != nil { points[it.id] = nil; changed = true }
                continue
            }
            let t = it.duration * it.percent / 100
            guard t > 20 else { continue }
            if let local, abs(local.time - t) < 15 { continue }
            points[it.id] = Point(time: t, duration: it.duration, updated: now - 15 * 60)
            changed = true
        }
        guard changed else { return }
        revision += 1
        persist(points, pointsKey)
    }

    /// Where to resume, for videos long enough to be worth resuming.
    func position(for id: String) -> Double? {
        _ = revision
        guard let p = points[id], p.time > 0 else { return nil }
        return p.time
    }

    /// 0...1 watched fraction, for the progress bar on thumbnails.
    func progress(for id: String) -> Double? {
        _ = revision
        guard let p = points[id], p.duration > 0 else { return nil }
        return min(max(p.time / p.duration, 0), 1)
    }

    /// Videos with a resume point, most recent first.
    var continueWatching: [VideoItem] {
        _ = revision
        return recent.filter { points[$0.id] != nil }
    }

    func save(_ t: Double, duration: Double, for id: String) {
        let old = points[id]
        if duration >= 300, t > 20, t < duration - 30 {
            points[id] = Point(time: t, duration: duration, updated: Date().timeIntervalSince1970)
        } else if t > 0 {
            points[id] = nil                     // short video, or watched to the end
        } else {
            return
        }
        let new = points[id]
        if (old == nil) != (new == nil)
            || abs((new.map { $0.time / $0.duration } ?? 0) - (old.map { $0.time / $0.duration } ?? 0)) >= 0.01 {
            revision += 1
        }
        if points.count > 300 {
            let drop = points.sorted { $0.value.updated < $1.value.updated }.prefix(points.count - 300)
            for (k, _) in drop { points[k] = nil }
        }
        persist(points, pointsKey)
    }

    func record(_ video: VideoItem) {
        var v = video
        if let old = recent.first(where: { $0.id == v.id }) {
            v.channelAvatar = v.channelAvatar ?? old.channelAvatar
        }
        recent.removeAll { $0.id == v.id }
        recent.insert(v, at: 0)
        if recent.count > 60 { recent.removeLast(recent.count - 60) }
        persist(recent, recentKey)
    }

    func remove(_ id: String) {
        recent.removeAll { $0.id == id }
        points[id] = nil
        revision += 1
        persist(recent, recentKey)
        persist(points, pointsKey)
    }

    func clear() {
        recent = []
        points = [:]
        revision += 1
        persist(recent, recentKey)
        persist(points, pointsKey)
    }

    private func persist<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { d.set(data, forKey: key) }
    }
}
