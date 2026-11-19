import AVKit
import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

func formatTime(_ t: Double) -> String {
    guard t.isFinite, t >= 0 else { return "0:00" }
    let s = Int(t.rounded(.down))
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
}

enum Orientation {
    static func request(_ mask: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}

/// Timeline with SponsorBlock segments drawn in their category colours.
struct Scrubber: View {
    var current: Double
    var duration: Double
    var segments: [SponsorSegment] = []
    var tint: Color = .white
    var chapterStarts: [Double] = []
    var onSeek: (Double) -> Void
    @State private var dragValue: Double?

    var body: some View {
        GeometryReader { g in
            let w = max(g.size.width, 1)
            let value = dragValue ?? current
            let frac = duration > 0 ? min(max(value / duration, 0), 1) : 0
            let barHeight: CGFloat = dragValue == nil ? 4 : 7
            let knob: CGFloat = dragValue == nil ? 12 : 18
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.28)).frame(height: barHeight)
                if duration > 0 {
                    ForEach(segments) { s in
                        Rectangle()
                            .fill(Color(hex: s.category.colorHex))
                            .frame(width: max(2, w * (s.end - s.start) / duration), height: barHeight)
                            .offset(x: w * s.start / duration)
                    }
                }
                Capsule().fill(tint).frame(width: w * frac, height: barHeight)
                if duration > 0 {
                    // Small breaks in the bar mark where chapters begin.
                    ForEach(chapterStarts.filter { $0 > 0 }, id: \.self) { s in
                        Rectangle()
                            .fill(.black.opacity(0.6))
                            .frame(width: 2, height: barHeight)
                            .offset(x: w * s / duration - 1)
                    }
                }
                Circle()
                    .fill(tint)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.25), radius: 2)
                    .offset(x: w * frac - knob / 2)
            }
            .frame(width: w, height: g.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        guard duration > 0 else { return }
                        dragValue = duration * min(max(v.location.x / w, 0), 1)
                    }
                    .onEnded { _ in
                        if let d = dragValue { onSeek(d) }
                        dragValue = nil
                    }
            )
            .animation(.easeOut(duration: 0.15), value: dragValue == nil)
            .overlay(alignment: .topLeading) {
                if let d = dragValue {
                    Text(formatTime(d))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                        .offset(x: min(max(w * frac - 24, 0), w - 56), y: -30)
                }
            }
        }
        .frame(height: 24)
        .sensoryFeedback(.selection, trigger: dragValue == nil)
    }
}

let playbackSpeeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

func speedLabel(_ r: Double) -> String { r == 1 ? "Normal" : String(format: "%g×", r) }

/// Playback speed as a checkmarked list.
struct SpeedMenu<MenuLabel: View>: View {
    @Environment(PlayerController.self) private var player
    @ViewBuilder var label: () -> MenuLabel

    var body: some View {
        Menu {
            Picker("Playback speed", selection: Binding(get: { Double(player.rate) }, set: { player.setRate(Float($0)) })) {
                ForEach(playbackSpeeds, id: \.self) { Text(speedLabel($0)).tag($0) }
            }
        } label: {
            label()
        }
    }
}

/// Music's "More" menu: actions that make sense for a song (no video resolutions).
struct MusicMoreMenu<MenuLabel: View>: View {
    @Environment(PlayerController.self) private var player
    @ViewBuilder var label: () -> MenuLabel

    var body: some View {
        Menu {
            Button { player.startRadio() } label: {
                Label("Start radio from this song", systemImage: "dot.radiowaves.left.and.right")
            }
            if let id = player.current?.videoId, let url = URL(string: "https://music.youtube.com/watch?v=\(id)") {
                ShareLink(item: url) { Label("Share song", systemImage: "square.and.arrow.up") }
            }
            Picker(selection: Binding(get: { Double(player.rate) }, set: { player.setRate(Float($0)) })) {
                ForEach(playbackSpeeds, id: \.self) { Text(speedLabel($0)).tag($0) }
            } label: {
                Label("Speed · " + speedLabel(Double(player.rate)), systemImage: "gauge.with.dots.needle.67percent")
            }
            .pickerStyle(.menu)
            SleepTimerMenu()
        } label: {
            label()
        }
    }
}

