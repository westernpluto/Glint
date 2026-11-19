import SwiftUI

/// YouTube Music "Now playing". An arrangement view keeps the player and the queue side
/// by side on the inner display (and on either side of the fold); on the narrow outer
/// display only the player shows and the queue opens as a sheet.
struct NowPlayingView: View {
    @Binding var drag: CGFloat
    @Environment(PlayerController.self) private var player
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showQueue = false

    var body: some View {
        let regular = horizontalSizeClass == .regular
        arranged(regular: regular)
            .background { backdrop }
            .sheet(isPresented: $showQueue) {
                NavigationStack {
                    QueueList()
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
                    playerColumn(showQueueButton: false).splitArrangementLayoutRatio(0.56)
                } secondary: {
                    QueueList()
                }
                .arrangementViewStyle(.split)
            } else {
                // Narrow display: split only side by side; when tall, just the player.
                ArrangementView {
                    playerColumn(showQueueButton: true)
                } secondary: {
                    QueueList()
                }
                .arrangementViewStyle(.split.axes(.horizontal))
            }
        } else if regular {
            HStack(spacing: 0) {
                playerColumn(showQueueButton: false)
                QueueList().frame(width: 400)
            }
        } else {
            playerColumn(showQueueButton: true)
        }
    }

    private var backdrop: some View {
        ZStack {
            Color(uiColor: .systemBackground)
            RemoteImage(url: player.current?.thumbnail)
                .blur(radius: 90)
                .opacity(0.55)
                .saturation(1.5)
        }
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
            Picker("Mode", selection: Binding(get: { player.audioOnly }, set: { player.setAudioOnly($0) })) {
                Text("Song").tag(true)
                Text("Video").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
            Spacer()
            QualityMenu {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .frame(width: 40, height: 40)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .accessibilityLabel("More")
        }
        .padding(.top, 8)
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
                Button { player.setRate(player.rate == 1 ? 1.25 : 1) } label: {
                    Text(player.rate == 1 ? "1×" : String(format: "%g×", player.rate))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .frame(width: 44, height: 44)
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
                            ProgressView()
                        } else {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 30, weight: .bold))
                                .contentTransition(.symbolEffect(.replace))
                        }
                    }
                    .frame(width: 80, height: 80)
                    .glassEffect(.regular.tint(.accentColor.opacity(0.35)).interactive(), in: .circle)
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
                if showQueueButton {
                    Button { showQueue = true } label: {
                        Image(systemName: "list.bullet").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Up next")
                } else {
                    Color.clear.frame(width: 44, height: 44)
                }
            }
            .foregroundStyle(.primary)
            .buttonStyle(.plain)
        }
    }
}

struct QueueList: View {
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
                    Text("Up next").font(.title3.weight(.bold)).foregroundStyle(.primary).textCase(nil)
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
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
            .onTapGesture { player.presentation = .expanded }
            .contextMenu {
                Button(role: .destructive) { player.close() } label: { Label("Stop playing", systemImage: "xmark") }
            }
        }
    }
}
