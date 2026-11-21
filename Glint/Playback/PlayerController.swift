import AVFoundation
import AVKit
import Observation
import UIKit
import VideoToolbox

struct QueueItem: Identifiable, Hashable {
    var id = UUID()
    var videoId: String
    var title: String
    var subtitle: String?
    var thumbnail: URL?
    var isMusic: Bool
    var playlistId: String?

    init(video v: VideoItem) {
        videoId = v.id; title = v.title; subtitle = v.channelName
        thumbnail = v.bestThumbnail; isMusic = false
    }

    init?(music m: MusicItem) {
        guard let vid = m.videoId else { return nil }
        videoId = vid; title = m.title; subtitle = m.subtitle
        thumbnail = m.thumbnail ?? URL(string: "https://i.ytimg.com/vi/\(vid)/hqdefault.jpg")
        isMusic = true; playlistId = m.playlistId
    }
}

enum PlayerPresentation { case hidden, mini, expanded }

/// The single app-wide player. One AVPlayer survives navigation, screen changes
/// (cover ⇄ inner display), backgrounding and Picture in Picture.
@MainActor
@Observable
final class PlayerController {
    static let shared = PlayerController()

    @ObservationIgnored let player = AVPlayer()
    @ObservationIgnored private let settings = AppSettings.shared

    var presentation: PlayerPresentation = .hidden
    var queue: [QueueItem] = []
    var index = 0
    var current: QueueItem? { queue.indices.contains(index) ? queue[index] : nil }

    var details: VideoDetails?
    var extras: WatchExtras?
    var stream: ResolvedStream?
    var selectedOption: StreamOption?          // nil = Auto
    var audioOnly = false
    var isPlaying = false
    var isBuffering = false
    var isLoading = false
    var loadError: String?
    var currentTime: Double = 0
    var duration: Double = 0
    var rate: Float = 1
    var segments: [SponsorSegment] = []
    var notice: String?
    /// Recent playback events (client used, stream checks, HTTP errors, stalls, recoveries)
    /// for the Playback info sheet, so problems on a real connection can be diagnosed.
    private(set) var diagnostics: [String] = []
    var showsPlaybackInfo = false
    var highlight: SponsorSegment?
    /// Captions for the current video.
    var selectedCaption: CaptionTrack?
    var captionCues: [CaptionCue] = []
    var captionTracks: [CaptionTrack] { stream?.captions ?? [] }
    @ObservationIgnored private var captionTask: Task<Void, Never>?

    /// A segment the user chose to skip by hand, while the playhead is inside it.
    var manualSegment: SponsorSegment?
    /// Pause at this time, or at the end of the current item when `sleepAtEnd`.
    var sleepAt: Date?
    var sleepAtEnd = false
    var isPiPActive = false
    var isFullscreen = false
    var showQueue = false
    var playingResolution: String?

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var itemObservations: [NSKeyValueObservation] = []
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var skipped = Set<String>()
    @ObservationIgnored private var mutedBySponsor = false
    @ObservationIgnored private var layers = NSHashTable<AVPlayerLayer>.weakObjects()
    @ObservationIgnored var pip: AVPictureInPictureController?
    @ObservationIgnored private var nowPlaying: NowPlaying!
    @ObservationIgnored private var lastNowPlayingUpdate = Date.distantPast
    @ObservationIgnored private var failures = 0
    /// Times the loopback SABR server was restarted for this item.
    @ObservationIgnored private var sabrServerRestarts = 0
    @ObservationIgnored private var lastSabrRestart = Date.distantPast
    @ObservationIgnored private var pausedAt: Date?
    /// The single variant SABR Auto is playing (nil when a quality was chosen or not SABR).
    @ObservationIgnored private var sabrAutoPick: DashFormat?
    /// Set when the floating mini player is tapped: the watch page grows the video out of it.
    @ObservationIgnored var expandFromMini = false
    /// SABR Auto with every quality offered and AVPlayer capped by our speed estimate.
    @ObservationIgnored private var sabrAutoABR = false
    @ObservationIgnored private var lastPeakUpdate = Date.distantPast

    /// Brings the loopback SABR server back (fresh listener, same port if it can) and rebuilds
    /// the item at the current position, in case the port changed.
    private func restartSabrServer(_ reason: String, force: Bool = false) {
        guard stream?.sabr != nil, force || Date().timeIntervalSince(lastSabrRestart) > 8 else { return }
        lastSabrRestart = Date()
        note("Local SABR server: restarting (\(reason))")
        isLoading = true
        let t = currentTime
        Task { @MainActor in
            try? await SabrServer.shared.restart()
            guard self.stream?.sabr != nil else { return }
            self.installItem(at: t)
        }
    }
    @ObservationIgnored private var resolvedAt = Date()
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// Fires when playback has been stuck waiting for data for too long.
    @ObservationIgnored private var stallTask: Task<Void, Never>?
    /// The item recovery last ran for, so one breakdown reported twice is handled once.
    @ObservationIgnored private weak var recoveredItem: AVPlayerItem?
    @ObservationIgnored private var activeVideoId: String?
    @ObservationIgnored private var activeIsMusic = false
    @ObservationIgnored private var lastPositionSave = Date.distantPast
    @ObservationIgnored private var prefetchedNext = false

