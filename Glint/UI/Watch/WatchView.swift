import AVKit
import SwiftUI

/// Full-window player host: the video watch page, the music Now Playing page, or the
/// immersive player.
struct PlayerScreen: View {
    @Environment(PlayerController.self) private var player
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.containerSize) private var container
    @Environment(AppRouter.self) private var router
    @State private var drag: CGFloat = 0
    /// 1 while growing out of the floating mini player, animated to 0 on appear.
    @State private var expanding: CGFloat = PlayerController.shared.expandFromMini ? 1 : 0

    var body: some View {
        let isMusic = player.current?.isMusic == true
        let videoMini = !isMusic && !player.audioOnly
        // A short display (outer screen held sideways) goes straight to an immersive player.
        let immersive = player.isFullscreen || (verticalSizeClass == .compact && videoMini)
        let musicProgress = max(min(drag / Self.musicCollapseDistance(container), 1), expanding)
        Group {
            if isMusic || player.audioOnly {
                Group {
                    if isMusic {
                        if immersive { FullscreenPlayer(drag: $drag) } else { NowPlayingView(drag: $drag) }
                    } else {
                        WatchView(drag: $drag)
                            .overlayPreferenceValue(VideoSlotKey.self) { slot in
                                SharedVideo(slot: slot, immersive: immersive, progress: 0, drag: $drag)
                            }
                    }
                }
                .offset(y: Self.musicCollapseDistance(container) * musicProgress)   // content rides with the card's top
                // Shrinks into the floating bar as you drag: the top edge follows the finger,
                // the sides and bottom close in on the bar's frame, and near the end the card
                // fades to reveal the bar itself (drawn here at the same place), so letting go
                // swaps in the real bar without a jump. Growing back out runs the same path.
                .mask {
                    GeometryReader { g in
                        let r = Self.musicCard(progress: musicProgress, window: g.size, insets: router.contentInsets)
                        RoundedRectangle(cornerRadius: min(musicProgress * 120, 22), style: .continuous)
                            .frame(width: r.width, height: r.height)
                            .position(x: r.midX, y: r.midY)
                    }
                    .ignoresSafeArea()
                }
                .opacity(musicProgress < 0.6 ? 1 : max(0, 1 - (musicProgress - 0.6) / 0.4))
                .background {
                    if musicProgress > 0.5 {
                        FloatingMusicBar(preview: true)
                            .opacity(min(1, (musicProgress - 0.5) / 0.2))
                    }
                }
            } else {
                // Video: one view for everything. The watch page only reserves the video's slot;
                // the player is drawn on top — in the slot, grown to the whole screen, or (while
                // dragging down / growing back) on its way to the floating mini player's corner,
                // as the page fades away behind it.
                let progress = max(min(drag / Self.collapseDistance(container), 1), expanding)
                WatchView(drag: $drag)
                    .opacity(1 - progress)
                    .allowsHitTesting(progress < 0.05)
                    .overlayPreferenceValue(VideoSlotKey.self) { slot in
                        SharedVideo(slot: slot, immersive: immersive, progress: progress, drag: $drag)
                    }
                    // No time / battery over the video while the player is up (they come back as
                    // it shrinks into the mini player).
                    .statusBarHidden(progress < 0.5)
                    .persistentSystemOverlays(immersive ? .hidden : .automatic)
            }
        }
        .onChange(of: player.presentation) { _, p in if p != .expanded { drag = 0 } }
        .onAppear {
            guard player.expandFromMini else { return }
            player.expandFromMini = false
            withAnimation(.smooth(duration: 0.34)) { expanding = 0 }
        }
    }

    /// How far to drag for the video to reach the mini player.
    static func collapseDistance(_ container: CGSize) -> CGFloat { max(container.height * 0.5, 280) }

    /// Music: how far to drag for the card's top to reach the bar's (so it tracks the finger).
    @MainActor static func musicCollapseDistance(_ container: CGSize) -> CGFloat {
        let router = AppRouter.shared
        guard router.windowSize.height > 0 else { return max(container.height * 0.7, 300) }
        return max(FloatingMusicBar.frame(in: router.windowSize, insets: router.contentInsets).minY, 200)
    }

    /// The music card's frame in the window, from full screen (0) to the bar (1).
    static func musicCard(progress p: CGFloat, window: CGSize, insets: EdgeInsets) -> CGRect {
        let bar = FloatingMusicBar.frame(in: window, insets: insets)
        let side = pow(p, 1.6)               // stays wide at first, narrows towards the end
        let minX = bar.minX * side
        let maxX = window.width + (bar.maxX - window.width) * side
        let minY = bar.minY * p
        let maxY = window.height + (bar.maxY - window.height) * pow(p, 0.8)
        return CGRect(x: minX, y: minY, width: max(maxX - minX, 1), height: max(maxY - minY, 1))
    }
}