/// Quality / speed / audio-only menu.
struct QualityMenu<MenuLabel: View>: View {
    @Environment(PlayerController.self) private var player
    @ViewBuilder var label: () -> MenuLabel

    var body: some View {
        Menu {
            if let s = player.stream, !s.options.isEmpty {
                Section("Quality") {
                    choice(title: "Auto" + (player.selectedOption == nil && !player.audioOnly
                                            ? (player.playingResolution.map { " · \($0)" } ?? "") : ""),
                           selected: player.selectedOption == nil && !player.audioOnly) { player.select(nil) }
                    ForEach(s.options) { o in
                        choice(title: o.label + (o.badge.map { "  \($0)" } ?? ""),
                               subtitle: o.codec.uppercased(),
                               selected: player.selectedOption?.id == o.id && !player.audioOnly) { player.select(o) }
                    }
                }
            }
            if player.stream?.isLive != true {
                Toggle(isOn: Binding(get: { player.audioOnly }, set: { player.setAudioOnly($0) })) {
                    Label("Audio only", systemImage: "headphones")
                }
            }
            SleepTimerMenu()
            Menu {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { r in
                    choice(title: r == 1 ? "Normal" : String(format: "%g×", r), selected: abs(Double(player.rate) - r) < 0.01) {
                        player.setRate(Float(r))
                    }
                }
            } label: {
                Label("Speed · " + (player.rate == 1 ? "Normal" : String(format: "%g×", player.rate)), systemImage: "gauge.with.dots.needle.67percent")
            }
        } label: {
            label()
        }
    }

    @ViewBuilder
    private func choice(title: String, subtitle: String? = nil, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if selected {
                Label { Text(title); if let subtitle { Text(subtitle) } } icon: { Image(systemName: "checkmark") }
            } else {
                Text(title)
                if let subtitle { Text(subtitle) }
            }
        }
    }
}