    func note(_ line: String) {
        let stamp = Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
        let pos = current == nil ? "" : " @\(formatTime(currentTime))"
        diagnostics.append("\(stamp)\(pos)  \(line)")
        if diagnostics.count > 300 { diagnostics.removeFirst(diagnostics.count - 300) }
    }

    /// Plain-text report for copying.
    var diagnosticsReport: String {
        let v = Bundle.main.infoDictionary
        var head = ["Glint \(v?["CFBundleShortVersionString"] as? String ?? "?") (\(v?["CFBundleVersion"] as? String ?? "?")), iOS \(UIDevice.current.systemVersion)"]
        if let c = current {
            head.append("Now: \(c.title) [\(c.videoId)] \(c.isMusic ? "music" : "video")\(audioOnly ? ", audio only" : "")")
        }
        if let s = stream {
            head.append("Client: \(s.clientKey), \(s.options.count) qualities, audio \(s.audio.map { "itag \($0.itag), \($0.contentLength) bytes" } ?? "none")\(s.isLive ? ", live" : "")\(s.hlsURL != nil ? ", HLS" : "")\(s.sabr != nil ? ", SABR" : "")\(s.progressiveURL != nil ? (s.hlsURL == nil && s.sabr == nil ? ", 360p progressive" : ", 360p fallback ready") : "")")
        }
        if let s = stream, AccountStore.shared.isSignedIn {
            head.append("Watch sync: " + (s.tracking != nil ? "reporting to your YouTube account" : "not reporting (this stream didn't come through your account)")
                        + ", YouTube progress received for \(WatchHistory.shared.remoteSeen) videos")
        }
        if let s = stream, s.sabr != nil {
            // Measured download speed vs. what the playing quality needs (video + audio).
            let mbps: (Double) -> String = { String(format: "%.1f Mbps", $0 / 1_000_000) }
            var line = "Speed " + (SabrBandwidth.bitsPerSecond.map { "≈ " + mbps($0) } ?? "not measured yet")
            let playing: DashFormat? = {
                if let o = selectedOption, case .dash(let f) = o.source { return f }
                return sabrAutoPick
            }()
            if sabrAutoABR, let item = player.currentItem {
                line += ", Auto cap ≈ " + mbps(item.preferredPeakBitRate)
                if let now = item.accessLog()?.events.last?.indicatedBitrate, now > 0 { line += ", playing ≈ " + mbps(now) }
            }
            if let v = playing, !audioOnly {
                let need = Double(v.bitrate + (s.audio?.bitrate ?? 0))
                let label = "\(v.width > 0 ? min(v.width, v.height) : v.height)p"
                line += ", \(label) needs ≈ " + mbps(need)
                if let bps = SabrBandwidth.bitsPerSecond, bps < need * 1.2 { line += " (expect buffering)" }
            }
            head.append(line)
        }
        head.append("Position \(formatTime(currentTime)) / \(formatTime(duration)), \(isPlaying ? "playing" : isBuffering ? "buffering" : "paused")\(loadError.map { ", error: \($0)" } ?? "")")
        return (head + [""] + diagnostics).joined(separator: "\n")
    }

