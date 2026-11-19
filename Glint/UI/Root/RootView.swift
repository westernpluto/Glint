import SwiftUI

/// One system TabView for every size: a tab bar on the outer display, a sidebar on the
/// inner display, and vertical bars where iPhone Duo uses them. Because the hierarchy
/// never changes when folding or unfolding, navigation state and playback carry over.
struct RootView: View {
    @Environment(PlayerController.self) private var player
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var section: AppSection = .home
    @State private var showSettings = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                TabView(selection: $section) {
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
                .tabViewBottomAccessory(isEnabled: player.presentation == .mini && player.current != nil) {
                    MiniPlayerAccessory()
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
        #if DEBUG
        .task { await ScreenshotDriver.run(section: $section) }
        #endif
    }
}

/// A tab's navigation stack with its toolbar.
private struct SectionStack: View {
    var section: AppSection
    @Binding var showSettings: Bool

    var body: some View {
        NavigationStack {
            content
                .withRoutes()
                .toolbar { AccountToolbarItem(showSettings: $showSettings) }
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

/// Account switcher + settings. Uses an icon *and* a title so the system can place it in
/// a vertical bar, a horizontal bar or the overflow menu on iPhone Duo.
struct AccountToolbarItem: ToolbarContent {
    @Binding var showSettings: Bool
    @Environment(AccountStore.self) private var accounts

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                if !accounts.accounts.isEmpty {
                    Section("Accounts") {
                        ForEach(accounts.accounts) { a in
                            Button {
                                accounts.switchTo(a.id)
                            } label: {
                                if a.id == accounts.activeID {
                                    Label(a.info.name, systemImage: "checkmark")
                                } else {
                                    Text(a.info.name)
                                }
                            }
                        }
                        if accounts.isSignedIn {
                            Button("Browse signed out") { accounts.switchTo(nil) }
                        }
                    }
                }
                Button { showSettings = true } label: { Label("Settings & accounts", systemImage: "gearshape") }
            } label: {
                Label(accounts.active?.info.name ?? "Account",
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
        switch scene {
        case "subscriptions": section.wrappedValue = .subscriptions
        case "music": section.wrappedValue = .music
        case "library": section.wrappedValue = .library
        case "search":
            section.wrappedValue = .search
        case "watch":
            let id = d.string(forKey: "GlintVideo") ?? "aqz-KE-bpKQ"
            PlayerController.shared.play(VideoItem(id: id, title: ""))
        case "nowplaying":
            let id = d.string(forKey: "GlintVideo") ?? "FGBhQbmPwH8"
            PlayerController.shared.playMusic(MusicItem(kind: .song, title: "", videoId: id))
            PlayerController.shared.presentation = .expanded
        case "mini":
            let id = d.string(forKey: "GlintVideo") ?? "aqz-KE-bpKQ"
            PlayerController.shared.play(VideoItem(id: id, title: ""))
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            PlayerController.shared.presentation = .mini
        default: section.wrappedValue = .home
        }
    }
}
#endif
