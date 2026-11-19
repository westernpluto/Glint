import SwiftUI

/// How much room the app has. Derived from size classes (never from device idiom,
/// orientation or screen size), as Apple recommends for iPhone Duo.
/// - `.compact`: compact width — the outer display, or a narrow window.
/// - `.expanded`: regular width — the inner display when unfolded.
enum ScreenClass: Hashable {
    case compact, expanded

    init(_ horizontal: UserInterfaceSizeClass?) {
        self = horizontal == .regular ? .expanded : .compact
    }
}

private struct ScreenClassKey: EnvironmentKey { static let defaultValue: ScreenClass = .compact }
private struct ContainerSizeKey: EnvironmentKey { static let defaultValue: CGSize = .zero }

extension EnvironmentValues {
    var screenClass: ScreenClass {
        get { self[ScreenClassKey.self] }
        set { self[ScreenClassKey.self] = newValue }
    }
    /// Size of the app's root container (not the screen).
    var containerSize: CGSize {
        get { self[ContainerSizeKey.self] }
        set { self[ContainerSizeKey.self] = newValue }
    }
}

/// The iPhone Duo fold, read from the view's reserved regions.
enum Fold {
    /// An active fold running top-to-bottom (book posture), in the proxy's coordinates.
    static func vertical(_ proxy: GeometryProxy) -> CGRect? {
        divisions(proxy).first { $0.height > $0.width }
    }

    /// An active fold running side-to-side (laptop / tabletop posture).
    static func horizontal(_ proxy: GeometryProxy) -> CGRect? {
        divisions(proxy).first { $0.width >= $0.height }
    }

    private static func divisions(_ proxy: GeometryProxy) -> [CGRect] {
        if #available(iOS 27.1, *) {
            return proxy.reservedRegions(kind: .division, layoutDirectionBehavior: .fixed).map(\.frame)
        }
        return []
    }
}

enum Metrics {
    static let corner: CGFloat = 16
    static func gutter(_ c: ScreenClass) -> CGFloat { c == .expanded ? 24 : 16 }
    static func gridMinimum(_ c: ScreenClass) -> CGFloat { c == .expanded ? 300 : 320 }
    static let readable: CGFloat = 720
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
