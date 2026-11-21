import SwiftUI

/// The minimized video: just the picture, floating in a corner above the app (videos only;
/// music and audio-only keep the bar). Tap to open, double-tap to play / pause, drag to
/// another corner, fling it off the side to stop. Long-press for the same actions.
struct FloatingMiniPlayer: View {
    @Environment(PlayerController.self) private var player
    @Environment(AppRouter.self) private var router
    @AppStorage("miniPlayerCorner.v2") private var cornerRaw = Corner.bottomTrailing.rawValue
    @State private var drag: CGSize = .zero
    @State private var leaving: CGFloat = 0

    enum Corner: String, CaseIterable {
        case topLeading, topTrailing, bottomLeading, bottomTrailing
        var isLeading: Bool { self == .topLeading || self == .bottomLeading }
        var isTop: Bool { self == .topLeading || self == .topTrailing }
    }

    private var corner: Corner { Corner(rawValue: cornerRaw) ?? .bottomTrailing }

    var body: some View {
        GeometryReader { g in
            let width = min(max(g.size.width * 0.44, 170), 280)
            let height = width * 9 / 16
            let home = position(for: corner, in: g, size: CGSize(width: width, height: height))

            video
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12))
                }
                .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .onTapGesture(count: 2) { player.togglePlay() }
                .onTapGesture { player.presentation = .expanded }
                .contextMenu {
                    Button { player.presentation = .expanded } label: { Label("Open", systemImage: "arrow.up.left.and.arrow.down.right") }
                    Button { player.togglePlay() } label: {
                        Label(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill")
                    }
                    Button(role: .destructive) { player.close() } label: { Label("Close", systemImage: "xmark") }
                }
                .position(x: home.x + drag.width + leaving, y: home.y + drag.height)
                .gesture(
                    DragGesture(coordinateSpace: .global)
                        .onChanged { drag = $0.translation }
                        .onEnded { v in end(v, in: g, size: CGSize(width: width, height: height), from: home) }
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Mini player: \(player.current?.title ?? "")")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { player.presentation = .expanded }
                .accessibilityAction(named: player.isPlaying ? "Pause" : "Play") { player.togglePlay() }
                .accessibilityAction(named: "Close") { player.close() }
        }
        // Whole window: positions come from the bars' measured room (`contentInsets`).
        .ignoresSafeArea()
    }

    private var video: some View {
        ZStack {
            Color.black
            // Primary surface while minimized, so Picture in Picture still works from here.
            PlayerSurface(primary: true)
            if player.isLoading || player.isBuffering {
                ProgressView().tint(.white)
            } else if !player.isPlaying {
                Image(systemName: "play.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(10)
                    .glassEffect(.regular, in: .circle)
            }
        }
    }

    /// Corner centres, clear of the bars: inside the room the current tab's content has
    /// (under the navigation bar, beside a vertical tab bar, above a bottom one).
    private func position(for corner: Corner, in g: GeometryProxy, size: CGSize) -> CGPoint {
        let inset: CGFloat = 12
        var room = router.contentInsets
        if room.top < 20 { room.top = 100 }        // not measured yet: typical bars
        if room.bottom < 20 { room.bottom = 90 }
        let x = corner.isLeading ? room.leading + inset + size.width / 2
                                 : g.size.width - room.trailing - inset - size.width / 2
        let y = corner.isTop ? room.top + inset + size.height / 2
                             : g.size.height - room.bottom - inset - size.height / 2
        return CGPoint(x: x, y: y)
    }

    private func end(_ v: DragGesture.Value, in g: GeometryProxy, size: CGSize, from home: CGPoint) {
        let flungX = v.predictedEndTranslation.width
        let atX = home.x + v.translation.width
        // Thrown past a side edge: stop playing.
        if abs(flungX) > 240, (flungX < 0 ? atX < g.size.width * 0.3 : atX > g.size.width * 0.7) {
            withAnimation(.easeIn(duration: 0.18)) {
                leaving = flungX < 0 ? -g.size.width : g.size.width
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 180_000_000)
                player.close()
                drag = .zero
                leaving = 0
            }
            return
        }
        // Otherwise settle in the nearest corner to where it was heading.
        let end = CGPoint(x: home.x + v.predictedEndTranslation.width, y: home.y + v.predictedEndTranslation.height)
        let target = Corner.allCases.min { a, b in
            dist(position(for: a, in: g, size: size), end) < dist(position(for: b, in: g, size: size), end)
        } ?? corner
        let newHome = position(for: target, in: g, size: size)
        // Keep it where it is visually, then glide into the corner.
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            drag = CGSize(width: home.x + v.translation.width - newHome.x, height: home.y + v.translation.height - newHome.y)
            cornerRaw = target.rawValue
        }
        withAnimation(.smooth(duration: 0.3)) { drag = .zero }
    }

    private func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
}
