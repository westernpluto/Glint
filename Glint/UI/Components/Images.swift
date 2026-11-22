import ImageIO
import SwiftUI

/// Thumbnail/artwork loader: memory cache + request coalescing + off-main downsampled decoding.
/// Raw bytes are also cached on disk by URLCache.
final class ImagePipeline: @unchecked Sendable {
    static let shared = ImagePipeline()
    /// Big enough for full-width cards and Now Playing artwork on 3× displays.
    static let maxPixelSize: CGFloat = 1280

    private let cache = NSCache<NSURL, UIImage>()
    private let lock = NSLock()
    private var inflight: [URL: Task<UIImage?, Never>] = [:]

    private init() {
        cache.totalCostLimit = 150 << 20
        cache.countLimit = 600
    }

    func cached(_ url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }

    func image(_ url: URL) async -> UIImage? {
        if let hit = cached(url) { return hit }
        let task: Task<UIImage?, Never> = lock.withLock {
            if let running = inflight[url] { return running }
            let t = Task.detached(priority: .utility) { () -> UIImage? in
                guard let (data, resp) = try? await URLSession.shared.data(from: url),
                      (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true
                else { return nil }
                return ImagePipeline.decode(data)
            }
            inflight[url] = t
            return t
        }
        let image = await task.value
        lock.withLock { inflight[url] = nil }
        if let image, let cg = image.cgImage {
            cache.setObject(image, forKey: url as NSURL, cost: cg.bytesPerRow * cg.height)
        }
        return image
    }

    private static func decode(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,      // decode now, not on the main thread at draw time
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return UIImage(data: data) }
        return UIImage(cgImage: cg)
    }
}

struct RemoteImage: View {
    var url: URL?
    var contentMode: ContentMode = .fill
    /// Shown instead when `url` can't be loaded (e.g. a hi-res size that doesn't exist).
    var fallback: URL? = nil
    @State private var loaded: UIImage?
    @State private var loadedURL: URL?

    var body: some View {
        // Cache hits render synchronously, so scrolling back never flashes a placeholder.
        let image = (loadedURL == url ? loaded : nil) ?? url.flatMap { ImagePipeline.shared.cached($0) }
            ?? fallback.flatMap { ImagePipeline.shared.cached($0) }
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .animation(.easeOut(duration: 0.2), value: image != nil)
        .task(id: url) {
            guard let url, ImagePipeline.shared.cached(url) == nil else { return }
            var img = await ImagePipeline.shared.image(url)
            if img == nil, let fallback { img = await ImagePipeline.shared.image(fallback) }
            guard !Task.isCancelled else { return }
            loaded = img
            loadedURL = url
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
    /// When set, shows how much of this video you've already watched.
    var videoId: String? = nil
    /// YouTube's own progress for it (signed in), 0–100, from the feed this card came from.
    var watchedPercent: Double? = nil

    var body: some View {
        // Signed in, the account's progress (what YouTube sent with the card, else the latest
        // known for the video); signed out, what was watched on this iPhone.
        let fromCard = AccountStore.shared.isSignedIn ? watchedPercent.map { min(max($0 / 100, 0), 1) } : nil
        let watched = fromCard.flatMap { $0 > 0 ? $0 : nil } ?? videoId.flatMap { WatchHistory.shared.progress(for: $0) }
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay { RemoteImage(url: url) }
            .overlay(alignment: .bottomTrailing) {
                if isLive {
                    Badge(text: "LIVE", tint: .red)
                        .padding(.bottom, watched == nil ? 0 : 4)
                } else if let duration, !duration.isEmpty {
                    Badge(text: duration)
                        .padding(.bottom, watched == nil ? 0 : 4)
                }
            }
            .overlay(alignment: .bottom) {
                if let watched {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.white.opacity(0.35))
                            Rectangle().fill(Color.accentColor).frame(width: g.size.width * watched)
                        }
                    }
                    .frame(height: 4)
                    .accessibilityLabel("\(Int(watched * 100))% watched")
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
