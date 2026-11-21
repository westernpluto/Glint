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

/// Topic destinations YouTube still publishes as channels with curated shelves.
enum ExploreTopic: String, CaseIterable, Identifiable, Hashable {
    case top, music, sports, news, live, learning

    var id: String { rawValue }

    var title: String {
        switch self {
        case .top: return "Top picks"
        case .music: return "Music"
        case .sports: return "Sports"
        case .news: return "News"
        case .live: return "Live"
        case .learning: return "Learning"
        }
    }

    var icon: String {
        switch self {
        case .top: return "sparkles"
        case .music: return "music.note"
        case .sports: return "sportscourt"
        case .news: return "newspaper"
        case .live: return "dot.radiowaves.left.and.right"
        case .learning: return "graduationcap"
        }
    }

    var channelId: String? {
        switch self {
        case .top: return nil
        case .music: return "UC-9-kyTW8ZkZNDHQJ6FgpwQ"
        case .sports: return "UCEgdi0XIXXZ-qJOFPf4JSKw"
        case .news: return "UCYfdidRxbB8Qhf0Nx7ioOYw"
        case .live: return "UC4R8DWoMoI7CAwX8_LjQHig"
        case .learning: return "UCtFRv9O2AHqOZjjynzrv-xg"
        }
    }
}

struct ChannelPage {
    var id: String
    var name: String
    var avatar: URL?
    var banner: URL?
    var subscribers: String?
    /// nil when signed out or unknown.
    var subscribed: Bool? = nil
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

    /// Signed-out home: YouTube's own "Popular on YouTube" channel (YouTube offers no
    /// anonymous recommendations any more).
    func trending() async throws -> FeedPage {
        let json = try await tube.call("browse", body: ["browseId": "UC4R8DWoMoI7CAwX8_LjQHig"], authenticated: false)
        return Parser.feed(json, hideShorts: hideShorts)
    }

    /// Curated shelves for a topic. "Top picks" interleaves the leading shelves of every topic.
    func explore(_ topic: ExploreTopic) async throws -> [FeedSection] {
        if let id = topic.channelId { return try await sections(channelId: id) }
        let topics: [ExploreTopic] = [.music, .news, .sports, .learning, .live]
        let fetched: [[FeedSection]] = await withTaskGroup(of: (Int, [FeedSection]).self) { group in
            for (i, t) in topics.enumerated() {
                group.addTask { (i, (try? await self.explore(t)) ?? []) }
            }
            var out = Array(repeating: [FeedSection](), count: topics.count)
            for await (i, secs) in group { out[i] = secs }
            return out
        }
        // Lead with each topic's flagship shelf ("Trending", "Biggest Hits", "Featured", ...).
        let flagship = ["trending", "biggest", "featured", "live now", "top stories", "new this week"]
        let ordered: [[FeedSection]] = fetched.map { secs in
            let lead = secs.filter { s in flagship.contains { s.title.lowercased().contains($0) } }
            return lead + secs.filter { !lead.contains($0) }
        }
        var mixed: [FeedSection] = []
        var seenVideos = Set<String>()
        for round in 0..<2 {
            for (i, secs) in ordered.enumerated() where round < secs.count {
                var sec = secs[round]
                sec.items = sec.items.filter { seenVideos.insert($0.id).inserted }
                guard sec.items.count >= 3 else { continue }
                // Prefix generic shelf names with their topic so "Trending" reads as "Sports · Trending".
                if sec.title.count < 22, !sec.title.lowercased().contains(topics[i].title.lowercased()) {
                    sec.title = "\(topics[i].title) · \(sec.title)"
                }
                mixed.append(sec)
            }
        }
        if mixed.isEmpty { throw InnerTubeError.empty }
        return mixed
    }

