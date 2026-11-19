import SwiftUI

struct SearchView: View {
    @State private var text = ""
    @State private var submitted = ""
    @State private var filter: SearchFilter = .all
    @State private var suggestions: [String] = []
    @AppStorage("recentSearches") private var recentRaw = ""
    @Environment(\.screenClass) private var screen

    private var recents: [String] { recentRaw.split(separator: "\n").map(String.init) }

    var body: some View {
        Group {
            if submitted.isEmpty {
                recentList
            } else {
                FeedScreen(reloadKey: "\(submitted)|\(filter.rawValue)", endpoint: .search,
                           emptyTitle: "No results", emptyIcon: "magnifyingglass") {
                    try await YouTubeService.shared.search(submitted, filter: filter)
                } header: {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(SearchFilter.allCases) { f in
                                Chip(title: f.title, selected: f == filter) { filter = f }
                            }
                        }
                        .padding(.horizontal, Metrics.gutter(screen))
                        .padding(.vertical, 8)
                    }
                }
            }
        }
        .navigationTitle("Search")
        .searchable(text: $text, placement: .automatic, prompt: "Search YouTube")
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

    private var recentList: some View {
        List {
            if recents.isEmpty {
                EmptyState(title: "Search YouTube", icon: "magnifyingglass",
                           message: "Videos, channels and playlists — no ads, ever.")
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
