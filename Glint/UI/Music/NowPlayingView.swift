import SwiftUI

/// YouTube Music "Now playing". An arrangement view keeps the player and the queue side
/// by side on the inner display (and on either side of the fold); on the narrow outer
/// display only the player shows and the queue opens as a sheet.
struct NowPlayingView: View {
    @Binding var drag: CGFloat
    @Environment(PlayerController.self) private var player
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showQueue = false
    /// Lyrics in place of the artwork.
    @State private var showLyrics = false
    @State private var palette: [Color]?

    var body: some View {
        let regular = horizontalSizeClass == .regular
        arranged(regular: regular)
            .background { backdrop }
            // Always light-on-dark over the artwork colours, like a music player should be.
            .environment(\.colorScheme, .dark)
            .task(id: player.current?.thumbnail) {
                guard let url = player.current?.thumbnail else { return }
                palette = await ArtworkPalette.shared.colors(for: url)
            }
            .sheet(isPresented: $showQueue) {
                NavigationStack {
                    QueueList(showsHeader: false)
                        .navigationTitle("Up next")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarPinnedTrailing) {
                                Button("Done", systemImage: "checkmark") { showQueue = false }
                            }
                        }
                }
                .presentationDetents([.medium, .large])
            }
    }

    @ViewBuilder
    private func arranged(regular: Bool) -> some View {
        if #available(iOS 27.1, *) {
            if regular {
                ArrangementView {
                    playerColumn(showQueueButton: false).splitArrangementLayoutRatio(0.62)
                } secondary: {
                    MusicSidePanel()
                }
                .arrangementViewStyle(.split)
            } else {
                // Narrow display: split only side by side; when tall, just the player.
                ArrangementView {
                    playerColumn(showQueueButton: true)
                } secondary: {
                    MusicSidePanel()
                }
                .arrangementViewStyle(.split.axes(.horizontal))
            }
        } else if regular {
            HStack(spacing: 0) {
                playerColumn(showQueueButton: false)
                MusicSidePanel().frame(width: 400)
            }
        } else {
            playerColumn(showQueueButton: true)
        }
    }

    /// A deep gradient taken from the artwork, with the artwork itself blurred on top.
    private var backdrop: some View {
        ZStack {
            Color.black
            LinearGradient(colors: palette ?? [Color(white: 0.22), Color(white: 0.1)], startPoint: .top, endPoint: .bottom)
            RemoteImage(url: player.current?.thumbnail)
                .blur(radius: 90)
                .opacity(0.35)
                .saturation(1.4)
        }
        .animation(.easeInOut(duration: 0.6), value: palette)
        .ignoresSafeArea()
    }

    private func playerColumn(showQueueButton: Bool) -> some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 16)
            artwork
            Spacer(minLength: 16)
            VStack(alignment: .leading, spacing: 18) {
                titleBlock
                VStack(spacing: 4) {
                    LiveScrubber(tint: .primary)
                    HStack {
                        ElapsedLabel(style: .elapsed)
                        Spacer()
                        ElapsedLabel(style: .remaining)
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                transport(showQueueButton: showQueueButton)
                actionRow(showQueueButton: showQueueButton)
                if let n = player.notice {
                    Text(n).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                } else if let e = player.loadError {
                    Text(e).font(.footnote).foregroundStyle(.red).frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: 520)
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
    }

    /// Top: just the grabber — drag down (or tap it) to minimize.
    private var topBar: some View {
        Button { player.presentation = .mini } label: {
            Capsule().fill(.secondary.opacity(0.6)).frame(width: 40, height: 5)
                .frame(maxWidth: .infinity, minHeight: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Minimize")
        .padding(.top, 4)
        .collapsesPlayer($drag)
    }

    @ViewBuilder
    private var artwork: some View {
        if showLyrics {
            // Scrolls on its own, so no drag-to-minimize here (the grabber still does it).
            LyricsView(compact: true)
                .frame(maxWidth: 560, maxHeight: .infinity)
                .transition(.opacity)
        } else {
            artworkImage
        }
    }

    @ViewBuilder
    private var artworkImage: some View {
        Group {
            if player.audioOnly {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay { RemoteImage(url: player.current?.thumbnail) }
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .shadow(color: .black.opacity(0.28), radius: 28, y: 14)
                    .scaleEffect(player.isPlaying ? 1 : 0.92)
                    .animation(.spring(response: 0.45, dampingFraction: 0.7), value: player.isPlaying)
            } else {
                VideoBox()
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
        // Flexes to the room left between the bars and the controls.
        .frame(maxWidth: player.audioOnly ? 520 : 760, maxHeight: .infinity)
        .collapsesPlayer($drag)
    }

    /// Three things under the transport: lyrics, the queue, and everything else.
    private func actionRow(showQueueButton: Bool) -> some View {
        HStack(spacing: 0) {
            if showQueueButton {
                actionTile("Lyrics", showLyrics ? "quote.bubble.fill" : "quote.bubble", on: showLyrics) {
                    withAnimation(.smooth(duration: 0.3)) { showLyrics.toggle() }
                }
                actionTile("Up next", "list.bullet") { showQueue = true }
            }
            PlayerOptionsMenu(music: true) {
                tileLabel("More", "ellipsis", on: player.sleepActive || player.rate != 1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }

    private func actionTile(_ title: String, _ icon: String, on: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { tileLabel(title, icon, on: on) }
            .frame(maxWidth: .infinity)
    }

    private func tileLabel(_ title: String, _ icon: String, on: Bool = false) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon).font(.title3).frame(height: 26)   // same height for every glyph
            Text(title).font(.caption2.weight(.semibold)).lineLimit(1)
        }
        .foregroundStyle(on ? Color.accentColor : Color.secondary)
        .frame(maxWidth: .infinity, minHeight: 48)
        .contentShape(Rectangle())
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(player.current?.title ?? "")
                .font(.title2.weight(.bold))
                .lineLimit(2)
            Text(player.current?.subtitle ?? player.details?.channelName ?? "")
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func transport(showQueueButton: Bool) -> some View {
        GlassEffectContainer(spacing: 20) {
            HStack {
                Spacer()
                Button { player.previous() } label: {
                    Image(systemName: "backward.fill").font(.title2)
                        .frame(width: 56, height: 56)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .accessibilityLabel("Previous")
                Spacer()
                Button { player.togglePlay() } label: {
                    ZStack {
                        if player.isLoading {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 30, weight: .bold))
                                .contentTransition(.symbolEffect(.replace))
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(width: 80, height: 80)
                    // The one prominent control: solid accent glass, not a washed-out tint.
                    .glassEffect(.regular.tint(.accentColor).interactive(), in: .circle)
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                .sensoryFeedback(.impact(weight: .light), trigger: player.isPlaying)
                Spacer()
                Button { player.next() } label: {
                    Image(systemName: "forward.fill").font(.title2)
                        .frame(width: 56, height: 56)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .accessibilityLabel("Next")
                Spacer()
            }
            .foregroundStyle(.primary)
            .buttonStyle(.plain)
        }
    }
}

struct QueueList: View {
    /// Off when a segmented control above already says "Up next".
    var showsHeader = true
    @Environment(PlayerController.self) private var player

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    ForEach(Array(player.queue.enumerated()), id: \.element.id) { pair in
                        row(pair.offset, pair.element)
                            .listRowBackground(Color.clear)
                            .id(pair.element.id)
                    }
                    .onMove { from, to in
                        let currentID = player.current?.id
                        player.queue.move(fromOffsets: from, toOffset: to)
                        if let currentID, let i = player.queue.firstIndex(where: { $0.id == currentID }) { player.index = i }
                    }
                    .onDelete { idx in
                        let currentID = player.current?.id
                        let remaining = player.queue.enumerated().filter { !idx.contains($0.offset) || $0.element.id == currentID }
                        player.queue = remaining.map(\.element)
                        if let currentID, let i = player.queue.firstIndex(where: { $0.id == currentID }) { player.index = i }
                    }
                } header: {
                    if showsHeader {
                        Text("Up next").font(.title3.weight(.bold)).foregroundStyle(.primary).textCase(nil)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onAppear { if let id = player.current?.id { proxy.scrollTo(id, anchor: .center) } }
        }
    }

    private func row(_ i: Int, _ item: QueueItem) -> some View {
        Button { player.playQueue(at: i) } label: {
            HStack(spacing: 12) {
                Color.clear.frame(width: 48, height: 48)
                    .overlay { RemoteImage(url: item.thumbnail) }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        if i == player.index {
                            RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.45))
                            Image(systemName: player.isPlaying ? "waveform" : "pause.fill")
                                .foregroundStyle(.white)
                                .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                        }
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.subheadline.weight(i == player.index ? .semibold : .regular))
                        .lineLimit(1)
                    if let s = item.subtitle {
                        Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Mini player

/// Lives in the tab view's bottom accessory, so the system places it correctly with a
/// horizontal tab bar, a minimized tab bar, or the vertical bars on iPhone Duo.
struct MiniPlayerAccessory: View {
    @Environment(PlayerController.self) private var player
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        if let item = player.current {
            HStack(spacing: 12) {
                Color.clear
                    .frame(width: item.isMusic ? 34 : 54, height: 34)
                    .overlay { RemoteImage(url: item.thumbnail) }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(player.details?.title ?? item.title)
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                    if placement != .inline {
                        Text(item.subtitle ?? player.details?.channelName ?? "")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Button { player.togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                if placement != .inline {
                    Button { player.next() } label: {
                        Image(systemName: "forward.fill").frame(width: 32, height: 36)
                    }
                    .accessibilityLabel("Next")
                    Button { player.close() } label: {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 36)
                    }
                    .accessibilityLabel("Stop playing")
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .overlay(alignment: .bottom) {
                ProgressLine().padding(.horizontal, 18).opacity(placement == .inline ? 0 : 1)
            }
            .contentShape(Rectangle())
            .onTapGesture { player.presentation = .expanded }
            .contextMenu {
                Button(role: .destructive) { player.close() } label: { Label("Stop playing", systemImage: "xmark") }
            }
        }
    }
}

/// Up next and Lyrics in one column, switched with a segmented control.
struct MusicSidePanel: View {
    enum Tab: String, CaseIterable, Identifiable {
        case queue = "Up next", lyrics = "Lyrics"
        var id: String { rawValue }
    }
    @State var tab: Tab = .queue

    var body: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            switch tab {
            case .queue: QueueList(showsHeader: false)
            case .lyrics: LyricsView()
            }
        }
    }
}

/// Lyrics you can sing along to: with timings, the current line is large and bright, its
/// words light up as they're sung (spread over the line's time by length), the view keeps
/// it in place as the song moves, and tapping a line jumps there. Without timings, the
/// plain text.
struct LyricsView: View {
    var compact = false
    @Environment(PlayerController.self) private var player
    @State private var lyrics: YouTubeService.Lyrics?
    @State private var loadedFor: String?
    @State private var loading = false
    /// After a manual scroll, follow the song again only after a few seconds.
    @State private var userScrolledAt = Date.distantPast

    var body: some View {
        Group {
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let l = lyrics, !l.lines.isEmpty {
                synced(l)
            } else if let l = lyrics, let text = l.text {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(text)
                            .font(.title3.weight(.semibold))
                            .lineSpacing(8)
                            .textSelection(.enabled)
                        if let source = l.source { Text(source).font(.caption).foregroundStyle(.secondary) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                }
            } else {
                ContentUnavailableView("No lyrics for this song", systemImage: "quote.bubble")
            }
        }
        .task(id: player.current?.videoId) { await load() }
    }

    private func synced(_ l: YouTubeService.Lyrics) -> some View {
        let t = player.currentTime
        let current = l.lines.lastIndex { $0.start <= t + 0.15 } ?? -1
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: compact ? 14 : 20) {
                    Color.clear.frame(height: compact ? 20 : 60)
                    ForEach(Array(l.lines.enumerated()), id: \.offset) { i, line in
                        Button { player.seek(to: line.start) } label: {
                            lineView(line, state: i < current ? .past : i == current ? .current : .future, time: t)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(i)
                    }
                    if let source = l.source {
                        Text(source).font(.caption).foregroundStyle(.secondary).padding(.top, 12)
                    }
                    Color.clear.frame(height: compact ? 80 : 240)
                }
                .padding(.horizontal, compact ? 4 : 24)
            }
            .scrollIndicators(.hidden)
            .simultaneousGesture(DragGesture().onChanged { _ in userScrolledAt = Date() })
            .onChange(of: current) { _, i in
                guard i >= 0, Date().timeIntervalSince(userScrolledAt) > 3 else { return }
                withAnimation(.smooth(duration: 0.45)) { proxy.scrollTo(i, anchor: UnitPoint(x: 0.5, y: 0.3)) }
            }
            .onAppear { if current >= 0 { proxy.scrollTo(current, anchor: UnitPoint(x: 0.5, y: 0.3)) } }
        }
        // Soft fade at the edges, like a music app's lyrics.
        .mask {
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.08),
                                   .init(color: .black, location: 0.85), .init(color: .clear, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
    }

    private enum LineState { case past, current, future }

    @ViewBuilder
    private func lineView(_ line: YouTubeService.Lyrics.Line, state: LineState, time: Double) -> some View {
        let font: Font = compact ? .title3.weight(.bold) : .title.weight(.bold)
        switch state {
        case .current:
            // Words light up as they're sung: the line's time spread over its words by length.
            let words = line.text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            let total = max(words.reduce(0) { $0 + $1.count + 1 }, 1)
            let progress = min(max((time - line.start) / max(line.end - line.start, 0.1), 0), 1) * Double(total)
            var used = 0
            let text = words.reduce(Text("")) { acc, w in
                let lit = Double(used) < progress
                used += w.count + 1
                return acc + Text(w + " ").foregroundStyle(lit ? Color.white : Color.white.opacity(0.42))
            }
            text.font(font)
                .scaleEffect(1.03, anchor: .leading)
                .animation(.easeOut(duration: 0.2), value: state == .current)
        case .past:
            Text(line.text).font(font).foregroundStyle(.white.opacity(0.32))
        case .future:
            Text(line.text).font(font).foregroundStyle(.white.opacity(0.5))
        }
    }

    private func load() async {
        guard let id = player.current?.videoId, id != loadedFor else { return }
        loading = true
        lyrics = nil
        let result = await YouTubeService.shared.lyrics(videoId: id)
        // Cancelled (panel closed, song changed): don't remember a failed lookup as "no lyrics".
        guard !Task.isCancelled, player.current?.videoId == id else { return }
        lyrics = result
        loadedFor = id
        loading = false
    }
}
