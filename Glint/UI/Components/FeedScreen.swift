import SwiftUI

/// Adaptive grid of feed items: one column of large cards on the cover screen,
/// a multi-column grid on the inner screen.
struct FeedGrid: View {
    var items: [FeedItem]
    @Environment(\.screenClass) private var screen

    var body: some View {
        // Adaptive everywhere: 1 column on the cover screen in portrait, 2 in landscape,
        // 2–4 on the inner screen depending on orientation.
        let columns = [GridItem(.adaptive(minimum: Metrics.gridMinimum(screen)), spacing: 20, alignment: .top)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: screen == .expanded ? 28 : 22) {
            ForEach(items) { item in
                switch item {
                case .video(let v): VideoCard(video: v)
                case .channel(let c): ChannelCard(channel: c)
                case .playlist(let p): PlaylistCard(playlist: p)
                }
            }
        }
        .padding(.horizontal, Metrics.gutter(screen))
    }
}

/// Loads a paginated feed with pull-to-refresh, infinite scroll and empty/error states.
struct FeedScreen<Header: View>: View {
    var reloadKey: AnyHashable = 0
    var endpoint: ContinuationEndpoint = .browse
    var emptyTitle = "Nothing here yet"
    var emptyIcon = "sparkles.tv"
    var load: () async throws -> FeedPage
    @ViewBuilder var header: () -> Header

    @State private var items: [FeedItem] = []
    @State private var continuation: String?
    @State private var error: Error?
    @State private var loading = false
    @State private var loadingMore = false
    @State private var loaded = false
    @State private var loadedKey: AnyHashable?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header()
                FeedGrid(items: items)
                    .padding(.top, 8)
                if let token = continuation {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(28)
                        // Keyed by token: fires again for each new page, even if the spinner never left the screen.
                        .task(id: token) { await loadMore() }
                }
            }
            .padding(.bottom, 24)
        }
        .overlay {
            if !loaded && loading {
                ProgressView().controlSize(.large)
            } else if let error, items.isEmpty {
                ErrorState(error: error) { Task { await reload() } }
            } else if loaded && items.isEmpty {
                EmptyState(title: emptyTitle, icon: emptyIcon)
            }
        }
        .refreshable { await reload() }
        .task(id: reloadKey) {
            // Returning to a screen (back navigation, tab switch) keeps what is already loaded.
            if loadedKey == reloadKey, !items.isEmpty { return }
            if loadedKey != reloadKey { items = []; continuation = nil; error = nil; loaded = false }
            await reload()
        }
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        do {
            let page = try await load()
            items = page.items
            continuation = page.continuation
            error = nil
            loadedKey = reloadKey
            loaded = true
        } catch is CancellationError {
        } catch {
            if (error as? URLError)?.code == .cancelled { return }
            self.error = error
            items = []
            continuation = nil
            loaded = true
        }
    }

    private func loadMore() async {
        guard let token = continuation, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        guard let page = try? await YouTubeService.shared.more(token, endpoint: endpoint) else {
            continuation = nil
            return
        }
        let known = Set(items.map(\.id))
        items += page.items.filter { !known.contains($0.id) }
        continuation = page.continuation == token ? nil : page.continuation
    }
}

extension FeedScreen where Header == EmptyView {
    init(reloadKey: AnyHashable = 0, endpoint: ContinuationEndpoint = .browse,
         emptyTitle: String = "Nothing here yet", emptyIcon: String = "sparkles.tv",
         load: @escaping () async throws -> FeedPage) {
        self.init(reloadKey: reloadKey, endpoint: endpoint, emptyTitle: emptyTitle, emptyIcon: emptyIcon,
                  load: load, header: { EmptyView() })
    }
}

// MARK: States

struct EmptyState: View {
    var title: String
    var icon: String
    var message: String?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            if let message { Text(message) }
        }
    }
}

struct ErrorState: View {
    var error: Error
    var retry: () -> Void

    var body: some View {
        if (error as? InnerTubeError) == .notSignedIn {
            SignInPrompt()
        } else {
            ContentUnavailableView {
                Label("Couldn't load", systemImage: "wifi.exclamationmark")
            } description: {
                Text(error.localizedDescription)
            } actions: {
                Button("Try again", action: retry).buttonStyle(.bordered)
            }
        }
    }
}

struct SignInPrompt: View {
    var message = "Sign in to see your subscriptions, history, playlists and recommendations."
    @State private var showSignIn = false

    var body: some View {
        ContentUnavailableView {
            Label("Sign in to YouTube", systemImage: "person.crop.circle.badge.plus")
        } description: {
            Text(message)
        } actions: {
            Button("Sign in") { showSignIn = true }
                .buttonStyle(.borderedProminent)
        }
        .sheet(isPresented: $showSignIn) { SignInView() }
    }
}
