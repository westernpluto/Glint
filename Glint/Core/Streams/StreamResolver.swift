import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One user-selectable quality.
struct StreamOption: Identifiable, Hashable {
    enum Source: Hashable {
        /// Variants of a real HLS master (live streams).
        case hls([HLSManifest.Variant])
        /// An adaptive MP4 video stream, played through a synthetic HLS playlist.
        case dash(DashFormat)
    }

    var height: Int
    var width: Int
    var fps: Int
    var codec: String
    var hdr: Bool
    var bitrate: Int
    var source: Source

    var id: String { "\(lines)-\(fps)-\(codec)-\(hdr)" }

    /// Shorter edge drives the "p" number so vertical videos read correctly.
    var lines: Int { width > 0 ? min(width, height) : height }

    var label: String { "\(lines)p" + (fps > 30 ? "\(fps)" : "") + (hdr ? " HDR" : "") }

    var badge: String? {
        switch lines {
        case 4320...: return "8K"
        case 2880..<4320: return "5K"
        case 2160..<2880: return "4K"
        case 1440..<2160: return "QHD"
        case 720..<1440: return "HD"
        default: return nil
        }
    }
}

struct ResolvedStream {
    var details: VideoDetails
    var options: [StreamOption]      // best first
    var hlsURL: URL?                 // live streams
    var manifest: HLSManifest?
    var audio: DashFormat?           // best AAC stream
    var streamUserAgent: String
    var isLive: Bool
    var captions: [CaptionTrack] = []

    /// Video formats suitable for "Auto" (one per resolution, decodable).
    var autoFormats: [DashFormat] {
        options.compactMap { if case .dash(let f) = $0.source { return f }; return nil }
    }
}

final class StreamResolver: @unchecked Sendable {
    static let shared = StreamResolver()
    private let tube = InnerTube.shared

    /// Returns true when the device can decode a codec string such as `av01.0.12M.08`.
    var codecSupported: (String) -> Bool = { _ in true }

    /// Clients tried in order. ANDROID_VR returns direct URLs without proof-of-origin tokens.
    var clients: [ClientProfile] = [.androidVR, .ios]

    // Stream URLs stay valid for hours; reuse a resolution for a while so replays,
    // quality changes after a relaunch of the item and "back to this video" are instant.
    private let cacheLock = NSLock()
    private var cache: [String: (stream: ResolvedStream, at: Date)] = [:]
    private let cacheLifetime: TimeInterval = 20 * 60

    func invalidate(_ videoId: String) {
        cacheLock.withLock { cache[videoId] = nil }
    }

    private func cached(_ videoId: String) -> ResolvedStream? {
        cacheLock.withLock {
            guard let hit = cache[videoId], Date().timeIntervalSince(hit.at) < cacheLifetime else { return nil }
            return hit.stream
        }
    }

    private func store(_ stream: ResolvedStream, for videoId: String) {
        cacheLock.withLock {
            let now = Date()
            cache = cache.filter { now.timeIntervalSince($0.value.at) < cacheLifetime }
            if cache.count >= 40, let oldest = cache.min(by: { $0.value.at < $1.value.at })?.key { cache[oldest] = nil }
            cache[videoId] = (stream, now)
        }
    }

    func resolve(videoId: String) async throws -> ResolvedStream {
        if let hit = cached(videoId) { return hit }
        let stream = try await resolveFresh(videoId: videoId)
        if !stream.isLive { store(stream, for: videoId) }
        return stream
    }

    private func resolveFresh(videoId: String) async throws -> ResolvedStream {
        var lastReason: String?
        for client in clients {
            guard let json = try? await player(videoId: videoId, client: client) else { continue }
            guard json.at("playabilityStatus.status").string == "OK" else {
                lastReason = json.at("playabilityStatus.reason").string ?? lastReason
                continue
            }
            if let stream = await build(json, client: client) { return stream }
        }
        throw InnerTubeError.unplayable(lastReason ?? "This video can't be played right now.")
    }

