import SwiftUI

/// Which Home view is showing: your personal feed or a curated topic.
enum HomeTab: Hashable {
    case forYou
    case topic(ExploreTopic)
}

/// Topic chips across the top of Home.
struct HomeChips: View {
    var selection: HomeTab
    var onSelect: (HomeTab) -> Void
    @Environment(AccountStore.self) private var accounts
    @Environment(\.screenClass) private var screen

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    if accounts.isSignedIn {
                        GlassChip(title: "For you", icon: "person.fill", selected: selection == .forYou) { onSelect(.forYou) }
                    }
                    ForEach(ExploreTopic.allCases) { t in
                        GlassChip(title: t.title, icon: t.icon, selected: selection == .topic(t)) { onSelect(.topic(t)) }
                    }
                }
            }
            .padding(.horizontal, Metrics.gutter(screen))
            .padding(.vertical, 4)
        }
    }
}

/// A capsule chip in Liquid Glass; the selected one is tinted with the accent colour.
struct GlassChip: View {
    var title: String
    var icon: String?
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let icon {
                    Label(title, systemImage: icon)
                } else {
                    Text(title)
                }
            }
            .font(.subheadline.weight(selected ? .semibold : .medium))
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .glassEffect(selected ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Curated shelves: a featured hero, then titled horizontal rows.
struct ExploreFeed<Header: View>: View {
    var topic: ExploreTopic
    @ViewBuilder var header: () -> Header

    @Environment(AccountStore.self) private var accounts
    @Environment(\.screenClass) private var screen
    @State private var cache: [ExploreTopic: [FeedSection]] = [:]
    @State private var error: Error?
    @State private var loading = false
    @AppStorage("signInStripDismissed") private var stripDismissed = false

    private var sections: [FeedSection] { cache[topic] ?? [] }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: screen == .expanded ? 34 : 26) {
                header()
                if !accounts.isSignedIn && !stripDismissed {
                    SignInStrip { withAnimation { stripDismissed = true } }
                }
                if let first = sections.first, let hero = first.items.first {
                    HeroCard(video: hero, eyebrow: first.title)
                }
                ForEach(Array(sections.enumerated()), id: \.offset) { i, section in
                    ShelfRow(section: section, dropFirst: i == 0)
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 28)
        }
        .overlay {
            if sections.isEmpty {
                if let error, !loading {
                    ErrorState(error: error) { Task { await load(force: true) } }
                } else {
                    ProgressView().controlSize(.large)
                }
            }
        }
        .refreshable { await load(force: true) }
        .task(id: topic) { await load(force: false) }
    }

    private func load(force: Bool) async {
        if !force, cache[topic] != nil { return }
        let t = topic
        loading = true
        defer { loading = false }
        do {
            let result = try await YouTubeService.shared.explore(t)
            cache[t] = result
            error = nil
        } catch is CancellationError {
        } catch {
            if (error as? URLError)?.code == .cancelled { return }
            if cache[t] == nil { self.error = error }
        }
    }
}

/// A titled, horizontally scrolling row of video cards.
struct ShelfRow: View {
    var section: FeedSection
    var dropFirst = false
    @Environment(\.screenClass) private var screen
    @Environment(\.containerSize) private var container

    var body: some View {
        let items = dropFirst ? Array(section.items.dropFirst()) : section.items
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(section.title)
                    .font(.title3.weight(.bold))
                    .lineLimit(1)
                    .padding(.horizontal, Metrics.gutter(screen))
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 16) {
                        ForEach(items) { VideoCard(video: $0).frame(width: cardWidth) }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, Metrics.gutter(screen), for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
            }
        }
    }

    /// Big enough to read, small enough that the next card peeks in as a scroll hint.
    private var cardWidth: CGFloat {
        screen == .expanded ? 300 : min(300, max(236, container.width * 0.7))
    }
}

/// The featured video at the top of a topic.
struct HeroCard: View {
    var video: VideoItem
    var eyebrow: String
    @Environment(PlayerController.self) private var player
    @Environment(\.screenClass) private var screen

    var body: some View {
        Group {
            if screen == .expanded { wide } else { compact }
        }
        .padding(.horizontal, Metrics.gutter(screen))
        .contextMenu { VideoMenu(video: video) }
    }

    /// Full-bleed thumbnail with the title on a gradient.
    private var compact: some View {
        Button { player.play(video) } label: {
            Thumbnail(url: video.bestThumbnail, duration: video.duration, isLive: video.isLive, corner: 22, videoId: video.id)
                .overlay {
                    LinearGradient(colors: [.clear, .clear, .black.opacity(0.78)], startPoint: .top, endPoint: .bottom)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(eyebrow.uppercased())
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                        Text(video.title)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(video.subtitle)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                    }
                    .padding(16)
                    .padding(.trailing, 56)
                }
        }
        .buttonStyle(.plain)
    }

    /// Thumbnail beside the details, with a prominent Play button.
    private var wide: some View {
        HStack(alignment: .center, spacing: 28) {
            Button { player.play(video) } label: {
                Thumbnail(url: video.bestThumbnail, duration: video.duration, isLive: video.isLive, corner: 22, videoId: video.id)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 12) {
                Text(eyebrow.uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tint)
                    .lineLimit(1)
                Text(video.title)
                    .font(.title2.weight(.bold))
                    .lineLimit(3)
                if let c = video.channelName {
                    HStack(spacing: 8) {
                        Avatar(url: video.channelAvatar, size: 28)
                        Text(c).font(.subheadline.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                let meta = [video.views, video.published].compactMap { $0 }.joined(separator: " · ")
                if !meta.isEmpty {
                    Text(meta).font(.footnote).foregroundStyle(.secondary)
                }
                Button { player.play(video) } label: {
                    Label("Play", systemImage: "play.fill")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .frame(height: 46)
                        .glassEffect(.regular.tint(.accentColor).interactive(), in: .capsule)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            .frame(width: 300, alignment: .leading)
        }
    }
}

/// A one-line, dismissible sign-in prompt (replaces the old full banner).
struct SignInStrip: View {
    var onDismiss: () -> Void
    @State private var showSignIn = false
    @Environment(\.screenClass) private var screen

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.title3)
                .foregroundStyle(.tint)
            Text("Sign in to see your subscriptions")
                .font(.subheadline)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Sign in") { showSignIn = true }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 10)
        .background(Color.cardFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, Metrics.gutter(screen))
        .sheet(isPresented: $showSignIn) { SignInView() }
    }
}
