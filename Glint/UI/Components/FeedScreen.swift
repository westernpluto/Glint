import SwiftUI

/// Fold position shared with grids, measured in the scroll container's coordinates.
private struct VerticalFoldKey: EnvironmentKey { static let defaultValue: CGRect? = nil }
private struct FeedWidthKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }

extension EnvironmentValues {
    var verticalFold: CGRect? {
        get { self[VerticalFoldKey.self] }
        set { self[VerticalFoldKey.self] = newValue }
    }
    var feedWidth: CGFloat {
        get { self[FeedWidthKey.self] }
        set { self[FeedWidthKey.self] = newValue }
    }
}

/// Adaptive grid of feed items: one column of large cards on a narrow display, two to four
/// on the inner display. When iPhone Duo is half open like a book, columns are placed on
/// each side of the fold so no card ever straddles it.
struct FeedGrid: View {
    var items: [FeedItem]
    @Environment(\.screenClass) private var screen
    @Environment(\.verticalFold) private var fold
    @Environment(\.feedWidth) private var width

    private enum Cell: Identifiable {
        case item(FeedItem)
        case gap(Int)
        var id: String {
            switch self {
            case .item(let i): return i.id
            case .gap(let n): return "fold-gap-\(n)"
            }
        }
    }

    var body: some View {
        let gutter = Metrics.gutter(screen)
        let rowSpacing: CGFloat = screen == .expanded ? 30 : 24
        if let fold, width > 0, let plan = FoldPlan(width: width, fold: fold, gutter: gutter, minimum: Metrics.gridMinimum(.expanded) - 40) {
            LazyVGrid(columns: plan.columns, alignment: .leading, spacing: rowSpacing) {
                ForEach(cells(perRow: plan.left + plan.right, leftCount: plan.left)) { cell in
                    switch cell {
                    case .item(let item): card(item)
                    case .gap: Color.clear.frame(height: 1)
                    }
                }
            }
            .padding(.leading, gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Metrics.gridMinimum(screen)), spacing: 20, alignment: .top)],
                      alignment: .leading, spacing: rowSpacing) {
                ForEach(items) { card($0) }
            }
            .padding(.horizontal, gutter)
        }
    }

    @ViewBuilder private func card(_ item: FeedItem) -> some View {
        switch item {
        case .video(let v): VideoCard(video: v)
        case .channel(let c): ChannelCard(channel: c)
        case .playlist(let p): PlaylistCard(playlist: p)
        }
    }

    /// Inserts an empty cell in the fold column of every row.
    private func cells(perRow: Int, leftCount: Int) -> [Cell] {
        var out: [Cell] = []
        var row = 0
        var i = 0
        while i < items.count {
            for k in 0..<perRow where i < items.count {
                if k == leftCount { out.append(.gap(row)) }
                out.append(.item(items[i]))
                i += 1
            }
            row += 1
        }
        return out
    }
}

/// Column layout around a vertical fold: N columns left, a spacer column over the fold, M right.
private struct FoldPlan {
    var columns: [GridItem]
    var left: Int
    var right: Int

    init?(width: CGFloat, fold: CGRect, gutter: CGFloat, minimum: CGFloat) {
        let spacing: CGFloat = 18
        let clearance: CGFloat = 14
        let leftWidth = fold.minX - clearance - gutter
        let rightWidth = width - gutter - fold.maxX - clearance
        guard leftWidth > minimum * 0.6, rightWidth > minimum * 0.6 else { return nil }
        func split(_ w: CGFloat) -> (Int, CGFloat) {
            let n = max(1, Int((w + spacing) / (minimum + spacing)))
            return (n, (w - spacing * CGFloat(n - 1)) / CGFloat(n))
        }
        let (l, lw) = split(leftWidth)
        let (r, rw) = split(rightWidth)
        var cols: [GridItem] = []
        for k in 0..<l { cols.append(GridItem(.fixed(lw), spacing: k == l - 1 ? clearance : spacing, alignment: .top)) }
        cols.append(GridItem(.fixed(fold.width), spacing: clearance))
        for k in 0..<r { cols.append(GridItem(.fixed(rw), spacing: k == r - 1 ? 0 : spacing, alignment: .top)) }
        columns = cols
        left = l
        right = r
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

    @State private var fold: CGRect?
    @State private var width: CGFloat = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header()
                if !loaded && error == nil && items.isEmpty {
                    SkeletonFeed().padding(.top, 8)
                }
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
                EmptyView()
            } else if let error, items.isEmpty {
                ErrorState(error: error) { Task { await reload() } }
            } else if loaded && items.isEmpty {
                EmptyState(title: emptyTitle, icon: emptyIcon)
            }
        }
        .environment(\.verticalFold, fold)
        .environment(\.feedWidth, width)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onGeometryChange(for: CGRect?.self) { Fold.vertical($0) } action: { fold = $0 }
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
