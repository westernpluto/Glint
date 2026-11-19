import Foundation

/// InnerTube client identities. YouTube occasionally retires old client
/// versions; if requests start failing, bumping the versions here is usually
/// the only change needed.
struct ClientProfile {
    var clientName: String
    var clientVersion: String
    var clientId: Int
    var host: String
    var userAgent: String
    var extraContext: [String: Any] = [:]
    var origin: String { "https://" + host }

    func context(visitorData: String?, hl: String, gl: String) -> [String: Any] {
        var client: [String: Any] = [
            "clientName": clientName,
            "clientVersion": clientVersion,
            "hl": hl,
            "gl": gl,
            "utcOffsetMinutes": TimeZone.current.secondsFromGMT() / 60,
        ]
        if let visitorData { client["visitorData"] = visitorData }
        for (k, v) in extraContext { client[k] = v }
        return ["client": client, "user": ["lockedSafetyMode": false]]
    }

    // Browsing, feeds, accounts, subscriptions, likes.
    static let web = ClientProfile(
        clientName: "WEB",
        clientVersion: "2.20251114.01.00",
        clientId: 1,
        host: "www.youtube.com",
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15",
        extraContext: ["platform": "DESKTOP"]
    )

    // YouTube Music.
    static let webRemix = ClientProfile(
        clientName: "WEB_REMIX",
        clientVersion: "1.20251110.03.00",
        clientId: 67,
        host: "music.youtube.com",
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15",
        extraContext: ["platform": "DESKTOP"]
    )

    // Playback: HLS manifests with every resolution up to 4K/8K (incl. HDR).
    static let ios = ClientProfile(
        clientName: "IOS",
        clientVersion: "20.10.4",
        clientId: 5,
        host: "www.youtube.com",
        userAgent: "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
        extraContext: [
            "deviceMake": "Apple",
            "deviceModel": "iPhone16,2",
            "osName": "iPhone",
            "osVersion": "18.3.2.22D82",
        ]
    )

    // Playback fallback: direct (unciphered) adaptive MP4/M4A streams.
    static let androidVR = ClientProfile(
        clientName: "ANDROID_VR",
        clientVersion: "1.65.10",
        clientId: 28,
        host: "www.youtube.com",
        userAgent: "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
        extraContext: [
            "deviceMake": "Oculus",
            "deviceModel": "Quest 3",
            "androidSdkVersion": 32,
            "osName": "Android",
            "osVersion": "12L",
        ]
    )
}