/// Controls drawn over the video.
struct PlayerOverlay: View {
    var fullscreen: Bool
    var onToggleFullscreen: () -> Void
    @Environment(PlayerController.self) private var player
    @State private var visible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var seekFlash: Int?

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                tapZone(-10)
                tapZone(10)
            }

            if visible { controls.transition(.opacity) }

            if let s = seekFlash {
                Label("10", systemImage: s < 0 ? "gobackward" : "goforward")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.black.opacity(0.45), in: Capsule())
                    .frame(maxWidth: .infinity, alignment: s < 0 ? .leading : .trailing)
                    .padding(.horizontal, 40)
                    .allowsHitTesting(false)
            }

            if (player.isLoading || player.isBuffering) && player.loadError == nil {
                ProgressView().tint(.white).controlSize(.large).allowsHitTesting(false)
            }

            if let err = player.loadError {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                    Text(err)
                        .font(.subheadline.weight(.medium))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                    Button { player.retry() } label: {
                        Label("Try again", systemImage: "arrow.clockwise")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .glassEffect(.regular.interactive(), in: .capsule)
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(.white)
                .padding(24)
                .frame(maxWidth: 360)
            }

            VStack {
                if let n = player.notice {
                    Text(n)
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: Capsule())
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(.top, 50)
                }
                Spacer()
                if let seg = player.manualSegment {
                    Button { player.skipManualSegment() } label: {
                        Label("Skip \(seg.category.title.lowercased())", systemImage: "forward.end.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .frame(height: 40)
                            .glassEffect(.regular.interactive(), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 14)
                    .padding(.bottom, visible ? 72 : 16)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                } else if player.highlight != nil {
                    Button { player.jumpToHighlight() } label: {
                        Label("Jump to highlight", systemImage: "sparkles")
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 14)
                    .padding(.bottom, visible ? 64 : 14)
                }
            }
            .animation(.snappy, value: player.notice)
            .animation(.snappy, value: player.manualSegment?.id)
        }
        .animation(.easeInOut(duration: 0.2), value: visible)
        .onAppear { scheduleHide() }
        .onChange(of: player.isPlaying) { _, playing in
            if playing { scheduleHide() } else { visible = true; hideTask?.cancel() }
        }
    }

    private func tapZone(_ delta: Double) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                player.skip(by: delta)
                seekFlash = Int(delta)
                Task { try? await Task.sleep(nanoseconds: 600_000_000); seekFlash = nil }
            }
            .onTapGesture {
                visible.toggle()
                if visible { scheduleHide() }
            }
    }

    private var controls: some View {
        ZStack {
            // A light scrim keeps white text legible on bright video without a heavy gradient.
            LinearGradient(colors: [.black.opacity(0.35), .clear, .clear, .black.opacity(0.5)],
                           startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                GlassEffectContainer(spacing: 10) {
                    HStack(spacing: 10) {
                        glassIcon(fullscreen ? "xmark" : "chevron.down",
                                  label: fullscreen ? "Exit full screen" : "Minimize") {
                            if fullscreen { onToggleFullscreen() } else { player.presentation = .mini }
                        }
                        Spacer()
                        if let pip = player.pip, AVPictureInPictureController.isPictureInPictureSupported() {
                            glassIcon("pip.enter", label: "Picture in Picture") { pip.startPictureInPicture() }
                        }
                        QualityMenu {
                            Image(systemName: "gearshape")
                                .font(.body.weight(.semibold))
                                .frame(width: 40, height: 40)
                                .glassEffect(.regular.interactive(), in: .circle)
                        }
                        .accessibilityLabel("Quality and speed")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, fullscreen ? 16 : 10)

                Spacer()

                if player.loadError == nil {
                GlassEffectContainer(spacing: 24) {
                    HStack(spacing: fullscreen ? 40 : 28) {
                        transport("backward.end.fill", size: 46, label: "Previous") { player.previous() }
                            .opacity(player.index > 0 ? 1 : 0)
                            .disabled(player.index == 0)
                        Button { player.togglePlay(); scheduleHide() } label: {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: fullscreen ? 34 : 28, weight: .semibold))
                                .contentTransition(.symbolEffect(.replace))
                                .frame(width: fullscreen ? 78 : 66, height: fullscreen ? 78 : 66)
                                .glassEffect(.regular.interactive(), in: .circle)
                        }
                        .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                        transport("forward.end.fill", size: 46, label: "Next") { player.next(); scheduleHide() }
                    }
                }
                }

                Spacer()

                VStack(spacing: 2) {
                    CurrentChapterButton()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    LiveScrubber(tint: .white) { scheduleHide() }
                    HStack(spacing: 10) {
                        if player.stream?.isLive == true {
                            Label("LIVE", systemImage: "dot.radiowaves.left.and.right").foregroundStyle(.red)
                        } else {
                            ElapsedLabel(style: .elapsedOfTotal)
                        }
                        Spacer()
                        if let r = player.playingResolution, !player.audioOnly {
                            Text(r)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .glassEffect(.regular, in: .capsule)
                        }
                        Button(action: onToggleFullscreen) {
                            Image(systemName: fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                                .font(.callout.weight(.semibold))
                                .frame(width: 32, height: 32)
                        }
                        .accessibilityLabel(fullscreen ? "Exit full screen" : "Full screen")
                    }
                    .font(.caption.weight(.semibold).monospacedDigit())
                }
                .padding(.horizontal, 16)
                .padding(.bottom, fullscreen ? 14 : 6)
            }
            .foregroundStyle(.white)
            .buttonStyle(.plain)
        }
    }

    private func glassIcon(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button { action(); scheduleHide() } label: {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .frame(width: 40, height: 40)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .accessibilityLabel(label)
    }

    private func transport(_ symbol: String, size: CGFloat, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .frame(width: size, height: size)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .accessibilityLabel(label)
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled, player.isPlaying else { return }
            visible = false
        }
    }
}

// MARK: Time-driven leaf views
// The player publishes its time 4× a second. Only these small views read it, so the
// rest of the controls / pages are not re-rendered on every tick.

struct LiveScrubber: View {
    var tint: Color
    var onSeek: () -> Void = {}
    @Environment(PlayerController.self) private var player

    var body: some View {
        Scrubber(current: player.currentTime, duration: player.duration, segments: player.segments, tint: tint,
                 chapterStarts: player.extras?.chapters.map(\.start) ?? []) {
            player.seek(to: $0)
            onSeek()
        }
    }
}

struct ElapsedLabel: View {
    enum Style { case elapsedOfTotal, elapsed, remaining }
    var style: Style
    @Environment(PlayerController.self) private var player

