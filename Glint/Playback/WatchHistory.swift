import Foundation
import Observation

/// What you've watched on this iPhone: resume points (with progress for thumbnails) and a
/// recently-watched list. Works signed out; nothing leaves the device.
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
    @ObservationIgnored private let pointsKey = "watchHistory.points.v1"
    @ObservationIgnored private let recentKey = "watchHistory.recent.v1"

    private init() {
        points = (d.data(forKey: "watchHistory.points.v1")).flatMap { try? JSONDecoder().decode([String: Point].self, from: $0) } ?? [:]
        recent = (d.data(forKey: "watchHistory.recent.v1")).flatMap { try? JSONDecoder().decode([VideoItem].self, from: $0) } ?? []
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
