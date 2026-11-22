import SwiftUI
import Observation

/// One system TabView for every size: a tab bar on the outer display, a sidebar on the
/// inner display, and vertical bars where iPhone Duo uses them. Because the hierarchy
/// never changes when folding or unfolding, navigation state and playback carry over.
struct RootView: View {
    @Environment(PlayerController.self) private var player
    @Environment(AppRouter.self) private var router
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showSettings = false

    var body: some View {
        let section = Binding(get: { router.section }, set: { router.section = $0 })
        // Videos minimize to a floating picture; music / audio only to the bar.
        let floatingMini = player.presentation == .mini && player.current != nil
            && player.current?.isMusic != true && !player.audioOnly
        let musicBar = player.presentation == .mini && player.current != nil && !floatingMini
        GeometryReader { geo in
            ZStack {
                TabView(selection: section) {
                    Tab(AppSection.home.title, systemImage: AppSection.home.icon, value: AppSection.home) {
                        SectionStack(section: .home, showSettings: $showSettings)
                    }
                    Tab(AppSection.subscriptions.title, systemImage: AppSection.subscriptions.icon, value: AppSection.subscriptions) {
                        SectionStack(section: .subscriptions, showSettings: $showSettings)
                    }
                    Tab(AppSection.music.title, systemImage: AppSection.music.icon, value: AppSection.music) {
                        SectionStack(section: .music, showSettings: $showSettings)
                    }
                    Tab(AppSection.library.title, systemImage: AppSection.library.icon, value: AppSection.library) {
                        SectionStack(section: .library, showSettings: $showSettings)
                    }
                    Tab(value: AppSection.search, role: .search) {
                        SectionStack(section: .search, showSettings: $showSettings)
                    }
                }
                .tabViewStyle(.sidebarAdaptable)
                .tabBarMinimizeBehavior(.onScrollDown)

                if musicBar {
                    FloatingMusicBar()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .zIndex(1)
                }

                if floatingMini {
                    FloatingMiniPlayer()
                        .transition(.scale(scale: 0.6, anchor: .bottom).combined(with: .opacity))
                        .zIndex(1)
                }

                if player.presentation == .expanded, player.current != nil {
                    PlayerScreen()
                        .transition(.move(edge: .bottom))
                        .zIndex(2)
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.9), value: player.presentation)
            .environment(\.screenClass, ScreenClass(horizontalSizeClass))
            .environment(\.containerSize, geo.size)
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: Binding(get: { player.showsPlaybackInfo }, set: { player.showsPlaybackInfo = $0 })) {
            PlaybackInfoView()
        }
        #if DEBUG
        .task { await ScreenshotDriver.run(section: section) }
        #endif
    }
}

/// App-wide navigation state that any screen can drive (e.g. Music → Search scoped to Music).
@MainActor
@Observable
final class AppRouter {
    static let shared = AppRouter()
    var section: AppSection = .home
    /// Room the bars take around the current tab's content (nav bar, tab bar — at the bottom,
    /// or the vertical bar on the side), measured from inside it; keeps floating views clear.
    var contentInsets = EdgeInsets()
    var searchScope: SearchScope {
        didSet { UserDefaults.standard.set(searchScope.rawValue, forKey: "searchScope") }
    }

    private init() {
        searchScope = SearchScope(rawValue: UserDefaults.standard.string(forKey: "searchScope") ?? "") ?? .youtube
    }
}

/// A tab's navigation stack with its toolbar.
private struct SectionStack: View {
    var section: AppSection
    @Binding var showSettings: Bool
    @Environment(PlayerController.self) private var player