/// Drag down to shrink the player into the mini player.
struct CollapseGesture: ViewModifier {
    @Binding var drag: CGFloat
    @Environment(PlayerController.self) private var player
    @Environment(\.containerSize) private var container

    func body(content: Content) -> some View {
        content.gesture(
            // Measured on the screen, not on the player: the player moves with the finger, so
            // local coordinates fed its own movement back into the drag and made it wobble.
            DragGesture(minimumDistance: 12, coordinateSpace: .global)
                .onChanged { v in
                    let dy = v.translation.height
                    guard abs(dy) > abs(v.translation.width) else { return }
                    // Follow the finger downwards only: moving up from the top would uncover the
                    // screen below the player.
                    drag = max(dy, 0)
                }
                .onEnded { v in
                    let close = v.translation.height > 110 || v.predictedEndTranslation.height > 260
                    if close {
                        // Finish the motion first, then hand off to the mini player without a second
                        // animation. Video: exactly into the mini player's place (progress 1).
                        let video = player.current?.isMusic != true && !player.audioOnly
                        let target = video ? PlayerScreen.collapseDistance(container) : PlayerScreen.musicCollapseDistance(container)
                        let duration = 0.26
                        withAnimation(.smooth(duration: duration)) { drag = target }
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: UInt64((duration - 0.01) * 1_000_000_000))
                            var t = Transaction()
                            t.disablesAnimations = true
                            withTransaction(t) {
                                player.isFullscreen = false
                                player.presentation = .mini
                                drag = 0
                            }
                        }
                    } else {
                        withAnimation(.smooth(duration: 0.3)) { drag = 0 }   // settle back, no overshoot
                    }
                }
        )
    }
}

extension View {
    func collapsesPlayer(_ drag: Binding<CGFloat>) -> some View { modifier(CollapseGesture(drag: drag)) }
}

// MARK: Shared video (inline ↔ fullscreen)

/// Where the watch page wants the video, and with what corner radius.
struct VideoSlot {
    var anchor: Anchor<CGRect>
    var corner: CGFloat
    /// Spans the window's full width (tall layout): the video runs under side bars, like the
    /// iPhone Duo outer display's status column, instead of stopping at the safe area.
    var fullWidth = false
}

struct VideoSlotKey: PreferenceKey {
    static let defaultValue: VideoSlot? = nil
    static func reduce(value: inout VideoSlot?, nextValue: () -> VideoSlot?) { value = nextValue() ?? value }
}

extension View {
    /// Reserves the video's place in the watch page (the player itself is drawn by `SharedVideo`).
    func videoSlot(corner: CGFloat, fullWidth: Bool = false) -> some View {
        anchorPreference(key: VideoSlotKey.self, value: .bounds) { VideoSlot(anchor: $0, corner: corner, fullWidth: fullWidth) }
    }
}

/// The single video view: in the watch page's slot, or the whole screen when immersive.
struct SharedVideo: View {
    var slot: VideoSlot?
    var immersive: Bool
    /// 0 = in place, 1 = at the floating mini player's frame.
    var progress: CGFloat = 0
    @Binding var drag: CGFloat
    @Environment(PlayerController.self) private var player
    @Environment(AppRouter.self) private var router
    @AppStorage(FloatingMiniPlayer.cornerKey) private var cornerRaw = FloatingMiniPlayer.Corner.bottomTrailing.rawValue

