import SwiftUI

/// A soft highlight sweeping across placeholder shapes (still when Reduce Motion is on).
struct Shimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                if !reduceMotion {
                    GeometryReader { g in
                        LinearGradient(colors: [.clear, .white.opacity(0.28), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: g.size.width * 0.6)
                            .offset(x: phase * g.size.width * 1.6)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}

extension View {
    func shimmering() -> some View { modifier(Shimmer()) }
}

private let placeholderFill = Color.secondary.opacity(0.14)

/// Placeholder shaped like a VideoCard.
struct SkeletonVideoCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
                .fill(placeholderFill)
                .aspectRatio(16 / 9, contentMode: .fit)
            HStack(alignment: .top, spacing: 12) {
                Circle().fill(placeholderFill).frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 4).fill(placeholderFill).frame(height: 13)
                    RoundedRectangle(cornerRadius: 4).fill(placeholderFill).frame(width: 140, height: 11)
                }
            }
        }
        .shimmering()
        .accessibilityHidden(true)
    }
}

/// Placeholder grid for feeds while the first page loads.
struct SkeletonFeed: View {
    @Environment(\.screenClass) private var screen

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: Metrics.gridMinimum(screen)), spacing: 20, alignment: .top)],
                  alignment: .leading, spacing: 24) {
            ForEach(0..<6, id: \.self) { _ in SkeletonVideoCard() }
        }
        .padding(.horizontal, Metrics.gutter(screen))
        .accessibilityLabel("Loading")
    }
}

/// Placeholder for a titled horizontal shelf.
struct SkeletonShelf: View {
    var square = false
    @Environment(\.screenClass) private var screen

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 5).fill(placeholderFill).frame(width: 170, height: 18)
                .padding(.horizontal, Metrics.gutter(screen))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(0..<4, id: \.self) { _ in
                        if square {
                            VStack(alignment: .leading, spacing: 8) {
                                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(placeholderFill).frame(width: 150, height: 150)
                                RoundedRectangle(cornerRadius: 4).fill(placeholderFill).frame(width: 110, height: 12)
                            }
                        } else {
                            SkeletonVideoCard().frame(width: screen == .expanded ? 300 : 260)
                        }
                    }
                }
                .padding(.horizontal, Metrics.gutter(screen))
            }
            .keepsToOwnFrame()
            .scrollDisabled(true)
        }
        .shimmering()
        .accessibilityHidden(true)
    }
}

/// Placeholder for the featured hero.
struct SkeletonHero: View {
    @Environment(\.screenClass) private var screen

    var body: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(placeholderFill)
            .aspectRatio(screen == .expanded ? 2.6 : 16 / 9, contentMode: .fit)
            .padding(.horizontal, Metrics.gutter(screen))
            .shimmering()
            .accessibilityHidden(true)
    }
}
