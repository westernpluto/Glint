import Foundation
import Observation

@Observable
final class AppSettings {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    /// 0 = Auto (adaptive). Otherwise the preferred resolution in lines (e.g. 2160).
    var defaultQuality: Int { didSet { d.set(defaultQuality, forKey: "defaultQuality") } }
    var hideShorts: Bool { didSet { d.set(hideShorts, forKey: "hideShorts"); YouTubeService.shared.hideShorts = hideShorts } }
    var autoplay: Bool { didSet { d.set(autoplay, forKey: "autoplay") } }
    var backgroundPlayback: Bool { didSet { d.set(backgroundPlayback, forKey: "backgroundPlayback") } }
    var musicAudioOnly: Bool { didSet { d.set(musicAudioOnly, forKey: "musicAudioOnly") } }
    var playbackSpeed: Double { didSet { d.set(playbackSpeed, forKey: "playbackSpeed") } }
    var sponsorBlockEnabled: Bool { didSet { d.set(sponsorBlockEnabled, forKey: "sbEnabled") } }
    var sponsorCategories: Set<SponsorCategory> {
        didSet { d.set(sponsorCategories.map(\.rawValue), forKey: "sbCategories") }
    }
    var showSkipNotice: Bool { didSet { d.set(showSkipNotice, forKey: "sbNotice") } }
    var preferHDR: Bool { didSet { d.set(preferHDR, forKey: "preferHDR") } }

    static let qualityChoices: [(Int, String)] = [
        (0, "Auto"), (4320, "8K · 4320p"), (2160, "4K · 2160p"), (1440, "1440p"),
        (1080, "1080p"), (720, "720p"), (480, "480p"), (360, "360p"),
    ]

    private init() {
        d.register(defaults: [
            "defaultQuality": 0, "hideShorts": true, "autoplay": true, "backgroundPlayback": true,
            "musicAudioOnly": true, "playbackSpeed": 1.0, "sbEnabled": true, "sbNotice": true,
            "preferHDR": true,
        ])
        defaultQuality = d.integer(forKey: "defaultQuality")
        hideShorts = d.bool(forKey: "hideShorts")
        autoplay = d.bool(forKey: "autoplay")
        backgroundPlayback = d.bool(forKey: "backgroundPlayback")
        musicAudioOnly = d.bool(forKey: "musicAudioOnly")
        playbackSpeed = d.double(forKey: "playbackSpeed")
        sponsorBlockEnabled = d.bool(forKey: "sbEnabled")
        showSkipNotice = d.bool(forKey: "sbNotice")
        preferHDR = d.bool(forKey: "preferHDR")
        if let raw = d.stringArray(forKey: "sbCategories") {
            sponsorCategories = Set(raw.compactMap(SponsorCategory.init(rawValue:)))
        } else {
            sponsorCategories = SponsorCategory.defaultSkip
        }
        YouTubeService.shared.hideShorts = hideShorts
    }
}
