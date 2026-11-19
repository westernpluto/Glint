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
    /// Which client produced these links (see `StreamResolver.reportFailure`).
    var clientKey: String = ""
    /// YouTube refused the end of the file for every available client: only the first
    /// part will play.
    var isPartial = false
    /// A single progressive MP4 (itag 18: 360p, video + audio) played directly. Used when
    /// every adaptive stream was cut short: YouTube doesn't require a proof-of-origin token
    /// for this format (per yt-dlp), so it plays to the end where the others stop.
    var progressiveURL: URL?

    /// Video formats suitable for "Auto" (one per resolution, decodable).
    var autoFormats: [DashFormat] {
        options.compactMap { if case .dash(let f) = $0.source { return f }; return nil }
    }
}

final class StreamResolver: @unchecked Sendable {
    static let shared = StreamResolver()
    private let tube = InnerTube.shared

    /// Receives a line for each resolution step (shown in Playback info).
    var trace: (@Sendable (String) -> Void)?

    /// Returns true when the device can decode a codec string such as `av01.0.12M.08`.
    var codecSupported: (String) -> Bool = { _ in true }

    /// Clients tried in order. Following yt-dlp, visionOS goes first: it needs no
    /// proof-of-origin token. MWEB comes next with a PO token minted on the device and its
    /// links deciphered with the player script. The app clients after it would need tokens
    /// only their real apps can make, so YouTube may cut their streams short; `reachability`
    /// catches that. (ANDROID_VR 1.65.10 is gone: every format it gets has been refused
    /// since August 2026.)
    var clients: [ClientProfile] = [.visionOS, .mweb, .androidVR, .androidVR("1.60.19"), .ios, .android]

    /// Clients whose streams recently failed during playback, and when. They are tried last.
    private var penalized: [String: Date] = [:]
    private let penaltyLifetime: TimeInterval = 60 * 60

    /// Called when a stream stopped working mid-playback: that client goes to the back of
    /// the line for a while and the cached links are dropped.
    func reportFailure(_ stream: ResolvedStream) {
        cacheLock.withLock {
            if !stream.clientKey.isEmpty { penalized[stream.clientKey] = Date() }
            cache[stream.details.id] = nil
        }
    }

