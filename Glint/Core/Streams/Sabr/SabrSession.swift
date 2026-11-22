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
/// sessions get in HD. Each POST names the formats, a player position and what is already
/// buffered; the answer (UMP) streams the init segments and the media segments that follow.
/// Segments are the byte ranges each file's `sidx` lists, so they slot straight into a
/// synthetic HLS playlist (see `SabrServer`).
///
/// Answers are processed as they stream in: a segment is handed to AVPlayer as soon as it is
/// complete (a 4K answer can carry ~25 s of video), and one request runs at a time, moving on
/// when playback jumps elsewhere. Modelled on LuanRT/googlevideo's SabrStream (MIT).
actor SabrSession {
    enum SabrFailure: LocalizedError {
        case http(Int), server(String), protection, reload, noMedia, notDelivered(String)
        var errorDescription: String? {
            switch self {
            case .http(let c): return "SABR request failed (\(c))"
            case .server(let s): return "SABR error: \(s)"
            case .protection: return "SABR: stream protection rejected the PO token"
            case .reload: return "SABR: YouTube asked for a fresh player response"
            case .noMedia: return "SABR: no media for that position"
            case .notDelivered(let what): return "SABR: \(what) wasn't delivered"
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
    /// Where playback last asked for media (ms), for init requests on quality switches.
    private var lastPositionMs: Double = 0

    /// itag → init segment as sent (ftyp + moov + sidx).
    private var inits: [Int: Data] = [:]
    /// itag → segments from the sidx, with start times in ms.
    private var indexes: [Int: [(start: Double, duration: Double)]] = [:]

    /// number 0 = the init segment.
    private struct Key: Hashable { var itag: Int; var number: Int }
    private var cache: [Key: Data] = [:]
    private var cacheOrder: [Key] = []
    private var cacheBytes = 0
    private let cacheLimit = 96 * 1024 * 1024

    // The one request in flight.
    private var inFlight: Task<Void, Never>?
    private var inFlightGeneration = 0
    private var inFlightStartMs: Double = 0
    private var inFlightVideo: Int?
    private var lastError: Error?

    private struct Waiter { var id: UUID; var key: Key; var continuation: CheckedContinuation<Void, Never> }
    private var waiters: [Waiter] = []

    private static let streamer = SabrStreamer()

    init(config: SabrConfig, audio: DashFormat, videos: [DashFormat]) {
        self.config = config
        self.audio = audio
        self.videos = videos
        self.url = config.url
    }

    private func format(_ itag: Int) -> DashFormat? {
        itag == audio.itag ? audio : videos.first { $0.itag == itag }
    }

    // MARK: Public

    /// First request: audio and (unless audio only) the video that will play, from where
    /// playback will start. Returns once the audio init is in (proves SABR answers); the rest
    /// of the answer keeps streaming into the cache.
    func prepare(video: DashFormat?, atMs: Double) async throws {
        if let video, format(video.itag) != nil { select(video) } else { audioOnly = true }
        lastPositionMs = atMs
        try await fetch(Key(itag: audio.itag, number: 0), atMs: atMs)
        guard inits[audio.itag] != nil else { throw lastError ?? SabrFailure.noMedia }
    }

    func setAudioOnly(_ value: Bool) { audioOnly = value }

    /// Drop cached media (keeps init segments and indexes): this session isn't playing.
    func trim() {
        idle = true
        inFlight?.cancel()
        cache = [:]
        cacheOrder = []
        cacheBytes = 0
    }

    /// ftyp + moov of a format (what HLS's EXT-X-MAP wants; the sidx is left out).
    func initSegment(_ itag: Int) async throws -> Data {
        guard let f = format(itag) else { throw SabrFailure.noMedia }
        // AVPlayer loads other qualities' playlists (and so their inits) while it plays one.
        // Ask for this one just long enough to get its init, then go back to the one playing,
        // or the two would keep cancelling each other's requests.
        let playing = currentVideo
        if !f.isAudio, inits[itag] == nil { select(f) }
        defer {
            if let playing, playing.itag != itag, currentVideo?.itag == itag { currentVideo = playing }
        }
        try await fetch(Key(itag: itag, number: 0), atMs: lastPositionMs)
        guard let d = inits[itag] else { throw lastError ?? SabrFailure.noMedia }
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
        idle = false
        let key = Key(itag: itag, number: number)
        guard let f = format(itag) else { throw SabrFailure.noMedia }
        if !f.isAudio { select(f) }
        if indexes[itag] == nil { _ = try await initSegment(itag) }
        guard let idx = indexes[itag], number >= 1, number <= idx.count else { throw SabrFailure.noMedia }
        lastPositionMs = idx[number - 1].start
        if cache[key] == nil {
            // Aim inside the segment: SABR answers from the segment containing the position.
            try await fetch(key, atMs: idx[number - 1].start + min(50, idx[number - 1].duration / 4))
        }
        guard let d = cache[key] else { throw lastError ?? SabrFailure.noMedia }
        prefetch(after: number, itag: itag)
        return d
    }

    // MARK: Requests

    private func select(_ video: DashFormat) {
        idle = false
        audioOnly = false
        currentVideo = video
    }

    /// Waits until `key` is cached, starting (or redirecting) the request as needed.
    private func fetch(_ key: Key, atMs: Double) async throws {
        for attempt in 0..<4 {
            if isCached(key) { return }
            let at = atMs + Double(attempt) * 200
            if inFlight == nil || !inFlightCovers(at) { startRequest(atMs: at) }
            await waitFor(key)
            if isCached(key) { return }
            if attempt >= 1, let e = lastError, !(e is CancellationError) { throw e }
        }
        throw lastError ?? SabrFailure.notDelivered(key.number == 0 ? "init of itag \(key.itag)" : "itag \(key.itag) segment \(key.number)")
    }

    private func isCached(_ key: Key) -> Bool {
        key.number == 0 ? inits[key.itag] != nil : cache[key] != nil
    }

    /// Not the playing session (trimmed): no fetching ahead until playback asks again.
    private var idle = false
    /// Whether the last answer carried any media (an empty one doesn't get an automatic follow-up).
    private var lastAnswerHadMedia = true

    /// How far past its start position the server says it sends per answer
    /// (NextRequestPolicy target readahead; ~15 s audio / ~25 s video seen).
    private var readaheadMs: Double = 15_000

    /// The running request will deliver `ms` (same video format; from the audio segment
    /// containing its start to the readahead the server announced).
    private func inFlightCovers(_ ms: Double) -> Bool {
        let video = audioOnly ? nil : currentVideo?.itag
        return inFlightVideo == video && ms >= inFlightStartMs - 11_000 && ms < inFlightStartMs + readaheadMs
    }

    private func startRequest(atMs: Double) {
        inFlight?.cancel()
        inFlightGeneration += 1
        let generation = inFlightGeneration
        inFlightStartMs = atMs
        inFlightVideo = audioOnly ? nil : currentVideo?.itag
        lastError = nil
        inFlight = Task {
            do {
                try await self.request(atMs: atMs)
            } catch {
                await self.recordError(error, generation: generation)
            }
            await self.requestEnded(generation)
        }
    }

    private func recordError(_ error: Error, generation: Int) {
        guard generation == inFlightGeneration else { return }
        if (error as? URLError)?.code == .cancelled || error is CancellationError { return }
        lastError = error
    }

    /// Wakes everyone waiting on this request (they re-check and retry if needed).
    private func requestEnded(_ generation: Int) {
        guard generation == inFlightGeneration else { return }
        inFlight = nil
        let all = waiters
        waiters = []
        for w in all { w.continuation.resume() }
        // Back to back: keep filling ahead without waiting for AVPlayer's next ask.
        if lastError == nil, all.isEmpty, lastAnswerHadMedia { continueAhead() }
    }

    private func waitFor(_ key: Key) async {
        if isCached(key) || inFlight == nil { return }
        await withCheckedContinuation { c in
            waiters.append(Waiter(id: UUID(), key: key, continuation: c))
        }
    }

    /// After AVPlayer took a segment.
    private func prefetch(after number: Int, itag: Int) { continueAhead() }

    /// Keep ~45 s cached ahead of the furthest point AVPlayer has asked for, in every playing
    /// track (but never more than half the cache), starting the next request at the first gap.
    private func continueAhead() {
        guard inFlight == nil, !idle else { return }
        let tracks = [audio.itag] + (audioOnly ? [] : [currentVideo?.itag].compactMap { $0 })
        var gaps: [Double] = []
        for itag in tracks {
            guard let idx = indexes[itag],
                  var i = idx.firstIndex(where: { lastPositionMs < $0.start + $0.duration }) else { continue }
            var ahead = 0.0, bytes = 0
            while i < idx.count, ahead < 45_000, bytes < cacheLimit / 2 {
                guard let d = cache[Key(itag: itag, number: i + 1)] else {
                    gaps.append(idx[i].start + min(50, idx[i].duration / 4))
                    break
                }
                ahead += idx[i].duration
                bytes += d.count
                i += 1
            }
        }
        if let at = gaps.min() { startRequest(atMs: at) }
    }

    private func request(atMs playerTimeMs: Double) async throws {
        for _ in 0..<4 {   // redirects
            let redirected = try await requestOnce(atMs: playerTimeMs)
            if !redirected { return }
        }
        throw SabrFailure.server("too many redirects")
    }

    /// One POST, processed as it streams in. Returns true when the server redirected.
    private func requestOnce(atMs playerTimeMs: Double) async throws -> Bool {
        let elapsed = Int64(Date().timeIntervalSince(started) * 1000)
        let video = audioOnly ? nil : (currentVideo ?? videos.first)
        let withInit = Array(inits.keys).compactMap(format)
        let selected = [audio] + (video.map { [$0] } ?? [])

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
            abr.string(69, audio.audioTrackId)          // audio language track
        }
        for f in withInit { body.message(2) { Self.formatId(f, &$0) } }
        // What we already hold from this position on, so the server skips it.
        for f in selected {
            guard let r = bufferedRun(f.itag, from: playerTimeMs) else { continue }
            body.message(3) { b in
                b.message(1) { Self.formatId(f, &$0) }
                b.int(2, Int64(r.startMs))
                b.int(3, Int64(r.durationMs))
                b.int(4, r.first)
                b.int(5, r.last)
                b.message(6) { t in
                    t.int(1, Int64(r.startMs))
                    t.int(2, Int64(r.durationMs))
                    t.int(3, 1000)
                }
            }
        }
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

        var parser = UMPStreamParser()
        var firstByte: Date?
        var received = 0
        var pending: [Int: (itag: Int, isInit: Bool, number: Int, data: Data)] = [:]
        var redirected = false
        var mediaCount = 0
        for try await event in Self.streamer.stream(req) {
            let parts: [UMP.Part]
            switch event {
            case .status(let code):
                guard code == 200 else { throw SabrFailure.http(code) }
                continue
            case .data(let chunk):
                if firstByte == nil { firstByte = Date() } else { received += chunk.count }
                parts = parser.feed(chunk)
            }
            for part in parts {
                switch part.type {
                case 20:   // MEDIA_HEADER
                    let h = ProtoMessage(part.payload)
                    pending[Int(h.uint(1) ?? 0)] = (Int(h.int(3) ?? 0), h.bool(8), Int(h.int(9) ?? 0), Data())
                case 21:   // MEDIA: header id byte + bytes
                    guard let first = part.payload.first else { continue }
                    pending[Int(first)]?.data.append(part.payload.dropFirst())
                case 22:   // MEDIA_END
                    guard let first = part.payload.first, let seg = pending.removeValue(forKey: Int(first)) else { continue }
                    mediaCount += 1
                    store(seg.itag, isInit: seg.isInit, number: seg.number, data: seg.data)
                case 35:   // NEXT_REQUEST_POLICY
                    let policy = ProtoMessage(part.payload)
                    if let c = policy.data(7) { cookie = c }
                    let target = audioOnly ? policy.int(1) : policy.int(2)
                    if let target, target > 2_000 { readaheadMs = Double(target) }
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
        }
        if !redirected { lastAnswerHadMedia = mediaCount > 0 }
        if let firstByte { SabrBandwidth.record(bytes: received, seconds: Date().timeIntervalSince(firstByte)) }
        return redirected && mediaCount == 0
    }

    /// The run of consecutive cached segments of `itag` starting at the one containing `ms`.
    private func bufferedRun(_ itag: Int, from ms: Double) -> (first: Int, last: Int, startMs: Double, durationMs: Double)? {
        guard let idx = indexes[itag],
              let i = idx.firstIndex(where: { ms >= $0.start && ms < $0.start + $0.duration }) else { return nil }
        var last = i
        guard cache[Key(itag: itag, number: i + 1)] != nil else { return nil }
        while last + 1 < idx.count, cache[Key(itag: itag, number: last + 2)] != nil { last += 1 }
        let start = idx[i].start
        return (i + 1, last + 1, start, idx[last].start + idx[last].duration - start)
    }

    private func store(_ itag: Int, isInit: Bool, number: Int, data: Data) {
        guard let f = format(itag) else { return }
        let key = Key(itag: itag, number: isInit ? 0 : number)
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
        } else {
            guard cache[key] == nil else { return }
            cache[key] = data
            cacheOrder.append(key)
            cacheBytes += data.count
            if cacheBytes > cacheLimit { evict() }
        }
        // Wake whoever was waiting for exactly this.
        let ready = waiters.filter { $0.key == key }
        guard !ready.isEmpty else { return }
        waiters.removeAll { $0.key == key }
        for w in ready { w.continuation.resume() }
    }

    /// Over the limit: first what lies more than a minute behind playback, then the oldest.
    private func evict() {
        let behind = lastPositionMs - 60_000
        if behind > 0 {
            let old = cacheOrder.filter { k in
                guard let idx = indexes[k.itag], k.number >= 1, k.number <= idx.count else { return true }
                return idx[k.number - 1].start + idx[k.number - 1].duration < behind
            }
            for k in old where cacheBytes > cacheLimit * 3 / 4 {
                cacheBytes -= cache.removeValue(forKey: k)?.count ?? 0
            }
            cacheOrder.removeAll { cache[$0] == nil }
        }
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

/// Streams a POST's response in chunks (URLSession's async `data(for:)` only returns at the end).
final class SabrStreamer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Event { case status(Int), data(Data) }

    private let lock = NSLock()
    private var streams: [Int: AsyncThrowingStream<Event, Error>.Continuation] = [:]
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 30
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    func stream(_ request: URLRequest) -> AsyncThrowingStream<Event, Error> {
        let task = session.dataTask(with: request)
        let id = task.taskIdentifier
        let s = AsyncThrowingStream<Event, Error> { c in
            lock.withLock { streams[id] = c }
            c.onTermination = { _ in task.cancel() }
        }
        task.resume()
        return s
    }

    private func continuation(_ task: URLSessionTask) -> AsyncThrowingStream<Event, Error>.Continuation? {
        lock.withLock { streams[task.taskIdentifier] }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        continuation(dataTask)?.yield(.status((response as? HTTPURLResponse)?.statusCode ?? 0))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        continuation(dataTask)?.yield(.data(data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let c = lock.withLock { streams.removeValue(forKey: task.taskIdentifier) }
        if let error { c?.finish(throwing: error) } else { c?.finish() }
    }
}

/// Download speed seen on SABR answers (time to first byte left out), kept across launches.
/// Auto quality is picked from it: AVPlayer can't judge, it only sees the loopback server.
enum SabrBandwidth {
    private static let lock = NSLock()
    private static let key = "sabrBandwidthBps"
    nonisolated(unsafe) private static var estimate: Double? = {
        let v = UserDefaults.standard.double(forKey: key)
        return v > 0 ? v : nil
    }()

    static func record(bytes: Int, seconds: Double) {
        guard bytes > 512 * 1024, seconds > 0.05 else { return }   // small answers say little
        let sample = Double(bytes) * 8 / seconds
        let v: Double = lock.withLock {
            let next = estimate.map { $0 * 0.7 + sample * 0.3 } ?? sample
            estimate = next
            return next
        }
        UserDefaults.standard.set(v, forKey: key)
    }

    static var bitsPerSecond: Double? { lock.withLock { estimate } }

    /// Variant bandwidth (video + audio) AVPlayer may pick in Auto: the speed with 1.5×
    /// headroom; 6 Mbps (about 1080p) before anything is measured.
    static var peakBitRate: Double { (bitsPerSecond ?? 9_000_000) / 1.5 }

    /// After a stall: the connection didn't carry `bitsPerSecond` (video + audio), so the
    /// estimate drops just under what Auto would need for it.
    static func limit(toBelow bitsPerSecond: Int) {
        let v: Double = lock.withLock {
            let next = min(estimate ?? .infinity, Double(bitsPerSecond) * 1.4)
            estimate = next
            return next
        }
        UserDefaults.standard.set(v, forKey: key)
    }

    /// The best of `videos` (best first) for Auto: the user's default quality when set; else
    /// what the measured speed carries with headroom (video + audio × 1.5), up to 4K; 1080p
    /// before anything has been measured.
    static func autoVideo(_ videos: [DashFormat], audioBitrate: Int, defaultQuality: Int) -> DashFormat? {
        guard !videos.isEmpty else { return nil }
        let lines: (DashFormat) -> Int = { $0.width > 0 ? min($0.width, $0.height) : $0.height }
        if defaultQuality > 0 {
            return videos.first { lines($0) <= defaultQuality } ?? videos.last
        }
        guard let bps = bitsPerSecond else {
            return videos.first { lines($0) <= 1080 } ?? videos.last
        }
        return videos.first { lines($0) <= 2160 && Double($0.bitrate + audioBitrate) * 1.5 <= bps } ?? videos.last
    }
}
