import SwiftUI

struct MusicHomeView: View {
    @Environment(AccountStore.self) private var accounts
    @Environment(\.screenClass) private var screen
    @State private var shelves: [MusicShelf] = []
    @State private var loading = false
    @State private var error: Error?
    @State private var query = ""
    @State private var submitted = ""
    @State private var results: MusicPage?
    @State private var resultsQuery: String?
    @State private var loadedGeneration: Int?

    var body: some View {
        Group {
            if !submitted.isEmpty {
                ScrollView {
                    if let results {
                        ShelfStack(shelves: results.shelves)
                    } else {
                        ProgressView().padding(60)
                    }
                }
                .task(id: submitted) {
                    guard resultsQuery != submitted else { return }
                    results = nil
                    let q = submitted
                    if let r = try? await YouTubeService.shared.musicSearch(q), q == submitted {
                        results = r
                        resultsQuery = q
                    } else if q == submitted {
                        results = MusicPage(shelves: [])
                    }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if accounts.isSignedIn { libraryRow }
                        ShelfStack(shelves: shelves)
                    }
                }
                .overlay {
                    if shelves.isEmpty && loading { ProgressView().controlSize(.large) }
                    else if shelves.isEmpty, let error { ErrorState(error: error) { Task { await load() } } }
                }
                .refreshable { await load() }
                .task(id: accounts.generation) {
                    if loadedGeneration == accounts.generation, !shelves.isEmpty { return }
                    await load()
                    loadedGeneration = accounts.generation
                }
            }
        }
        .navigationTitle("Music")
        .searchable(text: $query, prompt: "Songs, albums, artists")
        .onSubmit(of: .search) { submitted = query.trimmingCharacters(in: .whitespaces) }
        .onChange(of: query) { _, q in if q.isEmpty { submitted = "" } }
    }

    private var libraryRow: some View {
        HStack(spacing: 12) {
            NavigationLink(value: Route.musicLiked) { tile("Liked songs", icon: "heart.fill") }
            NavigationLink(value: Route.musicPlaylists) { tile("Playlists", icon: "music.note.list") }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Metrics.gutter(screen))
        .padding(.top, 8)
        .frame(maxWidth: 640, alignment: .leading)
    }

    private func tile(_ title: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(.tint)
            Text(title).font(.subheadline.weight(.semibold))
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Color.cardFill, in: RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
    }

    private func load() async {
        loading = true
        defer { loading = false }
        let svc = YouTubeService.shared
        async let home = try? svc.musicHome()
        async let explore = try? svc.musicExplore()
        async let charts = try? svc.musicCharts()
        let pages = await [home, explore, charts].compactMap { $0 }
        var seen = Set<String>()
        var merged: [MusicShelf] = []
        for shelf in pages.flatMap(\.shelves) where !shelf.title.isEmpty && seen.insert(shelf.title).inserted {
            merged.append(shelf)
        }
        if merged.isEmpty { error = InnerTubeError.empty } else { error = nil }
        shelves = merged
    }
}

/// Renders a page's shelves: song lists as rows, everything else as carousels.
struct ShelfStack: View {
    var shelves: [MusicShelf]
    @Environment(\.screenClass) private var screen

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 28) {
            ForEach(shelves) { shelf in
                VStack(alignment: .leading, spacing: 12) {
                    if !shelf.title.isEmpty {
                        Text(shelf.title).font(.title3.weight(.bold))
                            .padding(.horizontal, Metrics.gutter(screen))
                    }
                    if shelf.prefersList {
                        SongList(items: shelf.items)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 14) {
                                ForEach(shelf.items) { MusicCard(item: $0, siblings: shelf.items) }
                            }
                            .scrollTargetLayout()
                            .padding(.horizontal, Metrics.gutter(screen))
                        }
                        .scrollTargetBehavior(.viewAligned)
                    }
                }
            }
        }
        .padding(.vertical, 16)
    }
}

/// Songs: a single column on the cover screen, a two/three column grid on the inner screen.
struct SongList: View {
    var items: [MusicItem]
    @Environment(\.screenClass) private var screen

    var body: some View {
        let columns = screen == .expanded
            ? [GridItem(.adaptive(minimum: 320), spacing: 18, alignment: .top)]
            : [GridItem(.flexible())]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
            ForEach(items) { MusicRow(item: $0, siblings: items) }
        }
        .padding(.horizontal, Metrics.gutter(screen))
    }
}

struct MusicRow: View {
    var item: MusicItem
    var siblings: [MusicItem]
    @Environment(PlayerController.self) private var player