    var body: some View {
        GeometryReader { g in
            let full = CGRect(origin: .zero, size: g.size)
            let slotRect = slot.map { g[$0.anchor] } ?? .zero
            // Full-width slot: from the window's left edge to its right edge (the slot itself
            // stops at the safe area; its height is already sized for the full width).
            let home = immersive ? full
                : (slot?.fullWidth == true ? CGRect(x: 0, y: slotRect.minY, width: g.size.width, height: slotRect.height) : slotRect)
            let mini = FloatingMiniPlayer.frame(corner: FloatingMiniPlayer.Corner(rawValue: cornerRaw) ?? .bottomTrailing,
                                                in: g.size, insets: router.contentInsets)
            let p = min(max(progress, 0), 1)
            let rect = CGRect(x: lerp(home.minX, mini.minX, p), y: lerp(home.minY, mini.minY, p),
                              width: lerp(home.width, mini.width, p), height: lerp(home.height, mini.height, p))
            let corner = lerp(immersive ? 0 : (slot?.corner ?? 0), FloatingMiniPlayer.cornerRadius, p)
            ZStack(alignment: .topLeading) {
                Color.black
                    .opacity(immersive ? 1 - p : 0)
                    .allowsHitTesting(immersive && p < 0.05)
                if rect.width > 1 {
                    VideoBox(fullscreen: immersive, showsControls: p < 0.02)
                        .frame(width: rect.width, height: rect.height)
                        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                        .shadow(color: .black.opacity(0.35 * p), radius: 14 * p, y: 6 * p)
                        .overlay(alignment: .top) { if !immersive && p < 0.02 { GrabHandle() } }
                        .collapsesPlayer($drag)
                        .offset(x: rect.minX, y: rect.minY)
                }
            }
        }
        .ignoresSafeArea()
        .animation(.smooth(duration: 0.32), value: immersive)
    }
}

// MARK: Video

/// Just the picture: black backdrop, the video layer, and artwork in audio-only mode.
struct VideoSurfaceView: View {
    @Environment(PlayerController.self) private var player

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // The picture fills the whole box, also where the box runs under a side status
            // column (it was laid out inside the safe area: pushed left, black on the right).
            PlayerSurface(primary: true).ignoresSafeArea()
            if !player.audioOnly { CaptionOverlay() }
            if player.audioOnly, let t = player.current?.thumbnail {
                RemoteImage(url: t, contentMode: .fit)
                    .overlay {
                        Image(systemName: "headphones")
                            .font(.largeTitle)
                            .foregroundStyle(.white)
                            .padding(18)
                            .glassEffect(.regular, in: .circle)
                    }
            }
        }
    }
}

/// Video with its controls layered on top.
struct VideoBox: View {
    var fullscreen = false
    /// Off while the video is shrinking into the mini player.
    var showsControls = true
    @Environment(PlayerController.self) private var player
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        ZStack {
            VideoSurfaceView()
            if showsControls {
                PlayerOverlay(fullscreen: fullscreen) {
                    player.toggleFullscreen(from: fullscreen, rotate: horizontalSizeClass == .compact)
                }
            }
        }
    }
}

@inline(__always) func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

extension PlayerController {
    /// `from` is what is on screen now (fullscreen can also be automatic on a short display).
    func toggleFullscreen(from fullscreen: Bool, rotate: Bool) {
        let goingFull = !fullscreen
        withAnimation(.easeInOut(duration: 0.25)) { isFullscreen = goingFull }
        if rotate { Orientation.request(goingFull ? .landscape : .portrait) }
    }
}

