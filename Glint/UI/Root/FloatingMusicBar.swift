import SwiftUI

/// The minimized player for music and audio only: a roomy floating bar above the tab bar
/// (replacing the small system accessory). Big artwork, title and artist, play / pause and
/// next, and the song's progress along the bottom edge. Tap or swipe up to open, swipe down
/// to stop, swipe sideways for next / previous. Long-press for the same actions.
struct FloatingMusicBar: View {
    @Environment(PlayerController.self) private var player
    @Environment(AppRouter.self) private var router
    @State private var drag: CGSize = .zero

    static let height: CGFloat = 68

    var body: some View {
        GeometryReader { g in
            let f = Self.frame(in: g.size, insets: router.contentInsets)
            if let item = player.current {
                bar(item)
                    .frame(width: f.width, height: f.height)
                    .offset(x: drag.width * 0.4, y: max(drag.height, -24) * 0.6)
                    .opacity(drag.height > 0 ? 1 - min(drag.height / 160, 0.6) : 1)
                    .position(x: f.midX, y: f.midY)
                    .gesture(
                        DragGesture(minimumDistance: 10, coordinateSpace: .global)
                            .onChanged { drag = $0.translation }
                            .onEnded(end)
                    )
            }
        }
        .ignoresSafeArea()
    }

    /// Bottom of the content area, clear of a bottom tab bar or a side (vertical) one.
    static func frame(in container: CGSize, insets: EdgeInsets) -> CGRect {
        let margin: CGFloat = 12
        var room = insets
        if room == EdgeInsets() { room.bottom = 90 }   // not measured yet: a typical tab bar
        let width = min(container.width - room.leading - room.trailing - margin * 2, 640)
        let x = room.leading + (container.width - room.leading - room.trailing - width) / 2
        let y = container.height - room.bottom - margin - height
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func bar(_ item: QueueItem) -> some View {
        HStack(spacing: 12) {
            RemoteImage(url: Artwork.sharp(item.thumbnail, size: 240), fallback: item.thumbnail)
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(player.details?.title ?? item.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(item.subtitle ?? player.details?.channelName ?? "")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { player.togglePlay() } label: {
                ZStack {
                    if player.isLoading { ProgressView() } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: 46, height: 46)
                .contentShape(Rectangle())
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Button { player.next() } label: {
                Image(systemName: "forward.fill")
                    .font(.title3)
                    .frame(width: 42, height: 46)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Next")
        }
        .foregroundStyle(.primary)
        .buttonStyle(.plain)
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            BarProgress()
                .padding(.horizontal, 18)
                .padding(.bottom, 3)
        }
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture { player.presentation = .expanded }
        .contextMenu {
            Button { player.presentation = .expanded } label: { Label("Open", systemImage: "chevron.up") }
            Button { player.previous() } label: { Label("Previous", systemImage: "backward.fill") }
            Button(role: .destructive) { player.close() } label: { Label("Stop playing", systemImage: "xmark") }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Open") { player.presentation = .expanded }
        .accessibilityAction(named: "Stop playing") { player.close() }
    }

    private func end(_ v: DragGesture.Value) {
        let dx = v.translation.width, dy = v.translation.height
        let pdy = v.predictedEndTranslation.height, pdx = v.predictedEndTranslation.width
        if abs(dy) > abs(dx) {
            if dy < -30 || pdy < -120 {
                player.presentation = .expanded                  // swipe up: open
            } else if dy > 60 || pdy > 220 {
                withAnimation(.easeIn(duration: 0.15)) { drag.height = 200 }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    player.close()                               // swipe down: stop
                    drag = .zero
                }
                return
            }
        } else if abs(dx) > 70 || abs(pdx) > 260 {
            if dx < 0 { player.next() } else { player.previous() }   // sideways: skip
        }
        withAnimation(.smooth(duration: 0.25)) { drag = .zero }
    }
}

/// Thin progress line for the bar (only this view reads the playhead).
private struct BarProgress: View {
    @Environment(PlayerController.self) private var player

    var body: some View {
        GeometryReader { g in
            let p = player.duration > 0 ? min(max(player.currentTime / player.duration, 0), 1) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.12))
                Capsule().fill(Color.accentColor).frame(width: g.size.width * p)
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}

/// Sharper artwork URLs: Google image URLs at a larger size; YouTube thumbnails as the
/// full-frame 16:9 versions (no letterbox bars) — maxres when big, else mqdefault.
/// Use with `RemoteImage(fallback:)` (maxres doesn't exist for every video).
enum Artwork {
    static func sharp(_ url: URL?, size: Int) -> URL? {
        guard let url else { return nil }
        let s = url.absoluteString
        if s.contains("googleusercontent.com") || s.contains("ggpht.com") {
            if s.range(of: "=w\\d+-h\\d+", options: .regularExpression) != nil { return Parser.upscale(url, to: size) }
            if let r = s.range(of: "=s\\d+", options: .regularExpression) {
                return URL(string: s.replacingCharacters(in: r, with: "=s\(size)"))
            }
            return url
        }
        if url.host?.contains("ytimg.com") == true,
           let r = s.range(of: "/vi(_webp)?/[^/]+/", options: .regularExpression) {
            let base = s[..<r.upperBound]
            return URL(string: base + (size > 300 ? "maxresdefault.jpg" : "mqdefault.jpg"))
        }
        return url
    }
}
