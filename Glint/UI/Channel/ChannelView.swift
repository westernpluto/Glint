import SwiftUI

struct ChannelView: View {
    var channelId: String
    var name: String?
    @State private var page: ChannelPage?
    @Environment(\.screenClass) private var screen

    var body: some View {
        FeedScreen(reloadKey: channelId, emptyTitle: "No videos", emptyIcon: "film") {
            let p = try await YouTubeService.shared.channel(channelId)
            await MainActor.run { page = p }
            return p.feed
        } header: {
            header
        }
        .navigationTitle(page?.name ?? name ?? "")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let banner = page?.banner {
                Color.clear
                    .aspectRatio(screen == .expanded ? 6.2 : 4, contentMode: .fit)
                    .overlay { RemoteImage(url: banner) }
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
            }
            HStack(spacing: 14) {
                Avatar(url: page?.avatar, size: screen == .expanded ? 80 : 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(page?.name ?? name ?? "").font(.title2.weight(.bold)).lineLimit(2)
                    if let s = page?.subscribers { Text(s).font(.subheadline).foregroundStyle(.secondary) }
                }
                Spacer()
                SubscribeButton(channelId: channelId, initial: nil)
            }
        }
        .padding(.horizontal, Metrics.gutter(screen))
        .padding(.top, 8)
        .padding(.bottom, 12)
    }
}

/// Subscribe / unsubscribe toggle (needs an account).
struct SubscribeButton: View {
    var channelId: String
    var initial: Bool?
    @State private var subscribed: Bool?
    @State private var busy = false
    @Environment(AccountStore.self) private var accounts

    var body: some View {
        if accounts.isSignedIn {
            let on = subscribed ?? initial ?? false
            Group {
                if on {
                    Button("Subscribed", systemImage: "checkmark") { toggle(on) }
                        .buttonStyle(.glass)
                } else {
                    Button("Subscribe") { toggle(on) }
                        .buttonStyle(.glassProminent)
                }
            }
            .font(.subheadline.weight(.semibold))
            .disabled(busy)
            .sensoryFeedback(.selection, trigger: subscribed)
        }
    }

    private func toggle(_ on: Bool) {
        busy = true
        Task {
            do {
                try await YouTubeService.shared.setSubscribed(!on, channelId: channelId)
                subscribed = !on
            } catch {}
            busy = false
        }
    }
}
