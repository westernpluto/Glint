import SwiftUI

/// Full-window player host: the video watch page, the music Now Playing page, or the
/// immersive player.
struct PlayerScreen: View {
    @Environment(PlayerController.self) private var player
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var drag: CGFloat = 0

    var body: some View {
        let isMusic = player.current?.isMusic == true
        // A short display (outer screen held sideways) goes straight to an immersive player.
        let immersive = player.isFullscreen || (verticalSizeClass == .compact && !isMusic && !player.audioOnly)
        Group {
            if immersive {
                FullscreenPlayer(drag: $drag)
            } else if isMusic {
                NowPlayingView(drag: $drag)
            } else {
                WatchView(drag: $drag)
            }
        }
        .offset(y: drag)
        .onChange(of: player.presentation) { _, p in if p != .expanded { drag = 0 } }
    }
}

/// Drag down to shrink the player into the mini player.
struct CollapseGesture: ViewModifier {
    @Binding var drag: CGFloat
    @Environment(PlayerController.self) private var player

    func body(content: Content) -> some View {
        content.gesture(
            DragGesture(minimumDistance: 18)
                .onChanged { v in
                    if v.translation.height > 0, abs(v.translation.height) > abs(v.translation.width) {
                        drag = v.translation.height
                    }
                }
                .onEnded { v in
                    if v.translation.height > 140 || v.predictedEndTranslation.height > 320 {
                        player.isFullscreen = false
                        player.presentation = .mini
                    }
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { drag = 0 }
                }
        )
    }
}

extension View {
    func collapsesPlayer(_ drag: Binding<CGFloat>) -> some View { modifier(CollapseGesture(drag: drag)) }
}

// MARK: Video

/// Just the picture: black backdrop, the video layer, and artwork in audio-only mode.
struct VideoSurfaceView: View {
    @Environment(PlayerController.self) private var player

    var body: some View {
        ZStack {
            Color.black
            PlayerSurface(primary: true)
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
    @Environment(PlayerController.self) private var player
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        ZStack {
            VideoSurfaceView()
            PlayerOverlay(fullscreen: fullscreen) {
                player.toggleFullscreen(from: fullscreen, rotate: horizontalSizeClass == .compact)
            }
        }
    }
}

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
    @State private var horizontalFold = false

    var body: some View {
        // Laptop/tabletop posture: a horizontal fold always means video above, details below.
        let wide = size.width > size.height && !horizontalFold
        // Read geometry without wrapping the ArrangementView in another layout container.
        arrangement(wide: wide, size: size)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .onGeometryChange(for: Bool.self) { Fold.horizontal($0) != nil } action: { horizontalFold = $0 }
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
        let videoShare = min(0.5, max(0.22, size.width * 9 / 16 / max(size.height, 1)))
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
                    VideoBox()
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay(alignment: .top) { GrabHandle() }
                        .collapsesPlayer($drag)
                    WatchDetails(channelSheet: $channelSheet)
                }
                .padding(20)
            }
        } else {
            VideoBox()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Extend the black stage under the status bar / vertical bar instead of leaving a strip.
                .background { Color.black.ignoresSafeArea() }
                .overlay(alignment: .top) { GrabHandle() }
                .collapsesPlayer($drag)
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

    private var actions: some View {
        // Wraps onto more lines in narrow columns instead of clipping or scrolling sideways.
        GlassEffectContainer(spacing: 8) {
                FlowLayout(spacing: 8) {
                    if accounts.isSignedIn, let id = player.current?.videoId {
                        Button {
                            let now = !liked
                            liked = now
                            Task { try? await YouTubeService.shared.rate(id, now ? .like : .none) }
                        } label: {
                            pill(player.extras?.likeCount ?? "Like", liked ? "hand.thumbsup.fill" : "hand.thumbsup")
                        }
                        .sensoryFeedback(.impact(weight: .light), trigger: liked)
                        Button {
                            Task {
                                try? await YouTubeService.shared.saveToWatchLater(id)
                                player.flash("Saved to Watch later")
                            }
                        } label: { pill("Save", "clock") }
                    } else if let likes = player.extras?.likeCount {
                        pill(likes, "hand.thumbsup", interactive: false)
                    }
                    QualityMenu {
                        pill(player.audioOnly ? "Audio only" : "Quality · " + (player.selectedOption?.label ?? "Auto"),
                             player.audioOnly ? "headphones" : "slider.horizontal.3")
                    }
                    if let id = player.current?.videoId, let url = URL(string: "https://youtu.be/\(id)") {
                        ShareLink(item: url) { pill("Share", "square.and.arrow.up") }
                    }
                }
                .buttonStyle(.plain)
        }
    }

    /// One shape, size and material for every action so the row reads as a set.
    private func pill(_ title: String, _ icon: String, interactive: Bool = true) -> some View {
        Label(title, systemImage: icon)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .glassEffect(interactive ? .regular.interactive() : .regular, in: .capsule)
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
                Text("Up next").font(.title3.weight(.bold))
                Spacer()
                Toggle(isOn: Binding(get: { settings.autoplay }, set: { settings.autoplay = $0 })) {
                    Text("Autoplay").font(.subheadline).foregroundStyle(.secondary)
                }
                .toggleStyle(.switch)
                .fixedSize()
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
