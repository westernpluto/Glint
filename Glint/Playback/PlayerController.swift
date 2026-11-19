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
    var highlight: SponsorSegment?
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
    @ObservationIgnored private var resolvedAt = Date()
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var activeVideoId: String?
    @ObservationIgnored private var activeIsMusic = false
    @ObservationIgnored private var lastPositionSave = Date.distantPast
    @ObservationIgnored private var prefetchedNext = false

    private init() {
        rate = Float(settings.playbackSpeed)
        StreamResolver.shared.codecSupported = Self.supports
        player.allowsExternalPlayback = true
        player.automaticallyWaitsToMinimizeStalling = true
        nowPlaying = NowPlaying(controller: self)
        configureAudioSession()

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t.seconds) }
        }
        observations.append(player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] p, _ in
            let status = p.timeControlStatus
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPlaying = status == .playing
                self.isBuffering = status == .waitingToPlayAtSpecifiedRate
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
                let extra = more.compactMap(QueueItem.init(music:)).filter { $0.videoId != vid }
                self.queue = [self.queue[self.index]] + extra
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

    func enqueueNext(_ video: VideoItem) {
        let item = QueueItem(video: video)
        if queue.isEmpty { queue = [item]; index = 0; start(); return }
        queue.insert(item, at: min(index + 1, queue.count))
        flash("Playing next")
    }

    private func start() {
        guard let item = current else { return }
        savePosition()
        activeVideoId = item.videoId
        activeIsMusic = item.isMusic
        prefetchedNext = false
        refreshTask?.cancel()
        loadTask?.cancel()
        player.replaceCurrentItem(with: nil)
        details = nil; extras = nil; stream = nil; selectedOption = nil
        segments = []; skipped = []; highlight = nil; loadError = nil
        currentTime = 0; duration = 0; playingResolution = nil; failures = 0
        player.isMuted = false; mutedBySponsor = false
        isLoading = true
        if presentation == .hidden { presentation = item.isMusic ? .mini : .expanded }
        nowPlaying.update()

        let videoId = item.videoId
        let isMusic = item.isMusic
        let sbEnabled = settings.sponsorBlockEnabled
        let sbCategories = Array(settings.sponsorCategories) + [.poi_highlight]
        loadTask = Task { [weak self] in
            async let extrasTask: WatchExtras? = Self.fetchExtras(videoId, skip: isMusic)
            async let sbTask: [SponsorSegment] = Self.fetchSegments(videoId, enabled: sbEnabled, categories: sbCategories)
            guard let self else { return }
            do {
                let s = try await StreamResolver.shared.resolve(videoId: videoId)
                guard !Task.isCancelled, self.current?.videoId == videoId else { return }
                self.stream = s
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
                let resumeAt = (isMusic || s.isLive) ? nil : WatchHistory.shared.position(for: videoId)
                self.installItem(at: resumeAt ?? 0)
                if let resumeAt { self.flash("Resuming at \(formatTime(resumeAt))") }
            } catch {
                guard !Task.isCancelled else { return }
                self.isLoading = false
                self.loadError = error.localizedDescription
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
        if s.isLive, let hls = s.hlsURL {
            if let o = selectedOption, case .hls(let vs) = o.source, let m = s.manifest {
                asset = HLSLoader.asset(for: HLSLoader.shared.registerLive(master: m.playlist(keeping: vs)))
            } else {
                asset = AVURLAsset(url: hls)
            }
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
            let url = HLSLoader.shared.register(video: videos, audio: s.audio, userAgent: s.streamUserAgent)
            asset = HLSLoader.asset(for: url)
        }

        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 0
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
            isLoading = false
            let d = item.duration.seconds
            if d.isFinite, d > 0 { duration = d }
        case .failed:
            isLoading = false
            failures += 1
            let t = currentTime
            if failures == 1 {
                // Most failures are expired or rejected stream links: fetch fresh ones and continue.
                refresh(at: t)
            } else if failures == 2, selectedOption != nil || !audioOnly {
                // A chosen variant may be undecodable on this device; fall back to a compatible Auto.
                if selectedOption != nil {
                    selectedOption = nil
                } else if let s = stream {
                    // Retry Auto with AVC only.
                    stream?.options = s.options.filter { $0.codec == "avc" }
                }
                flash("Switched to a compatible quality")
                installItem(at: t)
            } else {
                loadError = message ?? "Playback failed."
            }
        default: break
        }
    }

    // MARK: Controls

    func togglePlay() { isPlaying ? pause() : resume() }

    func resume() {
        // Stream links expire after ~6 h; refresh them before resuming a long-paused video.
        if stream != nil, stream?.isLive != true, Date().timeIntervalSince(resolvedAt) > 4 * 3600 {
            refresh(at: currentTime)
            return
        }
        if player.currentItem == nil, current != nil, stream != nil { installItem(at: currentTime); return }
        // Finished video: play again from the start.
        if duration > 0, currentTime >= duration - 1 { seek(to: 0) }
        try? AVAudioSession.sharedInstance().setActive(true)
        player.playImmediately(atRate: rate)
    }

    func pause() {
        player.pause()
        savePosition()
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
                let s = try await StreamResolver.shared.resolve(videoId: id)
                guard let self, !Task.isCancelled, self.current?.videoId == id else { return }
                self.stream = s
                self.resolvedAt = Date()
                if let keepID { self.selectedOption = s.options.first { $0.id == keepID } ?? self.preferredOption(in: s) }
                self.installItem(at: time)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.isLoading = false
                self.loadError = error.localizedDescription
            }
        }
    }

    /// Remembers where long videos were left so they resume there next time.
    private func savePosition() {
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

    func setAudioOnly(_ on: Bool) {
        guard on != audioOnly else { return }
        audioOnly = on
        installItem(at: currentTime)
    }

    func close() {
        savePosition()
        activeVideoId = nil
        refreshTask?.cancel()
        loadTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        queue = []; index = 0; stream = nil; details = nil; extras = nil
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
        sponsorCheck(t)
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
        Task.detached(priority: .utility) { _ = try? await StreamResolver.shared.resolve(videoId: nextId) }
    }

    private func sponsorCheck(_ t: Double) {
        guard settings.sponsorBlockEnabled, !segments.isEmpty else { return }
        var inMute = false
        for s in segments where settings.sponsorCategories.contains(s.category) {
            guard t >= s.start, t < s.end - 0.35 else { continue }
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
    }

    private func handleEnd() {
        guard let c = current else { return }
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
        savePosition()
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
    }
}
