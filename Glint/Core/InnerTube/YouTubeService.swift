import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum SearchFilter: String, CaseIterable, Identifiable {
    case all, videos, channels, playlists
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var params: String? {
        switch self {
        case .all: return nil
        case .videos: return "EgIQAQ%3D%3D"
        case .channels: return "EgIQAg%3D%3D"
        case .playlists: return "EgIQAw%3D%3D"
        }
    }
}

struct ChannelPage {
    var id: String
    var name: String
    var avatar: URL?
    var banner: URL?
    var subscribers: String?
    var feed: FeedPage
}

/// Where to fetch the next page of a feed.
enum ContinuationEndpoint: Hashable {
    case browse, search, next
    var path: String {
        switch self {
        case .browse: return "browse"
        case .search: return "search"
        case .next: return "next"
        }
    }
}

/// High level YouTube + YouTube Music API.
final class YouTubeService: @unchecked Sendable {
    static let shared = YouTubeService()
    private let tube = InnerTube.shared
    var hideShorts = true

    // MARK: Video feeds

    func home() async throws -> FeedPage {
        let json = try await tube.call("browse", body: ["browseId": "FEwhat_to_watch"])
        return Parser.feed(json, hideShorts: hideShorts)
    }

    func subscriptions() async throws -> FeedPage {
        guard tube.isSignedIn else { throw InnerTubeError.notSignedIn }
        let json = try await tube.call("browse", body: ["browseId": "FEsubscriptions"])
        return Parser.feed(json, hideShorts: hideShorts)
    }

    func history() async throws -> FeedPage {
        guard tube.isSignedIn else { throw InnerTubeError.notSignedIn }
        let json = try await tube.call("browse", body: ["browseId": "FEhistory"])
        return Parser.feed(json, hideShorts: hideShorts)
    }

    func libraryPlaylists() async throws -> [PlaylistItem] {
        guard tube.isSignedIn else { throw InnerTubeError.notSignedIn }
        let json = try await tube.call("browse", body: ["browseId": "FEplaylist_aggregation"])
        var items = Parser.feed(json, hideShorts: false).items.compactMap { item -> PlaylistItem? in
            if case .playlist(let p) = item { return p }
            return nil
        }
        if items.isEmpty {
            let lib = try await tube.call("browse", body: ["browseId": "FElibrary"])
            items = Parser.feed(lib, hideShorts: false).items.compactMap { item -> PlaylistItem? in
                if case .playlist(let p) = item { return p }
                return nil
            }
        }
        return items.filter { $0.id != "WL" && $0.id != "LL" }
    }

    func search(_ query: String, filter: SearchFilter = .all) async throws -> FeedPage {
        var body: [String: Any] = ["query": query]
        if let p = filter.params { body["params"] = p }
        let json = try await tube.call("search", body: body)
        return Parser.feed(json, hideShorts: hideShorts)
    }

    func more(_ token: String, endpoint: ContinuationEndpoint) async throws -> FeedPage {
        let json = try await tube.call(endpoint.path, body: ["continuation": token])
        return Parser.feed(json, hideShorts: hideShorts)
    }

    func suggestions(_ query: String) async -> [String] {
        guard !query.isEmpty,
              var comps = URLComponents(string: "https://suggestqueries.google.com/complete/search") else { return [] }
        comps.queryItems = [
            URLQueryItem(name: "client", value: "firefox"),
            URLQueryItem(name: "ds", value: "yt"),
            URLQueryItem(name: "hl", value: tube.hl),
            URLQueryItem(name: "q", value: query),
        ]
        guard let url = comps.url, let (data, _) = try? await tube.session.data(from: url),
              let json = try? JSON.parse(data) else { return [] }
        return json[1].array.compactMap { $0.string }.prefix(8).map { $0 }
    }

    func playlist(_ id: String) async throws -> (title: String, feed: FeedPage) {
        let browseId = id.hasPrefix("VL") ? id : "VL" + id
        let json = try await tube.call("browse", body: ["browseId": browseId])
        let title = json.at("metadata.playlistMetadataRenderer.title").string
            ?? json["header"].first("title")?.text ?? "Playlist"
        return (title, Parser.feed(json, hideShorts: false))
    }

    func channel(_ id: String) async throws -> ChannelPage {
        let json = try await tube.call("browse", body: ["browseId": id, "params": "EgZ2aWRlb3PyBgQKAjoA"])
        let meta = json.at("metadata.channelMetadataRenderer")
        let header = json["header"]
        let subs = header.findAll("content").compactMap { $0.string }.first { $0.lowercased().contains("subscriber") }
            ?? header.first("subscriberCountText")?.text
        let banner = header.first("banner").flatMap { Parser.thumbnail($0["imageBannerViewModel"]["image"]) }
            ?? header.first("banner").flatMap { Parser.thumbnail($0) }
        var feed = Parser.feed(json["contents"], hideShorts: hideShorts)
        feed.items = feed.items.map { item in
            guard case .video(var v) = item else { return item }
            if v.channelName == nil { v.channelName = meta["title"].string }
            if v.channelId == nil { v.channelId = id }
            return .video(v)
        }
        return ChannelPage(id: id,
                           name: meta["title"].string ?? header.first("title")?.text ?? "",
                           avatar: Parser.thumbnail(meta["avatar"]),
                           banner: banner,
                           subscribers: subs,
                           feed: feed)
    }