/// Immersive player. On a half-folded iPhone Duo the overlay arrangement moves the
/// controls to one side of the fold and keeps the video on the other.
struct FullscreenPlayer: View {
    @Binding var drag: CGFloat
    @Environment(PlayerController.self) private var player
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if #available(iOS 27.1, *) {
                ArrangementView {
                    controls
                } secondary: {
                    VideoSurfaceView()
                }
                .arrangementViewStyle(.overlay)
            } else {
                ZStack {
                    VideoSurfaceView()
                    controls
                }
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .collapsesPlayer($drag)
    }

    private var controls: some View {
        PlayerOverlay(fullscreen: true) {
            player.toggleFullscreen(from: true, rotate: horizontalSizeClass == .compact)
        }
    }
}

// MARK: Watch page

struct WatchView: View {
    @Binding var drag: CGFloat
    @Environment(PlayerController.self) private var player
    @Environment(\.screenClass) private var screen
    @State private var channelSheet: Route?
    @State private var size: CGSize = .zero
    /// Side safe areas (the iPhone Duo outer display keeps its status bar in a column on the
    /// right): the tall layout's video extends under them instead of leaving a black strip.
    @State private var sideInsets: CGFloat = 0
    @State private var horizontalFold = false

    var body: some View {
        // Laptop/tabletop posture: a horizontal fold always means video above, details below.
        let wide = size.width > size.height && !horizontalFold
        // Read geometry without wrapping the ArrangementView in another layout container.
        arrangement(wide: wide, size: size)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.leading + $0.safeAreaInsets.trailing } action: { sideInsets = $0 }
            .onGeometryChange(for: Bool.self) { Fold.horizontal($0) != nil } action: { horizontalFold = $0 }
            // Tall: the whole page uses the full width, side safe areas included — the iPhone
            // Duo outer display's status column only holds anything up where the video is, so
            // details, buttons and comments below shouldn't stop short of it.
            .ignoresSafeArea(.container, edges: wide ? [] : .horizontal)
            .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .sheet(item: $channelSheet) { route in
            NavigationStack {
                Group {
                    if case .channel(let id, let name) = route { ChannelView(channelId: id, name: name) }
                }
                .withRoutes()
                .toolbar {
                    ToolbarItem(placement: .topBarPinnedTrailing) {
                        Button("Done", systemImage: "checkmark") { channelSheet = nil }
                    }
                }
            }
        }
        .onChange(of: player.current?.videoId) { _, _ in channelSheet = nil }
        .handlesSeekLinks()
    }

    @ViewBuilder
    private func arrangement(wide: Bool, size: CGSize) -> some View {
        // Tall: the video gets exactly its 16:9 height (capped at half the display).
        // Full-width 16:9, side safe areas included (the video runs under them).
        let videoShare = min(0.5, max(0.22, (size.width + sideInsets) * 9 / 16 / max(size.height, 1)))
        if #available(iOS 27.1, *) {
            ArrangementView {
                primary(wide: wide)
                    .splitArrangementLayoutRatio(wide ? 0.64 : videoShare)
            } secondary: {
                secondary(wide: wide)
            }
            .arrangementViewStyle(.split)
        } else if wide {
            HStack(spacing: 0) {
                primary(wide: true)
                Divider()
                secondary(wide: true).frame(width: size.width * 0.36)
            }
        } else {
            VStack(spacing: 0) {
                primary(wide: false).frame(height: size.height * videoShare)
                secondary(wide: false)
            }
        }
    }

    /// Wide: theatre player with details under it. Tall: just the video.
    @ViewBuilder
    private func primary(wide: Bool) -> some View {
        if wide {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Color.black
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .videoSlot(corner: 22)
                    WatchDetails(channelSheet: $channelSheet)
                }
                .padding(20)
            }
        } else {
            Color.black
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Out to the screen's sides, under a side status column.
                .videoSlot(corner: 0, fullWidth: true)
                // Extend the black stage under the status bar / vertical bar instead of leaving a strip.
                .background { Color.black.ignoresSafeArea() }
        }
    }

    /// Wide: Up next column. Tall: details then Up next (side by side on a large display).
    @ViewBuilder
    private func secondary(wide: Bool) -> some View {
        ScrollView {
            if wide {
                WatchSidePanel().padding(.horizontal, 16).padding(.vertical, 20)
            } else if screen == .expanded {
                HStack(alignment: .top, spacing: 28) {
                    WatchDetails(channelSheet: $channelSheet).frame(maxWidth: .infinity)
                    WatchSidePanel().frame(maxWidth: 420)
                }
                .padding(24)
            } else {
                VStack(alignment: .leading, spacing: 22) {
                    WatchDetails(channelSheet: $channelSheet)
                    CommentsPreview()
                    UpNextList()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
        }
        .scrollIndicators(.hidden)
    }
}

extension Route: Identifiable {
    var id: String { String(describing: self) }
}

// MARK: Details

struct WatchDetails: View {
    @Binding var channelSheet: Route?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(PlayerController.self) private var player
    @Environment(AccountStore.self) private var accounts
    @Environment(\.screenClass) private var screen
    @State private var expanded = false
    @State private var liked = false

    var body: some View {
        let d = player.details
        let item = player.current
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(d?.title ?? item?.title ?? " ")
                    .font(screen == .expanded ? .title2.weight(.bold) : .title3.weight(.bold))
                    .lineLimit(expanded ? nil : 3)
                    .textSelection(.enabled)
                if !meta.isEmpty {
                    Text(meta).font(.subheadline).foregroundStyle(.secondary)
                }
            }

            if let d {
                channelRow(d)
            }

            actions

            ChaptersRow()

            if let d, !d.description.isEmpty {
                description(d.description)
            }
        }
        .onChange(of: player.current?.videoId) { _, _ in expanded = false; liked = false }
        .onChange(of: player.extras?.isLiked) { _, v in liked = v ?? false }
    }

    private var meta: String {
        var parts: [String] = []
        if let v = player.details?.viewCount { parts.append(v.formatted(.number.notation(.compactName)) + " views") }
        if let date = player.extras?.dateText { parts.append(date) }
        if let r = player.playingResolution, !player.audioOnly { parts.append(r) }
        return parts.joined(separator: " · ")
    }

    private func channelRow(_ d: VideoDetails) -> some View {
        HStack(spacing: 12) {
            Button {
                if let id = d.channelId { channelSheet = .channel(id: id, name: d.channelName) }
            } label: {
                HStack(spacing: 12) {
                    Avatar(url: player.extras?.channelAvatar, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.channelName).font(.headline).lineLimit(1)
                        if let s = player.extras?.subscriberCount {
                            Text(s).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 8)
            if let id = d.channelId {
                SubscribeButton(channelId: id, initial: player.extras?.isSubscribed)
                    .id(id + "\(player.extras?.isSubscribed == true)")
            }
        }
    }

    /// The few things you do with a video, in one row. Playback settings live in the
    /// player's ⋯ menu, so they aren't repeated here.
    private var actions: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                if accounts.isSignedIn, let id = player.current?.videoId {
                    Button {
                        let now = !liked
                        liked = now
                        Task {
                            do { try await YouTubeService.shared.rate(id, now ? .like : .none) } catch {
                                // Didn't go through: show the real state again.
                                if liked == now { liked = !now }
                                player.flash("Couldn't update your like")
                            }
                        }
                    } label: {
                        pill(player.extras?.likeCount ?? "Like", liked ? "hand.thumbsup.fill" : "hand.thumbsup", on: liked)
                    }
                    .sensoryFeedback(.impact(weight: .light), trigger: liked)
                    Button {
                        Task {
                            do {
                                try await YouTubeService.shared.saveToWatchLater(id)
                                player.flash("Saved to Watch later")
                            } catch {
                                player.flash("Couldn't save to Watch later")
                            }
                        }
                    } label: { pill("Save", "bookmark") }
                } else if let likes = player.extras?.likeCount {
                    pill(likes, "hand.thumbsup", interactive: false)
                }
                if let id = player.current?.videoId {
                    ShareVideoMenu(videoId: id) { pill("Share", "square.and.arrow.up") }
                }
                Spacer(minLength: 0)
            }
            .buttonStyle(.plain)
        }
    }

    /// One shape, size and material for every action so the rows read as a set.
    /// `on` tints the pill so active states (liked, audio only, timer set) are obvious.
    private func pill(_ title: String, _ icon: String, interactive: Bool = true, on: Bool = false) -> some View {
        Label(title, systemImage: icon)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(on ? Color.white : Color.primary)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .glassEffect(on ? .regular.tint(.accentColor).interactive()
                         : (interactive ? .regular.interactive() : .regular), in: .capsule)
    }

    private func description(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(richText(text))
                .font(.subheadline)
                .lineLimit(expanded ? nil : 4)
                .textSelection(.enabled)
            Button(expanded ? "Show less" : "Show more") {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            }
            .font(.footnote.weight(.semibold))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardFill, in: RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
    }
}

