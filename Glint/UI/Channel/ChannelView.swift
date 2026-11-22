import SwiftUI

struct ChannelView: View {
    var channelId: String
    var name: String?
    @State private var page: ChannelPage?
    @State private var tab: YouTubeService.ChannelTab = .videos
    /// A chosen sort (Latest / Popular / Oldest); nil = the channel's default.
    @State private var sort: ChannelSort?
    @State private var searchText = ""
    /// The search that's showing (submitted); empty = the channel's tabs.
    @State private var query = ""
    @Environment(\.screenClass) private var screen

    var body: some View {
        FeedScreen(reloadKey: "\(channelId)|\(tab.rawValue)|\(sort?.title ?? "")|\(query)",
                   emptyTitle: !query.isEmpty ? "No results in this channel"
                       : tab == .live ? "No live streams" : tab == .playlists ? "No playlists" : "No videos",
                   emptyIcon: query.isEmpty ? "film" : "magnifyingglass") {
            let name = page?.name ?? self.name
            if !query.isEmpty {
                return try await YouTubeService.shared.channelSearch(channelId, name: name, query: query)
            }
            if let sort, page != nil {
                return try await YouTubeService.shared.channelSorted(channelId, name: name, token: sort.token)
            }
            let p = try await YouTubeService.shared.channel(channelId, tab: tab)
            await MainActor.run { page = p }
            return p.feed
        } header: {
            header
        }
        .navigationTitle(page?.name ?? name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic),
                    prompt: "Search \(page?.name ?? name ?? "this channel")")
        .onSubmit(of: .search) { query = searchText.trimmingCharacters(in: .whitespaces) }
        .onChange(of: searchText) { _, t in if t.isEmpty { query = "" } }
        .onChange(of: tab) { _, _ in sort = nil }
    }

    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let banner = page?.banner {
                Color.clear
                    .aspectRatio(screen == .expanded ? 6.2 : 4, contentMode: .fit)
                    .overlay { RemoteImage(url: banner) }
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
            }
            HStack(spacing: 14) {
                Avatar(url: page?.avatar, size: screen == .expanded ? 80 : 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(page?.name ?? name ?? "").font(.title2.weight(.bold)).lineLimit(2)
                    if let s = page?.subscribers { Text(s).font(.subheadline).foregroundStyle(.secondary) }
                }
                Spacer()
                SubscribeButton(channelId: channelId, initial: page?.subscribed)
            }
            if query.isEmpty {
                HStack(spacing: 10) {
                    Picker("Show", selection: $tab) {
                        ForEach(YouTubeService.ChannelTab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 420)
                    if tab != .playlists, let sorts = page?.sorts, !sorts.isEmpty {
                        sortMenu(sorts)
                    }
                }
            } else {
                Text("Results for “\(query)”").font(.headline)
            }
        }
        .padding(.horizontal, Metrics.gutter(screen))
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    /// Latest / Popular / Oldest, as the channel offers them.
    private func sortMenu(_ sorts: [ChannelSort]) -> some View {
        let current = sort ?? sorts.first(where: \.selected) ?? sorts.first
        return Menu {
            ForEach(sorts) { s in
                Button {
                    sort = s.title == sorts.first(where: \.selected)?.title ? nil : s
                } label: {
                    if s.title == current?.title { Label(s.title, systemImage: "checkmark") } else { Text(s.title) }
                }
            }
        } label: {
            Label(current?.title ?? "Sort", systemImage: "arrow.up.arrow.down")
                .font(.subheadline.weight(.semibold))
        }
        .accessibilityLabel("Sort videos")
    }
}

/// Subscribe / unsubscribe toggle (needs an account).
struct SubscribeButton: View {
    var channelId: String
    var initial: Bool?
    @State private var subscribed: Bool?
    @State private var busy = false
    @State private var failures = 0
    @Environment(AccountStore.self) private var accounts

    var body: some View {
        if accounts.isSignedIn {
            let on = subscribed ?? initial ?? false
            Group {
                if on {
                    Button("Subscribed", systemImage: "checkmark") { toggle(on) }
                        .buttonStyle(.glass)
                } else {
                    Button("Subscribe") { toggle(on) }
                        .buttonStyle(.glassProminent)
                }
            }
            .font(.subheadline.weight(.semibold))
            .disabled(busy)
            .sensoryFeedback(.selection, trigger: subscribed)
            .sensoryFeedback(.error, trigger: failures)
        }
    }

    private func toggle(_ on: Bool) {
        busy = true
        Task {
            do {
                try await YouTubeService.shared.setSubscribed(!on, channelId: channelId)
                subscribed = !on
            } catch {
                failures += 1
            }
            busy = false
        }
    }
}
