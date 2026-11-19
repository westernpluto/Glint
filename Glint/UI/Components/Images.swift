import SwiftUI

struct RemoteImage: View {
    var url: URL?
    var contentMode: ContentMode = .fill

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: contentMode)
            default:
                Rectangle().fill(.quaternary)
            }
        }
    }
}

struct Avatar: View {
    var url: URL?
    var size: CGFloat
    var placeholder = "person.circle.fill"

    var body: some View {
        Group {
            if let url {
                RemoteImage(url: url)
            } else {
                Image(systemName: placeholder)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

/// 16:9 thumbnail with duration / live badge.
struct Thumbnail: View {
    var url: URL?
    var duration: String?
    var isLive = false
    var corner: CGFloat = Metrics.corner

    var body: some View {
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay { RemoteImage(url: url) }
            .overlay(alignment: .bottomTrailing) {
                if isLive {
                    Badge(text: "LIVE", tint: .red)
                } else if let duration, !duration.isEmpty {
                    Badge(text: duration)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

struct Badge: View {
    var text: String
    var tint: Color = .black.opacity(0.75)

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(tint, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .padding(6)
    }
}

extension Color {
    static let cardFill = Color(uiColor: .secondarySystemBackground)
}
