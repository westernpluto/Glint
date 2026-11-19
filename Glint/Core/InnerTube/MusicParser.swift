import Foundation

/// Parses YouTube Music (WEB_REMIX) responses.
enum MusicParser {

    static func page(_ root: JSON) -> MusicPage {
        var shelves: [MusicShelf] = []

        root.walk { key, value in
            if Parser.adRenderers.contains(key) { return false }
            switch key {
            case "musicCarouselShelfRenderer":
                let title = value.at("header.musicCarouselShelfBasicHeaderRenderer.title").text
                    ?? value["header"].first("title")?.text ?? ""
                let items = value["contents"].array.compactMap(item)
                if !items.isEmpty {
                    let listy = value["contents"][0]["musicResponsiveListItemRenderer"].isNull == false
                    shelves.append(MusicShelf(title: title, items: items, prefersList: listy))
                }
                return false
            case "musicShelfRenderer", "musicPlaylistShelfRenderer":
                let title = value["title"].text ?? value.at("header.musicShelfHeaderRenderer.title").text ?? ""
                let items = value["contents"].array.compactMap(item)
                if !items.isEmpty { shelves.append(MusicShelf(title: title, items: items, prefersList: true)) }
                return false
            case "musicCardShelfRenderer":
                // The "Top result" card in search.
                if let top = cardItem(value) {
                    shelves.append(MusicShelf(title: "Top result", items: [top], prefersList: true))
                }
                return true
            case "itemSectionRenderer":
                let items = value["contents"].array.compactMap(item)
                if !items.isEmpty {
                    shelves.append(MusicShelf(title: value["header"].first("title")?.text ?? "", items: items, prefersList: true))
                    return false
                }
                return true
            case "gridRenderer":
                let items = value["items"].array.compactMap(item)
                if !items.isEmpty {
                    let title = value["header"].first("title")?.text ?? ""
                    shelves.append(MusicShelf(title: title, items: items, prefersList: false))
                }
                return false
            default:
                return true
            }
        }

        // Merge runs of untitled list shelves (search returns one section per result).
        var merged: [MusicShelf] = []
        for shelf in shelves {
            if shelf.title.isEmpty, shelf.prefersList, let last = merged.last, last.prefersList,
               last.title.isEmpty || last.title == "Results" {
                merged[merged.count - 1].items += shelf.items
                merged[merged.count - 1].title = "Results"
            } else {
                merged.append(shelf)
            }
        }
        shelves = merged

        // Header (album / playlist / artist pages)
        let header = root.first("musicResponsiveHeaderRenderer")
            ?? root.first("musicImmersiveHeaderRenderer")
            ?? root.first("musicDetailHeaderRenderer")
            ?? root.first("musicVisualHeaderRenderer")
        let title = header?["title"].text
        let subtitle = [header?["subtitle"].text, header?["secondSubtitle"].text, header?["straplineTextOne"].text]
            .compactMap { $0 }.joined(separator: " · ")
        let thumb = header.flatMap { h in
            Parser.thumbnail(h.first("musicThumbnailRenderer")?["thumbnail"] ?? h["thumbnail"].first("thumbnail") ?? .null)
        }
        let playlistId = root.first("watchPlaylistEndpoint")?["playlistId"].string
            ?? header?.first("watchEndpoint")?["playlistId"].string

        return MusicPage(title: title, subtitle: subtitle.isEmpty ? nil : subtitle,
                         thumbnail: Parser.upscale(thumb, to: 720),
                         shelves: shelves, playlistId: playlistId)
    }

    static func item(_ j: JSON) -> MusicItem? {
        if !j["musicResponsiveListItemRenderer"].isNull { return listItem(j["musicResponsiveListItemRenderer"]) }
        if !j["musicTwoRowItemRenderer"].isNull { return twoRow(j["musicTwoRowItemRenderer"]) }
        return nil
    }

    static func kind(pageType: String?) -> MusicKind {
        switch pageType {
        case "MUSIC_PAGE_TYPE_ALBUM", "MUSIC_PAGE_TYPE_AUDIOBOOK": return .album
        case "MUSIC_PAGE_TYPE_PLAYLIST": return .playlist
        case "MUSIC_PAGE_TYPE_ARTIST", "MUSIC_PAGE_TYPE_USER_CHANNEL", "MUSIC_PAGE_TYPE_LIBRARY_ARTIST": return .artist
        default: return .other
        }
    }

