import SwiftUI

/// What the player did and what YouTube answered, for diagnosing playback problems
/// on a real connection. Copy it and send it along with a bug report.
struct PlaybackInfoView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(PlayerController.self) private var player
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(player.diagnosticsReport)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                    Color.clear.frame(height: 1).id("end")
                }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
            .navigationTitle("Playback info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        UIPasteboard.general.string = player.diagnosticsReport
                        copied = true
                    }
                }
            }
            .sensoryFeedback(.success, trigger: copied)
        }
    }
}
