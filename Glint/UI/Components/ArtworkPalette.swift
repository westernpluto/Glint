import CoreImage
import SwiftUI
import UIKit

/// Two colours taken from artwork (top and bottom halves), deepened so white text stays
/// legible on top of them. Used to tint Now Playing like the artwork.
@MainActor
final class ArtworkPalette {
    static let shared = ArtworkPalette()
    private var cache: [URL: [Color]] = [:]

    func colors(for url: URL) async -> [Color]? {
        if let hit = cache[url] { return hit }
        guard let image = await ImagePipeline.shared.image(url), let cg = image.cgImage else { return nil }
        let colors = await Task.detached(priority: .utility) { ArtworkPalette.extract(cg) }.value
        if cache.count > 80 { cache.removeAll() }
        cache[url] = colors
        return colors
    }

    nonisolated private static func extract(_ cg: CGImage) -> [Color] {
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        let image = CIImage(cgImage: cg)
        let e = image.extent
        // Core Image's origin is bottom-left, so the top half starts at midY.
        let top = CGRect(x: e.minX, y: e.midY, width: e.width, height: e.height / 2)
        let bottom = CGRect(x: e.minX, y: e.minY, width: e.width, height: e.height / 2)
        return [top, bottom].map { tone(average(image, in: $0, context: context)) }
    }

    nonisolated private static func average(_ image: CIImage, in rect: CGRect, context: CIContext) -> UIColor {
        guard let filter = CIFilter(name: "CIAreaAverage",
                                    parameters: [kCIInputImageKey: image, kCIInputExtentKey: CIVector(cgRect: rect)]),
              let output = filter.outputImage else { return .darkGray }
        var px = [UInt8](repeating: 0, count: 4)
        context.render(output, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return UIColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
    }

    /// Richer and darker, so the background reads as colour but never fights the text.
    nonisolated private static func tone(_ c: UIColor) -> Color {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: Double(h), saturation: Double(min(1, s * 1.2)), brightness: Double(min(max(b * 0.75, 0.16), 0.42)))
    }
}
