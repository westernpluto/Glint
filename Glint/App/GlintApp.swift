import SwiftUI

@main
struct GlintApp: App {
    @State private var accounts = AccountStore.shared
    @State private var player = PlayerController.shared
    @State private var settings = AppSettings.shared
    @State private var router = AppRouter.shared

    init() {
        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20)
        // Signed-in resume bars on feeds update the account's watch progress.
        Parser.onResumeProgress = { items in
            Task { @MainActor in WatchHistory.shared.mergeRemote(items) }
        }
        Task {
            await InnerTube.shared.warmUp()
            try? await Task.sleep(for: .seconds(2))   // let the first screen load first
            await StreamResolver.shared.prewarm()
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(accounts)
                .environment(player)
                .environment(settings)
                .environment(router)
                .tint(Color("AccentColor"))
                .task { await accounts.refreshActive() }
        }
    }
}
