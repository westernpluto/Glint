import SwiftUI

struct HomeView: View {
    @Environment(AccountStore.self) private var accounts
    @Environment(AppSettings.self) private var settings

    var body: some View {
        FeedScreen(reloadKey: "\(accounts.generation)-\(settings.hideShorts)",
                   emptyTitle: "Your feed is empty",
                   emptyIcon: "house") {
            try await YouTubeService.shared.home()
        } header: {
            if !accounts.isSignedIn {
                SignedOutBanner()
            }
        }
        .navigationTitle("Home")
    }
}

private struct SignedOutBanner: View {
    @State private var showSignIn = false
    @Environment(\.screenClass) private var screen

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Make it yours").font(.subheadline.weight(.semibold))
                Text("Sign in for recommendations and subscriptions. Search works without an account.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Sign in") { showSignIn = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(14)
        .background(Color.cardFill, in: RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
        .padding(.horizontal, Metrics.gutter(screen))
        .padding(.vertical, 8)
        .sheet(isPresented: $showSignIn) { SignInView() }
    }
}

struct SubscriptionsView: View {
    @Environment(AccountStore.self) private var accounts
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Group {
            if accounts.isSignedIn {
                FeedScreen(reloadKey: "\(accounts.generation)-\(settings.hideShorts)",
                           emptyTitle: "No new videos",
                           emptyIcon: "play.square.stack") {
                    try await YouTubeService.shared.subscriptions()
                }
            } else {
                SignInPrompt(message: "Sign in to see the latest videos from channels you subscribe to.")
            }
        }
        .navigationTitle("Subscriptions")
    }
}

struct HistoryView: View {
    @Environment(AccountStore.self) private var accounts

    var body: some View {
        FeedScreen(reloadKey: accounts.generation, emptyTitle: "No history", emptyIcon: "clock.arrow.circlepath") {
            try await YouTubeService.shared.history()
        }
        .navigationTitle("History")
    }
}

struct PlaylistView: View {
    var playlistId: String
    var title: String?
    @State private var loadedTitle: String?
    @State private var firstVideo: VideoItem?
    @State private var videos: [VideoItem] = []
    @Environment(PlayerController.self) private var player
    @Environment(\.screenClass) private var screen

    var body: some View {
        FeedScreen(reloadKey: playlistId, emptyTitle: "Empty playlist", emptyIcon: "list.bullet") {
            let r = try await YouTubeService.shared.playlist(playlistId)
            await MainActor.run {
                loadedTitle = r.title
                videos = r.feed.items.compactMap(\.video)
            }
            return r.feed
        } header: {
            if !videos.isEmpty {
                HStack(spacing: 12) {
                    Button { playAll(shuffle: false) } label: {
                        Label("Play all", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button { playAll(shuffle: true) } label: {
                        Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)
                .padding(.horizontal, Metrics.gutter(screen))
                .padding(.vertical, 8)
                .frame(maxWidth: 520)
            }
        }
        .navigationTitle(loadedTitle ?? title ?? "Playlist")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func playAll(shuffle: Bool) {
        var list = videos
        if shuffle { list.shuffle() }
        player.playList(list)
    }
}
