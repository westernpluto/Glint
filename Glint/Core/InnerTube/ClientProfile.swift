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

    // Playback. YouTube limits clients that need a proof-of-origin token to the first part
    // of each stream (playback stops partway in), so several identities are kept and the
    // resolver checks each stream reaches its end before using it.

    /// Apple Vision Pro. yt-dlp's only default client that needs neither the JS player
    /// (signature / n deciphering) nor a proof-of-origin token, so its streams play to the end.
    /// "Made for kids" videos aren't available with it; the others below cover those.
    static let visionOS = ClientProfile(
        clientName: "VISIONOS",
        clientVersion: "1.02",
        clientId: 101,
        host: "www.youtube.com",
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
        extraContext: [
            "deviceMake": "Apple",
            "deviceModel": "RealityDevice17,1",
            "osName": "visionOS",
            "osVersion": "26.5.23O471",
        ]
    )

    static let ios = ClientProfile(
        clientName: "IOS",
        clientVersion: "20.45.3",
        clientId: 5,
        host: "www.youtube.com",
        userAgent: "com.google.ios.youtube/20.45.3 (iPhone16,2; U; CPU iOS 18_7 like Mac OS X;)",
        extraContext: [
            "deviceMake": "Apple",
            "deviceModel": "iPhone16,2",
            "osName": "iPhone",
            "osVersion": "18.7.0.22H20",
        ]
    )

    static let android = ClientProfile(
        clientName: "ANDROID",
        clientVersion: "20.10.38",
        clientId: 3,
        host: "www.youtube.com",
        userAgent: "com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip",
        extraContext: [
            "androidSdkVersion": 30,
            "osName": "Android",
            "osVersion": "11",
        ]
    )

    static func androidVR(_ version: String) -> ClientProfile {
        ClientProfile(
            clientName: "ANDROID_VR",
            clientVersion: version,
            clientId: 28,
            host: "www.youtube.com",
            userAgent: "com.google.android.apps.youtube.vr.oculus/\(version) (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
            extraContext: [
                "deviceMake": "Oculus",
                "deviceModel": "Quest 3",
                "androidSdkVersion": 32,
                "osName": "Android",
                "osVersion": "12L",
            ]
        )
    }

    static let androidVR = androidVR("1.62.27")

    /// Identity used for "this client failed" bookkeeping.
    var key: String { clientName + "/" + clientVersion }
}
