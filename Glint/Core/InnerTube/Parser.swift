import Foundation

/// Turns InnerTube browse/search/next responses into flat feeds.
/// Every advertising renderer YouTube ships is dropped here, so no ad ever reaches the UI.
enum Parser {
    static let adRenderers: Set<String> = [
        "adSlotRenderer", "promotedVideoRenderer", "promotedSparklesWebRenderer",
        "promotedSparklesTextSearchRenderer", "displayAdRenderer", "compactPromotedVideoRenderer",
        "compactPromotedItemRenderer", "searchPyvRenderer", "bannerPromoRenderer",
        "inFeedAdLayoutRenderer", "brandVideoShelfRenderer", "brandVideoSingletonRenderer",
        "mealbarPromoRenderer", "statementBannerRenderer", "primetimePromoRenderer",
        "adBreakServiceRenderer", "playerLegacyDesktopWatchAdsRenderer", "masthead",
        "movingThumbnailRenderer", "feedNudgeRenderer", "emergencyOneboxRenderer",
        "clarificationRenderer", "infoPanelContainerRenderer", "engagementPanels",
        "topbar", "frameworkUpdates", "adPlacements", "playerAds", "adSlots",
    ]

    // MARK: Feeds

    /// Receives YouTube's resume progress found while parsing (set at launch).
    nonisolated(unsafe) static var onResumeProgress: (@Sendable ([(id: String, percent: Double, duration: Double)]) -> Void)?

    static func feed(_ root: JSON, hideShorts: Bool) -> FeedPage {
        var items: [FeedItem] = []
        var seen = Set<String>()
        var continuation: String?

        func add(_ item: FeedItem?) {
            guard let item else { return }
            if hideShorts, case .video(let v) = item, v.isShort { return }
            // YouTube "Mix" radios (RD…) aren't browsable playlists; skip them rather than show a dead end.
            if case .playlist(let p) = item, p.id.hasPrefix("RD") { return }
            if seen.insert(item.id).inserted { items.append(item) }
        }

        root.walk { key, value in
            if adRenderers.contains(key) { return false }
            switch key {
            case "videoRenderer", "gridVideoRenderer", "compactVideoRenderer",
                 "playlistVideoRenderer", "playlistPanelVideoRenderer", "videoCardRenderer":
                add(video(value).map(FeedItem.video)); return false
            case "reelItemRenderer":
                add(reel(value).map(FeedItem.video)); return false
            case "shortsLockupViewModel":
                add(shortsLockup(value).map(FeedItem.video)); return false
            case "lockupViewModel":
                add(lockup(value)); return false
            case "channelRenderer", "gridChannelRenderer":
                add(channel(value).map(FeedItem.channel)); return false
            case "playlistRenderer", "gridPlaylistRenderer", "compactPlaylistRenderer":
                add(playlist(value).map(FeedItem.playlist)); return false
            case "continuationItemRenderer":
                if let t = value.at("continuationEndpoint.continuationCommand.token").string
                    ?? value.first("token")?.string {
                    continuation = t
                }
                return false
            case "nextContinuationData":
                if let t = value["continuation"].string { continuation = t }
                return false
            default:
                return true
            }
        }
        // Signed-in resume bars feed the local watch progress.
        let progress = items.compactMap { item -> (id: String, percent: Double, duration: Double)? in
            guard case .video(let v) = item, let p = v.watchedPercent, let d = v.durationSeconds else { return nil }
            return (v.id, p, d)
        }
        if !progress.isEmpty { onResumeProgress?(progress) }
        return FeedPage(items: items, continuation: continuation)
    }

    // MARK: Individual renderers

    static func video(_ r: JSON) -> VideoItem? {
        guard let id = r["videoId"].string else { return nil }
        let owner = [r["ownerText"], r["longBylineText"], r["shortBylineText"]].first { !$0.isNull } ?? .null
        let ownerRun = owner["runs"][0]

        var duration = r["lengthText"].text
        var live = false
        var watched: Double?
        for o in r["thumbnailOverlays"].array {
            if let p = o.at("thumbnailOverlayResumePlaybackRenderer.percentDurationWatched").double { watched = p }
            let ts = o["thumbnailOverlayTimeStatusRenderer"]
            if ts.isNull { continue }
            if ts["style"].string == "LIVE" { live = true }
            if duration == nil { duration = ts["text"].text }
        }
        for b in r["badges"].array where b.at("metadataBadgeRenderer.style").string == "BADGE_STYLE_TYPE_LIVE_NOW" {
            live = true
        }
        let isShort = !r.at("navigationEndpoint.reelWatchEndpoint").isNull

        return VideoItem(
            id: id,
            title: r["title"].text ?? r["headline"].text ?? "",
            channelName: owner.text,
            channelId: ownerRun.at("navigationEndpoint.browseEndpoint.browseId").string,
            channelAvatar: avatar(r.at("channelThumbnailSupportedRenderers.channelThumbnailWithLinkRenderer.thumbnail"))
                ?? avatar(r["channelThumbnail"]),
            thumbnail: thumbnail(r["thumbnail"]),
            duration: live ? nil : duration,
            views: r["shortViewCountText"].text ?? r["viewCountText"].text ?? r["videoInfo"].text,
            published: r["publishedTimeText"].text,
            isLive: live,
            isShort: isShort,
            watchedPercent: watched
        )
    }

    static func reel(_ r: JSON) -> VideoItem? {
        guard let id = r["videoId"].string else { return nil }
        return VideoItem(id: id, title: r["headline"].text ?? "", thumbnail: thumbnail(r["thumbnail"]),
                         views: r["viewCountText"].text, isShort: true)
    }

