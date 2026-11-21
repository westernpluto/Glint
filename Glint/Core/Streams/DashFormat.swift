import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One adaptive (DASH) stream: a fragmented MP4 file with an `sidx` index.
struct DashFormat: Hashable {
    var itag: Int
    var url: URL
    var mimeType: String
    var codecs: String
    var bitrate: Int
    var width: Int
    var height: Int
    var fps: Int
    var hdrRange: String?            // "PQ" / "HLG" / nil (SDR)
    var initRange: ClosedRange<Int>
    var indexRange: ClosedRange<Int>
    var durationMs: Int
    var isAudio: Bool
    /// File size in bytes (0 if YouTube didn't say).
    var contentLength: Int
    /// Identify the format in SABR requests.
    var lastModified: UInt64?
    var xtags: String?
    /// Multi-language audio: which track this is ("en.4" …), its name, and whether it's the
    /// video's default (normally the original language).
    var audioTrackId: String?
    var audioTrackName: String?
    var audioIsDefault = false

    /// `placeholderURL`: for SABR formats, which have no link of their own.
    init?(_ f: JSON, placeholderURL: URL? = nil) {
        guard let url = f["url"].string.flatMap(URL.init(string:)) ?? placeholderURL,
              let mime = f["mimeType"].string,
              mime.hasPrefix("video/mp4") || mime.hasPrefix("audio/mp4"),
              let i0 = f.at("initRange.start").int, let i1 = f.at("initRange.end").int,
              let x0 = f.at("indexRange.start").int, let x1 = f.at("indexRange.end").int,
              i1 >= i0, x1 >= x0
        else { return nil }
        self.itag = f["itag"].int ?? 0
        self.url = url
        self.mimeType = mime
        self.codecs = mime.components(separatedBy: "codecs=\"").last?.replacingOccurrences(of: "\"", with: "") ?? ""
        self.bitrate = f["bitrate"].int ?? f["averageBitrate"].int ?? 0
        self.width = f["width"].int ?? 0
        self.height = f["height"].int ?? 0
        self.fps = f["fps"].int ?? 30
        let transfer = f.at("colorInfo.transferCharacteristics").string ?? ""
        if transfer.contains("SMPTEST2084") { hdrRange = "PQ" }
        else if transfer.contains("ARIB_STD_B67") { hdrRange = "HLG" }
        else { hdrRange = nil }
        self.initRange = i0...i1
        self.indexRange = x0...x1
        self.durationMs = Int(f["approxDurationMs"].string ?? "") ?? 0
        self.isAudio = mime.hasPrefix("audio")
        self.contentLength = Int(f["contentLength"].string ?? "")
            ?? URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "clen" }?.value.flatMap { Int($0) } ?? 0
        self.lastModified = f["lastModified"].string.flatMap { UInt64($0) }
        self.xtags = f["xtags"].string
        self.audioTrackId = f.at("audioTrack.id").string
        self.audioTrackName = f.at("audioTrack.displayName").string
        self.audioIsDefault = f.at("audioTrack.audioIsDefault").bool ?? false
        if f["isDrc"].bool == true { return nil }  // skip dynamic-range-compressed duplicates
    }

    var codecFamily: String {
        if codecs.hasPrefix("av01") { return "av1" }
        if codecs.hasPrefix("hvc1") || codecs.hasPrefix("hev1") { return "hevc" }
        if codecs.hasPrefix("mp4a") { return "aac" }
        return "avc"
    }
}

/// Builds HLS playlists that point straight into the MP4 files with byte ranges,
/// so AVPlayer can play YouTube's separate video + audio streams at any resolution.
enum SyntheticHLS {
    struct Segment: Hashable { var offset: Int; var length: Int; var duration: Double }