    // MARK: Watch page

    func watchExtras(_ videoId: String) async throws -> WatchExtras {
        let json = try await tube.call("next", body: ["videoId": videoId])
        let results = json.at("contents.twoColumnWatchNextResults")
        let owner = results.first("videoOwnerRenderer") ?? .null
        let primary = results.first("videoPrimaryInfoRenderer") ?? .null
        let related = Parser.feed(results["secondaryResults"], hideShorts: true)
        let subscribed = results.first("subscribeButtonRenderer")?["subscribed"].bool
            ?? json.findAll("subscribeButtonViewModel").first.flatMap { _ in
                json.findAll("subscriptionStateEntity").first?["subscribed"].bool
            }
        let likes = results.first("likeButtonViewModel")?.first("title")?.string
        let avatar = Parser.thumbnail(owner["thumbnail"])
            ?? owner.first("avatarViewModel").flatMap { Parser.thumbnail($0["image"]) }
        let subs = owner["subscriberCountText"].text
            ?? owner.findAll("content").compactMap { $0.string }.first { $0.contains("subscriber") }
        return WatchExtras(
            channelAvatar: avatar,
            subscriberCount: subs,
            isSubscribed: subscribed,
            likeCount: likes,
            dateText: primary["dateText"].text ?? primary["relativeDateText"].text,
            related: related.items.compactMap(\.video),
            relatedContinuation: related.continuation)
    }

    func setSubscribed(_ on: Bool, channelId: String) async throws {
        guard tube.isSignedIn else { throw InnerTubeError.notSignedIn }
        _ = try await tube.call(on ? "subscription/subscribe" : "subscription/unsubscribe",
                                body: ["channelIds": [channelId]])
    }

    enum Rating { case like, dislike, none }

    func rate(_ videoId: String, _ rating: Rating) async throws {
        guard tube.isSignedIn else { throw InnerTubeError.notSignedIn }
        let path: String
        switch rating {
        case .like: path = "like/like"
        case .dislike: path = "like/dislike"
        case .none: path = "like/removelike"
        }
        _ = try await tube.call(path, body: ["target": ["videoId": videoId]])
    }

    func saveToWatchLater(_ videoId: String) async throws {
        guard tube.isSignedIn else { throw InnerTubeError.notSignedIn }
        _ = try await tube.call("browse/edit_playlist", body: [
            "playlistId": "WL",
            "actions": [["addedVideoId": videoId, "action": "ACTION_ADD_VIDEO"]],
        ])
    }

    // MARK: Account

    func accountInfo() async throws -> AccountInfo {
        let json = try await tube.call("account/account_menu", body: [:])
        guard let h = json.first("activeAccountHeaderRenderer") else { throw InnerTubeError.notSignedIn }
        return AccountInfo(name: h["accountName"].text ?? "YouTube account",
                           handle: h["channelHandle"].text ?? h["email"].text,
                           avatar: Parser.thumbnail(h["accountPhoto"]))
    }

    // MARK: Music

    func musicHome() async throws -> MusicPage {
        let json = try await tube.call("browse", client: .webRemix, body: ["browseId": "FEmusic_home"])
        return MusicParser.page(json)
    }

    /// New releases, moods and charts — works without an account.
    func musicExplore() async throws -> MusicPage {
        let json = try await tube.call("browse", client: .webRemix, body: ["browseId": "FEmusic_explore"])
        return MusicParser.page(json)
    }

    func musicCharts() async throws -> MusicPage {
        let json = try await tube.call("browse", client: .webRemix, body: ["browseId": "FEmusic_charts"])
        return MusicParser.page(json)
    }

    func musicSearch(_ query: String) async throws -> MusicPage {
        let json = try await tube.call("search", client: .webRemix, body: ["query": query])
        return MusicParser.page(json)
    }

    func musicBrowse(_ browseId: String) async throws -> MusicPage {
        let json = try await tube.call("browse", client: .webRemix, body: ["browseId": browseId])
        return MusicParser.page(json)
    }

    func musicLiked() async throws -> MusicPage {
        guard tube.isSignedIn else { throw InnerTubeError.notSignedIn }
        return try await musicBrowse("FEmusic_liked_videos")
    }

    func musicLibraryPlaylists() async throws -> MusicPage {
        guard tube.isSignedIn else { throw InnerTubeError.notSignedIn }
        return try await musicBrowse("FEmusic_liked_playlists")
    }

    /// Radio / album / playlist queue for a track.
    func musicQueue(videoId: String?, playlistId: String?) async throws -> [MusicItem] {
        var body: [String: Any] = ["isAudioOnly": true, "enablePersistentPlaylistPanel": true]
        if let videoId { body["videoId"] = videoId }
        body["playlistId"] = playlistId ?? videoId.map { "RDAMVM" + $0 } ?? ""
        let json = try await tube.call("next", client: .webRemix, body: body)
        return MusicParser.queue(json)
    }
}
