import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct CaptionTrack: Identifiable, Hashable {
    var id: String { languageCode + (isAuto ? "-auto" : "") }
    var languageCode: String
    var name: String
    var isAuto: Bool
    var url: URL

    /// "English", "English (auto-generated)".
    var label: String { isAuto && !name.lowercased().contains("auto") ? "\(name) (auto)" : name }
}

struct CaptionCue: Hashable {
    var start: Double
    var end: Double
    var text: String
}

enum Captions {
    /// Tracks from a player response, with WebVTT URLs.
    static func tracks(_ player: JSON) -> [CaptionTrack] {
        player.at("captions.playerCaptionsTracklistRenderer.captionTracks").array.compactMap { t in
            guard let base = t["baseUrl"].string, var c = URLComponents(string: base),
                  let code = t["languageCode"].string else { return nil }
            c.queryItems = (c.queryItems ?? []).filter { $0.name != "fmt" } + [URLQueryItem(name: "fmt", value: "vtt")]
            guard let url = c.url else { return nil }
            return CaptionTrack(languageCode: code,
                                name: t["name"].text ?? code,
                                isAuto: t["kind"].string == "asr",
                                url: url)
        }
    }

    /// The best track for the user's language: human captions first, then auto-generated.
    static func preferred(_ tracks: [CaptionTrack], language: String) -> CaptionTrack? {
        let lang = language.lowercased()
        func matches(_ t: CaptionTrack) -> Bool { t.languageCode.lowercased().hasPrefix(lang) }
        return tracks.first { matches($0) && !$0.isAuto }
            ?? tracks.first { matches($0) }
            ?? tracks.first { !$0.isAuto }
            ?? tracks.first
    }

    static func load(_ track: CaptionTrack) async throws -> [CaptionCue] {
        let (data, resp) = try await URLSession.shared.data(from: track.url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw InnerTubeError.empty }
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// Minimal WebVTT parser: timing lines, text, tags stripped. Auto-generated captions
    /// repeat the previous line in each cue; those repeats are removed so lines don't stutter.
    static func parse(_ vtt: String) -> [CaptionCue] {
        var cues: [CaptionCue] = []
        let lines = vtt.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.contains("-->") {
                let parts = line.components(separatedBy: "-->")
                let start = time(parts[0])
                let end = time(parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? "")
                var text: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    let clean = stripTags(lines[i]).trimmingCharacters(in: .whitespaces)
                    if !clean.isEmpty { text.append(clean) }
                    i += 1
                }
                if let start, let end, end > start, !text.isEmpty {
                    cues.append(CaptionCue(start: start, end: end, text: text.joined(separator: "\n")))
                }
            } else {
                i += 1
            }
        }
        return dedupeRolling(cues.sorted { $0.start < $1.start })
    }

    /// YouTube's auto captions are "rolling": each cue repeats the line before it.
    private static func dedupeRolling(_ cues: [CaptionCue]) -> [CaptionCue] {
        var out: [CaptionCue] = []
        for c in cues {
            var lines = c.text.components(separatedBy: "\n")
            if let prev = out.last, let first = lines.first, prev.text.components(separatedBy: "\n").last == first, lines.count > 1 {
                lines.removeFirst()
            }
            let text = lines.joined(separator: "\n")
            if let prev = out.last, prev.text == text, c.start - prev.end < 0.1 {
                out[out.count - 1].end = max(prev.end, c.end)       // merge identical consecutive cues
            } else if c.end - c.start > 0.05 {
                out.append(CaptionCue(start: c.start, end: c.end, text: text))
            }
        }
        return out
    }

    /// Text of the cue showing at `t` (binary search; cues are sorted by start).
    static func text(at t: Double, in cues: [CaptionCue]) -> String? {
        var lo = 0, hi = cues.count - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if cues[mid].start <= t { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        guard found >= 0 else { return nil }
        // Look back a little for a longer cue that is still on screen.
        for k in stride(from: found, through: max(0, found - 3), by: -1) where cues[k].end > t {
            return cues[k].text
        }
        return nil
    }

    private static func time(_ s: String) -> Double? {
        let parts = s.trimmingCharacters(in: .whitespaces).components(separatedBy: ":")
        guard !parts.isEmpty else { return nil }
        var total = 0.0
        for p in parts {
            guard let v = Double(p.replacingOccurrences(of: ",", with: ".")) else { return nil }
            total = total * 60 + v
        }
        return total
    }

    private static func stripTags(_ s: String) -> String {
        var out = ""
        var inTag = false
        for ch in s {
            if ch == "<" { inTag = true } else if ch == ">" { inTag = false } else if !inTag { out.append(ch) }
        }
        return out.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }
}
