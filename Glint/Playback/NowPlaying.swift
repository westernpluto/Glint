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
            MPMediaItemPropertyTitle: c.details?.title ?? item.title,
            MPMediaItemPropertyArtist: item.subtitle ?? c.details?.channelName ?? "",
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
        loadArtwork(item.thumbnail)
    }

    /// Built outside the main actor: MediaPlayer calls the handler on a background queue.
    nonisolated private static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    private func loadArtwork(_ url: URL?) {
        guard let url, url != artworkURL else { return }
        artworkURL = url
        artwork = nil
        Task {
            // The same picture Now Playing shows (the large cover; the original if that's missing),
            // from the same cache, so it's usually already decoded.
            var image: UIImage?
            if let sharp = Artwork.sharp(url, size: 1200), sharp != url { image = await ImagePipeline.shared.image(sharp) }
            if image == nil { image = await ImagePipeline.shared.image(url) }
            guard let image else { return }
            guard self.artworkURL == url else { return }
            self.artwork = Self.makeArtwork(image)
            self.update()
        }
    }
}