    static func shortsLockup(_ r: JSON) -> VideoItem? {
        let id = r.at("onTap.innertubeCommand.reelWatchEndpoint.videoId").string
            ?? r["entityId"].string?.replacingOccurrences(of: "shorts-shelf-item-", with: "")
        guard let id, !id.isEmpty else { return nil }
        return VideoItem(id: id,
                         title: r.at("overlayMetadata.primaryText").text ?? "",
                         thumbnail: thumbnail(r["thumbnail"]),
                         views: r.at("overlayMetadata.secondaryText").text,
                         isShort: true)
    }

    /// The 2024+ "view model" card used across home, related and search.
    static func lockup(_ r: JSON) -> FeedItem? {
        guard let contentId = r["contentId"].string else { return nil }
        let type = r["contentType"].string ?? ""
        let meta = r.at("metadata.lockupMetadataViewModel")
        let title = meta["title"].text ?? ""
        let rows = meta.at("metadata.contentMetadataViewModel.metadataRows").array
        let rowTexts: [[String]] = rows.map { row in
            row["metadataParts"].array.compactMap { $0["text"].text }
        }
        let badge = r["contentImage"].first("thumbnailBadgeViewModel")?["text"].string
            ?? r["contentImage"].findAll("thumbnailBadgeViewModel").first?["text"].string
        let image = r["contentImage"].first("image").flatMap { thumbnail($0) }

        // Stations (radio mixes), albums, podcasts and anything without an 11-character video
        // id are collections — never present them as a playable video.
        if type.contains("PLAYLIST") || type.contains("ALBUM") || type.contains("PODCAST")
            || type.contains("STATION") || type.contains("MIX") || contentId.count != 11 {
            return .playlist(PlaylistItem(id: contentId, title: title, thumbnail: image,
                                          detail: badge ?? rowTexts.first?.first))
        }
        if type.contains("CHANNEL") {
            return .channel(ChannelItem(id: contentId, name: title, thumbnail: image, detail: rowTexts.first?.first))
        }

        let channelId = meta.findAll("browseEndpoint")
            .compactMap { $0["browseId"].string }
            .first { $0.hasPrefix("UC") }
        let avatar = meta.first("avatarViewModel").flatMap { Parser.avatar($0["image"]) }
        let live = badge?.uppercased().contains("LIVE") == true
        let secondRow = rowTexts.count > 1 ? rowTexts[1] : []
        return .video(VideoItem(
            id: contentId,
            title: title,
            channelName: rowTexts.first?.first,
            channelId: channelId,
            channelAvatar: avatar,
            thumbnail: image ?? URL(string: "https://i.ytimg.com/vi/\(contentId)/hqdefault.jpg"),
            duration: live ? nil : badge,
            views: secondRow.first,
            published: secondRow.count > 1 ? secondRow[1] : nil,
            isLive: live,
            watchedPercent: r["contentImage"].first("thumbnailOverlayProgressBarViewModel")?["startPercent"].double
        ))
    }

    static func channel(_ r: JSON) -> ChannelItem? {
        guard let id = r["channelId"].string else { return nil }
        return ChannelItem(id: id,
                           name: r["title"].text ?? "",
                           thumbnail: avatar(r["thumbnail"]),
                           detail: r["videoCountText"].text ?? r["subscriberCountText"].text)
    }

    static func playlist(_ r: JSON) -> PlaylistItem? {
        guard let id = r["playlistId"].string else { return nil }
        let thumb = thumbnail(r["thumbnail"]) ?? thumbnail(r["thumbnails"][0]) ?? thumbnail(r["thumbnailRenderer"].first("thumbnail") ?? .null)
        return PlaylistItem(id: id, title: r["title"].text ?? "",
                            thumbnail: thumb,
                            detail: r["videoCountText"].text ?? r["videoCountShortText"].text)
    }

    // MARK: Thumbnails

    /// Picks an image from `{thumbnails:[...]}` or `{sources:[...]}`: the smallest one at least
    /// `minWidth` wide (sharp on cards without downloading 1280 px originals), else the largest.
    static func thumbnail(_ j: JSON, minWidth: Int = 640) -> URL? {
        var list = j["thumbnails"].array
        if list.isEmpty { list = j["sources"].array }
        if list.isEmpty, j["url"].string != nil { list = [j] }
        let sized = list.filter { ($0["width"].int ?? 0) >= minWidth }
        let best = sized.min { ($0["width"].int ?? 0) < ($1["width"].int ?? 0) }
            ?? list.max { ($0["width"].int ?? 0) < ($1["width"].int ?? 0) } ?? list.last
        guard var s = best?["url"].string else { return nil }
        if s.hasPrefix("//") { s = "https:" + s }
        return URL(string: s)
    }

    /// Channel avatars come as tiny `=s68-` / `=s88-` images; ask for a crisp 3× size.
    static func avatar(_ j: JSON) -> URL? {
        guard let url = thumbnail(j, minWidth: 0) else { return nil }
        let str = url.absoluteString
        guard let r = str.range(of: "=s\\d+-", options: .regularExpression) else { return url }
        return URL(string: str.replacingCharacters(in: r, with: "=s240-"))
    }

    /// Upgrades `=w60-h60` style Google image URLs to a crisp size.
    static func upscale(_ url: URL?, to size: Int = 544) -> URL? {
        guard let url else { return nil }
        let s = url.absoluteString
        if let r = s.range(of: "=w\\d+-h\\d+", options: .regularExpression) {
            return URL(string: s.replacingCharacters(in: r, with: "=w\(size)-h\(size)"))
        }
        return url
    }
}
