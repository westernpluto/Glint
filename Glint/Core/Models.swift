import Foundation

struct VideoItem: Identifiable, Hashable, Codable {
    var id: String              // videoId
    var title: String
    var channelName: String?
    var channelId: String?
    var channelAvatar: URL?
    var thumbnail: URL?
    var duration: String?
    var views: String?
    var published: String?
    var isLive: Bool = false
    var isShort: Bool = false

    var subtitle: String {
        [channelName, views, published].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// High resolution thumbnail that always exists for a public video.
    var bestThumbnail: URL? {
        thumbnail ?? URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
    }
}

struct ChannelItem: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    var thumbnail: URL?
    var detail: String?
}

struct PlaylistItem: Identifiable, Hashable, Codable {
    var id: String              // playlistId (without VL prefix)
    var title: String
    var thumbnail: URL?
    var detail: String?
}

enum FeedItem: Identifiable, Hashable {
    case video(VideoItem)
    case channel(ChannelItem)
    case playlist(PlaylistItem)

    var id: String {
        switch self {
        case .video(let v): return "v:" + v.id
        case .channel(let c): return "c:" + c.id
        case .playlist(let p): return "p:" + p.id
        }
    }

    var video: VideoItem? { if case .video(let v) = self { return v }; return nil }
}

/// A titled row of videos (an Explore shelf).
struct FeedSection: Identifiable, Hashable {
    var id: String { title }
    var title: String
    var items: [VideoItem]
}

struct FeedPage {
    var items: [FeedItem]
    var continuation: String?
}

// MARK: Watch page

struct VideoDetails: Hashable {
    var id: String
    var title: String
    var channelName: String
    var channelId: String?
    var description: String
    var viewCount: Int?
    var lengthSeconds: Int?
    var isLive: Bool
    var thumbnail: URL?
    var publishDate: String?
}

struct Chapter: Identifiable, Hashable {
    var id: Double { start }
    var title: String
    var start: Double
    var thumbnail: URL?
}

struct WatchExtras {
    var channelAvatar: URL?
    var subscriberCount: String?
    var isSubscribed: Bool?
    var isLiked: Bool?
    var likeCount: String?
    var dateText: String?
    var related: [VideoItem]
    var relatedContinuation: String?
    var commentsToken: String? = nil
    var commentCount: String? = nil
    var chapters: [Chapter] = []
}

// MARK: Music

enum MusicKind: String, Codable, Hashable {
    case song, video, album, playlist, artist, other
}

struct MusicItem: Identifiable, Hashable, Codable {
    var id: String { (videoId ?? browseId ?? playlistId ?? title) + kind.rawValue }
    var kind: MusicKind
    var title: String
    var subtitle: String?
    var thumbnail: URL?
    var videoId: String?
    var playlistId: String?
    var browseId: String?
    var duration: String?

    var isPlayable: Bool { videoId != nil }
}

struct MusicShelf: Identifiable, Hashable {
    var id = UUID()
    var title: String
    var items: [MusicItem]
    /// Shelves of songs render as lists; albums/playlists render as carousels.
    var prefersList: Bool
}

struct MusicPage {
    var title: String? = nil
    var subtitle: String? = nil
    var thumbnail: URL? = nil
    var shelves: [MusicShelf]
    var playlistId: String? = nil
}

// MARK: Library

struct AccountInfo: Codable, Hashable {
    var name: String
    var handle: String?
    var avatar: URL?
}
