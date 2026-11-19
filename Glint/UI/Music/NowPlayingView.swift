import SwiftUI

/// YouTube Music "Now playing". An arrangement view keeps the player and the queue side
/// by side on the inner display (and on either side of the fold); on the narrow outer
/// display only the player shows and the queue opens as a sheet.
struct NowPlayingView: View {
    @Binding var drag: CGFloat
    @Environment(PlayerController.self) private var player
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showQueue = false
    @State private var sheetTab: MusicSidePanel.Tab = .queue
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
                    MusicSidePanel(tab: sheetTab)
                        .navigationTitle(sheetTab == .queue ? "Up next" : "Lyrics")
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

    /// Top: only the way out (and a grab area). Everything else is in the bottom action row.
    private var topBar: some View {
        HStack {
            Button { player.presentation = .mini } label: {
                Image(systemName: "chevron.down")
                    .font(.body.weight(.semibold))
                    .frame(width: 40, height: 40)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Minimize")
            Spacer()
            Capsule().fill(.white.opacity(0.4)).frame(width: 36, height: 5).accessibilityHidden(true)
            Spacer()
            Color.clear.frame(width: 40, height: 40)
        }
        .padding(.top, 8)
        .contentShape(Rectangle())
        .collapsesPlayer($drag)
    }

    @ViewBuilder
    private var artwork: some View {
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

    /// One thumb-reachable row of labelled actions under the transport.
    private func actionRow(showQueueButton: Bool) -> some View {
        HStack(spacing: 0) {
            if showQueueButton {
                actionTile("Lyrics", "quote.bubble") { sheetTab = .lyrics; showQueue = true }
                actionTile("Up next", "list.bullet") { sheetTab = .queue; showQueue = true }
            }
            actionTile(player.audioOnly ? "Video" : "Song", player.audioOnly ? "play.rectangle" : "music.note") {
                player.setAudioOnly(!player.audioOnly)
            }
            Menu { SleepTimerOptions() } label: {
                tileLabel(player.sleepActive ? player.sleepSummary : "Sleep", "moon.zzz", on: player.sleepActive)
            }
            .frame(maxWidth: .infinity)
            Group {
                if player.audioOnly {
                    MusicMoreMenu { tileLabel("More", "ellipsis") }
                } else {
                    QualityMenu { tileLabel("More", "ellipsis") }
                }
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
            Image(systemName: icon).font(.title3)
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
                SpeedMenu {
                    Text(player.rate == 1 ? "1×" : String(format: "%g×", player.rate))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Playback speed")
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
                // Balances the speed control on the leading side.
                Color.clear.frame(width: 44, height: 44)
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

struct LyricsView: View {
    @Environment(PlayerController.self) private var player
    @State private var text: String?
    @State private var source: String?
    @State private var loadedFor: String?
    @State private var loading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                } else if let text {
                    Text(text)
                        .font(.title3.weight(.semibold))
                        .lineSpacing(8)
                        .textSelection(.enabled)
                    if let source {
                        Text(source).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    ContentUnavailableView("No lyrics for this song", systemImage: "quote.bubble")
                        .padding(.top, 30)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .task(id: player.current?.videoId) { await load() }
    }

    private func load() async {
        guard let id = player.current?.videoId, id != loadedFor else { return }
        loading = true
        text = nil
        source = nil
        let result = await YouTubeService.shared.lyrics(videoId: id)
        // Cancelled (panel closed, song changed): don't remember a failed lookup as "no lyrics".
        guard !Task.isCancelled, player.current?.videoId == id else { return }
        text = result?.text
        source = result?.source
        loadedFor = id
        loading = false
    }
}
