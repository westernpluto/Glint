import SwiftUI

/// Full-window player host. Chooses the video watch page or the music "Now playing" page,
/// and the right layout for the cover or inner screen.
struct PlayerScreen: View {
    @Environment(PlayerController.self) private var player
    @Environment(\.screenClass) private var screen
    @Environment(\.containerSize) private var size
    @State private var drag: CGFloat = 0

    var body: some View {
        let isMusic = player.current?.isMusic == true
        let landscapeCover = screen == .compact && size.width > size.height
        Group {
            if player.isFullscreen || (landscapeCover && !isMusic && !player.audioOnly) {
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

/// Drag down to shrink the player into the mini bar.
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

// MARK: Video box

struct VideoBox: View {
    var fullscreen = false
    @Environment(PlayerController.self) private var player
    @Environment(\.screenClass) private var screen

    var body: some View {
        ZStack {
            Color.black
            PlayerSurface(primary: true)
            if player.audioOnly, let t = player.current?.thumbnail {
                RemoteImage(url: t)
                    .overlay(.black.opacity(0.35))
                    .overlay { Image(systemName: "headphones").font(.largeTitle).foregroundStyle(.white.opacity(0.9)) }
                    .clipped()
            }
            PlayerOverlay(fullscreen: fullscreen) { toggleFullscreen() }
        }
    }

    private func toggleFullscreen() {
        let goingFull = !player.isFullscreen
        withAnimation(.easeInOut(duration: 0.25)) { player.isFullscreen = goingFull }
        if screen == .compact {
            Orientation.request(goingFull ? .landscape : .portrait)
        }
    }
}

struct FullscreenPlayer: View {
    @Binding var drag: CGFloat

    var body: some View {
        VideoBox(fullscreen: true)
            .ignoresSafeArea()
            .statusBarHidden()
            .persistentSystemOverlays(.hidden)
            .collapsesPlayer($drag)
    }
}

// MARK: Watch page

struct WatchView: View {
    @Binding var drag: CGFloat
    @Environment(PlayerController.self) private var player
    @Environment(\.screenClass) private var screen
    @Environment(\.containerSize) private var size
    @State private var channelSheet: Route?

    var body: some View {
        Group {
            if screen == .expanded && size.width >= 1000 {
                // Inner screen, landscape: theatre player + details on the left, Up next on the right.
                HStack(alignment: .top, spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            VideoBox().aspectRatio(16 / 9, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .collapsesPlayer($drag)
                                .padding([.horizontal, .top], 20)
                            WatchDetails(channelSheet: $channelSheet).padding(20)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    Divider()
                    ScrollView { UpNextList().padding(.vertical, 20) }
                        .frame(width: min(max(size.width * 0.32, 340), 460))
                }
            } else if screen == .expanded {
                // Inner screen, portrait: wide player on top, details and Up next side by side.
                VStack(spacing: 0) {
                    VideoBox().aspectRatio(16 / 9, contentMode: .fit)
                        .collapsesPlayer($drag)
                    ScrollView {
                        HStack(alignment: .top, spacing: 24) {
                            WatchDetails(channelSheet: $channelSheet).frame(maxWidth: .infinity)
                            UpNextList(compactRows: true).frame(width: size.width * 0.42)
                        }
                        .padding(20)
                    }
                }
            } else {
                // Cover screen.
                VStack(spacing: 0) {
                    VideoBox().aspectRatio(16 / 9, contentMode: .fit)
                        .collapsesPlayer($drag)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            WatchDetails(channelSheet: $channelSheet)
                            UpNextList()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                    }
                }
            }
        }
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .sheet(item: $channelSheet) { route in
            NavigationStack {
                Group {
                    if case .channel(let id, let name) = route { ChannelView(channelId: id, name: name) }
                }
                .withRoutes()
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { channelSheet = nil } } }
            }
        }
        .onChange(of: player.current?.videoId) { _, _ in channelSheet = nil }
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
    @State private var expanded = false
    @State private var liked = false

    var body: some View {
        let d = player.details
        let item = player.current
        VStack(alignment: .leading, spacing: 14) {
            Text(d?.title ?? item?.title ?? "")
                .font(.title3.weight(.bold))
                .lineLimit(expanded ? nil : 3)
                .textSelection(.enabled)

            Text(meta)
                .font(.footnote)
                .foregroundStyle(.secondary)

            actions

            if let d {
                HStack(spacing: 12) {
                    Button {
                        if let id = d.channelId { channelSheet = .channel(id: id, name: d.channelName) }
                    } label: {
                        HStack(spacing: 12) {
                            Avatar(url: player.extras?.channelAvatar, size: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(d.channelName).font(.subheadline.weight(.semibold)).lineLimit(1)
                                if let s = player.extras?.subscriberCount {
                                    Text(s).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    if let id = d.channelId {
                        SubscribeButton(channelId: id, initial: player.extras?.isSubscribed)
                            .id(id + "\(player.extras?.isSubscribed == true)")
                    }
                }

                if !d.description.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(linkified(d.description))
                            .font(.subheadline)
                            .lineLimit(expanded ? nil : 3)
                            .textSelection(.enabled)
                        Button(expanded ? "Show less" : "Show more") {
                            withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                        }
                        .font(.footnote.weight(.semibold))
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.cardFill, in: RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
                }
            }
        }
        .onChange(of: player.current?.videoId) { _, _ in expanded = false; liked = false }
    }

    private var meta: String {
        var parts: [String] = []
        if let v = player.details?.viewCount {
            parts.append(v.formatted(.number.notation(.compactName)) + " views")
        }
        if let date = player.extras?.dateText { parts.append(date) }
        if let r = player.playingResolution, !player.audioOnly { parts.append(r) }
        return parts.joined(separator: " · ")
    }

    private var actions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if accounts.isSignedIn, let id = player.current?.videoId {
                    pill(liked ? "Liked" : (player.extras?.likeCount ?? "Like"),
                         icon: liked ? "hand.thumbsup.fill" : "hand.thumbsup") {
                        let now = !liked
                        liked = now
                        Task { try? await YouTubeService.shared.rate(id, now ? .like : .none) }
                    }
                    pill("Save", icon: "clock") {
                        Task {
                            try? await YouTubeService.shared.saveToWatchLater(id)
                            player.flash("Saved to Watch later")
                        }
                    }
                } else if let likes = player.extras?.likeCount {
                    pill(likes, icon: "hand.thumbsup") {}
                        .disabled(true)
                }
                QualityMenu {
                    pillLabel(player.selectedOption?.label ?? (player.audioOnly ? "Audio" : "Auto"), icon: "slider.horizontal.3")
                }
                pill(player.audioOnly ? "Video" : "Audio only", icon: player.audioOnly ? "play.rectangle" : "headphones") {
                    player.setAudioOnly(!player.audioOnly)
                }
                if let id = player.current?.videoId, let url = URL(string: "https://youtu.be/\(id)") {
                    ShareLink(item: url) { pillLabel("Share", icon: "square.and.arrow.up") }
                }
            }
        }
        .scrollClipDisabled()
    }

    private func pill(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { pillLabel(title, icon: icon) }.buttonStyle(.plain)
    }

    private func pillLabel(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.cardFill, in: Capsule())
            .foregroundStyle(.primary)
    }

    private func linkified(_ s: String) -> AttributedString {
        var a = AttributedString(s)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return a }
        let ns = s as NSString
        for m in detector.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            guard let url = m.url, let r = Range(m.range, in: s),
                  let lower = AttributedString.Index(r.lowerBound, within: a),
                  let upper = AttributedString.Index(r.upperBound, within: a) else { continue }
            a[lower..<upper].link = url
        }
        return a
    }
}

