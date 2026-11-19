import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What a SABR session needs from the player response.
struct SabrConfig: Sendable {
    var videoId: String
    /// `streamingData.serverAbrStreamingUrl`, with its n challenge solved.
    var url: URL
    /// `playerConfig.mediaCommonConfig.mediaUstreamerRequestConfig.videoPlaybackUstreamerConfig`.
    var ustreamerConfig: Data
    var clientNameId: Int
    var clientVersion: String
    var poToken: Data?
    var userAgent: String
}

/// YouTube's own streaming protocol (SABR, "server adaptive bitrate"), which is all some
/// sessions get in HD. Each POST names the formats and a player position; the answer (UMP)
/// carries the init segments and the media segments around that position. Segments are the
/// same byte ranges the file's `sidx` index lists, so they slot straight into a synthetic HLS
/// playlist (see `SabrServer`).
///
/// Modelled on LuanRT/googlevideo's SabrStream (MIT).
actor SabrSession {
    enum SabrFailure: LocalizedError {
        case http(Int), server(String), protection, reload, noMedia
        var errorDescription: String? {
            switch self {
            case .http(let c): return "SABR request failed (\(c))"
            case .server(let s): return "SABR error: \(s)"
            case .protection: return "SABR: stream protection rejected the PO token"
            case .reload: return "SABR: YouTube asked for a fresh player response"
            case .noMedia: return "SABR: no media for that position"
            }
        }
    }

    nonisolated let config: SabrConfig
    nonisolated let audio: DashFormat
    nonisolated let videos: [DashFormat]
    nonisolated let id = UUID().uuidString.lowercased()

    private var url: URL
    private var cookie: Data?
    private var requestNumber = 0
    private let started = Date()
    private var audioOnly = false
    private var currentVideo: DashFormat?

    /// itag → init segment as sent (ftyp + moov + sidx).
    private var inits: [Int: Data] = [:]
    /// itag → segments from the sidx, with start times in ms.
    private var indexes: [Int: [(start: Double, duration: Double)]] = [:]

    private struct Key: Hashable { var itag: Int; var number: Int }
    private var cache: [Key: Data] = [:]
    private var cacheOrder: [Key] = []
    private var cacheBytes = 0
    private let cacheLimit = 48 * 1024 * 1024

    /// One SABR request at a time (an answer covers both tracks anyway).
    private var queueTail: Task<Void, Never>?
    private let session: URLSession

    init(config: SabrConfig, audio: DashFormat, videos: [DashFormat], session: URLSession) {
        self.config = config
        self.audio = audio
        self.videos = videos
        self.url = config.url
        self.session = session
    }

    private func format(_ itag: Int) -> DashFormat? {
        itag == audio.itag ? audio : videos.first { $0.itag == itag }
    }

    // MARK: Public

    /// First request (audio, from the start): proves SABR answers and caches the audio init.
    func prepare() async throws {
        audioOnly = true
        _ = try await initSegment(audio.itag)
    }

    func setAudioOnly(_ value: Bool) { audioOnly = value }

    /// ftyp + moov of a format (what HLS's EXT-X-MAP wants; the sidx is left out).
    func initSegment(_ itag: Int) async throws -> Data {
        if let d = inits[itag], let f = format(itag) { return d.prefix(f.initRange.count) }
        guard let f = format(itag) else { throw SabrFailure.noMedia }
        if !f.isAudio { currentVideo = f; audioOnly = false }
        try await serialized { [self] in
            if await self.hasInit(itag) { return }
            try await self.request(atMs: 0, wantInitFor: itag)
        }
        guard let d = inits[itag] else { throw SabrFailure.noMedia }
        return d.prefix(f.initRange.count)
    }

    /// Segment durations (seconds) from the format's sidx.
    func segmentDurations(_ itag: Int) async throws -> [Double] {
        if indexes[itag] == nil { _ = try await initSegment(itag) }
        guard let idx = indexes[itag], !idx.isEmpty else { throw SabrFailure.noMedia }
        return idx.map { $0.duration / 1000 }
    }

    /// Media segment `number` (1-based, as SABR counts) of a format.
    func segment(_ itag: Int, number: Int) async throws -> Data {
        let key = Key(itag: itag, number: number)
        if let d = cache[key] { prefetch(after: number, itag: itag); return d }
        guard let f = format(itag) else { throw SabrFailure.noMedia }
        if !f.isAudio, currentVideo?.itag != itag { currentVideo = f; audioOnly = false }
        if indexes[itag] == nil { _ = try await initSegment(itag) }
        guard let idx = indexes[itag], number >= 1, number <= idx.count else { throw SabrFailure.noMedia }
        // Aim inside the segment: SABR answers from the segment containing the position.
        let at = idx[number - 1].start + min(50, idx[number - 1].duration / 4)
        for attempt in 0..<3 {
            try await serialized { [self] in
                if await self.cached(key) { return }
                try await self.request(atMs: at + Double(attempt) * 200, wantInitFor: nil)
            }
            if let d = cache[key] { prefetch(after: number, itag: itag); return d }
        }
        throw SabrFailure.noMedia
    }

    /// Fetch ahead so the next segments are cached before AVPlayer asks (it gives up on a
    /// segment after a few seconds without an answer). One prefetch at a time.
    private var prefetching = false

    private func prefetch(after number: Int, itag: Int) {
        guard !prefetching, let count = indexes[itag]?.count, number < count else { return }
        let ahead = (number + 1)...min(number + 3, count)
        guard let missing = ahead.first(where: { cache[Key(itag: itag, number: $0)] == nil }) else { return }
        prefetching = true
        Task {
            _ = try? await self.segment(itag, number: missing)
            await self.prefetchFinished()
        }
    }

    private func prefetchFinished() { prefetching = false }

    // MARK: Plumbing

    private func hasInit(_ itag: Int) -> Bool { inits[itag] != nil }
    private func cached(_ key: Key) -> Bool { cache[key] != nil }

    private func serialized(_ op: @escaping @Sendable () async throws -> Void) async throws {
        let previous = queueTail
        let task = Task { await previous?.value; try await op() }
        queueTail = Task { _ = try? await task.value }
        try await task.value
    }

    private func request(atMs playerTimeMs: Double, wantInitFor itag: Int?) async throws {
        for _ in 0..<4 {   // redirects
            let redirected = try await requestOnce(atMs: playerTimeMs)
            if !redirected { return }
        }
        throw SabrFailure.server("too many redirects")
    }

    /// One POST. Returns true when the server redirected (retry against the new host).
    private func requestOnce(atMs playerTimeMs: Double) async throws -> Bool {
        let elapsed = Int64(Date().timeIntervalSince(started) * 1000)
        let video = audioOnly ? nil : (currentVideo ?? videos.first)
        let withInit = Array(inits.keys).compactMap(format)

        var body = ProtoWriter()
        body.message(1) { abr in   // ClientAbrState
            abr.int(21, video?.height)                 // sticky resolution
            abr.int(28, Int64(playerTimeMs))           // player time
            abr.int(29, elapsed)                        // since last seek
            abr.int(34, 2)                              // visibility
            abr.int(36, elapsed)                        // elapsed wall time
            abr.int(39, elapsed)                        // since last action
            abr.int(40, video == nil ? 1 : 0)           // enabled tracks: audio only / both
            abr.bool(71, true)                          // host fallback
        }
        for f in withInit { body.message(2) { Self.formatId(f, &$0) } }
        body.bytes(5, config.ustreamerConfig)
        body.message(16) { Self.formatId(audio, &$0) }
        if let video { body.message(17) { Self.formatId(video, &$0) } }
        body.message(19) { ctx in   // StreamerContext
            ctx.message(1) { ci in
                ci.int(16, config.clientNameId)
                ci.string(17, config.clientVersion)
            }
            ctx.bytes(2, config.poToken)
            ctx.bytes(3, cookie)
        }

        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var items = comps?.percentEncodedQueryItems ?? []
        items.removeAll { $0.name == "rn" }
        items.append(URLQueryItem(name: "rn", value: String(requestNumber)))
        comps?.percentEncodedQueryItems = items
        requestNumber += 1

        var req = URLRequest(url: comps?.url ?? url)
        req.httpMethod = "POST"
        req.httpBody = body.data
        req.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")
        req.setValue("application/vnd.yt-ump", forHTTPHeaderField: "Accept")
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        req.setValue(config.userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 30

        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw SabrFailure.http(code) }

        var pending: [Int: (itag: Int, isInit: Bool, number: Int, data: Data)] = [:]
        var redirected = false
        var mediaCount = 0
        for part in UMP.parts(data) {
            switch part.type {
            case 20:   // MEDIA_HEADER
                let h = ProtoMessage(part.payload)
                let headerId = Int(h.uint(1) ?? 0)
                pending[headerId] = (Int(h.int(3) ?? 0), h.bool(8), Int(h.int(9) ?? 0), Data())
            case 21:   // MEDIA: header id byte + bytes
                guard let first = part.payload.first else { continue }
                pending[Int(first)]?.data.append(part.payload.dropFirst())
            case 22:   // MEDIA_END
                guard let first = part.payload.first, let seg = pending.removeValue(forKey: Int(first)) else { continue }
                mediaCount += 1
                store(seg.itag, isInit: seg.isInit, number: seg.number, data: seg.data)
            case 35:   // NEXT_REQUEST_POLICY
                if let c = ProtoMessage(part.payload).data(7) { cookie = c }
            case 43:   // SABR_REDIRECT
                if let s = ProtoMessage(part.payload).string(1), let u = URL(string: s) {
                    url = u
                    redirected = true
                }
            case 44:   // SABR_ERROR
                let e = ProtoMessage(part.payload)
                throw SabrFailure.server("\(e.string(1) ?? "?") \(e.int(2) ?? 0)")
            case 46:   // RELOAD_PLAYER_RESPONSE
                throw SabrFailure.reload
            case 58:   // STREAM_PROTECTION_STATUS (3 = rejected)
                if ProtoMessage(part.payload).int(1) == 3 { throw SabrFailure.protection }
            default:
                break
            }
        }
        if redirected && mediaCount == 0 { return true }
        return false
    }

    private func store(_ itag: Int, isInit: Bool, number: Int, data: Data) {
        guard let f = format(itag) else { return }
        if isInit {
            guard inits[itag] == nil else { return }
            inits[itag] = data
            let x = f.indexRange
            if data.count > x.upperBound {
                let sidx = data.subdata(in: x.lowerBound..<(x.upperBound + 1))
                var start = 0.0
                indexes[itag] = SyntheticHLS.parseSidx(sidx, indexEnd: x.upperBound).map { s in
                    defer { start += s.duration * 1000 }
                    return (start, s.duration * 1000)
                }
            }
            return
        }
        let key = Key(itag: itag, number: number)
        guard cache[key] == nil else { return }
        cache[key] = data
        cacheOrder.append(key)
        cacheBytes += data.count
        while cacheBytes > cacheLimit, cacheOrder.count > 1 {
            let old = cacheOrder.removeFirst()
            cacheBytes -= cache.removeValue(forKey: old)?.count ?? 0
        }
    }

    private static func formatId(_ f: DashFormat, _ w: inout ProtoWriter) {
        w.int(1, f.itag)
        w.uint(2, f.lastModified)
        w.string(3, f.xtags)
    }
}
