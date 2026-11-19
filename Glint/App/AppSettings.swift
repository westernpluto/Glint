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
    /// Categories that show a Skip button instead of skipping automatically.
    var sponsorManual: Set<SponsorCategory> {
        didSet { d.set(sponsorManual.map(\.rawValue), forKey: "sbManual") }
    }
    var showSkipNotice: Bool { didSet { d.set(showSkipNotice, forKey: "sbNotice") } }

    enum SponsorMode: String, CaseIterable, Identifiable {
        case auto, ask, off
        var id: String { rawValue }
        var title: String {
            switch self {
            case .auto: return "Skip automatically"
            case .ask: return "Show a Skip button"
            case .off: return "Don't skip"
            }
        }
    }

    func sponsorMode(_ c: SponsorCategory) -> SponsorMode {
        sponsorCategories.contains(c) ? .auto : sponsorManual.contains(c) ? .ask : .off
    }

    func setSponsorMode(_ mode: SponsorMode, for c: SponsorCategory) {
        sponsorCategories.remove(c)
        sponsorManual.remove(c)
        switch mode {
        case .auto: sponsorCategories.insert(c)
        case .ask: sponsorManual.insert(c)
        case .off: break
        }
    }
    var preferHDR: Bool { didSet { d.set(preferHDR, forKey: "preferHDR") } }
    /// Turn captions on automatically (in the device language when available).
    var captionsOn: Bool { didSet { d.set(captionsOn, forKey: "captionsOn") } }

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
        sponsorManual = Set((d.stringArray(forKey: "sbManual") ?? ["intro", "outro", "preview", "filler"])
            .compactMap(SponsorCategory.init(rawValue:)))
        preferHDR = d.bool(forKey: "preferHDR")
        captionsOn = d.bool(forKey: "captionsOn")
        if let raw = d.stringArray(forKey: "sbCategories") {
            sponsorCategories = Set(raw.compactMap(SponsorCategory.init(rawValue:)))
        } else {
            sponsorCategories = SponsorCategory.defaultSkip
        }
        YouTubeService.shared.hideShorts = hideShorts
    }
}
