import SwiftUI

/// Which physical display the app is drawing on.
/// - `.compact`: the front/cover screen (phone-sized), or any narrow window.
/// - `.expanded`: the large inner screen when unfolded (tablet-like, near square).
enum ScreenClass: Hashable {
    case compact, expanded

    static func from(_ size: CGSize) -> ScreenClass {
        // The inner display is wide *and* tall. A phone-sized cover screen in landscape
        // is wide but short, so it stays compact (and gets the immersive landscape player).
        size.width >= 600 && size.height >= 500 ? .expanded : .compact
    }
}

private struct ScreenClassKey: EnvironmentKey { static let defaultValue: ScreenClass = .compact }
private struct ContainerSizeKey: EnvironmentKey { static let defaultValue: CGSize = .zero }

extension EnvironmentValues {
    var screenClass: ScreenClass {
        get { self[ScreenClassKey.self] }
        set { self[ScreenClassKey.self] = newValue }
    }
    var containerSize: CGSize {
        get { self[ContainerSizeKey.self] }
        set { self[ContainerSizeKey.self] = newValue }
    }
}

enum Metrics {
    static let corner: CGFloat = 14
    static func gutter(_ c: ScreenClass) -> CGFloat { c == .expanded ? 24 : 16 }
    static func gridMinimum(_ c: ScreenClass) -> CGFloat { c == .expanded ? 290 : 320 }
}

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case home, subscriptions, music, library, search

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .subscriptions: return "Subscriptions"
        case .music: return "Music"
        case .library: return "Library"
        case .search: return "Search"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house"
        case .subscriptions: return "play.square.stack"
        case .music: return "music.note"
        case .library: return "books.vertical"
        case .search: return "magnifyingglass"
        }
    }
}

enum Route: Hashable {
    case channel(id: String, name: String?)
    case playlist(id: String, title: String?)
    case music(browseId: String, title: String?)
    case history
    case watchLater
    case liked
    case musicLiked
    case musicPlaylists
}

extension View {
    func withRoutes() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .channel(let id, let name): ChannelView(channelId: id, name: name)
            case .playlist(let id, let title): PlaylistView(playlistId: id, title: title)
            case .music(let id, let title): MusicBrowseView(browseId: id, title: title)
            case .history: HistoryView()
            case .watchLater: PlaylistView(playlistId: "WL", title: "Watch later")
            case .liked: PlaylistView(playlistId: "LL", title: "Liked videos")
            case .musicLiked: MusicBrowseView(browseId: "FEmusic_liked_videos", title: "Liked songs")
            case .musicPlaylists: MusicBrowseView(browseId: "FEmusic_liked_playlists", title: "Your playlists")
            }
        }
    }
}