    private func build(_ json: JSON, client: ClientProfile) async -> ResolvedStream? {
        let details = Self.details(json["videoDetails"], microformat: json.at("microformat.playerMicroformatRenderer"))
        let sd = json["streamingData"]

        // Live: real HLS.
        if let s = sd["hlsManifestUrl"].string, let url = URL(string: s) {
            if let text = try? await fetchText(url, userAgent: client.userAgent) {
                let m = HLSManifest(text: text, baseURL: url)
                if !m.variants.isEmpty {
                    return ResolvedStream(details: details, options: hlsOptions(m), hlsURL: url, manifest: m,
                                          audio: nil, streamUserAgent: client.userAgent, isLive: true,
                                          captions: Captions.tracks(json))
                }
            }
        }

        let formats = sd["adaptiveFormats"].array.compactMap(DashFormat.init)
        let audio = formats.filter { $0.isAudio && $0.codecs.hasPrefix("mp4a") }
            .max { $0.bitrate < $1.bitrate }
        let videos = formats.filter { !$0.isAudio && codecSupported($0.codecs) }
        guard audio != nil || !videos.isEmpty else { return nil }

        var best: [String: StreamOption] = [:]
        for v in videos {
            let o = StreamOption(height: v.height, width: v.width, fps: v.fps, codec: v.codecFamily,
                                 hdr: v.hdrRange != nil, bitrate: v.bitrate, source: .dash(v))
            let key = "\(o.lines)-\(o.fps)-\(o.hdr)"
            if let cur = best[key], prefer(cur, over: o) { continue }
            best[key] = o
        }
        let options = best.values.sorted(by: Self.order)
        return ResolvedStream(details: details, options: options, hlsURL: nil, manifest: nil,
                              audio: audio, streamUserAgent: client.userAgent, isLive: details.isLive,
                              captions: Captions.tracks(json))
    }

    /// AVC up to 1080p (hardware decode everywhere, light on battery); AV1 above.
    private func prefer(_ a: StreamOption, over b: StreamOption) -> Bool {
        if a.codec == b.codec { return a.bitrate >= b.bitrate }
        let wantAVC = a.lines <= 1080
        if wantAVC { return a.codec == "avc" }
        return a.codec == "av1"
    }

    static func order(_ a: StreamOption, _ b: StreamOption) -> Bool {
        if a.lines != b.lines { return a.lines > b.lines }
        if a.fps != b.fps { return a.fps > b.fps }
        if a.hdr != b.hdr { return a.hdr }
        return a.bitrate > b.bitrate
    }

    // MARK: Requests

    private func player(videoId: String, client: ClientProfile) async throws -> JSON {
        try await tube.call("player", client: client, body: [
            "videoId": videoId,
            "contentCheckOk": true,
            "racyCheckOk": true,
            "playbackContext": ["contentPlaybackContext": ["html5Preference": "HTML5_PREF_WANTS"]],
        ], authenticated: false)
    }

    private func fetchText(_ url: URL, userAgent: String) async throws -> String {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await tube.session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw InnerTubeError.http(code) }
        return String(decoding: data, as: UTF8.self)
    }

    private func hlsOptions(_ m: HLSManifest) -> [StreamOption] {
        var groups: [String: [HLSManifest.Variant]] = [:]
        for v in m.variants where v.height > 0 && codecSupported(v.videoCodec) {
            groups["\(v.height)-\(Int(v.fps.rounded()))-\(v.isHDR)", default: []].append(v)
        }
        return groups.values.map { vs -> StreamOption in
            let v = vs.max { $0.bandwidth < $1.bandwidth }!
            return StreamOption(height: v.height, width: v.width, fps: Int(v.fps.rounded()),
                                codec: v.codecFamily, hdr: v.isHDR, bitrate: v.bandwidth, source: .hls(vs))
        }.sorted(by: Self.order)
    }

    // MARK: Details

    static func details(_ d: JSON, microformat: JSON) -> VideoDetails {
        VideoDetails(
            id: d["videoId"].string ?? "",
            title: d["title"].string ?? microformat["title"].text ?? "",
            channelName: d["author"].string ?? microformat["ownerChannelName"].string ?? "",
            channelId: d["channelId"].string,
            description: d["shortDescription"].string ?? microformat["description"].text ?? "",
            viewCount: d["viewCount"].int,
            lengthSeconds: d["lengthSeconds"].int,
            isLive: d["isLive"].bool ?? false,
            thumbnail: Parser.thumbnail(d["thumbnail"]),
            publishDate: microformat["publishDate"].string
        )
    }
}
