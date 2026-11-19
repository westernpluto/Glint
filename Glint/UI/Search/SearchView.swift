import SwiftUI

enum SearchScope: String, CaseIterable, Identifiable {
    case youtube, music
    var id: String { rawValue }
    var title: String { self == .youtube ? "YouTube" : "Music" }
    var prompt: String { self == .youtube ? "Search videos, channels, playlists" : "Search songs, albums, artists" }
}

/// One search for everything, with a clear YouTube / Music switch.
struct SearchView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.screenClass) private var screen
    @State private var text = ""
    @State private var submitted = ""
    @State private var filter: SearchFilter = .all
    @State private var suggestions: [String] = []
    @AppStorage("recentSearches") private var recentRaw = ""

    private var recents: [String] { recentRaw.split(separator: "\n").map(String.init) }
    private var scope: SearchScope { router.searchScope }

    var body: some View {
        Group {
            if submitted.isEmpty {
                recentList
            } else if scope == .youtube {
                FeedScreen(reloadKey: "\(submitted)|\(filter.rawValue)", endpoint: .search,
                           emptyTitle: "No results", emptyIcon: "magnifyingglass") {
                    try await YouTubeService.shared.search(submitted, filter: filter)
                } header: {
                    VStack(alignment: .leading, spacing: 12) {
                        scopePicker
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(SearchFilter.allCases) { f in
                                    GlassChip(title: f.title, selected: f == filter) { filter = f }
                                }
                            }
                            .padding(.horizontal, Metrics.gutter(screen))
                        }
                        .scrollClipDisabled()
                    }
                    .padding(.vertical, 8)
                }
            } else {
                MusicSearchResults(query: submitted) { scopePicker.padding(.top, 8) }
            }
        }
        .navigationTitle("Search")
        .searchable(text: $text, placement: .automatic, prompt: scope.prompt)
        .searchSuggestions {
            ForEach(suggestions, id: \.self) { s in
                Label(s, systemImage: "magnifyingglass").searchCompletion(s)
            }
        }
        .onSubmit(of: .search) { submit(text) }
        .task(id: text) {
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            suggestions = await YouTubeService.shared.suggestions(text)
        }
        .onChange(of: text) { _, new in if new.isEmpty { submitted = "" } }
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

    private var scopePicker: some View {
        Picker("Search in", selection: Binding(get: { router.searchScope }, set: { router.searchScope = $0 })) {
            ForEach(SearchScope.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 360)
        .padding(.horizontal, Metrics.gutter(screen))
    }

    private var recentList: some View {
        List {
            Section {
                scopePicker
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .padding(.vertical, 8)
            }
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
    }

    private func submit(_ q: String) {
        let query = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
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