    var body: some View {
        switch style {
        case .elapsedOfTotal: Text("\(formatTime(player.currentTime)) / \(formatTime(player.duration))")
        case .elapsed: Text(formatTime(player.currentTime))
        case .remaining: Text("-" + formatTime(max(player.duration - player.currentTime, 0)))
        }
    }
}

struct ProgressLine: View {
    @Environment(PlayerController.self) private var player

    var body: some View {
        GeometryReader { g in
            Capsule().fill(.tint)
                .frame(width: player.duration > 0 ? g.size.width * min(max(player.currentTime / player.duration, 0), 1) : 0,
                       height: 2)
        }
        .frame(height: 2)
    }
}

// MARK: Chapters

/// The chapter the playhead is in; tap for the full list.
struct CurrentChapterButton: View {
    @Environment(PlayerController.self) private var player
    @State private var showList = false

    var body: some View {
        let chapters = player.extras?.chapters ?? []
        if let current = chapters.last(where: { $0.start <= player.currentTime + 0.5 }) {
            Button { showList = true } label: {
                HStack(spacing: 4) {
                    Text(current.title).lineLimit(1)
                    Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Chapter: \(current.title). Show chapters")
            .sheet(isPresented: $showList) {
                NavigationStack {
                    ScrollView { ChapterList(chapters: chapters) { showList = false }.padding(16) }
                        .navigationTitle("Chapters")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarPinnedTrailing) {
                                Button("Done", systemImage: "checkmark") { showList = false }
                            }
                        }
                }
                .presentationDetents([.medium, .large])
            }
        }
    }
}

/// Vertical list of chapters with thumbnails; the current one is highlighted.
struct ChapterList: View {
    var chapters: [Chapter]
    var onPick: () -> Void = {}
    @Environment(PlayerController.self) private var player

    var body: some View {
        let currentStart = chapters.last(where: { $0.start <= player.currentTime + 0.5 })?.start
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(chapters) { c in
                Button {
                    player.seek(to: c.start)
                    onPick()
                } label: {
                    HStack(spacing: 12) {
                        Thumbnail(url: c.thumbnail, duration: formatTime(c.start), corner: 8).frame(width: 112)
                        Text(c.title)
                            .font(.subheadline.weight(c.start == currentStart ? .semibold : .regular))
                            .foregroundStyle(c.start == currentStart ? Color.accentColor : .primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Horizontal chapter cards for the watch page.
struct ChaptersRow: View {
    @Environment(PlayerController.self) private var player

    var body: some View {
        let chapters = player.extras?.chapters ?? []
        if !chapters.isEmpty {
            let currentStart = chapters.last(where: { $0.start <= player.currentTime + 0.5 })?.start
            VStack(alignment: .leading, spacing: 10) {
                Text("Chapters").font(.headline)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(chapters) { c in
                            Button { player.seek(to: c.start) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Thumbnail(url: c.thumbnail, duration: formatTime(c.start), corner: 10)
                                        .overlay {
                                            if c.start == currentStart {
                                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                    .strokeBorder(Color.accentColor, lineWidth: 2.5)
                                            }
                                        }
                                    Text(c.title)
                                        .font(.footnote.weight(c.start == currentStart ? .semibold : .regular))
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                }
                                .frame(width: 150)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

// MARK: Sleep timer

/// Sleep timer choices, as a submenu.
struct SleepTimerMenu: View {
    @Environment(PlayerController.self) private var player

    var body: some View {
        Menu {
            Button("Off") { player.setSleepTimer(minutes: nil) }
            ForEach([15, 30, 45, 60, 90], id: \.self) { m in
                Button("\(m) minutes") { player.setSleepTimer(minutes: m) }
            }
            Button(player.current?.isMusic == true ? "End of song" : "End of video") { player.setSleepAtEnd() }
        } label: {
            Label(label, systemImage: "moon.zzz")
        }
    }

    private var label: String {
        if player.sleepAtEnd { return "Sleep timer · End of " + (player.current?.isMusic == true ? "song" : "video") }
        if let at = player.sleepAt {
            let mins = max(1, Int(ceil(at.timeIntervalSinceNow / 60)))
            return "Sleep timer · \(mins) min"
        }
        return "Sleep timer"
    }
}