// MARK: Up next

struct UpNextList: View {
    var compactRows = false
    @Environment(PlayerController.self) private var player
    @Environment(AppSettings.self) private var settings
    @Environment(\.screenClass) private var screen

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            let upcoming = Array(player.queue.enumerated()).filter { $0.offset > player.index }
            if !upcoming.isEmpty {
                Text("Queue").font(.headline)
                ForEach(upcoming, id: \.element.id) { pair in
                    Button { player.playQueue(at: pair.offset) } label: {
                        HStack(spacing: 12) {
                            Thumbnail(url: pair.element.thumbnail, duration: nil, corner: 8).frame(width: 96)
                            Text(pair.element.title).font(.subheadline).lineLimit(2).foregroundStyle(.primary)
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                }
                Divider().padding(.vertical, 4)
            }

            HStack {
                Text("Up next").font(.headline)
                Spacer()
                Toggle("Autoplay", isOn: Binding(get: { settings.autoplay }, set: { settings.autoplay = $0 }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.mini)
                Text("Autoplay").font(.caption).foregroundStyle(.secondary)
            }

            if let related = player.extras?.related, !related.isEmpty {
                ForEach(related) { v in
                    if screen == .compact && !compactRows {
                        VideoRow(video: v, thumbWidth: 150)
                    } else {
                        VideoRow(video: v, thumbWidth: compactRows ? 132 : 160)
                    }
                }
            } else if player.extras == nil && player.details != nil {
                ForEach(0..<5, id: \.self) { _ in
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 10).fill(.quaternary).aspectRatio(16 / 9, contentMode: .fit).frame(width: 150)
                        VStack(alignment: .leading, spacing: 6) {
                            RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(height: 12)
                            RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 90, height: 10)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, screen == .expanded && !compactRows ? 16 : 0)
    }
}