    static func twoRow(_ r: JSON) -> MusicItem? {
        let title = r["title"].text ?? ""
        let thumb = Parser.upscale(Parser.thumbnail(r.at("thumbnailRenderer.musicThumbnailRenderer.thumbnail")))
        let nav = r["navigationEndpoint"]
        let w = nav["watchEndpoint"]
        if let vid = w["videoId"].string {
            return MusicItem(kind: .video, title: title, subtitle: r["subtitle"].text, thumbnail: thumb,
                             videoId: vid, playlistId: w["playlistId"].string)
        }
        if let bid = nav.at("browseEndpoint.browseId").string {
            let pt = nav.at("browseEndpoint.browseEndpointContextSupportedConfigs.browseEndpointContextMusicConfig.pageType").string
            return MusicItem(kind: kind(pageType: pt), title: title, subtitle: r["subtitle"].text,
                             thumbnail: thumb, browseId: bid)
        }
        if let pl = nav.at("watchPlaylistEndpoint.playlistId").string {
            return MusicItem(kind: .playlist, title: title, subtitle: r["subtitle"].text, thumbnail: thumb, playlistId: pl)
        }
        return nil
    }

    static func listItem(_ r: JSON) -> MusicItem? {
        let cols = r["flexColumns"].array.map { $0.at("musicResponsiveListItemFlexColumnRenderer.text") }
        let fixed = r["fixedColumns"].array.map { $0.at("musicResponsiveListItemFixedColumnRenderer.text") }
        guard let title = cols.first?.text else { return nil }
        let subtitle = cols.dropFirst().compactMap { $0.text }.filter { !$0.isEmpty }.joined(separator: " · ")
        let thumb = Parser.upscale(Parser.thumbnail(r.at("thumbnail.musicThumbnailRenderer.thumbnail")), to: 226)

        let videoId = r.at("playlistItemData.videoId").string
            ?? r["overlay"].first("watchEndpoint")?["videoId"].string
            ?? cols.first?["runs"][0].at("navigationEndpoint.watchEndpoint.videoId").string
        let playlistId = r["overlay"].first("watchEndpoint")?["playlistId"].string

        if let videoId {
            let mvType = r["overlay"].first("musicVideoType")?.string
                ?? cols.first?["runs"][0].first("musicVideoType")?.string
            let k: MusicKind = (mvType == "MUSIC_VIDEO_TYPE_ATV" || mvType == nil) ? .song : .video
            return MusicItem(kind: k, title: title, subtitle: subtitle.isEmpty ? nil : subtitle, thumbnail: thumb,
                             videoId: videoId, playlistId: playlistId, duration: fixed.first?.text)
        }
        let nav = r["navigationEndpoint"]
        if let bid = nav.at("browseEndpoint.browseId").string {
            let pt = nav.at("browseEndpoint.browseEndpointContextSupportedConfigs.browseEndpointContextMusicConfig.pageType").string
            return MusicItem(kind: kind(pageType: pt), title: title, subtitle: subtitle, thumbnail: thumb, browseId: bid)
        }
        return nil
    }

    static func cardItem(_ r: JSON) -> MusicItem? {
        let title = r["title"].text ?? ""
        let thumb = Parser.upscale(Parser.thumbnail(r.at("thumbnail.musicThumbnailRenderer.thumbnail")))
        let titleRun = r["title"]["runs"][0]
        if let vid = titleRun.at("navigationEndpoint.watchEndpoint.videoId").string {
            return MusicItem(kind: .song, title: title, subtitle: r["subtitle"].text, thumbnail: thumb, videoId: vid)
        }
        if let bid = titleRun.at("navigationEndpoint.browseEndpoint.browseId").string {
            let pt = titleRun.at("navigationEndpoint.browseEndpoint.browseEndpointContextSupportedConfigs.browseEndpointContextMusicConfig.pageType").string
            return MusicItem(kind: kind(pageType: pt), title: title, subtitle: r["subtitle"].text, thumbnail: thumb, browseId: bid)
        }
        return nil
    }

    /// Up-next queue from the `next` endpoint (radio / album / playlist).
    static func queue(_ root: JSON) -> [MusicItem] {
        root.findAll("playlistPanelVideoRenderer").compactMap { r in
            guard let vid = r["videoId"].string else { return nil }
            return MusicItem(kind: .song,
                             title: r["title"].text ?? "",
                             subtitle: r["shortBylineText"].text ?? r["longBylineText"].text,
                             thumbnail: Parser.upscale(Parser.thumbnail(r["thumbnail"])),
                             videoId: vid,
                             playlistId: r.at("navigationEndpoint.watchEndpoint.playlistId").string,
                             duration: r["lengthText"].text)
        }
    }
}
