import SwiftUI

struct LibraryView: View {
    @Environment(AccountStore.self) private var accounts
    @Environment(\.screenClass) private var screen
    @State private var playlists: [PlaylistItem] = []
    @State private var loadedGeneration: Int?

    var body: some View {
        Group {
            if accounts.isSignedIn {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        shortcuts
                        if !playlists.isEmpty {
                            Text("Playlists").font(.title3.weight(.bold))
                                .padding(.horizontal, Metrics.gutter(screen))
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: screen == .expanded ? 240 : 160), spacing: 16, alignment: .top)],
                                      spacing: 20) {
                                ForEach(playlists) { PlaylistCard(playlist: $0) }
                            }
                            .padding(.horizontal, Metrics.gutter(screen))
                        }
                    }
                    .padding(.vertical, 12)
                }
                .task(id: accounts.generation) {
                    if loadedGeneration == accounts.generation { return }
                    playlists = (try? await YouTubeService.shared.libraryPlaylists()) ?? []
                    loadedGeneration = accounts.generation
                }
                .refreshable {
                    playlists = (try? await YouTubeService.shared.libraryPlaylists()) ?? playlists
                }
            } else {
                SignInPrompt(message: "Sign in to see your history, Watch later, liked videos and playlists.")
            }
        }
        .navigationTitle("Library")
    }

    private var shortcuts: some View {
        let items: [(String, String, Route)] = [
            ("History", "clock.arrow.circlepath", .history),
            ("Watch later", "clock", .watchLater),
            ("Liked videos", "hand.thumbsup", .liked),
            ("Liked songs", "heart", .musicLiked),
            ("Music playlists", "music.note.list", .musicPlaylists),
        ]
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: screen == .expanded ? 220 : 150), spacing: 12)], spacing: 12) {
            ForEach(items, id: \.0) { item in
                NavigationLink(value: item.2) {
                    HStack(spacing: 12) {
                        Image(systemName: item.1)
                            .font(.headline)
                            .foregroundStyle(.tint)
                            .frame(width: 26)
                        Text(item.0).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .background(Color.cardFill, in: RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Metrics.gutter(screen))
    }
}