    /// Parses an ISO-BMFF `sidx` box. `indexEnd` is the absolute byte offset of the box's last byte.
    static func parseSidx(_ data: Data, indexEnd: Int) -> [Segment] {
        let b = [UInt8](data)
        func u32(_ i: Int) -> Int { guard i + 4 <= b.count else { return 0 }
            return Int(b[i]) << 24 | Int(b[i+1]) << 16 | Int(b[i+2]) << 8 | Int(b[i+3]) }
        func u64(_ i: Int) -> Int { u32(i) << 32 | u32(i + 4) }
        func u16(_ i: Int) -> Int { guard i + 2 <= b.count else { return 0 }; return Int(b[i]) << 8 | Int(b[i+1]) }

        // Find the sidx box (it is normally the first box in the range).
        var p = 0
        while p + 8 <= b.count {
            let size = u32(p)
            if b[p+4] == 0x73, b[p+5] == 0x69, b[p+6] == 0x64, b[p+7] == 0x78 { break } // "sidx"
            if size < 8 { return [] }
            p += size
        }
        guard p + 12 <= b.count else { return [] }
        let version = b[p + 8]
        var i = p + 12
        i += 4                                   // reference_ID
        let timescale = u32(i); i += 4
        guard timescale > 0 else { return [] }
        let firstOffset: Int
        if version == 0 { i += 4; firstOffset = u32(i); i += 4 }
        else { i += 8; firstOffset = u64(i); i += 8 }
        i += 2                                   // reserved
        let count = u16(i); i += 2

        var segments: [Segment] = []
        var offset = indexEnd + 1 + firstOffset
        for _ in 0..<count {
            guard i + 12 <= b.count else { break }
            let ref = u32(i)
            let size = ref & 0x7FFF_FFFF
            let dur = u32(i + 4)
            segments.append(Segment(offset: offset, length: size, duration: Double(dur) / Double(timescale)))
            offset += size
            i += 12
        }
        return segments
    }

    static func fetchSegments(_ f: DashFormat, session: URLSession, userAgent: String) async throws -> [Segment] {
        var req = URLRequest(url: f.url)
        req.setValue("bytes=\(f.indexRange.lowerBound)-\(f.indexRange.upperBound)", forHTTPHeaderField: "Range")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw InnerTubeError.http(code) }
        let segs = parseSidx(data, indexEnd: f.indexRange.upperBound)
        if segs.isEmpty { throw InnerTubeError.unplayable("Could not read the stream index.") }
        return segs
    }

    static func mediaPlaylist(_ f: DashFormat, segments: [Segment]) -> String {
        let target = Int((segments.map(\.duration).max() ?? 10).rounded(.up))
        let url = f.url.absoluteString
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(max(target, 1))",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-MAP:URI=\"\(url)\",BYTERANGE=\"\(f.initRange.count)@\(f.initRange.lowerBound)\"",
        ]
        lines.reserveCapacity(segments.count * 3 + 10)
        for s in segments {
            lines.append("#EXTINF:\(String(format: "%.5f", s.duration)),")
            lines.append("#EXT-X-BYTERANGE:\(s.length)@\(s.offset)")
            lines.append(url)
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Master playlist. `videoURI`/`audioURI` resolve playlist URIs (served by the resource loader).
    static func masterPlaylist(video: [DashFormat], audio: DashFormat?,
                               videoURI: (DashFormat) -> String, audioURI: (DashFormat) -> String) -> String {
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-INDEPENDENT-SEGMENTS"]
        if let audio {
            lines.append("#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"Audio\",DEFAULT=YES,AUTOSELECT=YES,CHANNELS=\"2\",URI=\"\(audioURI(audio))\"")
        }
        if video.isEmpty, let audio {
            lines.append("#EXT-X-STREAM-INF:BANDWIDTH=\(max(audio.bitrate, 1)),CODECS=\"\(audio.codecs)\"")
            lines.append(audioURI(audio))
        }
        for v in video {
            var attrs = ["BANDWIDTH=\(max(v.bitrate + (audio?.bitrate ?? 0), 1))"]
            let codecs = [v.codecs, audio?.codecs].compactMap { $0 }.joined(separator: ",")
            attrs.append("CODECS=\"\(codecs)\"")
            if v.width > 0 && v.height > 0 { attrs.append("RESOLUTION=\(v.width)x\(v.height)") }
            attrs.append("FRAME-RATE=\(String(format: "%.3f", Double(v.fps)))")
            if let r = v.hdrRange { attrs.append("VIDEO-RANGE=\(r)") } else { attrs.append("VIDEO-RANGE=SDR") }
            if audio != nil { attrs.append("AUDIO=\"aud\"") }
            lines.append("#EXT-X-STREAM-INF:" + attrs.joined(separator: ","))
            lines.append(videoURI(v))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
