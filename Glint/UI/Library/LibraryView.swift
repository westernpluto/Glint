import SwiftUI

struct LibraryView: View {
    @Environment(AccountStore.self) private var accounts
    @Environment(\.screenClass) private var screen
    @State private var playlists: [PlaylistItem] = []
    @State private var loadedGeneration: Int?
    @State private var confirmClear = false
    @State private var showSettings = false
    private var history: WatchHistory { WatchHistory.shared }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                // On this iPhone — works without an account.
                if !history.continueWatching.isEmpty {
                    ShelfRow(section: FeedSection(title: "Continue watching", items: history.continueWatching))
                }
                if !history.recent.isEmpty {
                    ShelfRow(section: FeedSection(title: "Recently watched", items: history.recent))
                }

                if accounts.isSignedIn {
                    sectionTitle("Your YouTube")
                    shortcuts
                    if !playlists.isEmpty {
                        sectionTitle("Playlists")
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: screen == .expanded ? 240 : 160), spacing: 16, alignment: .top)],
                                  spacing: 20) {
                            ForEach(playlists) { PlaylistCard(playlist: $0) }
                        }
                        .padding(.horizontal, Metrics.gutter(screen))
                    }
                } else {
                    signInCard
                }

                accountAndSettings

                if history.recent.isEmpty {
                    Label("Videos you watch show up here, so you can pick up where you left off.",
                          systemImage: "clock.arrow.circlepath")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Metrics.gutter(screen))
                }
            }
            .padding(.vertical, 12)
        }
        .navigationTitle("Library")
        .toolbar {
            if !history.recent.isEmpty {
                ToolbarItem(placement: .secondaryAction) {
                    Button("Clear watch history", systemImage: "trash", role: .destructive) { confirmClear = true }
                }
            }
        }
        .confirmationDialog("Clear what you've watched on this iPhone?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear watch history", role: .destructive) { history.clear() }
        } message: {
            Text("Removes Continue watching and Recently watched. Your YouTube account history isn't affected.")
        }
        .task(id: accounts.generation) {
            guard accounts.isSignedIn, loadedGeneration != accounts.generation else { return }
            playlists = (try? await YouTubeService.shared.libraryPlaylists()) ?? []
            loadedGeneration = accounts.generation
        }
        .refreshable {
            if accounts.isSignedIn {
                playlists = (try? await YouTubeService.shared.libraryPlaylists()) ?? playlists
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.title3.weight(.bold)).padding(.horizontal, Metrics.gutter(screen))
    }

    /// Who you are and where settings live — visible, not hidden in a menu.
    private var accountAndSettings: some View {
        VStack(spacing: 0) {
            if let a = accounts.active {
                HStack(spacing: 12) {
                    Avatar(url: a.info.avatar, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.info.name).font(.subheadline.weight(.semibold))
                        if let h = a.info.handle { Text(h).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if accounts.accounts.count > 1 {
                        Menu {
                            ForEach(accounts.accounts) { other in
                                Button(other.info.name) { accounts.switchTo(other.id) }
                            }
                        } label: {
                            Text("Switch").font(.subheadline.weight(.semibold))
                        }
                    }
                }
                .padding(14)
                Divider().padding(.leading, 14)
            }
            Button { showSettings = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "gearshape").font(.headline).foregroundStyle(.tint).frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Settings").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        Text("Accounts, quality, SponsorBlock, playback")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(Color.cardFill, in: RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
        .padding(.horizontal, Metrics.gutter(screen))
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    private var signInCard: some View {
        SignInCard()
            .padding(.horizontal, Metrics.gutter(screen))
    }

    private var shortcuts: some View {
        let items: [(String, String, Route)] = [
            ("History", "clock.arrow.circlepath", .history),
            ("Watch later", "clock", .watchLater),
            ("Liked videos", "hand.thumbsup", .liked),
            ("Liked songs", "heart", .musicLiked),
            ("Music playlists", "music.note.list", .musicPlaylists),
        ]
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: screen == .expanded ? 220 : 150), spacing: 12)], spacing: 12) {
            ForEach(items, id: \.0) { item in
                NavigationLink(value: item.2) {
                    HStack(spacing: 12) {
                        Image(systemName: item.1)
                            .font(.headline)
                            .foregroundStyle(.tint)
                            .frame(width: 26)
                        Text(item.0).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(14)
                    .background(Color.cardFill, in: RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Metrics.gutter(screen))
    }
}

/// Explains what signing in adds, with one clear action.
struct SignInCard: View {
    @State private var showSignIn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Sign in to YouTube", systemImage: "person.crop.circle.badge.plus")
                .font(.headline)
            Text("See your subscriptions, history, Watch later, liked videos and playlists — and add more than one account.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Sign in") { showSignIn = true }
                .buttonStyle(.glassProminent)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .sheet(isPresented: $showSignIn) { SignInView() }
    }
}
