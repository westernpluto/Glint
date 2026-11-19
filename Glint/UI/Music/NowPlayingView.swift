import SwiftUI

/// YouTube Music "Now playing". On the inner screen the queue sits beside the player.
struct NowPlayingView: View {
    @Binding var drag: CGFloat
    @Environment(PlayerController.self) private var player
    @Environment(\.screenClass) private var screen
    @Environment(\.containerSize) private var size
    @State private var showQueue = false

    var body: some View {
        let sideBySide = screen == .expanded || size.width > size.height
        ZStack {
            backdrop
            if sideBySide {
                HStack(spacing: 0) {
                    Group {
                        if size.height < 500 {
                            // Cover screen in landscape: too short for the full stack.
                            ScrollView { playerColumn(showQueueButton: false).padding(.top, 8) }
                        } else {
                            playerColumn(showQueueButton: false)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    QueueList()
                        .frame(width: min(max(size.width * 0.4, 320), 460))
                        .background(.ultraThinMaterial)
                }
            } else {
                playerColumn(showQueueButton: true)
            }
        }
        .sheet(isPresented: $showQueue) {
            NavigationStack {
                QueueList()
                    .navigationTitle("Up next")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showQueue = false } } }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var backdrop: some View {
        ZStack {
            Color(uiColor: .systemBackground)
            RemoteImage(url: player.current?.thumbnail)
                .blur(radius: 80)
                .opacity(0.45)
                .saturation(1.4)
        }
        .ignoresSafeArea()
    }

    private func playerColumn(showQueueButton: Bool) -> some View {
        let maxArt = min(size.width * (screen == .expanded ? 0.42 : 0.86), size.height * 0.48, 560)
        return VStack(spacing: 0) {
            HStack {
                Button { player.presentation = .mini } label: {
                    Image(systemName: "chevron.down").font(.title3.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                Spacer()
                Picker("Mode", selection: Binding(get: { player.audioOnly }, set: { player.setAudioOnly($0) })) {
                    Text("Song").tag(true)
                    Text("Video").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(width: 170)
                Spacer()
                QualityMenu {
                    Image(systemName: "ellipsis").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
                }
            }
            .padding(.horizontal, 12)
            .collapsesPlayer($drag)

            Spacer(minLength: 12)

            Group {
                if player.audioOnly {
                    Color.clear
                        .frame(width: maxArt, height: maxArt)
                        .overlay { RemoteImage(url: player.current?.thumbnail) }
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .shadow(color: .black.opacity(0.25), radius: 24, y: 12)
                        .scaleEffect(player.isPlaying ? 1 : 0.9)
                        .animation(.spring(response: 0.45, dampingFraction: 0.7), value: player.isPlaying)
                } else {
                    VideoBox()
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .frame(maxWidth: maxArt * 1.5)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
            .collapsesPlayer($drag)

            Spacer(minLength: 12)

            VStack(alignment: .leading, spacing: 18) {
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

                VStack(spacing: 6) {
                    Scrubber(current: player.currentTime, duration: player.duration,
                             segments: player.segments, tint: .primary) { player.seek(to: $0) }
                    HStack {
                        Text(formatTime(player.currentTime))
                        Spacer()
                        Text("-" + formatTime(max(player.duration - player.currentTime, 0)))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }

                HStack {
                    Button { player.setRate(player.rate == 1 ? 1.25 : 1) } label: {
                        Text(player.rate == 1 ? "1×" : String(format: "%g×", player.rate))
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .frame(width: 44, height: 44)
                    }
                    Spacer()
                    Button { player.previous() } label: {
                        Image(systemName: "backward.fill").font(.title)
                    }
                    Spacer()
                    Button { player.togglePlay() } label: {
                        ZStack {
                            Circle().fill(.primary).frame(width: 76, height: 76)
                            if player.isLoading {
                                ProgressView().tint(Color(uiColor: .systemBackground))
                            } else {
                                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 32, weight: .bold))
                                    .foregroundStyle(Color(uiColor: .systemBackground))
                                    .contentTransition(.symbolEffect(.replace))
                            }
                        }
                    }
                    .sensoryFeedback(.impact(weight: .light), trigger: player.isPlaying)
                    Spacer()
                    Button { player.next() } label: {
                        Image(systemName: "forward.fill").font(.title)
                    }
                    Spacer()
                    if showQueueButton {
                        Button { showQueue = true } label: {
                            Image(systemName: "list.bullet").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
                        }
                    } else {
                        Color.clear.frame(width: 44, height: 44)
                    }
                }
                .foregroundStyle(.primary)
                .buttonStyle(.plain)

                if let n = player.notice {
                    Text(n).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                } else if let e = player.loadError {
                    Text(e).font(.footnote).foregroundStyle(.red).frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
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
                        Button { player.playQueue(at: pair.offset) } label: {
                            HStack(spacing: 12) {
                                Color.clear.frame(width: 48, height: 48)
                                    .overlay { RemoteImage(url: pair.element.thumbnail) }
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay {
                                        if pair.offset == player.index {
                                            RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.45))
                                            Image(systemName: player.isPlaying ? "waveform" : "pause.fill")
                                                .foregroundStyle(.white)
                                                .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                                        }
                                    }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pair.element.title)
                                        .font(.subheadline.weight(pair.offset == player.index ? .semibold : .regular))
                                        .lineLimit(1)
                                    if let s = pair.element.subtitle {
                                        Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
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
                    Text("Up next").font(.headline).foregroundStyle(.primary).textCase(nil)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onAppear { if let id = player.current?.id { proxy.scrollTo(id, anchor: .center) } }
        }
    }
}

// MARK: Mini player

struct MiniPlayerBar: View {
    @Environment(PlayerController.self) private var player

    var body: some View {
        if player.presentation == .mini, let item = player.current {
            HStack(spacing: 12) {
                Group {
                    if !player.audioOnly && !item.isMusic {
                        PlayerSurface()
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .frame(height: 44)
                    } else {
                        RemoteImage(url: item.thumbnail).frame(width: 44, height: 44)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(player.details?.title ?? item.title)
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(item.subtitle ?? player.details?.channelName ?? "")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button { player.togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 40, height: 40)
                }
                Button { player.next() } label: {
                    Image(systemName: "forward.fill").font(.body).frame(width: 34, height: 40)
                }
                Button { player.close() } label: {
                    Image(systemName: "xmark").font(.footnote.weight(.bold)).foregroundStyle(.secondary).frame(width: 30, height: 40)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(alignment: .bottom) {
                GeometryReader { g in
                    Capsule().fill(.tint)
                        .frame(width: player.duration > 0 ? g.size.width * min(player.currentTime / player.duration, 1) : 0, height: 2)
                }
                .frame(height: 2)
                .padding(.horizontal, 16)
            }
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
            .contentShape(Rectangle())
            .onTapGesture { player.presentation = .expanded }
            .gesture(DragGesture(minimumDistance: 12).onEnded { v in
                if v.translation.height < -30 { player.presentation = .expanded }
                else if abs(v.translation.width) > 90 { player.close() }
            })
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
