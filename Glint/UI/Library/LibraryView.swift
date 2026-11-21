import SwiftUI

struct LibraryView: View {
    @Environment(AccountStore.self) private var accounts
    @Environment(\.screenClass) private var screen
    @State private var playlists: [PlaylistItem] = []
    @State private var loadedGeneration: Int?
    @State private var confirmClear = false
    /// Signed in: the account's YouTube watch history.
    @State private var youtubeHistory: [VideoItem] = []
    private var history: WatchHistory { WatchHistory.shared }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if accounts.isSignedIn {
                    // From the YouTube account (same history and progress as everywhere else).
                    let partly = youtubeHistory.filter { ($0.watchedPercent ?? 0) > 0 && ($0.watchedPercent ?? 0) < 97 }
                    if !partly.isEmpty {
                        ShelfRow(section: FeedSection(title: "Continue watching", items: partly))
                    }
                    if !youtubeHistory.isEmpty {
                        ShelfRow(section: FeedSection(title: "History", items: youtubeHistory))
                    }
                } else {
                    // On this iPhone — works without an account.
                    if !history.continueWatching.isEmpty {
                        ShelfRow(section: FeedSection(title: "Continue watching", items: history.continueWatching))
                    }
                    if !history.recent.isEmpty {
                        ShelfRow(section: FeedSection(title: "Recently watched", items: history.recent))
                    }
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

                if !accounts.isSignedIn, history.recent.isEmpty {
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
            if !accounts.isSignedIn, !history.recent.isEmpty {
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
            guard accounts.isSignedIn, loadedGeneration != accounts.generation else {
                if !accounts.isSignedIn { youtubeHistory = [] }
                return
            }
            youtubeHistory = []
            async let lists = YouTubeService.shared.libraryPlaylists()
            youtubeHistory = Self.videos(try? await YouTubeService.shared.history())
            playlists = (try? await lists) ?? []
            loadedGeneration = accounts.generation
        }
        .refreshable {
            if accounts.isSignedIn {
                async let lists = YouTubeService.shared.libraryPlaylists()
                if let page = try? await YouTubeService.shared.history() { youtubeHistory = Self.videos(page) }
                playlists = (try? await lists) ?? playlists
            }
        }
    }

    private static func videos(_ page: FeedPage?) -> [VideoItem] {
        (page?.items ?? []).compactMap { if case .video(let v) = $0, !v.isShort { return v }; return nil }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.title3.weight(.bold)).padding(.horizontal, Metrics.gutter(screen))
    }

    private var signInCard: some View {
        SignInCard()
            .padding(.horizontal, Metrics.gutter(screen))
    }

    /// A plain list, like Settings: no boxes competing with the shelves above.
    private var shortcuts: some View {
        let items: [(String, String, Route)] = [
            ("Watch later", "clock", .watchLater),
            ("Liked videos", "hand.thumbsup", .liked),
            ("Liked songs", "heart", .musicLiked),
            ("Music playlists", "music.note.list", .musicPlaylists),
            ("Full history", "clock.arrow.circlepath", .history),
        ]
        return VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                NavigationLink(value: item.2) {
                    HStack(spacing: 14) {
                        Image(systemName: item.1).foregroundStyle(.tint).frame(width: 24)
                        Text(item.0).foregroundStyle(.primary)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .font(.body)
                    .padding(.vertical, 13)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if i < items.count - 1 { Divider().padding(.leading, 38) }
            }
        }
        .padding(.horizontal, Metrics.gutter(screen))
        .frame(maxWidth: 640, alignment: .leading)
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
