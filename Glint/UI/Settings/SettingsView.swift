import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AccountStore.self) private var accounts
    @Environment(AppSettings.self) private var settings
    @State private var showSignIn = false

    var body: some View {
        @Bindable var s = settings
        NavigationStack {
            Form {
                Section {
                    ForEach(accounts.accounts) { a in
                        Button { accounts.switchTo(a.id) } label: {
                            HStack(spacing: 12) {
                                Avatar(url: a.info.avatar, size: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(a.info.name).foregroundStyle(.primary)
                                    if let h = a.info.handle { Text(h).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                if a.id == accounts.activeID {
                                    Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
                                }
                            }
                        }
                        .swipeActions {
                            Button("Sign out", role: .destructive) { accounts.remove(a.id) }
                        }
                    }
                    Button { showSignIn = true } label: {
                        Label(accounts.accounts.isEmpty ? "Sign in with Google" : "Add another account",
                              systemImage: "person.crop.circle.badge.plus")
                    }
                    if accounts.isSignedIn {
                        Button("Browse signed out") { accounts.switchTo(nil) }
                    }
                } header: {
                    Text("Accounts")
                } footer: {
                    Text("Each account signs in separately and is stored only in this iPhone's Keychain. Swipe to sign out.")
                }

                Section("Playback") {
                    Picker("Default quality", selection: $s.defaultQuality) {
                        ForEach(AppSettings.qualityChoices, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    Toggle("Prefer HDR when available", isOn: $s.preferHDR)
                    Picker("Speed", selection: Binding(get: { settings.playbackSpeed },
                                                       set: { PlayerController.shared.setRate(Float($0)) })) {
                        ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { r in
                            Text(r == 1 ? "Normal" : String(format: "%g×", r)).tag(r)
                        }
                    }
                    Toggle("Autoplay next video", isOn: $s.autoplay)
                    Toggle("Background playback", isOn: $s.backgroundPlayback)
                    Toggle("Music plays audio only", isOn: $s.musicAudioOnly)
                }

                Section("Feeds") {
                    Toggle("Hide Shorts", isOn: $s.hideShorts)
                }

                Section {
                    Toggle("SponsorBlock", isOn: $s.sponsorBlockEnabled)
                    if settings.sponsorBlockEnabled {
                        ForEach(SponsorCategory.allCases.filter { $0 != .poi_highlight }) { c in
                            Picker(selection: Binding(
                                get: { settings.sponsorMode(c) },
                                set: { settings.setSponsorMode($0, for: c) })) {
                                ForEach(AppSettings.SponsorMode.allCases) { Text($0.title).tag($0) }
                            } label: {
                                HStack(spacing: 10) {
                                    Circle().fill(Color(hex: c.colorHex)).frame(width: 10, height: 10)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(c.title)
                                        Text(c.detail).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .pickerStyle(.menu)
                        }
                        Toggle("Show a notice when skipping", isOn: $s.showSkipNotice)
                    }
                } header: {
                    Text("SponsorBlock")
                } footer: {
                    Text("Community-submitted segments from sponsor.ajay.app. Lookups are anonymised with a partial hash of the video ID.")
                }

                Section {
                    LabeledContent("Ads", value: "Never shown")
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                } header: {
                    Text("About")
                } footer: {
                    Text("Glint talks to YouTube directly with its own player, so ads, promoted videos and sponsored shelves are never loaded.")
                }
            }
            .navigationTitle("Account & Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarPinnedTrailing) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
            .sheet(isPresented: $showSignIn) { SignInView() }
        }
    }
}