// MARK: Up next

struct UpNextList: View {
    /// Off when a segmented control above already says "Up next".
    var showsTitle = true
    @Environment(PlayerController.self) private var player
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            let upcoming = Array(player.queue.enumerated()).filter { $0.offset > player.index }
            if !upcoming.isEmpty {
                Text("Queue").font(.title3.weight(.bold))
                ForEach(upcoming, id: \.element.id) { pair in
                    Button { player.playQueue(at: pair.offset) } label: {
                        HStack(spacing: 12) {
                            Thumbnail(url: pair.element.thumbnail, duration: nil, corner: 10).frame(width: 120)
                            Text(pair.element.title).font(.subheadline.weight(.medium)).lineLimit(2).foregroundStyle(.primary)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Divider().padding(.vertical, 2)
            }

            HStack(alignment: .center) {
                if showsTitle {
                    Text("Up next").font(.title3.weight(.bold))
                }
                Spacer()
                if !settings.autoplay {
                    Text("Autoplay off").font(.footnote).foregroundStyle(.secondary)
                }
            }

            if let related = player.extras?.related, !related.isEmpty {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(related) { VideoRow(video: $0, thumbWidth: 156) }
                }
            } else if player.extras == nil {
                ForEach(0..<6, id: \.self) { _ in
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                            .aspectRatio(16 / 9, contentMode: .fit).frame(width: 156)
                        VStack(alignment: .leading, spacing: 8) {
                            RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(height: 12)
                            RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 100, height: 10)
                        }
                    }
                }
            }
        }
    }
}