    var body: some View {
        MusicLink(item: item, siblings: siblings) {
            HStack(spacing: 12) {
                Color.clear.frame(width: 52, height: 52)
                    .overlay { RemoteImage(url: item.thumbnail) }
                    .clipShape(item.kind == .artist ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 8, style: .continuous)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(player.current?.videoId == item.videoId && item.videoId != nil ? Color.accentColor : .primary)
                        .lineLimit(1)
                    if let s = item.subtitle {
                        Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if let d = item.duration {
                    Text(d).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                } else if !item.isPlayable {
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
    }
}

struct MusicCard: View {
    var item: MusicItem
    var siblings: [MusicItem]
    @Environment(\.screenClass) private var screen

    var body: some View {
        let side: CGFloat = screen == .expanded ? 180 : 150
        MusicLink(item: item, siblings: siblings) {
            VStack(alignment: .leading, spacing: 8) {
                Color.clear.frame(width: item.kind == .video ? side * 16 / 9 * 0.75 : side, height: item.kind == .video ? side * 0.75 : side)
                    .overlay { RemoteImage(url: item.thumbnail) }
                    .clipShape(item.kind == .artist ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 12, style: .continuous)))
                Text(item.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
                if let s = item.subtitle {
                    Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .frame(width: item.kind == .video ? side * 16 / 9 * 0.75 : side, alignment: .leading)
        }
    }
}

/// Plays a track or navigates to an album / artist / playlist.
struct MusicLink<Content: View>: View {
    var item: MusicItem
    var siblings: [MusicItem]
    @ViewBuilder var content: () -> Content
    @Environment(PlayerController.self) private var player

    var body: some View {
        if item.isPlayable {
            Button {
                let songs = siblings.filter(\.isPlayable)
                // Play a song list in order; single tracks/videos start a radio.
                if songs.count > 1 && siblings.allSatisfy({ $0.kind == .song || $0.kind == .video }) {
                    player.playMusic(item, in: songs)
                } else {
                    player.playMusic(item)
                }
            } label: { content() }
            .buttonStyle(.plain)
            .contextMenu {
                Button { player.playMusic(item) } label: { Label("Start radio", systemImage: "dot.radiowaves.left.and.right") }
                if let vid = item.videoId, let url = URL(string: "https://music.youtube.com/watch?v=\(vid)") {
                    ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                }
            }
        } else if let bid = item.browseId {
            NavigationLink(value: Route.music(browseId: bid, title: item.title)) { content() }
                .buttonStyle(.plain)
        } else if let pl = item.playlistId {
            Button { player.playMusicCollection(playlistId: pl) } label: { content() }
                .buttonStyle(.plain)
        } else {
            content()
        }
    }
}

/// Album, playlist or artist page.
struct MusicBrowseView: View {
    var browseId: String
    var title: String?
    @State private var page: MusicPage?
    @State private var error: Error?
    @Environment(PlayerController.self) private var player
    @Environment(\.screenClass) private var screen

    var body: some View {
        ScrollView {
            if let page {
                VStack(alignment: .leading, spacing: 0) {
                    header(page)
                    ShelfStack(shelves: page.shelves)
                }
            }
        }
        .overlay {
            if page == nil && error == nil { ProgressView().controlSize(.large) }
            else if let error { ErrorState(error: error) { Task { await load() } } }
        }
        .navigationTitle(page?.title ?? title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: browseId) { if page == nil { await load() } }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            if browseId.hasPrefix("FEmusic_liked") && !InnerTube.shared.isSignedIn { throw InnerTubeError.notSignedIn }
            page = try await YouTubeService.shared.musicBrowse(browseId)
            error = nil
        } catch {
            self.error = error
        }
    }

    @ViewBuilder
    private func header(_ p: MusicPage) -> some View {
        let songs = p.shelves.flatMap(\.items).filter(\.isPlayable)
        let art = screen == .expanded ? 220.0 : 160.0
        let layout = screen == .expanded ? AnyLayout(HStackLayout(alignment: .bottom, spacing: 24)) : AnyLayout(VStackLayout(alignment: .center, spacing: 16))
        layout {
            if let t = p.thumbnail {
                Color.clear.frame(width: art, height: art)
                    .overlay { RemoteImage(url: t) }
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
            }
            VStack(alignment: screen == .expanded ? .leading : .center, spacing: 8) {
                Text(p.title ?? title ?? "").font(.title.weight(.bold))
                    .multilineTextAlignment(screen == .expanded ? .leading : .center)
                if let s = p.subtitle { Text(s).font(.subheadline).foregroundStyle(.secondary) }
                if !songs.isEmpty || p.playlistId != nil {
                    HStack(spacing: 12) {
                        Button { play(p, songs, shuffle: false) } label: { Label("Play", systemImage: "play.fill").frame(minWidth: 110) }
                            .buttonStyle(.borderedProminent)
                        Button { play(p, songs, shuffle: true) } label: { Label("Shuffle", systemImage: "shuffle").frame(minWidth: 110) }
                            .buttonStyle(.bordered)
                    }
                    .controlSize(.large)
                    .padding(.top, 6)
                }
            }
            if screen == .expanded { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Metrics.gutter(screen))
        .padding(.top, 12)
    }

    private func play(_ p: MusicPage, _ songs: [MusicItem], shuffle: Bool) {
        let list = p.shelves.first(where: { $0.prefersList && $0.items.contains(where: \.isPlayable) })?.items.filter(\.isPlayable) ?? songs
        if !list.isEmpty {
            let ordered = shuffle ? list.shuffled() : list
            player.playMusic(ordered[0], in: ordered)
        } else if let pl = p.playlistId {
            player.playMusicCollection(playlistId: pl, shuffle: shuffle)
        }
    }
}