    var body: some View {
        // Videos float in a corner; music / audio only gets the bar, which content scrolls clear of.
        let musicBar = player.presentation == .mini && player.current != nil
            && (player.current?.isMusic == true || player.audioOnly)
        NavigationStack {
            content
                .withRoutes()
                .toolbar { AccountToolbarItem(showSettings: $showSettings) }
        }
        // On the stack (so pushed pages get it too); measured below without it.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if musicBar { Color.clear.frame(height: FloatingMusicBar.height + 12).allowsHitTesting(false) }
        }
        .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { insets in
            if AppRouter.shared.section == section { AppRouter.shared.contentInsets = insets }
        }
    }

    @ViewBuilder private var content: some View {
        switch section {
        case .home: HomeView()
        case .subscriptions: SubscriptionsView()
        case .music: MusicHomeView()
        case .library: LibraryView()
        case .search: SearchView()
        }
    }
}

/// The profile button: one tap opens Account & Settings (the familiar top-right pattern).
/// Icon *and* title so iPhone Duo can place it in a vertical bar or the overflow menu.
struct AccountToolbarItem: ToolbarContent {
    @Binding var showSettings: Bool
    @Environment(AccountStore.self) private var accounts

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                showSettings = true
            } label: {
                Label(accounts.isSignedIn ? "Account & Settings" : "Sign in & Settings",
                      systemImage: accounts.isSignedIn ? "person.crop.circle.fill" : "person.crop.circle")
            }
        }
        .visibilityPriority(.high)
    }
}

#if DEBUG
/// Drives the app into specific states for automated simulator screenshots.
/// Launch with `-GlintScene <home|subscriptions|music|library|search|watch|nowplaying>`
/// and optionally `-GlintVideo <id>` / `-GlintQuery <text>`.
@MainActor
enum ScreenshotDriver {
    static func run(section: Binding<AppSection>) async {
        let d = UserDefaults.standard
        guard let scene = d.string(forKey: "GlintScene") else { return }
        try? await Task.sleep(nanoseconds: 600_000_000)
        if d.string(forKey: "GlintOrientation") == "landscape" {
            Orientation.request(.landscapeRight)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        switch scene {
        case "subscriptions": section.wrappedValue = .subscriptions
        case "music": section.wrappedValue = .music
        case "library": section.wrappedValue = .library
        case "search":
            section.wrappedValue = .search
        case "watch":
            let id = d.string(forKey: "GlintVideo") ?? "aqz-KE-bpKQ"
            PlayerController.shared.play(VideoItem(id: id, title: "Big Buck Bunny 60fps 4K - Official Blender Foundation Short Film",
                                                   channelName: "Blender"))
        case "watchtest":
            // A real picture on the watch page (YouTube can't play on the build machines).
            let url = URL(string: d.string(forKey: "GlintStream")
                          ?? "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8")!
            PlayerController.shared.debugPlayStream(url, title: "Apple HLS sample stream (16:9)")
        case "lyrics":
            // Now Playing with the sing-along lyrics open ("Shape of You" has timed lyrics).
            let id = d.string(forKey: "GlintVideo") ?? "JGwWNGJdvx8"
            PlayerController.shared.playMusic(MusicItem(kind: .song, title: "Shape of You", subtitle: "Ed Sheeran", videoId: id))
            PlayerController.shared.presentation = .expanded
        case "nowplaying":
            let id = d.string(forKey: "GlintVideo") ?? "FGBhQbmPwH8"
            PlayerController.shared.playMusic(MusicItem(kind: .song, title: "One More Time", subtitle: "Daft Punk", videoId: id))
            PlayerController.shared.presentation = .expanded
        case "musicbar":
            section.wrappedValue = .music
            let id = d.string(forKey: "GlintVideo") ?? "FGBhQbmPwH8"
            PlayerController.shared.playMusic(MusicItem(kind: .song, title: "One More Time", subtitle: "Daft Punk", videoId: id))
            PlayerController.shared.presentation = .mini
        case "mini":
            let id = d.string(forKey: "GlintVideo") ?? "aqz-KE-bpKQ"
            PlayerController.shared.play(VideoItem(id: id, title: "Big Buck Bunny 60fps 4K", channelName: "Blender"))
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            PlayerController.shared.presentation = .mini
        default: section.wrappedValue = .home
        }
    }
}
#endif
