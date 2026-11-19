import Foundation

/// Minimal HLS master playlist model used to expose every resolution YouTube
/// offers and to build single-resolution playlists for exact quality selection.
struct HLSManifest {
    struct Variant: Hashable {
        var bandwidth: Int
        var width: Int
        var height: Int
        var fps: Double
        var codecs: String
        var videoRange: String?
        var attributes: String     // raw attribute list (re-emitted verbatim)
        var uri: URL

        var isHDR: Bool { videoRange == "PQ" || videoRange == "HLG" }
        var codecFamily: String {
            let c = codecs.lowercased()
            if c.contains("av01") { return "av1" }
            if c.contains("vp09") || c.contains("vp9") { return "vp9" }
            if c.contains("hvc1") || c.contains("hev1") { return "hevc" }
            return "avc"
        }
        var videoCodec: String {
            codecs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.hasPrefix("mp4a") && !$0.hasPrefix("opus") && !$0.hasPrefix("ac-3") && !$0.hasPrefix("ec-3") } ?? codecs
        }
    }

    var headerLines: [String]      // #EXTM3U, #EXT-X-INDEPENDENT-SEGMENTS, #EXT-X-MEDIA ...
    var variants: [Variant]

    init(text: String, baseURL: URL) {
        var header: [String] = []
        var variants: [Variant] = []
        var pending: String?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pending = String(line.dropFirst("#EXT-X-STREAM-INF:".count))
            } else if let attrs = pending, !line.hasPrefix("#") {
                pending = nil
                guard let uri = URL(string: line, relativeTo: baseURL)?.absoluteURL else { continue }
                let a = HLSManifest.attributes(attrs)
                let res = (a["RESOLUTION"] ?? "0x0").split(separator: "x").compactMap { Int($0) }
                variants.append(Variant(
                    bandwidth: Int(a["BANDWIDTH"] ?? "") ?? 0,
                    width: res.first ?? 0,
                    height: res.count > 1 ? res[1] : 0,
                    fps: Double(a["FRAME-RATE"] ?? "") ?? 30,
                    codecs: a["CODECS"] ?? "",
                    videoRange: a["VIDEO-RANGE"],
                    attributes: attrs,
                    uri: uri))
            } else if line.hasPrefix("#EXT-X-I-FRAME-STREAM-INF") {
                continue
            } else if line.hasPrefix("#") {
                header.append(HLSManifest.absolutizeURIAttribute(line, baseURL: baseURL))
            }
        }
        self.headerLines = header
        self.variants = variants
    }

    /// Parses `KEY=value,KEY2="quoted,value"`.
    static func attributes(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        var key = "", value = "", inKey = true, inQuotes = false
        func flush() {
            if !key.isEmpty { out[key.trimmingCharacters(in: .whitespaces)] = value }
            key = ""; value = ""; inKey = true
        }
        for ch in s {
            if inKey {
                if ch == "=" { inKey = false } else if ch == "," { flush() } else { key.append(ch) }
            } else {
                if ch == "\"" { inQuotes.toggle() }
                else if ch == "," && !inQuotes { flush() }
                else { value.append(ch) }
            }
        }
        flush()
        return out
    }

    private static func absolutizeURIAttribute(_ line: String, baseURL: URL) -> String {
        guard let r = line.range(of: "URI=\"") else { return line }
        let rest = line[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return line }
        let uri = String(rest[..<end])
        guard let abs = URL(string: uri, relativeTo: baseURL)?.absoluteString else { return line }
        return line.replacingCharacters(in: r.upperBound..<end, with: abs)
    }

    /// A master playlist containing only the given variants.
    func playlist(keeping keep: [Variant]) -> String {
        var lines = headerLines
        if !lines.contains(where: { $0.hasPrefix("#EXTM3U") }) { lines.insert("#EXTM3U", at: 0) }
        for v in keep {
            lines.append("#EXT-X-STREAM-INF:" + v.attributes)
            lines.append(v.uri.absoluteString)
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