    private var orderedClients: [ClientProfile] {
        cacheLock.withLock {
            let now = Date()
            penalized = penalized.filter { now.timeIntervalSince($0.value) < penaltyLifetime }
            let ok = clients.filter { penalized[$0.key] == nil }
            let bad = clients.filter { penalized[$0.key] != nil }
                .sorted { (penalized[$0.key] ?? now) < (penalized[$1.key] ?? now) }
            return ok + bad
        }
    }

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
        var limited: ResolvedStream?
        var progressive: ResolvedStream?
        for client in orderedClients {
            var webPlayer: JSChallengeSolver.Player?
            if client.isWebPlayback {
                if tube.visitorData == nil { await tube.warmUp() }
                do { webPlayer = try await JSChallengeSolver.shared.player(session: tube.session) } catch {
                    trace?("\(client.key): player script unavailable (\(error.localizedDescription))")
                    continue
                }
            }
            var json: JSON
            do { json = try await player(videoId: videoId, client: client, sts: webPlayer?.sts) } catch {
                trace?("\(client.key): request failed (\(error.localizedDescription))")
                continue
            }
            guard json.at("playabilityStatus.status").string == "OK" else {
                lastReason = json.at("playabilityStatus.reason").string ?? lastReason
                trace?("\(client.key): \(json.at("playabilityStatus.status").string ?? "?") \(json.at("playabilityStatus.reason").string ?? "")")
                continue
            }
            if let webPlayer { json = await prepareWebFormats(json, client: client, player: webPlayer) }
            guard var stream = await build(json, client: client) else {
                trace?("\(client.key): no usable formats")
                continue
            }
            stream.clientKey = client.key
            if stream.isLive || stream.hlsURL != nil { trace?("\(client.key): live HLS"); return stream }
            let check = await reachability(stream, userAgent: client.userAgent)
            trace?("\(client.key): \(stream.options.count) qualities, audio \(stream.audio.map { "itag \($0.itag)" } ?? "none"), check \(check.description)")
            if check.ok { return stream }
            // This client only gets the start of each file: keep looking, but remember it
            // in case nothing better turns up (better a partial play than none).
            if limited == nil { limited = stream }
            cacheLock.withLock { penalized[client.key] = Date() }
            if client.isWebPlayback { await PoTokenProvider.shared.reset() }   // mint a fresh one next time
            if progressive == nil, let url = Self.progressiveURL(json) {
                let p = await reachability(url, length: nil, userAgent: client.userAgent)
                trace?("\(client.key): 360p progressive check \(p.description)")
                if p.ok {
                    var s = stream
                    s.options = []
                    s.audio = nil
                    s.progressiveURL = url
                    progressive = s
                }
            }
        }
        // Full length at 360p beats the first part in HD.
        if let progressive { trace?("Using 360p progressive from \(progressive.clientKey)"); return progressive }
        if var limited {
            limited.isPartial = true
            return limited
        }
        throw InnerTubeError.unplayable(lastReason ?? "This video can't be played right now.")
    }

    private func build(_ json: JSON, client: ClientProfile) async -> ResolvedStream? {
        let details = Self.details(json["videoDetails"], microformat: json.at("microformat.playerMicroformatRenderer"))
        let sd = json["streamingData"]

        // Live: real HLS. (Some clients also send a manifest for regular videos; those play
        // from the adaptive formats below so every quality, audio-only and the checks apply.)
        if details.isLive || sd["adaptiveFormats"].array.isEmpty,
           let s = sd["hlsManifestUrl"].string, let url = URL(string: s) {
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

    struct Reachability {
        var start: Int?
        var end: Int?
        /// Only a definite refusal rejects a client; network trouble doesn't.
        var ok: Bool { !Self.refused(start) && !Self.refused(end) }
        var description: String { "start " + Self.text(start) + " end " + Self.text(end) }
        private static func refused(_ code: Int?) -> Bool { code == 403 || code == 401 }
        private static func text(_ code: Int?) -> String {
            guard let code else { return "–" }
            return String(code)
        }
    }

    /// YouTube serves clients without a proof-of-origin token only the first part of each
    /// stream (or nothing) and answers 403 beyond that. Two tiny range requests, at the start
    /// and near the end of the file, tell them apart.
    private func reachability(_ s: ResolvedStream, userAgent: String) async -> Reachability {
        guard let f = s.audio ?? s.autoFormats.last else { return Reachability() }
        return await reachability(f.url, length: f.contentLength, userAgent: userAgent)
    }

    /// `length` nil or 0: learned from the first response's Content-Range.
    private func reachability(_ url: URL, length: Int?, userAgent: String) async -> Reachability {
        if let length, length > 1024 {
            async let start = status(url, at: 0, userAgent: userAgent)
            async let end = status(url, at: length * 9 / 10, userAgent: userAgent)
            return await Reachability(start: start.code, end: end.code)
        }
        let start = await status(url, at: 0, userAgent: userAgent)
        guard let total = start.total, total > 1024 else { return Reachability(start: start.code) }
        return Reachability(start: start.code, end: await status(url, at: total * 9 / 10, userAgent: userAgent).code)
    }

    private func status(_ url: URL, at offset: Int, userAgent: String) async -> (code: Int?, total: Int?) {
        var req = URLRequest(url: url)
        req.setValue("bytes=\(offset)-\(offset + 15)", forHTTPHeaderField: "Range")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 6
        guard let (_, resp) = try? await tube.session.data(for: req),
              let http = resp as? HTTPURLResponse else { return (nil, nil) }
        // "bytes 0-15/12345"
        let total = (http.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last)
            .flatMap { Int($0) }
        return (http.statusCode, total)
    }

    /// The muxed 360p MP4 (itag 18), when this client got a direct link for it.
    private static func progressiveURL(_ json: JSON) -> URL? {
        json.at("streamingData.formats").array
            .first { $0["itag"].int == 18 }?["url"].string
            .flatMap(URL.init(string:))
    }

    // MARK: Requests

    private func player(videoId: String, client: ClientProfile, sts: Int? = nil) async throws -> JSON {
        var playback: [String: Any] = ["html5Preference": "HTML5_PREF_WANTS"]
        if let sts { playback["signatureTimestamp"] = sts }
        return try await tube.call("player", client: client, body: [
            "videoId": videoId,
            "contentCheckOk": true,
            "racyCheckOk": true,
            "playbackContext": ["contentPlaybackContext": playback],
        ], authenticated: false)
    }

    // MARK: Web clients

    /// One format's link before its challenges are solved.
    private struct PendingLink {
        var url: String
        var s: String?          // encrypted signature (from signatureCipher)
        var sp = "signature"    // query name the solved signature goes under
        var n: String?

        init?(_ f: JSON) {
            if let u = f["url"].string {
                url = u
            } else if let cipher = f["signatureCipher"].string {
                var fields: [String: String] = [:]
                for pair in cipher.split(separator: "&") {
                    let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                    guard kv.count == 2 else { continue }
                    fields[kv[0]] = kv[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? kv[1]
                }
                guard let u = fields["url"], let sig = fields["s"] else { return nil }
                url = u
                s = sig
                if let p = fields["sp"], !p.isEmpty { sp = p }
            } else {
                return nil
            }
            n = URLComponents(string: url)?.queryItems?.first { $0.name == "n" }?.value
        }
    }

    /// Web clients' links: solve the signature and n challenges with the player script and add
    /// a PO token bound to this visitor (as yt-dlp does), so the formats below are directly
    /// playable. Formats whose challenges couldn't be solved lose their link.
    private func prepareWebFormats(_ json: JSON, client: ClientProfile, player: JSChallengeSolver.Player) async -> JSON {
        let keys = ["adaptiveFormats", "formats"]
        let pending = keys.flatMap { json.at("streamingData.\($0)").array.compactMap(PendingLink.init) }
        guard !pending.isEmpty else { return json }

        let solutions: JSChallengeSolver.Solutions
        do {
            solutions = try await JSChallengeSolver.shared.solve(
                n: pending.compactMap(\.n), sig: pending.compactMap(\.s), player: player)
        } catch {
            trace?("\(client.key): challenges not solved (\(error.localizedDescription))")
            return json
        }

        var pot: String?
        if let visitorData = tube.visitorData {
            let binding = PoTokenProvider.contentBinding(visitorData: visitorData)
            do {
                pot = try await PoTokenProvider.shared.token(for: binding, visitorData: visitorData)
            } catch {
                trace?("\(client.key): PO token failed (\(error.localizedDescription))")
            }
        }
        trace?("\(client.key): player \(player.id), solved \(solutions.n.count) n / \(solutions.sig.count) sig, PO token \(pot == nil ? "none" : "ok")")

        func rewrite(_ f: JSON) -> JSON {
            guard case .object(var o) = f, let link = PendingLink(f) else { return f }
            o["signatureCipher"] = nil
            o["url"] = nil
            var url = link.url
            if let n = link.n {
                guard let solved = solutions.n[n] else { return .object(o) }
                url = Self.settingQuery(url, "n", solved)
            }
            if let s = link.s {
                guard let solved = solutions.sig[s] else { return .object(o) }
                url = Self.settingQuery(url, link.sp, solved)
            }
            if let pot { url = Self.settingQuery(url, "pot", pot) }
            o["url"] = .string(url)
            return .object(o)
        }

        guard case .object(var root) = json, case .object(var sd) = json["streamingData"] else { return json }
        for key in keys {
            if case .array(let formats) = sd[key] { sd[key] = .array(formats.map(rewrite)) }
        }
        root["streamingData"] = .object(sd)
        return .object(root)
    }

    private static let queryValueAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

    /// Sets one query item, leaving the rest of the (already encoded) link exactly as it was.
    private static func settingQuery(_ url: String, _ name: String, _ value: String) -> String {
        guard var c = URLComponents(string: url) else { return url }
        var items = c.percentEncodedQueryItems ?? []
        items.removeAll { $0.name == name }
        items.append(URLQueryItem(name: name, value: value.addingPercentEncoding(withAllowedCharacters: queryValueAllowed)))
        c.percentEncodedQueryItems = items
        return c.string ?? url
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
