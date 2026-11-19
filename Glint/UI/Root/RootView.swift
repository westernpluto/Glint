import SwiftUI

struct RootView: View {
    @Environment(PlayerController.self) private var player
    @State private var section: AppSection = .home
    @State private var showSettings = false

    var body: some View {
        GeometryReader { geo in
            let screen = ScreenClass.from(geo.size)
            ZStack {
                Group {
                    if screen == .expanded {
                        ExpandedShell(section: $section, showSettings: $showSettings)
                    } else {
                        CompactShell(section: $section, showSettings: $showSettings)
                    }
                }

                if player.presentation == .expanded, player.current != nil {
                    PlayerScreen()
                        .transition(.move(edge: .bottom))
                        .zIndex(2)
                }
            }
            .animation(.spring(response: 0.38, dampingFraction: 0.9), value: player.presentation)
            .environment(\.screenClass, screen)
            .environment(\.containerSize, geo.size)
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }
}

// MARK: Cover screen — tab bar

private struct CompactShell: View {
    @Binding var section: AppSection
    @Binding var showSettings: Bool

    var body: some View {
        TabView(selection: $section) {
            Tab(AppSection.home.title, systemImage: AppSection.home.icon, value: AppSection.home) {
                stack { HomeView() }
            }
            Tab(AppSection.subscriptions.title, systemImage: AppSection.subscriptions.icon, value: AppSection.subscriptions) {
                stack { SubscriptionsView() }
            }
            Tab(AppSection.music.title, systemImage: AppSection.music.icon, value: AppSection.music) {
                stack { MusicHomeView() }
            }
            Tab(AppSection.library.title, systemImage: AppSection.library.icon, value: AppSection.library) {
                stack { LibraryView() }
            }
            Tab(value: AppSection.search, role: .search) {
                stack { SearchView() }
            }
        }
    }

    private func stack<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        NavigationStack {
            content()
                .withRoutes()
                .toolbar { ToolbarItem(placement: .topBarTrailing) { AccountButton(showSettings: $showSettings) } }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayerBar() }
    }
}

// MARK: Inner screen — sidebar + content

private struct ExpandedShell: View {
    @Binding var section: AppSection
    @Binding var showSettings: Bool
    @State private var visibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            List(selection: Binding(get: { Optional(section) }, set: { if let s = $0 { section = s } })) {
                Section {
                    ForEach(AppSection.allCases) { s in
                        Label(s.title, systemImage: s.icon).tag(s)
                    }
                }
            }
            .navigationTitle("Glint")
            .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 280)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { AccountButton(showSettings: $showSettings) } }
        } detail: {
            NavigationStack {
                Group {
                    switch section {
                    case .home: HomeView()
                    case .subscriptions: SubscriptionsView()
                    case .music: MusicHomeView()
                    case .library: LibraryView()
                    case .search: SearchView()
                    }
                }
                .withRoutes()
            }
            .id(section)
            .safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayerBar() }
        }
        .navigationSplitViewStyle(.balanced)
    }
}

// MARK: Account button

struct AccountButton: View {
    @Binding var showSettings: Bool
    @Environment(AccountStore.self) private var accounts

    var body: some View {
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
            Avatar(url: accounts.active?.info.avatar, size: 28, placeholder: "person.crop.circle")
        }
        .accessibilityLabel("Account and settings")
    }
}
