import MediaPlayer
import UIKit

/// Lock screen / Control Center / Dynamic Island integration.
@MainActor
final class NowPlaying {
    private weak var controller: PlayerController?
    private var artworkURL: URL?
    private var artwork: MPMediaItemArtwork?

    init(controller: PlayerController) {
        self.controller = controller
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.controller?.resume() }; return .success }
        c.pauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.controller?.pause() }; return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.controller?.togglePlay() }; return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.controller?.next() }; return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.controller?.previous() }; return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let t = e.positionTime
            MainActor.assumeIsolated { self?.controller?.seek(to: t) }
            return .success
        }
        c.changeRepeatModeCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangeRepeatModeCommandEvent else { return .commandFailed }
            let mode: RepeatMode
            switch e.repeatType {
            case .one: mode = .one
            case .all: mode = .all
            default: mode = .off
            }
            MainActor.assumeIsolated { self?.controller?.repeatMode = mode }
            return .success
        }
        c.skipForwardCommand.preferredIntervals = [10]
        c.skipBackwardCommand.preferredIntervals = [10]
        c.skipForwardCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.controller?.skip(by: 10) }; return .success }
        c.skipBackwardCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.controller?.skip(by: -10) }; return .success }
    }

    func update() {
        guard let c = controller, let item = c.current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        let cc = MPRemoteCommandCenter.shared()
        // Music gets track skipping; videos get ±10 s.
        cc.nextTrackCommand.isEnabled = c.index + 1 < c.queue.count || !item.isMusic
        cc.previousTrackCommand.isEnabled = true
        cc.skipForwardCommand.isEnabled = !item.isMusic
        cc.skipBackwardCommand.isEnabled = !item.isMusic
        let repeatType: MPRepeatType
        switch c.repeatMode {
        case .off: repeatType = .off
        case .all: repeatType = .all
        case .one: repeatType = .one
        }
        cc.changeRepeatModeCommand.currentRepeatType = repeatType

        var info: [String: Any] = [
            // Songs: the song's own title and just the artist ("Artist • 19M views" → "Artist").
            MPMediaItemPropertyTitle: item.isMusic ? item.title : (c.details?.title ?? item.title),
            MPMediaItemPropertyArtist: item.isMusic ? Self.artist(item.subtitle) ?? c.details?.channelName ?? ""
                                                    : item.subtitle ?? c.details?.channelName ?? "",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: c.currentTime,
            MPMediaItemPropertyPlaybackDuration: c.duration,
            MPNowPlayingInfoPropertyPlaybackRate: c.isPlaying ? Double(c.rate) : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyIsLiveStream: c.stream?.isLive ?? false,
            // Songs are audio to the system (square cover on the lock screen), even played as video.
            MPNowPlayingInfoPropertyMediaType: (c.audioOnly || item.isMusic) ? MPNowPlayingInfoMediaType.audio.rawValue : MPNowPlayingInfoMediaType.video.rawValue,
        ]
        if let artwork, artworkURL == item.thumbnail { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        loadArtwork(item.thumbnail, square: item.isMusic)
    }

    /// The artist part of a music subtitle ("Song • Artist • Album", "Artist • 19M views").
    private static func artist(_ subtitle: String?) -> String? {
        guard let parts = subtitle?.components(separatedBy: " • ").map({ $0.trimmingCharacters(in: .whitespaces) }) else { return nil }
        let useful = parts.filter { p in
            let l = p.lowercased()
            return !p.isEmpty && !["song", "video", "single", "ep", "album"].contains(l)
                && !l.contains("view") && !l.contains("play") && p.rangeOfCharacter(from: .letters) != nil
        }
        return useful.first
    }

    /// A song's picture as a square: a 16:9 video thumbnail is cut to its centre, where an
    /// uploaded track's cover sits between black bars (Now Playing in the app does the same).
    nonisolated private static func squared(_ image: UIImage) -> UIImage {
        let w = image.size.width, h = image.size.height
        guard w > h * 1.05, let cg = image.cgImage else { return image }
        let scale = CGFloat(cg.width) / w
        let side = h * scale
        let rect = CGRect(x: (CGFloat(cg.width) - side) / 2, y: 0, width: side, height: side)
        guard let cropped = cg.cropping(to: rect) else { return image }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }

    /// "album cover (lh3…)" / "video thumbnail (i.ytimg.com/vi/…/hqdefault.jpg)" for the log.
    private static func describe(_ url: URL) -> String {
        let host = url.host ?? ""
        let kind = host.contains("googleusercontent") || host.contains("ggpht") ? "album cover" : host.contains("ytimg") ? "video thumbnail" : "image"
        return "\(kind) (\(host)\(url.path.suffix(40)))"
    }

    /// Built outside the main actor: MediaPlayer calls the handler on a background queue.
    nonisolated private static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    private func loadArtwork(_ url: URL?, square: Bool) {
        guard let url, url != artworkURL else { return }
        artworkURL = url
        artwork = nil
        Task {
            // The same picture Now Playing shows (the large cover; the original if that's missing),
            // from the same cache, so it's usually already decoded.
            var image: UIImage?
            if let sharp = Artwork.sharp(url, size: 1200), sharp != url { image = await ImagePipeline.shared.image(sharp) }
            if image == nil { image = await ImagePipeline.shared.image(url) }
            guard let image else {
                self.controller?.note("Lock screen artwork: couldn't load \(Self.describe(url))")
                return
            }
            guard self.artworkURL == url else { return }
            let shown = square ? Self.squared(image) : image
            self.artwork = Self.makeArtwork(shown)
            self.update()
            self.controller?.note("Lock screen artwork: \(Self.describe(url)), \(Int(shown.size.width))×\(Int(shown.size.height))")
        }
    }
}