    private func sections(channelId: String) async throws -> [FeedSection] {
        let json = try await tube.call("browse", body: ["browseId": channelId], authenticated: false)
        var out: [FeedSection] = []
        var seen = Set<String>()
        json["contents"].walk { key, value in
            guard key == "richShelfRenderer" || key == "shelfRenderer" else { return !Parser.adRenderers.contains(key) }
            let title = value["title"].text
                ?? value["header"].first("title")?.text
                ?? value["header"].findAll("content").compactMap(\.string).first
                ?? ""
            let items = Parser.feed(value, hideShorts: true).items.compactMap(\.video).filter { seen.insert($0.id).inserted }
            if !title.isEmpty, items.count >= 3 { out.append(FeedSection(title: title, items: items)) }
            return false
        }
        if out.isEmpty { throw InnerTubeError.empty }
        return out
    }

    func subscriptions() async throws -> FeedPage {
        guard tube.isSignedIn else { throw InnerTubeError.notSignedIn }
        let json = try await tube.call("browse", body: ["browseId": "FEsubscriptions"])
        return Parser.feed(json, hideShorts: hideShorts)
    }

    /// Channels you subscribe to (signed in).
    func subscribedChannels() async throws -> [ChannelItem] {
        guard tube.isSignedIn else { throw InnerTubeError.notSignedIn }
        let json = try await tube.call("browse", body: ["browseId": "FEchannels"])
        return Parser.feed(json, hideShorts: false).items.compactMap { item -> ChannelItem? in
            if case .channel(let c) = item { return c }
            return nil
        }
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

    enum ChannelTab: String, CaseIterable, Identifiable {
        case videos = "Videos", live = "Live", playlists = "Playlists"
        var id: String { rawValue }
        var params: String {
            switch self {
            case .videos: return "EgZ2aWRlb3PyBgQKAjoA"
            case .live: return "EgdzdHJlYW1z8gYECgJ6AA%3D%3D"
            case .playlists: return "EglwbGF5bGlzdHPyBgQKAkIA"
            }
        }
    }

    func channel(_ id: String, tab: ChannelTab = .videos) async throws -> ChannelPage {
        let json = try await tube.call("browse", body: ["browseId": id, "params": tab.params])
        let meta = json.at("metadata.channelMetadataRenderer")
        let header = json["header"]
        let subs = header.findAll("content").compactMap { $0.string }.first { $0.lowercased().contains("subscriber") }
            ?? header.first("subscriberCountText")?.text
        let banner = header.first("banner").flatMap { Parser.thumbnail($0["imageBannerViewModel"]["image"]) }
            ?? header.first("banner").flatMap { Parser.thumbnail($0) }
        let subscribed = header.first("subscribeButtonRenderer")?["subscribed"].bool
            ?? json.findAll("subscriptionStateEntity").first?["subscribed"].bool
        var feed = Parser.feed(json["contents"], hideShorts: hideShorts)
        feed.items = feed.items.map { item in
            guard case .video(var v) = item else { return item }
            if v.channelName == nil { v.channelName = meta["title"].string }
            if v.channelId == nil { v.channelId = id }
            return .video(v)
        }
        return ChannelPage(id: id,
                           name: meta["title"].string ?? header.first("title")?.text ?? "",
                           avatar: Parser.avatar(meta["avatar"]),
                           banner: banner,
                           subscribers: subs,
                           subscribed: subscribed,
                           feed: feed)
    }

    // MARK: Watch page

    func watchExtras(_ videoId: String) async throws -> WatchExtras {
        let json = try await tube.call("next", body: ["videoId": videoId])
        let results = json.at("contents.twoColumnWatchNextResults")
        let owner = results.first("videoOwnerRenderer") ?? .null
        let primary = results.first("videoPrimaryInfoRenderer") ?? .null
        let related = Parser.feed(results["secondaryResults"], hideShorts: true)
        let subscribed = results.first("videoSecondaryInfoRenderer")?["subscribeButton"].first("subscribeState")?["subscribed"].bool
            ?? results.first("subscribeButtonRenderer")?["subscribed"].bool
            ?? json.findAll("subscribeButtonViewModel").first.flatMap { _ in
                json.findAll("subscriptionStateEntity").first?["subscribed"].bool
            }
        let likes = results.first("likeButtonViewModel")?.first("title")?.string
        let avatar = Parser.avatar(owner["thumbnail"])
            ?? owner.first("avatarViewModel").flatMap { Parser.avatar($0["image"]) }
        let subs = owner["subscriberCountText"].text
            ?? owner.findAll("content").compactMap { $0.string }.first { $0.contains("subscriber") }
        return WatchExtras(
            channelAvatar: avatar,
            subscriberCount: subs,
            isSubscribed: subscribed,
            isLiked: json.findAll("likeStatusEntity").first?["likeStatus"].string.map { $0 == "LIKE" },
            likeCount: likes,
            dateText: primary["dateText"].text ?? primary["relativeDateText"].text,
            related: related.items.compactMap(\.video),
            relatedContinuation: related.continuation,
            commentsToken: results.findAll("itemSectionRenderer")
                .first { $0["sectionIdentifier"].string == "comment-item-section" }?
                .first("continuationCommand")?["token"].string,
            commentCount: Self.commentCount(json),
            chapters: Self.chapters(json))
    }

    private static func commentCount(_ json: JSON) -> String? {
        json["engagementPanels"].array
                .first { ($0.first("panelIdentifier")?.string ?? "").contains("comment") }?
                .first("contextualInfo")?.text
    }

    /// Creator chapters (deduplicated by start time, in order).
    static func chapters(_ json: JSON) -> [Chapter] {
        var seen = Set<Int>()
        let list = json.findAll("chapterRenderer").compactMap { c -> Chapter? in
            guard let ms = c["timeRangeStartMillis"].int, let title = c["title"].text,
                  seen.insert(ms).inserted else { return nil }
            return Chapter(title: title, start: Double(ms) / 1000, thumbnail: Parser.thumbnail(c["thumbnail"], minWidth: 0))
        }
        return list.count >= 2 ? list.sorted { $0.start < $1.start } : []
    }

    /// A page of comments (or of a thread's replies) from a continuation token.
    func comments(_ token: String) async throws -> CommentPage {
        let json = try await tube.call("next", body: ["continuation": token])
        return CommentParser.page(json)
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
                           avatar: Parser.avatar(h["accountPhoto"]))
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

    struct Lyrics: Sendable {
        struct Line: Sendable, Hashable { var text: String; var start: Double; var end: Double }
        /// Timed lines (seconds), when YouTube Music has synced lyrics for the song.
        var lines: [Line]
        /// Plain text otherwise.
        var text: String?
        var source: String?
    }

    /// Song lyrics: synced lines when YouTube Music has them (its Android client returns line
    /// timings), else plain text, with the credit line.
    func lyrics(videoId: String) async -> Lyrics? {
        guard let next = try? await tube.call("next", client: .webRemix, body: ["videoId": videoId, "isAudioOnly": true]),
              let id = next.findAll("tabRenderer")
                .compactMap({ $0.at("endpoint.browseEndpoint.browseId").string })
                .first(where: { $0.hasPrefix("MPLY") })
        else { return nil }

        if let page = try? await tube.call("browse", client: .androidMusic, body: ["browseId": id], authenticated: false),
           let model = page.first("timedLyricsModel") {
            let data = model["lyricsData"]
            let lines = data["timedLyricsData"].array.compactMap { l -> Lyrics.Line? in
                guard let text = l["lyricLine"].string,
                      let s = l.at("cueRange.startTimeMilliseconds").double,
                      let e = l.at("cueRange.endTimeMilliseconds").double else { return nil }
                return Lyrics.Line(text: text, start: s / 1000, end: e / 1000)
            }
            let source = data["sourceMessage"].text
            if !lines.isEmpty { return Lyrics(lines: lines, text: nil, source: source) }
            let plain = data["timedLyricsData"].array.compactMap { $0["lyricLine"].string }.joined(separator: "\n")
            if !plain.isEmpty { return Lyrics(lines: [], text: plain, source: source) }
        }

        guard let page = try? await tube.call("browse", client: .webRemix, body: ["browseId": id]),
              let shelf = page.first("musicDescriptionShelfRenderer"),
              let text = shelf["description"].text, !text.isEmpty
        else { return nil }
        return Lyrics(lines: [], text: text, source: shelf["footer"].text)
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
