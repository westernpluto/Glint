import SwiftUI

/// The minimized video: the picture floating in a corner above the app (videos only; music
/// and audio only get the floating bar), with play / pause and close buttons. Tap to open,
/// drag to another corner, fling it off the side to stop. Long-press for the same actions.
struct FloatingMiniPlayer: View {
    @Environment(PlayerController.self) private var player
    @Environment(AppRouter.self) private var router
    @AppStorage(FloatingMiniPlayer.cornerKey) private var cornerRaw = Corner.bottomTrailing.rawValue
    static let cornerKey = "miniPlayerCorner.v2"
    static let cornerRadius: CGFloat = 14
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
            let width = Self.frame(corner: corner, in: g.size, insets: router.contentInsets).width
            let height = width * 9 / 16
            let home = position(for: corner, in: g, size: CGSize(width: width, height: height))

            video
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
                .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
                // Single tap only (a double-tap gesture made every tap wait to see if a second
                // one followed); play / pause has its own button.
                .onTapGesture { expand() }
                .overlay(alignment: .topTrailing) {
                    miniButton("xmark", size: 26, label: "Close") { player.close() }
                        .padding(6)
                }
                .overlay(alignment: .bottomLeading) {
                    miniButton(player.isPlaying ? "pause.fill" : "play.fill", size: 34,
                               label: player.isPlaying ? "Pause" : "Play") { player.togglePlay() }
                        .padding(6)
                }
                .contextMenu {
                    Button { expand() } label: { Label("Open", systemImage: "arrow.up.left.and.arrow.down.right") }
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
                .accessibilityAction { expand() }
                .accessibilityAction(named: player.isPlaying ? "Pause" : "Play") { player.togglePlay() }
                .accessibilityAction(named: "Close") { player.close() }
        }
        // Whole window: positions come from the bars' measured room (`contentInsets`).
        .ignoresSafeArea()
    }

    /// Grow back into the watch page from right here (the page animates from this frame).
    private func expand() {
        player.expandFromMini = true
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { player.presentation = .expanded }
    }

    private func miniButton(_ symbol: String, size: CGFloat, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size, height: size)
                .glassEffect(.regular.interactive(), in: .circle)
                .padding(4)                       // larger hit area than it looks
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var video: some View {
        ZStack {
            Color.black
            // Primary surface while minimized, so Picture in Picture still works from here.
            PlayerSurface(primary: true)
            if player.isLoading || player.isBuffering {
                ProgressView().tint(.white)
            }
        }
    }

    /// Corner centres, clear of the bars (see `frame`).
    private func position(for corner: Corner, in g: GeometryProxy, size: CGSize) -> CGPoint {
        let f = Self.frame(corner: corner, in: g.size, insets: router.contentInsets)
        return CGPoint(x: f.midX, y: f.midY)
    }

    /// The mini player's frame in window coordinates: inside the room the current tab's
    /// content has (under the navigation bar, beside a vertical tab bar, above a bottom one).
    /// Shared with the watch page, which shrinks the video into exactly this frame.
    static func frame(corner: Corner, in container: CGSize, insets: EdgeInsets) -> CGRect {
        let width = min(max(container.width * 0.44, 170), 280)
        let size = CGSize(width: width, height: width * 9 / 16)
        let inset: CGFloat = 12
        var room = insets
        if room.top < 20 { room.top = 100 }        // not measured yet: typical bars
        if room.bottom < 20 { room.bottom = 90 }
        let x = corner.isLeading ? room.leading + inset : container.width - room.trailing - inset - size.width
        let y = corner.isTop ? room.top + inset : container.height - room.bottom - inset - size.height
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
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
        // A small nudge stays put; otherwise the corner nearest to where it was let go (with a
        // little momentum — the full projected fling could carry it to the opposite corner).
        guard hypot(v.translation.width, v.translation.height) > 48 else {
            withAnimation(.smooth(duration: 0.25)) { drag = .zero }
            return
        }
        let momentum = 0.25
        let end = CGPoint(x: home.x + v.translation.width + (v.predictedEndTranslation.width - v.translation.width) * momentum,
                          y: home.y + v.translation.height + (v.predictedEndTranslation.height - v.translation.height) * momentum)
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
