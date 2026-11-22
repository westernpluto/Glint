import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Better-timed lyrics from LRCLIB (lrclib.net, an open, community lyrics database).
/// YouTube Music's timings are per line, and its lines can be long — one line can run for nine
/// seconds while the singer holds a single word. LRCLIB's lines are usually split where the
/// singing pauses, and some songs have every word timed (enhanced LRC). Its timings are lined up
/// against YouTube's own lines when there are any (which also corrects a music video's intro),
/// or used only when the track lengths match.
enum SyncedLyrics {
    typealias Line = YouTubeService.Lyrics.Line

    static func lookup(title: String, artist: String?, duration: Double?, reference: [Line]) async -> [Line]? {
        var comps = URLComponents(string: "https://lrclib.net/api/search")!
        comps.queryItems = [URLQueryItem(name: "track_name", value: cleanTitle(title))]
        if let artist, !artist.isEmpty { comps.queryItems?.append(URLQueryItem(name: "artist_name", value: artist)) }
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Glint (iOS)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 8
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let results = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }

        struct Candidate { var lines: [Line]; var words: Bool; var durationGap: Double }
        let candidates: [Candidate] = results.compactMap { r in
            guard let lrc = r["syncedLyrics"] as? String else { return nil }
            let lines = parse(lrc)
            guard lines.count >= 3 else { return nil }
            let gap = (r["duration"] as? Double).flatMap { d in duration.map { abs($0 - d) } } ?? 99
            return Candidate(lines: lines, words: lines.contains { $0.words != nil }, durationGap: gap)
        }
        // Word-timed first, then the closest length.
        let ordered = candidates.sorted {
            if $0.words != $1.words { return $0.words }
            return $0.durationGap < $1.durationGap
        }
        for c in ordered.prefix(6) {
            if !reference.isEmpty {
                guard let offset = offset(of: c.lines, against: reference) else { continue }
                return c.lines.map { $0.shifted(by: offset) }
            }
            if c.durationGap <= 3 { return c.lines }
        }
        return nil
    }

    /// The shift that lines LRCLIB's timings up with YouTube's: the median difference between
    /// lines that start with the same words. Nil when too few match, or they don't agree.
    static func offset(of lines: [Line], against reference: [Line]) -> Double? {
        var diffs: [Double] = []
        var used = Set<Int>()
        for r in reference {
            let key = normalized(r.text)
            guard key.count >= 6 else { continue }
            // The first unused LRCLIB line starting the same way, near where this one is.
            if let match = lines.enumerated().first(where: { i, l in
                !used.contains(i) && abs(l.start - r.start) < 30 && {
                    let k = normalized(l.text)
                    let n = min(k.count, key.count, 14)
                    return n >= 6 && k.prefix(n) == key.prefix(n)
                }()
            }) {
                used.insert(match.offset)
                diffs.append(r.start - match.element.start)
            }
        }
        guard diffs.count >= 3 else { return nil }
        let sorted = diffs.sorted()
        let median = sorted[sorted.count / 2]
        // Most matched lines should agree with it (same recording, same arrangement).
        let close = diffs.filter { abs($0 - median) < 1.0 }.count
        guard Double(close) >= Double(diffs.count) * 0.6 else { return nil }
        // YouTube's line starts are often a little early; a small difference is noise.
        return abs(median) < 0.35 ? 0 : median
    }

    // MARK: LRC

    /// `[mm:ss.xx] text` lines; enhanced LRC adds `<mm:ss.xx>` before words. Each line ends
    /// where the next one starts.
    static func parse(_ lrc: String) -> [Line] {
        var out: [(start: Double, text: String, words: [Line.Word]?, end: Double?)] = []
        for raw in lrc.split(whereSeparator: \.isNewline) {
            var rest = Substring(raw)
            var starts: [Double] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                if let t = time(rest[rest.index(after: rest.startIndex)..<close]) { starts.append(t) }
                rest = rest[rest.index(after: close)...]
            }
            guard !starts.isEmpty else { continue }
            // Empty lines are kept for now: they mark where the line before them stops.
            let (text, words, end) = parseWords(String(rest))
            for s in starts { out.append((s, text, words, end)) }
        }
        out.sort { $0.start < $1.start }
        return out.enumerated().compactMap { i, l in
            guard !l.text.isEmpty else { return nil }
            let next = i + 1 < out.count ? out[i + 1].start : l.start + 6
            let end = l.end.map { min($0, next) } ?? next
            return Line(text: l.text, start: l.start, end: max(end, l.start + 0.3), words: l.words)
        }
    }

    /// Text with any `<mm:ss.xx>` word stamps taken out (and kept as word timings).
    private static func parseWords(_ s: String) -> (String, [Line.Word]?, Double?) {
        guard s.contains("<") else { return (s.trimmingCharacters(in: .whitespaces), nil, nil) }
        var words: [Line.Word] = []
        var end: Double?
        var plain = ""
        var rest = Substring(s)
        var pending: Double?
        func flush(_ chunk: Substring) {
            let t = chunk.trimmingCharacters(in: .whitespaces)
            plain += chunk
            guard !t.isEmpty else { return }
            if let p = pending {
                // One stamp can cover several words: split them (same start) so the line wraps
                // the same way; the view spreads them over the stamp's time.
                for w in t.split(separator: " ") {
                    words.append(Line.Word(text: String(w), start: p))
                }
                pending = nil
            } else if words.isEmpty == false {
                words[words.count - 1].text += " " + t
            }
        }
        while let open = rest.firstIndex(of: "<") {
            flush(rest[..<open])
            guard let close = rest[open...].firstIndex(of: ">") else { rest = rest[open...]; break }
            let stamp = time(rest[rest.index(after: open)..<close])
            pending = stamp ?? pending
            rest = rest[rest.index(after: close)...]
        }
        if rest.isEmpty, let p = pending { end = p } else { flush(rest) }
        let text = plain.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        guard words.count >= 2 else { return (text, nil, nil) }
        // Words as they appear in the text, so the view can lay them out one by one.
        return (words.map(\.text).joined(separator: " "), words, end)
    }

    private static func time(_ s: Substring) -> Double? {
        let parts = s.split(separator: ":")
        guard parts.count == 2, let m = Double(parts[0]), let sec = Double(parts[1]) else { return nil }
        return m * 60 + sec
    }

    // MARK: Matching

    static func normalized(_ s: String) -> String {
        String(s.lowercased().folding(options: .diacriticInsensitive, locale: nil).filter { $0.isLetter || $0.isNumber })
    }

    /// "Song (Official Video) [HD]" → "Song"; "Song - Remastered 2011" kept as is otherwise.
    static func cleanTitle(_ title: String) -> String {
        var t = title
        for pattern in [#"\s*[\(\[][^\)\]]*(official|video|audio|lyric|visuali[sz]er|hd|4k|mv)[^\)\]]*[\)\]]"#] {
            t = t.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return t.trimmingCharacters(in: .whitespaces)
    }
}

extension YouTubeService.Lyrics.Line {
    func shifted(by d: Double) -> Self {
        Self(text: text, start: start + d, end: end + d,
             words: words?.map { .init(text: $0.text, start: $0.start + d) })
    }
}
