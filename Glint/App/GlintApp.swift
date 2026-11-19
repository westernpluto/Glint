import SwiftUI

@main
struct GlintApp: App {
    @State private var accounts = AccountStore.shared
    @State private var player = PlayerController.shared
    @State private var settings = AppSettings.shared

    init() {
        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20)
        Task { await InnerTube.shared.warmUp() }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(accounts)
                .environment(player)
                .environment(settings)
                .tint(Color("AccentColor"))
                .task { await accounts.refreshActive() }
        }
    }
}
