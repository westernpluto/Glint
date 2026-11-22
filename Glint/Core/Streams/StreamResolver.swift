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

/// One audio language of a multi-language video.
struct AudioTrackOption: Identifiable, Hashable {
    var id: String
    var name: String
    var isDefault: Bool
    var format: DashFormat
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
    /// User agent for `progressiveURL` when it came from another client's response.
    var progressiveUserAgent: String?
    /// Set when the formats are fetched over SABR (their `url`s are placeholders).
    var sabr: SabrSession?
    /// Signed-in web response: where to report watch progress (`YouTubeWatchSync`).
    var tracking: PlaybackTracking?
    /// More than one entry when the video has several audio languages (dubs).
    var audioTracks: [AudioTrackOption] = []

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
    var clients: [ClientProfile] = [.visionOS, .tvSamsung, .mweb, .androidVR, .androidVR("1.60.19"), .ios, .android]

    /// Clients whose streams recently failed during playback, and when. They are tried last.
    private var penalized: [String: Date] = [:]
    /// Signed in, YouTube's stream protection kept refusing the account-bound token: fetch
    /// streams without the account (as before signing in) and use the account only for the
    /// watch-history reports. Until the app restarts.
    /// Remembered across launches (only matters while signed in).
    /// When the switch happened; after 12 hours SABR with the account gets another try (in case
    /// YouTube's stream protection changes back). Read once at launch, so a session doesn't flip.
    private static let anonymousKey = "anonymousStreamsSince.v3"
    private static let anonymousRetry: TimeInterval = 12 * 60 * 60
    private var _anonymousStreams: Bool = {
        let since = UserDefaults.standard.double(forKey: StreamResolver.anonymousKey)
        return since > 0 && Date().timeIntervalSince1970 - since < StreamResolver.anonymousRetry
    }()
    var anonymousStreams: Bool { cacheLock.withLock { _anonymousStreams } }
    func useAnonymousStreams(because reason: String = "Stream protection refuses the account's token") {
        let changed: Bool = cacheLock.withLock {
            _refusals += 1
            defer { _anonymousStreams = true }
            if !_anonymousStreams { cache = [:] }   // links resolved with the account
            return !_anonymousStreams
        }
        if changed { UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.anonymousKey) }
        trace?("\(reason): streaming without the account (history still syncs)")
    }
    /// Page tokens didn't satisfy stream protection: don't try the page again this app session.
    private var _pageOff = false
    func stopUsingPage() { cacheLock.withLock { _pageOff = true } }
    private var pageOff: Bool { cacheLock.withLock { _pageOff } }
    /// How many refusals so far (to tell whether one happened during a resolution).
    private var _refusals = 0
    private var refusals: Int { cacheLock.withLock { _refusals } }
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

    /// What playback is about to do, so a SABR session's first request can fetch exactly that.
    /// At launch: player script, solver and PO token minter ready before the first video.
    func prewarm() async {
        if tube.visitorData == nil { await tube.warmUp() }
        async let solver: Void = JSChallengeSolver.shared.prewarm(session: tube.session)
        if let vd = tube.visitorData {
            _ = try? await PoTokenProvider.shared.token(for: PoTokenProvider.contentBinding(visitorData: vd), visitorData: vd)
        }
        await solver
    }

    struct Hints: Sendable {
        var startAt: Double = 0
        var audioOnly = false
        var defaultQuality = 0
    }

    func resolve(videoId: String, hints: Hints = Hints()) async throws -> ResolvedStream {
        if let hit = cached(videoId) { return hit }
        var stream = try await resolveFresh(videoId: videoId, hints: hints)
        // A stream that didn't come through the account (VISIONOS, account-free mode): a
        // signed-in request just for the watch-history links.
        if stream.tracking == nil, tube.isSignedIn, !stream.isLive {
            stream.tracking = await accountTracking(videoId)
        }
        if !stream.isLive { store(stream, for: videoId) }
        return stream
    }

    private func resolveFresh(videoId: String, hints: Hints, isRetry: Bool = false, skipPage: Bool = false) async throws -> ResolvedStream {
        var lastReason: String?
        var limited: ResolvedStream?
        var progressive: ResolvedStream?
        var refusals = 0, botChecks = 0
        var answeredWithoutLinks = false
        let accountSignedIn = tube.isSignedIn
        let refusalsBefore = refusals
        // The signed-in page's session (tokens minted inside youtube.com with the account).
        // When it works the account's streams get a try even in account-free mode.
        let usePage = accountSignedIn && !skipPage && !pageOff
        let page = usePage ? await AccountPoTokenProvider.shared.currentSession() : nil
        if usePage {
            if let page {
                trace?("Signed-in page: tokens from youtube.com with your account (account id \(page.dataSyncId == nil ? "missing" : "found"))")
            } else if let e = await AccountPoTokenProvider.shared.lastError {
                trace?("Signed-in page unavailable (\(e))")
            }
        }
        let anonymous = accountSignedIn && anonymousStreams && page == nil
        // Whether the stream requests carry the account.
        let signedIn = accountSignedIn && !anonymous
        var order = orderedClients
        if signedIn {
            // Signed in, the clients that take cookies carry the account (yt-dlp's choice):
            // the TV client (direct links up to 4K), MWEB, then Safari WEB for its HLS manifest.
            // VISIONOS stays first though: direct 4K links without the account (history
            // comes from a separate signed-in request), the others back it up.
            let vision = order.filter { $0.clientName == "VISIONOS" }
            let web = order.filter(\.isWebPlayback) + [.webSafari]
            let rest = order.filter { !$0.isWebPlayback && $0.clientName != "VISIONOS" }
            if let page {
                // The signed-in page works: first the player response embedded in the watch page
                // it fetches (desktop WEB, its version and user agent, its tokens), i.e. what the
                // website itself plays from. If stream protection still holds that SABR stream,
                // Glint switches to VISIONOS at once.
                let watch = ClientProfile(clientName: "WEB", clientVersion: page.clientVersion ?? ClientProfile.webSafari.clientVersion,
                                          clientId: 1, host: "www.youtube.com", userAgent: ClientProfile.web.userAgent,
                                          isWebPlayback: true, fromWatchPage: true)
                order = [watch] + vision + web + rest
            } else {
                order = vision + web + rest
            }
        }
        for client in order {
            var webPlayer: JSChallengeSolver.Player?
            var playerToken: String?
            let pageClient = page != nil && client.isWebPlayback && client.needsPoToken
            if client.isWebPlayback {
                if tube.visitorData == nil { await tube.warmUp() }
                // A token bound to the video, sent with the request like the website does (it's
                // what YouTube looks at before asking "are you a bot?"); minted while the player
                // script loads.
                let visitorData = tube.visitorData
                let wantsToken = client.needsPoToken
                async let token = Self.optionalVideoToken(wantsToken ? videoId : nil, visitorData: visitorData)
                do { webPlayer = try await JSChallengeSolver.shared.player(session: tube.session) } catch {
                    trace?("\(client.key): player script unavailable (\(error.localizedDescription))")
                    _ = await token
                    continue
                }
                switch await token {
                case .success(let t)?: playerToken = t
                case .failure(let e)?: trace?("\(client.key): player PO token failed (\(e.localizedDescription))")
                case nil: break
                }
                if pageClient, let t = await AccountPoTokenProvider.shared.token(for: videoId) { playerToken = t }
            }
            var json: JSON
            if client.fromWatchPage {
                guard let data = await AccountPoTokenProvider.shared.pagePlayerResponse(videoId: videoId, sts: webPlayer?.sts),
                      let parsed = try? JSON.parse(data) else {
                    let why = await AccountPoTokenProvider.shared.lastPlayerError ?? "no response"
                    trace?("\(client.key) (signed-in page): no player response (\(why))")
                    continue
                }
                json = parsed
                trace?("\(client.key) (signed-in page): player response as the website gets it")
            } else {
                do {
                    json = try await player(videoId: videoId, client: client, sts: webPlayer?.sts,
                                            poToken: playerToken, authenticated: client.isWebPlayback && signedIn,
                                            visitorOverride: pageClient ? page?.visitorData : nil)
                } catch {
                    trace?("\(client.key): request failed (\(error.localizedDescription))")
                    continue
                }
            }
            guard json.at("playabilityStatus.status").string == "OK" else {
                let reason = json.at("playabilityStatus.reason").string
                lastReason = reason ?? lastReason
                refusals += 1
                if Self.isBotCheck(reason) { botChecks += 1 }
                trace?("\(client.key)\(client.isWebPlayback && signedIn ? " (signed in)" : ""): \(json.at("playabilityStatus.status").string ?? "?") \(reason ?? "")")
                continue
            }
            if let webPlayer {
                json = await prepareWebFormats(json, client: client, player: webPlayer, videoToken: playerToken,
                                               accountBound: signedIn && client.isWebPlayback,
                                               page: pageClient ? page : nil)
            }
            let built = await build(json, client: client, hints: hints)
            // Stream protection just refused the account's token (build still hands back the
            // 360p file): start over without the account.
            if signedIn, refusals > refusalsBefore {
                do {
                    return try await resolveFresh(videoId: videoId, hints: hints, isRetry: isRetry, skipPage: true)
                } catch {
                    // Without the account it doesn't play at all (bot check, sign-in only…):
                    // back to the account's streams.
                    trace?("Without the account: \(error.localizedDescription) → back to streaming with it")
                    cacheLock.withLock { _anonymousStreams = false }
                    UserDefaults.standard.removeObject(forKey: Self.anonymousKey)
                }
            }
            guard var stream = built else {
                if client.isWebPlayback { answeredWithoutLinks = true }
                trace?("\(client.key): no usable formats")
                continue
            }
            stream.clientKey = client.key
            // Only a request that carried the account reports to it.
            if client.isWebPlayback, signedIn { stream.tracking = PlaybackTracking(json) }
            if stream.sabr != nil {
                if let p = progressive, let url = p.progressiveURL {
                    stream.progressiveURL = url
                    stream.progressiveUserAgent = p.streamUserAgent
                }
                return stream
            }
            if stream.hlsURL != nil {
                trace?("\(client.key): \(stream.isLive ? "live " : "")HLS, \(stream.options.count) qualities")
                // Fall back to a 360p file that another client already got (MWEB's has played
                // where the HLS client's own one couldn't be opened).
                if !stream.isLive, let p = progressive, let url = p.progressiveURL {
                    stream.progressiveURL = url
                    stream.progressiveUserAgent = p.streamUserAgent
                }
                return stream
            }
            if stream.progressiveURL != nil, stream.audio == nil {
                // Full length but 360p: keep it in case nothing better turns up (the Safari
                // WEB client may still get HD over HLS).
                trace?("\(client.key): only the 360p muxed file has a link; trying the others for HD")
                if progressive == nil { progressive = stream }
                continue
            }
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
        if refusals > 0, botChecks == refusals {
            // YouTube flags the visitor session (and the network it comes from). A new visitor
            // id sometimes clears it; signing in is yt-dlp's real answer.
            if !isRetry, !signedIn {
                trace?("Every client got the bot check: retrying once with a new visitor id")
                tube.visitorData = nil
                await tube.warmUp()
                await PoTokenProvider.shared.reset()
                return try await resolveFresh(videoId: videoId, hints: hints, isRetry: true, skipPage: skipPage)
            }
            if answeredWithoutLinks {
                throw InnerTubeError.unplayable("YouTube let your account through but sent no stream Glint can play for this video (only its own streaming format). Try again later.")
            }
            throw InnerTubeError.unplayable(signedIn
                ? "YouTube is asking to confirm you're not a bot, even signed in. Try again in a while or on another network."
                : "YouTube is asking to confirm you're not a bot. Sign in to YouTube in Settings, then try again.")
        }
        throw InnerTubeError.unplayable(lastReason ?? "This video can't be played right now.")
    }

    /// A SABR-backed stream: the same adaptive formats, fetched through `SabrSession` and served
    /// to AVPlayer as HLS by `SabrServer`. The first request (audio from the start) must answer.
    private func sabrStream(_ json: JSON, details: VideoDetails, client: ClientProfile, hints: Hints) async -> ResolvedStream? {
        let sd = json["streamingData"]
        guard let s = sd[Self.sabrURLKey].string, let url = URL(string: s),
              let configText = json.at("playerConfig.mediaCommonConfig.mediaUstreamerRequestConfig.videoPlaybackUstreamerConfig").string,
              let ustreamer = Self.base64URLData(configText) else { return nil }
        let formats = sd["adaptiveFormats"].array.compactMap { DashFormat($0, placeholderURL: url) }
        let (defaultAudio, tracks) = Self.audioChoices(formats)
        guard let audio = defaultAudio else { return nil }
        let videos = formats.filter { !$0.isAudio && codecSupported($0.codecs) }
        var best: [String: StreamOption] = [:]
        for v in videos {
            let o = StreamOption(height: v.height, width: v.width, fps: v.fps, codec: v.codecFamily,
                                 hdr: v.hdrRange != nil, bitrate: v.bitrate, source: .dash(v))
            let key = "\(o.lines)-\(o.fps)-\(o.hdr)"
            if let cur = best[key], prefer(cur, over: o) { continue }
            best[key] = o
        }
        let options = best.values.sorted(by: Self.order)
        let videoFormats = options.compactMap { if case .dash(let f) = $0.source { return f }; return nil }
        // The stream token; if stream protection refuses it, the video-bound one.
        let tokens = [sd[Self.sabrTokenKey].string, sd[Self.sabrVideoTokenKey].string].compactMap { $0 }
        var session: SabrSession!
        for (attempt, token) in (tokens.isEmpty ? [nil] : tokens.map(Optional.some)).enumerated() {
            let videoId = details.id
            let visitorData = tube.visitorData
            var config = SabrConfig(videoId: videoId, url: url, ustreamerConfig: ustreamer,
                                    clientNameId: client.clientId, clientVersion: client.clientVersion,
                                    poToken: token.flatMap(Self.base64URLData),
                                    userAgent: client.userAgent)
            if client.isWebPlayback {
                // Stream protection asking again: a fresh token, alternating between the
                // binding the first one had and the video id (googlevideo's choice).
                let binding = sd[Self.sabrBindingKey].string ?? videoId
                let fromPage = sd[Self.sabrPageKey].bool ?? false
                let counter = MintCounter()
                config.mintToken = {
                    let b = counter.next() % 2 == 0 ? binding : videoId
                    let t: String?
                    if fromPage {
                        t = await AccountPoTokenProvider.shared.token(for: b, fresh: true)
                    } else {
                        t = try? await PoTokenProvider.shared.token(for: b, visitorData: visitorData, fresh: true)
                    }
                    return t.flatMap(Self.base64URLData)
                }
            }
            session = SabrSession(config: config, audio: audio, videos: videoFormats)
            do {
                try await SabrServer.shared.start()
                // Audio plus the video Auto will play, from where playback starts: one round trip
                // gets both init segments and the first media.
                let video = hints.audioOnly ? nil : SabrBandwidth.autoVideo(
                    session.videos, audioBitrate: audio.bitrate, defaultQuality: hints.defaultQuality)
                try await session.prepare(video: video, atMs: max(0, hints.startAt) * 1000)
                // Signed in and stream protection is already waiting on the token: it would play
                // the free first batch and then stop. Switch before playback starts.
                if tube.isSignedIn, await session.protectionPending {
                    stopUsingPage()
                    useAnonymousStreams(because: "Stream protection is holding the account's SABR stream")
                    return nil
                }
                if attempt > 0 { trace?("\(client.key): SABR ok with the video-bound token") }
                break
            } catch {
                var refused = false
                if case .protection? = error as? SabrSession.SabrFailure { refused = true }
                if refused, attempt + 1 < tokens.count {
                    trace?("\(client.key): SABR refused the stream token; trying the video-bound one")
                    continue
                }
                if refused, tube.isSignedIn { stopUsingPage(); useAnonymousStreams() }
                trace?("\(client.key): SABR failed (\(error.localizedDescription))")
                return nil
            }
        }
        trace?("\(client.key): SABR ok, \(options.count) qualities, audio itag \(audio.itag)")
        var stream = ResolvedStream(details: details, options: options, hlsURL: nil, manifest: nil,
                                    audio: audio, streamUserAgent: client.userAgent, isLive: false,
                                    captions: Captions.tracks(json))
        stream.sabr = session
        stream.audioTracks = tracks
        stream.progressiveURL = Self.progressiveURL(json)   // fallback if SABR breaks mid-play
        return stream
    }

    /// AAC audio: the best stream of each language track, the video's default track first
    /// (normally the original language; picking by bitrate alone could land on a dub).
    static func audioChoices(_ formats: [DashFormat]) -> (DashFormat?, [AudioTrackOption]) {
        let aac = formats.filter { $0.isAudio && $0.codecs.hasPrefix("mp4a") }
        var best: [String: DashFormat] = [:]
        for f in aac {
            let key = f.audioTrackId ?? ""
            if let cur = best[key], cur.bitrate >= f.bitrate { continue }
            best[key] = f
        }
        let tracks = best.map { key, f in
            AudioTrackOption(id: key, name: f.audioTrackName ?? (key.isEmpty ? "Default" : key),
                             isDefault: f.audioIsDefault, format: f)
        }.sorted { a, b in a.isDefault != b.isDefault ? a.isDefault : a.name < b.name }
        let chosen = tracks.first { $0.isDefault }?.format ?? aac.max { $0.bitrate < $1.bitrate }
        return (chosen, tracks.count > 1 ? tracks : [])
    }

    private static func base64URLData(_ s: String) -> Data? {
        var t = (s.removingPercentEncoding ?? s).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    /// Fetches each variant's and audio track's playlist and the first bytes of its first
    /// segment; drops what YouTube refuses (and variants whose audio group lost every track).
    private func validated(_ m: HLSManifest, client: ClientProfile, label: String) async -> HLSManifest {
        let ua = client.userAgent
        let variants = m.variants.filter { codecSupported($0.videoCodec) }
        let media = m.headerLines.enumerated().compactMap { i, line -> (Int, URL)? in
            guard line.hasPrefix("#EXT-X-MEDIA"), let u = HLSManifest.attributes(String(line.drop { $0 != ":" }.dropFirst()))["URI"],
                  let url = URL(string: u) else { return nil }
            return (i, url)
        }
        var variantOK: [Int: Bool] = [:], mediaOK: [Int: Bool] = [:]
        var refusals: [String: Int] = [:]   // "playlist 403" → count
        await withTaskGroup(of: (Bool, Int, String?).self) { group in
            for (i, v) in variants.enumerated() {
                group.addTask { (true, i, await self.hlsRefusal(v.uri, userAgent: ua)) }
            }
            for (i, url) in media {
                group.addTask { (false, i, await self.hlsRefusal(url, userAgent: ua)) }
            }
            for await (isVariant, i, refusal) in group {
                // Only a refused playlist drops an entry. A refused segment probe is just
                // logged: YouTube has refused Glint's probe while serving AVPlayer the same
                // segments.
                let ok = !(refusal?.hasPrefix("playlist") ?? false)
                if isVariant { variantOK[i] = ok } else { mediaOK[i] = ok }
                if let refusal { refusals[refusal, default: 0] += 1 }
            }
        }

        var out = m
        let groupOf: (String) -> String? = { HLSManifest.attributes(String($0.drop { $0 != ":" }.dropFirst()))["GROUP-ID"] }
        let allGroups = Set(media.compactMap { groupOf(m.headerLines[$0.0]) })
        out.headerLines = m.headerLines.enumerated().filter { mediaOK[$0.offset] != false }.map { $0.element }
        let liveGroups = Set(out.headerLines.filter { $0.hasPrefix("#EXT-X-MEDIA") }.compactMap(groupOf))
        out.variants = variants.enumerated().filter { i, v in
            guard variantOK[i] != false else { return false }
            guard let g = HLSManifest.attributes(v.attributes)["AUDIO"], allGroups.contains(g) else { return true }
            return liveGroups.contains(g)
        }.map { $0.element }
        let why = refusals.sorted { $0.key < $1.key }.map { "\($0.value)× \($0.key)" }.joined(separator: ", ")
        trace?("\(client.key): HLS check (\(label)) \(out.variants.count)/\(variants.count) qualities, \(mediaOK.values.filter { $0 }.count)/\(media.count) audio tracks kept\(why.isEmpty ? "" : "; refused: " + why)")
        return out
    }

    /// Nil when the playlist loads and its first segment answers (network trouble counts as
    /// fine); otherwise what was refused, e.g. "segment 403".
    private func hlsRefusal(_ url: URL, userAgent: String) async -> String? {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 6
        guard let (data, resp) = try? await tube.session.data(for: req),
              let code = (resp as? HTTPURLResponse)?.statusCode else { return nil }
        guard (200..<300).contains(code) else { return "playlist \(code)" }
        let text = String(decoding: data, as: UTF8.self)
        guard let line = text.split(whereSeparator: \.isNewline).first(where: { !$0.hasPrefix("#") && !$0.isEmpty }),
              let seg = URL(string: String(line), relativeTo: url)?.absoluteURL else { return nil }
        guard let status = await status(seg, at: 0, userAgent: userAgent).code else { return nil }
        return (200..<300).contains(status) ? nil : "segment \(status)"
    }

    /// Playback-tracking links from a signed-in MWEB player request (only the history part of
    /// the answer is used).
    private func accountTracking(_ videoId: String) async -> PlaybackTracking? {
        let sts = try? await JSChallengeSolver.shared.player(session: tube.session).sts
        let token = try? await Self.videoToken(videoId, visitorData: tube.visitorData).get()
        guard let json = try? await player(videoId: videoId, client: .mweb, sts: sts, poToken: token, authenticated: true)
        else { return nil }
        let t = PlaybackTracking(json)
        if t == nil { trace?("No watch-history links for your account (\(json.at("playabilityStatus.status").string ?? "?"))") }
        return t
    }

    private static func optionalVideoToken(_ videoId: String?, visitorData: String?) async -> Result<String, Error>? {
        guard let videoId else { return nil }
        return await videoToken(videoId, visitorData: visitorData)
    }

    private static func videoToken(_ videoId: String, visitorData: String?) async -> Result<String, Error> {
        do { return .success(try await PoTokenProvider.shared.token(for: videoId, visitorData: visitorData)) }
        catch { return .failure(error) }
    }

    private static func isBotCheck(_ reason: String?) -> Bool {
        guard let r = reason?.lowercased() else { return false }
        return r.contains("not a bot") || (r.contains("sign in") && r.contains("confirm"))
    }

    private func build(_ json: JSON, client: ClientProfile, hints: Hints = Hints()) async -> ResolvedStream? {
        let details = Self.details(json["videoDetails"], microformat: json.at("microformat.playerMicroformatRenderer"))
        let sd = json["streamingData"]

        let formats = sd["adaptiveFormats"].array.compactMap { DashFormat($0) }

        // No direct links: YouTube's own protocol (SABR) gets every quality with separate audio.
        if formats.isEmpty, !details.isLive, let stream = await sabrStream(json, details: details, client: client, hints: hints) {
            return stream
        }

        // HLS: live streams, and regular videos when YouTube sent no direct adaptive links
        // (signed-in web sessions often get only its streaming protocol plus an HLS manifest).
        // Otherwise the adaptive formats below play, so every quality, audio-only and the
        // checks apply.
        if details.isLive || formats.isEmpty {
            let candidates = [("account/visitor token", sd["hlsManifestUrl"].string),
                              ("video-bound token", sd[Self.videoBoundManifestKey].string)]
            for (label, s) in candidates {
                guard let s, let url = URL(string: s),
                      let text = try? await fetchText(url, userAgent: client.userAgent) else { continue }
                var m = HLSManifest(text: text, baseURL: url)
                // Regular videos: YouTube may refuse some of the qualities or audio tracks in
                // the manifest (403), so only those that answer are kept.
                if !details.isLive { m = await validated(m, client: client, label: label) }
                if !m.variants.isEmpty {
                    // The muxed 360p file rides along: if the player is refused the HLS
                    // segments, it switches to that instead of failing.
                    return ResolvedStream(details: details, options: hlsOptions(m), hlsURL: url, manifest: m,
                                          audio: nil, streamUserAgent: client.userAgent, isLive: details.isLive,
                                          captions: Captions.tracks(json),
                                          progressiveURL: details.isLive ? nil : Self.progressiveURL(json))
                }
                if details.isLive { break }
            }
        }

        let (audio, tracks) = Self.audioChoices(formats)
        let videos = formats.filter { !$0.isAudio && codecSupported($0.codecs) }
        guard audio != nil || !videos.isEmpty else {
            // Only the muxed 360p file has a link: play that (full length, video + audio).
            guard let url = Self.progressiveURL(json) else { return nil }
            return ResolvedStream(details: details, options: [], hlsURL: nil, manifest: nil,
                                  audio: nil, streamUserAgent: client.userAgent, isLive: details.isLive,
                                  captions: Captions.tracks(json), progressiveURL: url)
        }

        var best: [String: StreamOption] = [:]
        for v in videos {
            let o = StreamOption(height: v.height, width: v.width, fps: v.fps, codec: v.codecFamily,
                                 hdr: v.hdrRange != nil, bitrate: v.bitrate, source: .dash(v))
            let key = "\(o.lines)-\(o.fps)-\(o.hdr)"
            if let cur = best[key], prefer(cur, over: o) { continue }
            best[key] = o
        }
        let options = best.values.sorted(by: Self.order)
        var stream = ResolvedStream(details: details, options: options, hlsURL: nil, manifest: nil,
                                    audio: audio, streamUserAgent: client.userAgent, isLive: details.isLive,
                                    captions: Captions.tracks(json))
        stream.audioTracks = tracks
        return stream
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

    private func player(videoId: String, client: ClientProfile, sts: Int? = nil,
                        poToken: String? = nil, authenticated: Bool = false,
                        visitorOverride: String? = nil) async throws -> JSON {
        var playback: [String: Any] = ["html5Preference": "HTML5_PREF_WANTS"]
        if let sts { playback["signatureTimestamp"] = sts }
        var body: [String: Any] = [
            "videoId": videoId,
            "contentCheckOk": true,
            "racyCheckOk": true,
            "playbackContext": ["contentPlaybackContext": playback],
        ]
        if let poToken { body["serviceIntegrityDimensions"] = ["poToken": poToken] }
        return try await tube.call("player", client: client, body: body, authenticated: authenticated,
                                   visitorOverride: visitorOverride)
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
    private func prepareWebFormats(_ json: JSON, client: ClientProfile, player: JSChallengeSolver.Player,
                                   videoToken: String?, accountBound: Bool,
                                   page: AccountPoTokenProvider.Session? = nil) async -> JSON {
        let keys = ["adaptiveFormats", "formats"]
        let pending = keys.flatMap { json.at("streamingData.\($0)").array.compactMap(PendingLink.init) }
        let hls = json.at("streamingData.hlsManifestUrl").string
        let hlsN = hls.flatMap(Self.manifestN)
        let sabr = json.at("streamingData.serverAbrStreamingUrl").string
        let sabrN = sabr.flatMap { URLComponents(string: $0)?.queryItems?.first { $0.name == "n" }?.value }
        let adaptiveLinks = json.at("streamingData.adaptiveFormats").array.compactMap(PendingLink.init).count
        trace?("\(client.key): \(adaptiveLinks) adaptive links, \(pending.count - adaptiveLinks) muxed, HLS \(hls == nil ? "no" : "yes")")
        guard !pending.isEmpty || hls != nil || sabr != nil else {
            trace?("\(client.key): YouTube sent no direct links (streaming-protocol-only session)")
            return json
        }

        let solutions: JSChallengeSolver.Solutions
        do {
            solutions = try await JSChallengeSolver.shared.solve(
                n: pending.compactMap(\.n) + [hlsN, sabrN].compactMap { $0 }, sig: pending.compactMap(\.s), player: player)
        } catch {
            trace?("\(client.key): challenges not solved (\(error.localizedDescription))")
            return json
        }

        var pot: String?
        // As in the versions where signed-in SABR played: the account's data sync id when the
        // player response carries it, otherwise the (anonymous) visitor id. Fetching the account
        // id separately (1.17.7) and minting for the account's visitor (1.18.4) made stream
        // protection hold every signed-in SABR stream at "pending".
        let visitorData = tube.visitorData
        let dataSyncId = accountBound ? json.at("responseContext.mainAppWebResponseContext.datasyncId").string : nil
        var bindingKind = dataSyncId != nil ? "account" : "visitor"
        var binding = dataSyncId ?? visitorData.map(PoTokenProvider.contentBinding(visitorData:))
        if let page, client.needsPoToken {
            // Minted in the signed-in page, bound to the account it reports.
            let b = page.dataSyncId ?? dataSyncId ?? PoTokenProvider.contentBinding(visitorData: page.visitorData)
            if let t = await AccountPoTokenProvider.shared.token(for: b) {
                pot = t
                binding = b
                bindingKind = "signed-in page"
            }
        }
        if pot == nil, let binding, client.needsPoToken {
            do {
                pot = try await PoTokenProvider.shared.token(for: binding, visitorData: visitorData)
            } catch {
                trace?("\(client.key): PO token failed (\(error.localizedDescription))")
            }
        }
        trace?("\(client.key): player \(player.id), solved \(solutions.n.count) n / \(solutions.sig.count) sig, PO token \(!client.needsPoToken ? "not needed" : pot == nil ? "none" : "ok (\(bindingKind))")")

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
        if let hls {
            // As yt-dlp: solve the n in the manifest path, add /pot/<token> before the file part.
            if let n = hlsN, solutions.n[n] == nil {
                sd["hlsManifestUrl"] = nil
            } else {
                let n = hlsN.flatMap { n in solutions.n[n].map { (n, $0) } }
                sd["hlsManifestUrl"] = .string(Self.preparedManifestURL(hls, n: n, pot: pot))
                // Some videos want the stream token bound to the video id instead (a YouTube
                // experiment yt-dlp detects from the watch page); kept as a second try.
                if let videoToken, videoToken != pot {
                    sd[Self.videoBoundManifestKey] = .string(Self.preparedManifestURL(hls, n: n, pot: videoToken))
                }
            }
        }
        if let sabr, sabrN.map({ solutions.n[$0] != nil }) ?? true {
            // SABR (YouTube's own protocol): the link with n solved, and the token it sends.
            sd[Self.sabrURLKey] = .string(sabrN.flatMap { n in solutions.n[n].map { Self.settingQuery(sabr, "n", $0) } } ?? sabr)
            if let pot { sd[Self.sabrTokenKey] = .string(pot) }
            if let binding { sd[Self.sabrBindingKey] = .string(binding) }
            if page != nil { sd[Self.sabrPageKey] = .bool(true) }
            // If stream protection refuses that one: a token bound to the video (some sessions
            // are in YouTube's video-bound experiment, as with HLS above).
            if let videoToken, videoToken != pot { sd[Self.sabrVideoTokenKey] = .string(videoToken) }
        }
        root["streamingData"] = .object(sd)
        return .object(root)
    }

    private static let videoBoundManifestKey = "glintVideoBoundHlsManifestUrl"
    private static let sabrURLKey = "glintSabrUrl"
    private static let sabrTokenKey = "glintSabrPoToken"
    private static let sabrVideoTokenKey = "glintSabrVideoPoToken"
    private static let sabrBindingKey = "glintSabrTokenBinding"
    private static let sabrPageKey = "glintSabrPageTokens"

    /// The n challenge in an HLS manifest URL's path (`…/n/<challenge>/…`).
    private static func manifestN(_ url: String) -> String? {
        guard let path = URLComponents(string: url)?.percentEncodedPath else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let i = parts.firstIndex(of: "n"), i + 1 < parts.count else { return nil }
        return String(parts[i + 1])
    }

    private static func preparedManifestURL(_ url: String, n: (String, String)?, pot: String?) -> String {
        guard var c = URLComponents(string: url) else { return url }
        var path = c.percentEncodedPath
        if let n { path = path.replacingOccurrences(of: "/n/\(n.0)/", with: "/n/\(n.1)/") }
        if let pot {
            var suffix = ""
            for s in ["/file/index.m3u8", "/playlist/index.m3u8"] where path.hasSuffix(s) {
                suffix = s
                path = String(path.dropLast(s.count))
            }
            while path.hasSuffix("/") { path.removeLast() }
            path += "/pot/" + (pot.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? pot) + suffix
        }
        c.percentEncodedPath = path
        return c.string ?? url
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

/// Counts re-mints for one SABR session (alternates token bindings).
private final class MintCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.withLock { defer { n += 1 }; return n } }
}
