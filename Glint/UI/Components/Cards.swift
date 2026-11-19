import SwiftUI

/// Large card: thumbnail on top, avatar + text below.
struct VideoCard: View {
    var video: VideoItem
    @Environment(PlayerController.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { player.play(video) } label: {
                Thumbnail(url: video.bestThumbnail, duration: video.duration, isLive: video.isLive, videoId: video.id)
                    .overlay {
                        // Thin edge so light thumbnails don't melt into the background.
                        RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
                            .strokeBorder(.primary.opacity(0.06))
                    }
            }
            .buttonStyle(.plain)

            HStack(alignment: .top, spacing: 12) {
                if let id = video.channelId {
                    NavigationLink(value: Route.channel(id: id, name: video.channelName)) {
                        Avatar(url: video.channelAvatar, size: 36)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(video.channelName ?? "Channel")
                }
                Button { player.play(video) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(video.title)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(video.subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                MoreButton(video: video)
            }
        }
        .contextMenu { VideoMenu(video: video) }
    }
}

/// Visible "⋯" for a video's actions (the same as long-press, but discoverable).
struct MoreButton: View {
    var video: VideoItem

    var body: some View {
        Menu {
            VideoMenu(video: video)
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("More actions for \(video.title)")
    }
}

/// Compact row: small thumbnail left, text right. Used for "Up next" and playlists.
struct VideoRow: View {
    var video: VideoItem
    var thumbWidth: CGFloat = 150
    var isCurrent = false
    @Environment(PlayerController.self) private var player

    var body: some View {
        Button { player.play(video) } label: {
            HStack(alignment: .top, spacing: 12) {
                Thumbnail(url: video.bestThumbnail, duration: video.duration, isLive: video.isLive, corner: 10, videoId: video.id)
                    .frame(width: thumbWidth)
                VStack(alignment: .leading, spacing: 4) {
                    Text(video.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let c = video.channelName {
                        Text(c).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    let meta = [video.views, video.published].compactMap { $0 }.joined(separator: " · ")
                    if !meta.isEmpty {
                        Text(meta).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                MoreButton(video: video)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { VideoMenu(video: video) }
    }
}

struct VideoMenu: View {
    var video: VideoItem
    @Environment(PlayerController.self) private var player
    @Environment(AccountStore.self) private var accounts

    var body: some View {
        Button { player.play(video) } label: { Label("Play", systemImage: "play") }
        Button { player.playAudio(video) } label: { Label("Listen (audio only)", systemImage: "headphones") }
        Button { player.enqueueNext(video) } label: { Label("Play next", systemImage: "text.line.first.and.arrowtriangle.forward") }
        Button { player.enqueue(video) } label: { Label("Add to queue", systemImage: "text.line.last.and.arrowtriangle.forward") }
        if accounts.isSignedIn {
            Button {
                Task {
                    try? await YouTubeService.shared.saveToWatchLater(video.id)
                    player.flash("Saved to Watch later")
                }
            } label: { Label("Save to Watch later", systemImage: "clock") }
        }
        if let url = URL(string: "https://youtu.be/\(video.id)") {
            ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
        }
    }
}

struct ChannelCard: View {
    var channel: ChannelItem

    var body: some View {
        NavigationLink(value: Route.channel(id: channel.id, name: channel.name)) {
            HStack(spacing: 14) {
                Avatar(url: channel.thumbnail, size: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(channel.name).font(.headline).foregroundStyle(.primary).lineLimit(1)
                    if let d = channel.detail { Text(d).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color.cardFill, in: RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct PlaylistCard: View {
    var playlist: PlaylistItem

    var body: some View {
        NavigationLink(value: Route.playlist(id: playlist.id, title: playlist.title)) {
            VStack(alignment: .leading, spacing: 8) {
                Thumbnail(url: playlist.thumbnail, duration: nil)
                    .overlay(alignment: .bottomTrailing) {
                        Label(playlist.detail ?? "Playlist", systemImage: "list.bullet")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 5))
                            .padding(6)
                    }
                Text(playlist.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }
        }
        .buttonStyle(.plain)
    }
}