    private init() {
        rate = Float(settings.playbackSpeed)
        StreamResolver.shared.codecSupported = Self.supports
        player.allowsExternalPlayback = true
        player.automaticallyWaitsToMinimizeStalling = true
        nowPlaying = NowPlaying(controller: self)
        configureAudioSession()

        StreamResolver.shared.trace = { line in
            Task { @MainActor in PlayerController.shared.note(line) }
        }
        YouTubeWatchSync.shared.trace = { [weak self] line in self?.note(line) }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t.seconds) }
        }
        observations.append(player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] p, _ in
            let status = p.timeControlStatus
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPlaying = status == .playing
                self.isBuffering = status == .waitingToPlayAtSpecifiedRate
                self.watchForStall(waiting: status == .waitingToPlayAtSpecifiedRate)
                self.nowPlaying.update()
            }
        })

        let nc = NotificationCenter.default
        nc.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, (n.object as? AVPlayerItem) === self.player.currentItem else { return }
                self.handleEnd()
            }
        }
        // A segment that can't be fetched (e.g. YouTube refusing the rest of a stream) ends
        // playback early instead of failing the item: recover the same way as a failure.
        nc.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] n in
            let message = (n.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
            MainActor.assumeIsolated {
                guard let self, let item = n.object as? AVPlayerItem, item === self.player.currentItem else { return }
                self.recover(item, message: message)
            }
        }
        nc.addObserver(forName: AVPlayerItem.newErrorLogEntryNotification, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, let item = n.object as? AVPlayerItem, item === self.player.currentItem,
                      let e = item.errorLog()?.events.last else { return }
                let itag = e.uri.flatMap { u -> String? in
                    if let q = URLComponents(string: u)?.queryItems?.first(where: { $0.name == "itag" })?.value { return q }
                    let parts = u.split(separator: "/")   // HLS links carry it in the path: …/itag/96/…
                    guard let i = parts.firstIndex(of: "itag"), i + 1 < parts.count else { return nil }
                    return String(parts[i + 1])
                }
                let kind = e.uri.map { $0.contains("/api/manifest/") ? " playlist" : $0.contains("videoplayback") ? " segment" : "" } ?? ""
                // Can't reach the loopback SABR server: it was taken away while suspended.
                if e.errorDomain == NSURLErrorDomain, e.errorStatusCode == NSURLErrorCannotConnectToHost {
                    self.restartSabrServer("unreachable")
                }
                self.note("AVPlayer error \(e.errorStatusCode) \(e.errorDomain)\(itag.map { " itag \($0)" } ?? "")\(kind)\(e.errorComment.map { ": \($0)" } ?? "")")
            }
        }
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.enteredBackground() }
        }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.enteringForeground() }
        }
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            let raw = n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let type = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            MainActor.assumeIsolated {
                if type == AVAudioSession.InterruptionType.ended.rawValue,
                   AVAudioSession.InterruptionOptions(rawValue: raw).contains(.shouldResume) {
                    self?.resume()
                }
            }
        }
    }

    // MARK: Codec support

    nonisolated static func supports(_ codec: String) -> Bool {
        let c = codec.lowercased()
        if c.hasPrefix("av01") {
            // 'av01' FourCC — only offer AV1 where it is hardware decoded (A17 Pro / M3 and newer).
            guard VTIsHardwareDecodeSupported(CMVideoCodecType(0x6176_3031)) else { return false }
        }
        let type = c.hasPrefix("mp4a") ? "audio/mp4" : "video/mp4"
        return AVURLAsset.isPlayableExtendedMIMEType("\(type); codecs=\"\(codec)\"")
    }

    private func configureAudioSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo, options: [])
    }

    // MARK: Starting playback

    func play(_ video: VideoItem) {
        // Tapping what is already playing just brings the watch page back.
        if current?.videoId == video.id, loadError == nil {
            presentation = .expanded
            return
        }
        queue = [QueueItem(video: video)]
        index = 0
        audioOnly = false
        presentation = .expanded
        start()
    }

    /// Plays a video as audio only (background-friendly, light on data).
    func playAudio(_ video: VideoItem) {
        queue = [QueueItem(video: video)]
        index = 0
        audioOnly = true
        presentation = .expanded
        start()
    }

    /// Plays a list of videos in order (playlists, "play all").
    func playList(_ videos: [VideoItem], startAt i: Int = 0) {
        guard videos.indices.contains(i) else { return }
        queue = videos.map(QueueItem.init(video:))
        index = i
        audioOnly = false
        presentation = .expanded
        start()
    }

    /// Plays a track. If `list` is given it becomes the queue, otherwise a radio is generated.
    func playMusic(_ item: MusicItem, in list: [MusicItem]? = nil) {
        guard let first = QueueItem(music: item) else { return }
        audioOnly = settings.musicAudioOnly
        if let list {
            let items = list.compactMap(QueueItem.init(music:))
            queue = items.isEmpty ? [first] : items
            index = queue.firstIndex { $0.videoId == first.videoId } ?? 0
            start()
        } else {
            queue = [first]
            index = 0
            start()
            let vid = first.videoId, pl = item.playlistId
            Task {
                guard let more = try? await YouTubeService.shared.musicQueue(videoId: vid, playlistId: pl) else { return }
                guard self.current?.videoId == vid else { return }
                // Keep anything queued while the radio loaded, then the radio.
                let queued = Array(self.queue[(self.index + 1)...])
                let known = Set(queued.map(\.videoId)).union([vid])
                let extra = more.compactMap(QueueItem.init(music:)).filter { !known.contains($0.videoId) }
                self.queue = [self.queue[self.index]] + queued + extra
                self.index = 0
            }
        }
    }

    /// Replaces what's coming up with a radio built from the current song.
    func startRadio() {
        guard let c = current else { return }
        let vid = c.videoId
        Task {
            guard let more = try? await YouTubeService.shared.musicQueue(videoId: vid, playlistId: nil),
                  self.current?.videoId == vid else { return }
            let extra = more.compactMap(QueueItem.init(music:)).filter { $0.videoId != vid }
            guard !extra.isEmpty, let now = self.current else { return }
            self.queue = [now] + extra
            self.index = 0
            self.flash("Radio started")
        }
    }

    /// Plays a whole album / playlist from YouTube Music.
    func playMusicCollection(playlistId: String, shuffle: Bool = false) {
        Task {
            guard var items = try? await YouTubeService.shared.musicQueue(videoId: nil, playlistId: playlistId),
                  !items.isEmpty else { return }
            if shuffle { items.shuffle() }
            self.playMusic(items[0], in: items)
        }
    }

    func playQueue(at i: Int) {
        guard queue.indices.contains(i) else { return }
        index = i
        start()
    }

    /// Re-resolves the current item from scratch (fresh stream URLs).
    func retry() {
        if let id = current?.videoId { StreamResolver.shared.invalidate(id) }
        start()
    }

    /// Queue a song to play right after the current one (or start it if nothing is playing).
    func enqueueNextMusic(_ item: MusicItem) {
        guard let q = QueueItem(music: item) else { return }
        if queue.isEmpty { playMusic(item); return }
        queue.insert(q, at: min(index + 1, queue.count))
        flash("Playing next")
    }

    func enqueueMusic(_ item: MusicItem) {
        guard let q = QueueItem(music: item) else { return }
        if queue.isEmpty { playMusic(item); return }
        queue.append(q)
        flash("Added to queue")
    }

    func enqueueNext(_ video: VideoItem) {
        let item = QueueItem(video: video)
        if queue.isEmpty { queue = [item]; index = 0; start(); return }
        queue.insert(item, at: min(index + 1, queue.count))
        flash("Playing next")
    }

    private func start() {
        guard let item = current else { return }
        savePosition(force: true)
        activeVideoId = item.videoId
        activeIsMusic = item.isMusic
        prefetchedNext = false
        refreshTask?.cancel()
        loadTask?.cancel()
        stallTask?.cancel()
        player.replaceCurrentItem(with: nil)
        details = nil; extras = nil; stream = nil; selectedOption = nil
        segments = []; skipped = []; highlight = nil; manualSegment = nil; loadError = nil
        captionTask?.cancel(); selectedCaption = nil; captionCues = []
        currentTime = 0; duration = 0; playingResolution = nil; failures = 0; sabrServerRestarts = 0
        player.isMuted = false; mutedBySponsor = false
        isLoading = true
        if presentation == .hidden { presentation = item.isMusic ? .mini : .expanded }
        nowPlaying.update()
        note("Start \(item.isMusic ? "song" : "video") \(item.videoId): \(item.title)")

        let videoId = item.videoId
        let isMusic = item.isMusic
        let sbEnabled = settings.sponsorBlockEnabled
        let sbCategories = Array(settings.sponsorCategories.union(settings.sponsorManual)) + [.poi_highlight]
        loadTask = Task { [weak self] in
            async let extrasTask: WatchExtras? = Self.fetchExtras(videoId, skip: isMusic)
            async let sbTask: [SponsorSegment] = Self.fetchSegments(videoId, enabled: sbEnabled, categories: sbCategories)
            guard let self else { return }
            do {
                let hints = StreamResolver.Hints(
                    startAt: isMusic ? 0 : WatchHistory.shared.position(for: videoId) ?? 0,
                    audioOnly: self.audioOnly,
                    defaultQuality: self.settings.defaultQuality)
                let s = try await StreamResolver.shared.resolve(videoId: videoId, hints: hints)
                guard !Task.isCancelled, self.current?.videoId == videoId else { return }
                self.stream = s
                YouTubeWatchSync.shared.begin(videoId: videoId, tracking: s.tracking, at: hints.startAt)
                self.details = s.details
                if !isMusic, !s.isLive {
                    WatchHistory.shared.record(VideoItem(
                        id: videoId, title: s.details.title, channelName: s.details.channelName,
                        channelId: s.details.channelId, thumbnail: item.thumbnail,
                        duration: s.details.lengthSeconds.map { formatTime(Double($0)) }))
                }
                self.selectedOption = self.preferredOption(in: s)
                self.duration = Double(s.details.lengthSeconds ?? 0)
                self.resolvedAt = Date()
                if self.settings.captionsOn, !isMusic,
                   let t = Captions.preferred(s.captions, language: Locale.current.language.languageCode?.identifier ?? "en") {
                    self.loadCaptions(t)
                }
                let resumeAt = (isMusic || s.isLive) ? nil : WatchHistory.shared.position(for: videoId)
                self.installItem(at: resumeAt ?? 0)
                if let resumeAt { self.flash("Resuming at \(formatTime(resumeAt))") }
            } catch {
                guard !Task.isCancelled else { return }
                self.isLoading = false
                self.loadError = error.localizedDescription
                self.note("Couldn't load: \(error.localizedDescription)")
            }
            let sb = await sbTask
            let ex = await extrasTask
            guard !Task.isCancelled, self.current?.videoId == videoId else { return }
            self.segments = sb.filter { $0.category != .poi_highlight }
            self.highlight = sb.first { $0.category == .poi_highlight }
            self.extras = ex
        }
    }

    nonisolated private static func fetchExtras(_ id: String, skip: Bool) async -> WatchExtras? {
        skip ? nil : (try? await YouTubeService.shared.watchExtras(id))
    }

    nonisolated private static func fetchSegments(_ id: String, enabled: Bool, categories: [SponsorCategory]) async -> [SponsorSegment] {
        enabled ? await SponsorBlock.shared.segments(for: id, categories: categories) : []
    }

    private func preferredOption(in s: ResolvedStream) -> StreamOption? {
        let pref = settings.defaultQuality
        guard pref > 0 else { return nil }
        let candidates = s.options.filter { settings.preferHDR || !$0.hdr }
        return candidates.first { $0.lines <= pref } ?? candidates.last
    }

    /// (Re)builds the AVPlayerItem for the current stream, quality and mode.
    private func installItem(at time: Double) {
        guard let s = stream else { return }
        let asset: AVURLAsset
        if let hls = s.hlsURL {
            if let o = selectedOption, case .hls(let vs) = o.source, let m = s.manifest {
                asset = HLSLoader.asset(for: HLSLoader.shared.registerLive(master: m.playlist(keeping: vs)))
            } else if !s.isLive, let m = s.manifest {
                // Regular video: the checked manifest (qualities YouTube refused are left out).
                asset = HLSLoader.asset(for: HLSLoader.shared.registerLive(master: m.playlist(keeping: m.variants)))
            } else {
                asset = AVURLAsset(url: hls)
            }
        } else if s.sabr == nil, let url = s.progressiveURL {
            // One muxed 360p file; AVPlayer streams it directly (audio-only just hides the video).
            asset = AVURLAsset(url: url, options: [AVURLAssetHTTPUserAgentKey: s.progressiveUserAgent ?? s.streamUserAgent])
        } else {
            var videos: [DashFormat] = []
            if !audioOnly {
                if let o = selectedOption, case .dash(let f) = o.source {
                    videos = [f]
                } else {
                    videos = s.options
                        .filter { settings.preferHDR || !$0.hdr }
                        .compactMap { if case .dash(let f) = $0.source { return f }; return nil }
                }
            }
            if videos.isEmpty && s.audio == nil { loadError = "No playable stream."; return }
            if let sabr = s.sabr {
                // SABR: segments come from YouTube's own protocol through the loopback server.
                // Auto offers one quality: AVPlayer measures the loopback server (cached segments
                // arrive instantly), so left to itself it climbs past what the connection carries.
                sabrAutoPick = nil
                sabrAutoABR = false
                if selectedOption == nil, videos.count > 1 {
                    if settings.defaultQuality > 0,
                       let pick = SabrBandwidth.autoVideo(videos, audioBitrate: s.audio?.bitrate ?? 0,
                                                          defaultQuality: settings.defaultQuality) {
                        videos = [pick]          // a default quality was set: hold it
                        sabrAutoPick = pick
                    } else {
                        // Every quality up to 4K; AVPlayer switches between them at segment
                        // boundaries, kept under our measured speed by preferredPeakBitRate
                        // (its own measurement only sees the loopback server).
                        let lines: (DashFormat) -> Int = { $0.width > 0 ? min($0.width, $0.height) : $0.height }
                        videos = videos.filter { lines($0) <= 2160 }
                        sabrAutoABR = true
                    }
                }
                let audioOnly = videos.isEmpty
                Task { await sabr.setAudioOnly(audioOnly) }
                guard let url = SabrServer.shared.url(for: sabr, videos: videos, audioOnly: audioOnly) else {
                    loadError = "Couldn't start the local stream server."
                    return
                }
                asset = AVURLAsset(url: url)
            } else {
                let url = HLSLoader.shared.register(video: videos, audio: s.audio, userAgent: s.streamUserAgent)
                asset = HLSLoader.asset(for: url)
            }
        }

        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 0
        if sabrAutoABR, stream?.sabr != nil, stream?.hlsURL == nil {
            item.preferredPeakBitRate = SabrBandwidth.peakBitRate
            lastPeakUpdate = Date()
        }
        observe(item)
        isLoading = true
        player.replaceCurrentItem(with: item)
        if time > 0 { player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
        try? AVAudioSession.sharedInstance().setActive(true)
        player.playImmediately(atRate: s.isLive ? 1 : rate)
        nowPlaying.update()
    }

    private func observe(_ item: AVPlayerItem) {
        itemObservations = [
            item.observe(\.status, options: [.new]) { [weak self] it, _ in
                let status = it.status
                let message = it.error?.localizedDescription
                Task { @MainActor [weak self] in self?.itemStatusChanged(status, message: message, item: it) }
            },
            item.observe(\.presentationSize, options: [.new]) { [weak self] it, _ in
                let size = it.presentationSize
                Task { @MainActor [weak self] in
                    guard size.height > 0 else { return }
                    self?.playingResolution = "\(Int(min(size.width, size.height)))p"
                }
            },
        ]
    }

    private func itemStatusChanged(_ status: AVPlayerItem.Status, message: String?, item: AVPlayerItem) {
        guard item === player.currentItem else { return }
        switch status {
        case .readyToPlay:
            note("Ready (\(audioOnly ? "audio only" : selectedOption?.label ?? "Auto"))")
            isLoading = false
            failures = 0          // recovered: the next failure gets the full recovery path again
            sabrServerRestarts = 0
            loadError = nil
            let d = item.duration.seconds
            if d.isFinite, d > 0 { duration = d }
        case .failed:
            recover(item, message: message)
        default: break
        }
    }

    /// Something stopped playback early. Fetch fresh links (from another client when this one's
    /// were refused) and continue from the same spot; after that, try a compatible quality.
    private func recover(_ item: AVPlayerItem?, message: String?) {
        guard current != nil, item == nil || item !== recoveredItem else { return }
        recoveredItem = item
        if stream?.isPartial == true {
            // Every client was already limited to the start of this file; retrying can't help.
            note("Stopped at YouTube's limit for this stream (\(message ?? "refused"))")
            isLoading = false
            player.pause()
            loadError = "YouTube is only letting Glint play the first part of this "
                + (current?.isMusic == true ? "song" : "video") + " right now."
            return
        }
        if let s = stream, s.sabr != nil, sabrServerRestarts < 3,
           let m = message?.lowercased(), m.contains("connect") || m.contains("server") || m.contains("stall") {
            // The loopback server was gone (iOS reclaims sockets of suspended apps) or stopped
            // answering: bring it back and carry on from the same spot.
            sabrServerRestarts += 1
            restartSabrServer("playback stopped: \(message ?? "?")", force: true)
            return
        }
        if let s = stream, s.hlsURL != nil || s.sabr != nil, !s.isLive, s.progressiveURL != nil {
            // YouTube refused the HLS / SABR stream (signed-in web sessions: some videos'
            // segments are 403): play the full-length 360p file from the same response instead.
            note("\(s.sabr != nil ? "SABR" : "HLS") failed (\(message ?? "error")) → 360p progressive")
            stream?.hlsURL = nil
            stream?.sabr = nil
            stream?.audio = nil
            stream?.manifest = nil
            stream?.options = []
            selectedOption = nil
            isLoading = false
            installItem(at: currentTime)
            return
        }
        note("Stopped: \(message ?? "unknown") → recovery step \(failures + 1)")
        isLoading = false
        failures += 1
        let t = currentTime
        switch failures {
        case 2 where selectedOption != nil || !audioOnly:
            // A chosen variant may be undecodable on this device; fall back to a compatible Auto.
            if selectedOption != nil {
                selectedOption = nil
            } else if let s = stream {
                stream?.options = s.options.filter { $0.codec == "avc" }   // Auto with AVC only
            }
            flash("Switched to a compatible quality")
            installItem(at: t)
        case 1...3:
            // Most failures are expired or refused stream links: fresh ones, from another
            // client if this one's were cut off, and carry on from the same spot.
            if let s = stream, !s.isLive { StreamResolver.shared.reportFailure(s) }
            refresh(at: t)
        default:
            loadError = message ?? "Playback failed."
        }
    }

    private func watchForStall(waiting: Bool) {
        stallTask?.cancel()
        guard waiting else { return }
        let item = player.currentItem
        let at = currentTime
        // SABR in Auto steps down sooner: the stall is most likely the connection.
        let sabrAuto = stream?.sabr != nil && selectedOption == nil && !audioOnly && (sabrAutoPick != nil || sabrAutoABR)
        stallTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(sabrAuto ? 8 : 15))
            if sabrAuto {
                guard let self, !Task.isCancelled, self.player.currentItem === item, item != nil,
                      self.isBuffering, abs(self.currentTime - at) < 1, !self.isLoading else { return }
                await self.sabrStalled(item)
                return
            }
            guard let self, !Task.isCancelled, self.player.currentItem === item, item != nil,
                  self.isBuffering, abs(self.currentTime - at) < 1,
                  self.stream?.isLive != true, !self.isLoading else { return }
            self.recover(item, message: "Playback stalled.")
        }
    }

    /// SABR, Auto, buffering for a while: if the loopback server answers, the connection can't
    /// keep up, so lower the speed estimate and step down a quality at the same spot.
    private func sabrStalled(_ item: AVPlayerItem?) async {
        guard await SabrServer.shared.isAlive() else {
            restartSabrServer("stalled, local server gone", force: true)
            return
        }
        if sabrAutoABR, let item {
            // Lower the cap just under the quality that stalled; AVPlayer steps down itself.
            let playing = item.accessLog()?.events.last?.indicatedBitrate ?? 0
            guard playing > 0 else { return recover(item, message: "Playback stalled.") }
            SabrBandwidth.limit(toBelow: Int(playing))
            item.preferredPeakBitRate = SabrBandwidth.peakBitRate
            note(String(format: "Stalling at %.1f Mbps → Auto cap %.1f Mbps", playing / 1e6, item.preferredPeakBitRate / 1e6))
            flash("Lowered quality to keep playing")
            return
        }
        guard let s = stream, let pick = sabrAutoPick else { return recover(item, message: "Playback stalled.") }
        let videos = s.options.compactMap { if case .dash(let f) = $0.source { return f }; return nil }
            .filter { settings.preferHDR || $0.hdrRange == nil }
        let lower = videos.filter { $0.bitrate < pick.bitrate }
        guard !lower.isEmpty else { return recover(item, message: "Playback stalled.") }
        SabrBandwidth.limit(toBelow: pick.bitrate + (s.audio?.bitrate ?? 0))
        let next = SabrBandwidth.autoVideo(videos, audioBitrate: s.audio?.bitrate ?? 0, defaultQuality: 0) ?? lower[0]
        let label: (DashFormat) -> String = { "\($0.width > 0 ? min($0.width, $0.height) : $0.height)p" }
        note("Stalling at \(label(pick)) → Auto steps down to \(label(next))")
        flash("Lowered quality to keep playing")
        installItem(at: currentTime)
    }

    // MARK: Controls

    func togglePlay() { isPlaying ? pause() : resume() }

    func resume() {
        // After an error, "play" means "try again".
        if loadError != nil, current != nil { retry(); return }
        // Stream links expire after ~6 h; refresh them before resuming a long-paused video.
        if stream != nil, stream?.isLive != true, Date().timeIntervalSince(resolvedAt) > 4 * 3600 {
            refresh(at: currentTime)
            return
        }
        if player.currentItem == nil, current != nil, stream != nil { installItem(at: currentTime); return }
        // SABR after a pause: the app may have been suspended and lost its loopback server.
        if stream?.sabr != nil, let p = pausedAt, Date().timeIntervalSince(p) > 20 {
            pausedAt = nil
            Task { @MainActor in
                if await SabrServer.shared.isAlive() {
                    try? AVAudioSession.sharedInstance().setActive(true)
                    self.player.playImmediately(atRate: self.rate)
                } else {
                    self.restartSabrServer("resuming after a pause", force: true)
                }
            }
            return
        }
        pausedAt = nil
        // Finished video: play again from the start.
        if duration > 0, currentTime >= duration - 1 { seek(to: 0) }
        try? AVAudioSession.sharedInstance().setActive(true)
        player.playImmediately(atRate: rate)
    }

    func pause() {
        pausedAt = Date()
        player.pause()
        savePosition(force: true)
    }

    /// Re-resolves the current video (fresh URLs) and continues at `time` with the same quality.
    private func refresh(at time: Double) {
        guard let id = current?.videoId else { return }
        StreamResolver.shared.invalidate(id)
        let keepID = selectedOption?.id
        isLoading = true
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            do {
                let hints = StreamResolver.Hints(startAt: time, audioOnly: self?.audioOnly ?? false,
                                                       defaultQuality: self?.settings.defaultQuality ?? 0)
                let s = try await StreamResolver.shared.resolve(videoId: id, hints: hints)
                guard let self, !Task.isCancelled, self.current?.videoId == id else { return }
                self.stream = s
                YouTubeWatchSync.shared.begin(videoId: id, tracking: s.tracking, at: time)
                self.resolvedAt = Date()
                if let keepID { self.selectedOption = s.options.first { $0.id == keepID } ?? self.preferredOption(in: s) }
                self.installItem(at: time)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.isLoading = false
                self.loadError = error.localizedDescription
                self.note("Refresh failed: \(error.localizedDescription)")
            }
        }
    }

    /// Remembers where long videos were left so they resume there next time.
    private func savePosition(force: Bool = false) {
        if activeVideoId != nil, stream?.isLive != true, duration > 0 {
            YouTubeWatchSync.shared.report(position: currentTime, length: duration, playing: isPlaying, force: force)
        }
        guard let id = activeVideoId, !activeIsMusic, stream?.isLive != true, duration > 0 else { return }
        WatchHistory.shared.save(currentTime, duration: duration, for: id)
        lastPositionSave = Date()
    }

    func seek(to seconds: Double) {
        let t = max(0, min(seconds, duration > 0 ? duration - 0.5 : seconds))
        currentTime = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        nowPlaying.update()
    }

    func skip(by delta: Double) { seek(to: currentTime + delta) }

    func next() {
        if index + 1 < queue.count {
            index += 1
            start()
        } else if let c = current, !c.isMusic, let n = extras?.related.first {
            queue.append(QueueItem(video: n))
            index += 1
            start()
        } else if current?.isMusic == true {
            extendRadio()
        }
    }

    /// Appends more radio tracks for the current song, then moves on to the next one.
    private func extendRadio() {
        guard let c = current else { return }
        let vid = c.videoId
        Task {
            guard let more = try? await YouTubeService.shared.musicQueue(videoId: vid, playlistId: nil),
                  self.current?.videoId == vid else { return }
            let known = Set(self.queue.map(\.videoId))
            let extra = more.compactMap(QueueItem.init(music:)).filter { !known.contains($0.videoId) }
            guard !extra.isEmpty else { return }
            self.queue += extra
            self.next()
        }
    }

    func previous() {
        if currentTime > 3 || index == 0 { seek(to: 0); return }
        index -= 1
        start()
    }

    func setRate(_ r: Float) {
        rate = r
        settings.playbackSpeed = Double(r)
        if isPlaying { player.rate = r }
    }

    func select(_ option: StreamOption?) {
        guard option != selectedOption || audioOnly else { return }
        selectedOption = option
        audioOnly = false
        installItem(at: currentTime)
    }

    /// Switch the audio language (dubbed / original tracks), keeping position and quality.
    func selectAudioTrack(_ track: AudioTrackOption) {
        guard var s = stream, s.audio?.audioTrackId != track.format.audioTrackId else { return }
        s.audio = track.format
        if let old = s.sabr {
            // A SABR session streams one audio format: a new one for this track.
            s.sabr = SabrSession(config: old.config, audio: track.format, videos: old.videos)
        }
        stream = s
        note("Audio track: \(track.name)")
        installItem(at: currentTime)
    }

    func setAudioOnly(_ on: Bool) {
        guard on != audioOnly else { return }
        audioOnly = on
        installItem(at: currentTime)
    }

    func close() {
        savePosition(force: true)
        activeVideoId = nil
        refreshTask?.cancel()
        loadTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        queue = []; index = 0; stream = nil; details = nil; extras = nil
        sleepAt = nil; sleepAtEnd = false; manualSegment = nil
        presentation = .hidden
        isFullscreen = false
        nowPlaying.update()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func jumpToHighlight() {
        guard let h = highlight else { return }
        seek(to: h.start)
        highlight = nil
    }

    // MARK: Ticks, SponsorBlock, end of item

    private func tick(_ t: Double) {
        guard t.isFinite else { return }
        // @Observable notifies on every assignment, so only write real changes
        // (paused/buffering ticks would otherwise still redraw the timeline).
        if abs(t - currentTime) >= 0.05 { currentTime = t }
        if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0, abs(d - duration) > 1 { duration = d }
        // SABR Auto: follow the speed estimate (up as well as down) every few seconds.
        if sabrAutoABR, Date().timeIntervalSince(lastPeakUpdate) > 5, let item = player.currentItem {
            lastPeakUpdate = Date()
            let peak = SabrBandwidth.peakBitRate
            if abs(peak - item.preferredPeakBitRate) / max(peak, 1) > 0.1 { item.preferredPeakBitRate = peak }
        }
        sponsorCheck(t)
        sleepCheck()
        if Date().timeIntervalSince(lastPositionSave) > 10 { savePosition() }
        prefetchNextIfNeeded(t)
        if Date().timeIntervalSince(lastNowPlayingUpdate) > 5 {
            lastNowPlayingUpdate = Date()
            nowPlaying.update()
        }
    }

    /// Resolves the next video's streams shortly before the end so autoplay starts instantly.
    private func prefetchNextIfNeeded(_ t: Double) {
        guard !prefetchedNext, duration > 60, duration - t < 45, let c = current else { return }
        let nextId: String?
        if index + 1 < queue.count { nextId = queue[index + 1].videoId }
        else if !c.isMusic, settings.autoplay { nextId = extras?.related.first?.id }
        else { nextId = nil }
        guard let nextId else { return }
        prefetchedNext = true
        let hints = StreamResolver.Hints(startAt: 0, audioOnly: audioOnly, defaultQuality: settings.defaultQuality)
        Task.detached(priority: .utility) { _ = try? await StreamResolver.shared.resolve(videoId: nextId, hints: hints) }
    }

    private func sponsorCheck(_ t: Double) {
        guard settings.sponsorBlockEnabled, !segments.isEmpty else { return }
        var inMute = false
        var manual: SponsorSegment?
        for s in segments {
            guard t >= s.start, t < s.end - 0.35 else { continue }
            if settings.sponsorManual.contains(s.category), s.actionType == "skip" {
                manual = s
                continue
            }
            guard settings.sponsorCategories.contains(s.category) else { continue }
            if s.actionType == "mute" {
                inMute = true
            } else if s.actionType == "skip", !skipped.contains(s.id) {
                skipped.insert(s.id)
                seek(to: s.end)
                if settings.showSkipNotice { flash("Skipped \(s.category.title.lowercased())") }
                return
            }
        }
        if inMute != mutedBySponsor {
            mutedBySponsor = inMute
            player.isMuted = inMute
        }
        if manual?.id != manualSegment?.id { manualSegment = manual }
    }

    /// The Skip button for categories set to "Show a Skip button".
    func skipManualSegment() {
        guard let s = manualSegment else { return }
        manualSegment = nil
        seek(to: s.end)
    }

    // MARK: Captions

    /// Choose a caption track (nil turns captions off). Remembered as the default.
    func selectCaption(_ track: CaptionTrack?) {
        settings.captionsOn = track != nil
        if let track { loadCaptions(track); flash("Captions: \(track.label)") } else {
            captionTask?.cancel()
            selectedCaption = nil
            captionCues = []
            flash("Captions off")
        }
    }

    /// The CC button: off ↔ the best track for the device language.
    func toggleCaptions() {
        if selectedCaption != nil { selectCaption(nil); return }
        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        if let t = Captions.preferred(captionTracks, language: lang) { selectCaption(t) } else { flash("No captions for this video") }
    }

    private func loadCaptions(_ track: CaptionTrack) {
        selectedCaption = track
        captionCues = []
        captionTask?.cancel()
        let id = current?.videoId
        captionTask = Task { [weak self] in
            let cues = (try? await Captions.load(track)) ?? []
            guard let self, !Task.isCancelled, self.current?.videoId == id else { return }
            self.captionCues = cues
        }
    }

    // MARK: Queue & sleep timer

    func enqueue(_ video: VideoItem) {
        let item = QueueItem(video: video)
        if queue.isEmpty { queue = [item]; index = 0; presentation = .expanded; start(); return }
        queue.append(item)
        flash("Added to queue")
    }

    func setSleepTimer(minutes: Int?) {
        sleepAtEnd = false
        sleepAt = minutes.map { Date().addingTimeInterval(Double($0) * 60) }
        if let m = minutes { flash("Pausing in \(m) min") } else { flash("Sleep timer off") }
    }

    func setSleepAtEnd() {
        sleepAt = nil
        sleepAtEnd = true
        flash(current?.isMusic == true ? "Pausing after this song" : "Pausing after this video")
    }

    private func sleepCheck() {
        if let at = sleepAt, Date() >= at {
            sleepAt = nil
            pause()
            flash("Sleep timer: paused")
        }
    }

    private func handleEnd() {
        guard let c = current else { return }
        savePosition(force: true)   // last watchtime report: watched to the end
        if sleepAtEnd {
            sleepAtEnd = false
            flash("Sleep timer: paused")
            return
        }
        if index + 1 < queue.count {
            next()
        } else if !c.isMusic, settings.autoplay, extras?.related.first != nil {
            next()
        } else if c.isMusic {
            extendRadio()   // keep the radio going
        }
    }

    func flash(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if !Task.isCancelled { self.notice = nil }
        }
    }

    // MARK: Layers, background, PiP

    func attach(_ layer: AVPlayerLayer) {
        layers.add(layer)
        if UIApplication.shared.applicationState != .background { layer.player = player }
    }

    func detach(_ layer: AVPlayerLayer) { layers.remove(layer) }

    private func enteredBackground() {
        savePosition(force: true)
        // Leave the layer alone while Picture in Picture is running or about to start automatically.
        let pipStarting = pip.map { $0.isPictureInPictureActive || ($0.canStartPictureInPictureAutomaticallyFromInline && $0.isPictureInPicturePossible && isPlaying) } ?? false
        guard current != nil, !isPiPActive, !pipStarting else { return }
        if settings.backgroundPlayback || audioOnly {
            // Detaching video layers lets audio continue in the background.
            for l in layers.allObjects { l.player = nil }
        } else {
            pause()
        }
    }

    private func enteringForeground() {
        for l in layers.allObjects { l.player = player }
        SabrServer.shared.ensureRunning()
    }
}