/// Left-aligned wrapping layout for pills and chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxWidth), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Always-visible hint that the player can be swiped down to the mini player.
struct GrabHandle: View {
    var body: some View {
        Capsule()
            .fill(.white.opacity(0.55))
            .frame(width: 36, height: 5)
            .shadow(color: .black.opacity(0.3), radius: 2)
            .padding(.top, 7)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Share the video, or share it starting where you are now.
struct ShareVideoMenu<MenuLabel: View>: View {
    var videoId: String
    @ViewBuilder var label: () -> MenuLabel
    @Environment(PlayerController.self) private var player

    var body: some View {
        Menu {
            if let url = URL(string: "https://youtu.be/\(videoId)") {
                ShareLink(item: url) { Label("Share video", systemImage: "square.and.arrow.up") }
            }
            // Read from AVPlayer directly: not observed, so this menu doesn't redraw every tick.
            let raw = player.player.currentTime().seconds
            let t = raw.isFinite ? Int(raw) : 0
            if t > 5, let url = URL(string: "https://youtu.be/\(videoId)?t=\(t)") {
                ShareLink(item: url) { Label("Share at \(formatTime(Double(t)))", systemImage: "clock") }
            }
        } label: {
            label()
        }
    }
}

/// The caption line for the current moment, drawn over the video.
struct CaptionOverlay: View {
    @Environment(PlayerController.self) private var player

    var body: some View {
        let line = player.captionCues.isEmpty ? nil : Captions.text(at: player.currentTime, in: player.captionCues)
        GeometryReader { g in
            if let text = line {
                Text(text)
                    .font(.system(size: max(14, min(g.size.width / 32, 26)), weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .frame(maxWidth: g.size.width * 0.86)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, max(18, g.size.height * 0.1))
                    .transition(.opacity)
                    .id(text)
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.12), value: line)
        .accessibilityHidden(true)
    }
}
