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
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.title2)
                    Text(err).font(.subheadline).multilineTextAlignment(.center)
                    Button("Retry") { player.playQueue(at: player.index) }
                        .buttonStyle(.borderedProminent)
                }
                .foregroundStyle(.white)
                .padding(24)
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
                if player.highlight != nil {
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
            LinearGradient(colors: [.black.opacity(0.55), .clear, .clear, .black.opacity(0.7)],
                           startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                HStack(spacing: 18) {
                    Button {
                        if fullscreen { onToggleFullscreen() } else { player.presentation = .mini }
                    } label: {
                        Image(systemName: fullscreen ? "xmark" : "chevron.down")
                    }
                    Spacer()
                    if let pip = player.pip, AVPictureInPictureController.isPictureInPictureSupported() {
                        Button { pip.startPictureInPicture() } label: { Image(systemName: "pip.enter") }
                    }
                    QualityMenu { Image(systemName: "gearshape") }
                }
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.top, fullscreen ? 20 : 12)

                Spacer()

                HStack(spacing: fullscreen ? 64 : 44) {
                    Button { player.previous() } label: { Image(systemName: "backward.end.fill").font(.title3) }
                        .opacity(player.index > 0 ? 1 : 0.0001)
                    Button { player.togglePlay(); scheduleHide() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: fullscreen ? 46 : 38, weight: .semibold))
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 64, height: 64)
                    }
                    Button { player.next(); scheduleHide() } label: { Image(systemName: "forward.end.fill").font(.title3) }
                }

                Spacer()

                VStack(spacing: 4) {
                    Scrubber(current: player.currentTime, duration: player.duration, segments: player.segments) {
                        player.seek(to: $0); scheduleHide()
                    }
                    HStack {
                        if player.stream?.isLive == true {
                            Label("LIVE", systemImage: "dot.radiowaves.left.and.right").foregroundStyle(.red)
                        } else {
                            Text("\(formatTime(player.currentTime)) / \(formatTime(player.duration))")
                        }
                        Spacer()
                        if let r = player.playingResolution, !player.audioOnly {
                            Text(r).foregroundStyle(.white.opacity(0.75))
                        }
                        Button(action: onToggleFullscreen) {
                            Image(systemName: fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                                .font(.callout.weight(.semibold))
                        }
                        .padding(.leading, 10)
                    }
                    .font(.caption.weight(.medium).monospacedDigit())
                }
                .padding(.horizontal, 16)
                .padding(.bottom, fullscreen ? 18 : 8)
            }
            .foregroundStyle(.white)
            .buttonStyle(.plain)
        }
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
