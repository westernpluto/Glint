import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum SponsorCategory: String, CaseIterable, Codable, Identifiable {
    case sponsor, selfpromo, interaction, intro, outro, preview, music_offtopic, filler, poi_highlight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sponsor: return "Sponsor"
        case .selfpromo: return "Self promotion"
        case .interaction: return "Interaction reminder"
        case .intro: return "Intro"
        case .outro: return "Endcards & credits"
        case .preview: return "Preview / recap"
        case .music_offtopic: return "Non-music section"
        case .filler: return "Filler tangent"
        case .poi_highlight: return "Highlight"
        }
    }

    var detail: String {
        switch self {
        case .sponsor: return "Paid promotions and paid referrals."
        case .selfpromo: return "Merch, donations, shout-outs."
        case .interaction: return "\u{201C}Like and subscribe\u{201D} reminders."
        case .intro: return "Intro animations and pauses."
        case .outro: return "End screens and credits."
        case .preview: return "Clips of what is coming up."
        case .music_offtopic: return "Talking in music videos."
        case .filler: return "Off-topic jokes and tangents."
        case .poi_highlight: return "Jump straight to the best part."
        }
    }

    /// Hex colour used on the scrubber (SponsorBlock's own palette).
    var colorHex: UInt32 {
        switch self {
        case .sponsor: return 0x00D400
        case .selfpromo: return 0xFFFF00
        case .interaction: return 0xCC00FF
        case .intro: return 0x00FFFF
        case .outro: return 0x0202ED
        case .preview: return 0x008FD6
        case .music_offtopic: return 0xFF9900
        case .filler: return 0x7300FF
        case .poi_highlight: return 0xFF1684
        }
    }

    static let defaultSkip: Set<SponsorCategory> = [.sponsor, .selfpromo, .interaction, .music_offtopic]
}

struct SponsorSegment: Identifiable, Hashable {
    var id: String
    var start: Double
    var end: Double
    var category: SponsorCategory
    var actionType: String
}

/// Privacy-preserving SponsorBlock client: only the first 4 characters of the
/// SHA-256 of the video id are sent to the server.
final class SponsorBlock: @unchecked Sendable {
    static let shared = SponsorBlock()
    var server = URL(string: "https://sponsor.ajay.app")!

    func segments(for videoId: String, categories: [SponsorCategory]) async -> [SponsorSegment] {
        guard !categories.isEmpty else { return [] }
        let cats = "[" + categories.map { "\"\($0.rawValue)\"" }.joined(separator: ",") + "]"
        let actions = "[\"skip\",\"mute\",\"poi\",\"full\"]"
        let hash = Hashing.sha256Hex(videoId)
        var comps: URLComponents
        if hash.count >= 4 {
            comps = URLComponents(url: server.appendingPathComponent("api/skipSegments/\(hash.prefix(4))"),
                                  resolvingAgainstBaseURL: false)!
        } else {
            comps = URLComponents(url: server.appendingPathComponent("api/skipSegments"), resolvingAgainstBaseURL: false)!
            comps.queryItems = [URLQueryItem(name: "videoID", value: videoId)]
        }
        comps.queryItems = (comps.queryItems ?? []) + [
            URLQueryItem(name: "categories", value: cats),
            URLQueryItem(name: "actionTypes", value: actions),
        ]
        guard let url = comps.url else { return [] }
        do {
            let (data, resp) = try await URLSession.shared.data(from: url)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return [] }
            let json = try JSON.parse(data)
            // Hash endpoint returns many videos; direct endpoint returns segments.
            let segmentList: [JSON]
            if let match = json.array.first(where: { $0["videoID"].string == videoId }) {
                segmentList = match["segments"].array
            } else if json.array.first?["segment"].isNull == false {
                segmentList = json.array
            } else {
                segmentList = []
            }
            return segmentList.compactMap { s in
                let seg = s["segment"].array.compactMap { $0.double }
                guard seg.count == 2, let cat = SponsorCategory(rawValue: s["category"].string ?? "") else { return nil }
                return SponsorSegment(id: s["UUID"].string ?? UUID().uuidString, start: seg[0], end: seg[1],
                                      category: cat, actionType: s["actionType"].string ?? "skip")
            }.sorted { $0.start < $1.start }
        } catch {
            return []
        }
    }
}
