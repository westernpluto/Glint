import SwiftUI

enum SearchScope: String, CaseIterable, Identifiable {
    case youtube, music
    var id: String { rawValue }
    var title: String { self == .youtube ? "YouTube" : "Music" }
    var prompt: String { self == .youtube ? "Search videos, channels, playlists" : "Search songs, albums, artists" }
}

/// One search for everything, with a clear YouTube / Music switch.
/// Uses its own search field (not the system-placed one) so it works the same on both
/// displays, including when iPhone Duo shows its bars vertically.
struct SearchView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.screenClass) private var screen
    @State private var text = ""
    @State private var submitted = ""
    @State private var filter: SearchFilter = .all
    @State private var suggestions: [String] = []
    @FocusState private var focused: Bool
    @AppStorage("recentSearches") private var recentRaw = ""

    private var recents: [String] { recentRaw.split(separator: "\n").map(String.init) }
    private var scope: SearchScope { router.searchScope }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                searchField
                scopePicker
            }
            .padding(.horizontal, Metrics.gutter(screen))
            .padding(.top, 4)
            .padding(.bottom, 8)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: text) {
            guard focused, !text.isEmpty, text != submitted else { suggestions = []; return }
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            suggestions = await YouTubeService.shared.suggestions(text)
        }
        .onAppear { if submitted.isEmpty { focused = true } }
        #if DEBUG
        .task {
            if submitted.isEmpty, let q = UserDefaults.standard.string(forKey: "GlintQuery"),
               UserDefaults.standard.string(forKey: "GlintScene") == "search" {
                text = q
                submit(q)
            }
        }
        #endif
    }

    // MARK: Field

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(scope.prompt, text: $text)
                .focused($focused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit { submit(text) }
            if !text.isEmpty {
                Button {
                    text = ""
                    submitted = ""
                    focused = true
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .font(.body)
        .padding(.horizontal, 14)
        .frame(height: 46)
        .glassEffect(.regular.interactive(), in: .capsule)
        .onTapGesture { focused = true }
    }

    private var scopePicker: some View {
        Picker("Search in", selection: Binding(get: { router.searchScope }, set: { router.searchScope = $0 })) {
            ForEach(SearchScope.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if focused, !text.isEmpty, text != submitted, !suggestions.isEmpty {
            List(suggestions, id: \.self) { s in
                Button { text = s; submit(s) } label: {
                    Label(s, systemImage: "magnifyingglass").foregroundStyle(.primary)
                }
            }
            .listStyle(.plain)
        } else if submitted.isEmpty {
            recentList
        } else if scope == .youtube {
            FeedScreen(reloadKey: "\(submitted)|\(filter.rawValue)", endpoint: .search,
                       emptyTitle: "No results", emptyIcon: "magnifyingglass") {
                try await YouTubeService.shared.search(submitted, filter: filter)
            } header: {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(SearchFilter.allCases) { f in
                            GlassChip(title: f.title, selected: f == filter) { filter = f }
                        }
                    }
                    .padding(.horizontal, Metrics.gutter(screen))
                }
                .keepsToOwnFrame()
                .padding(.vertical, 6)
            }
            .scrollDismissesKeyboard(.immediately)
        } else {
            MusicSearchResults(query: submitted) { EmptyView() }
                .scrollDismissesKeyboard(.immediately)
        }
    }

    private var recentList: some View {
        List {
            if recents.isEmpty {
                EmptyState(title: scope == .youtube ? "Search YouTube" : "Search Music",
                           icon: scope == .youtube ? "magnifyingglass" : "music.note",
                           message: scope == .youtube
                               ? "Videos, channels and playlists — no ads, ever."
                               : "Songs, albums and artists from YouTube Music.")
                    .listRowSeparator(.hidden)
            } else {
                Section {
                    ForEach(recents, id: \.self) { r in
                        Button { text = r; submit(r) } label: {
                            Label(r, systemImage: "clock.arrow.circlepath").foregroundStyle(.primary)
                        }
                    }
                    .onDelete { idx in
                        var list = recents
                        list.remove(atOffsets: idx)
                        recentRaw = list.joined(separator: "\n")
                    }
                } header: {
                    HStack {
                        Text("Recent")
                        Spacer()
                        Button("Clear") { recentRaw = "" }.font(.caption)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.immediately)
    }

    private func submit(_ q: String) {
        let query = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        focused = false
        suggestions = []
        submitted = query
        var list = recents.filter { $0.caseInsensitiveCompare(query) != .orderedSame }
        list.insert(query, at: 0)
        recentRaw = list.prefix(20).joined(separator: "\n")
    }
}

/// YouTube Music search results (songs, albums, artists, videos).
struct MusicSearchResults<Header: View>: View {
    var query: String
    @ViewBuilder var header: () -> Header
    @State private var page: MusicPage?
    @State private var loadedQuery: String?
    @State private var failed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header()
                if let page {
                    ShelfStack(shelves: page.shelves)
                }
            }
        }
        .overlay {
            if page == nil {
                if failed {
                    EmptyState(title: "No results", icon: "music.note", message: "Try a different search.")
                } else {
                    ProgressView().controlSize(.large)
                }
            }
        }
        .task(id: query) {
            guard loadedQuery != query else { return }
            page = nil
            failed = false
            let q = query
            if let result = try? await YouTubeService.shared.musicSearch(q), q == query {
                page = result
                loadedQuery = q
                failed = result.shelves.isEmpty
                if failed { page = nil }
            } else if q == query {
                failed = true
            }
        }
    }
}
