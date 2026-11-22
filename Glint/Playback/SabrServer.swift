import Foundation
import Network

/// A tiny HTTP server on 127.0.0.1 that turns SABR sessions into ordinary HLS for AVPlayer.
/// (AVPlayer only lets a resource loader answer playlist requests, not media segments, so a
/// loopback server is the way to feed it segments fetched over SABR.)
///
/// Paths: `/<session>/master.m3u8`, `/<session>/v<itag>.m3u8` / `a<itag>.m3u8` (playlists from
/// each format's sidx), `/<session>/i<itag>.mp4` (init), `/<session>/s<itag>_<n>.m4s` (media).
final class SabrServer: @unchecked Sendable {
    static let shared = SabrServer()

    private let queue = DispatchQueue(label: "com.glint.sabr-server")
    private var listener: NWListener?
    private var port: UInt16?
    /// The port handed out in URLs. iOS takes listening sockets away from suspended apps, so
    /// the server comes back on this same port and AVPlayer's existing URLs keep working.
    private var preferredPort: UInt16?
    private var starting: [CheckedContinuation<Void, Error>] = []
    private var sessions: [String: SabrSession] = [:]
    private var order: [String] = []
    /// A request AVPlayer made couldn't be answered (it gets a 502): which file and why.
    var onError: (@Sendable (_ file: String, _ error: Error) -> Void)?

    // MARK: Lifecycle

    func start() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            queue.async {
                if self.port != nil, self.listener != nil { c.resume(); return }
                self.starting.append(c)
                guard self.listener == nil else { return }
                self.makeListener(on: self.preferredPort)
            }
        }
    }

    /// A fresh listener on the same port. iOS can take a suspended app's listening socket
    /// without the listener ever reporting it, so this replaces it rather than trusting it.
    func restart() async throws {
        queue.sync {
            let old = listener
            listener = nil
            port = nil
            old?.cancel()
        }
        try await start()
    }

    /// Whether the listener still answers (iOS may have taken it while the app was suspended).
    func isAlive() async -> Bool {
        guard let port = queue.sync(execute: { listener != nil ? port : nil }),
              let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 1
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        guard let (_, resp) = try? await session.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    /// Called when the app returns to the foreground.
    func ensureRunning() {
        let hasSessions = queue.sync { !sessions.isEmpty }
        guard hasSessions else { return }
        Task {
            if await isAlive() { return }
            try? await restart()
        }
    }

    private func makeListener(on wanted: UInt16?) {
        do {
            let params = NWParameters.tcp
            let port = wanted.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            l.stateUpdateHandler = { [weak self, weak l] state in
                guard let self, let l, l === self.listener else { return }
                self.listenerState(state)
            }
            listener = l
            l.start(queue: queue)
        } catch {
            if wanted != nil {
                makeListener(on: nil)   // that port is taken: any port (new URLs from now on)
            } else {
                finishStarting(error)
            }
        }
    }

    private func listenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            port = listener?.port?.rawValue
            preferredPort = port
            finishStarting(nil)
        case .failed(let error):
            listener?.cancel()
            listener = nil
            port = nil
            if starting.isEmpty {
                // Reclaimed while running (app suspended): come back on the same port.
                queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self, self.listener == nil, !self.sessions.isEmpty else { return }
                    self.makeListener(on: self.preferredPort)
                }
            } else if preferredPort != nil {
                preferredPort = nil
                makeListener(on: nil)
            } else {
                finishStarting(error)
            }
        case .cancelled:
            listener = nil
            port = nil
        default:
            break
        }
    }

    private func finishStarting(_ error: Error?) {
        let waiting = starting
        starting = []
        for c in waiting {
            if let error { c.resume(throwing: error) } else { c.resume() }
        }
    }

    /// Playable URL for a session (the server must have been started). Audio only plays the
    /// audio playlist directly.
    func url(for session: SabrSession, videos: [DashFormat], audioOnly: Bool) -> URL? {
        queue.sync {
            guard let port else { return nil }
            if sessions[session.id] == nil {
                // Older sessions give their segment memory back (they keep init segments, so
                // going back to one is still quick).
                for old in sessions.values { Task { await old.trim() } }
                sessions[session.id] = session
                order.append(session.id)
                while order.count > 2 { sessions[order.removeFirst()] = nil }
            }
            selectedVideos[session.id] = audioOnly ? [] : videos
            let base = "http://127.0.0.1:\(port)/\(session.id)/"
            return URL(string: audioOnly ? base + "a\(session.audio.itag).m3u8" : base + "master.m3u8")
        }
    }

    private var selectedVideos: [String: [DashFormat]] = [:]

    // MARK: Connections

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[..<end.lowerBound], as: UTF8.self)
                self.handle(head, conn)
            } else if error != nil || done || buf.count > 64 * 1024 {
                conn.cancel()
            } else {
                self.receive(conn, buffer: buf)
            }
        }
    }

    private func handle(_ head: String, _ conn: NWConnection) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2 else { return respond(conn, status: 400, body: Data()) }
        let isHead = parts[0] == "HEAD"
        let path = String(parts[1]).split(separator: "?").first.map(String.init) ?? ""
        let range = lines.dropFirst().first { $0.lowercased().hasPrefix("range:") }
            .map { String($0.dropFirst("range:".count)).trimmingCharacters(in: .whitespaces) }

        let comps = path.split(separator: "/").map(String.init)
        if comps == ["health"] { return respond(conn, status: 200, body: Data("ok".utf8)) }
        guard comps.count == 2, let session = sessions[comps[0]] else {
            return respond(conn, status: 404, body: Data())
        }
        let videos = selectedVideos[comps[0]] ?? session.videos
        let name = comps[1]

        Task {
            do {
                let (body, type) = try await Self.serve(name, session: session, videos: videos)
                self.queue.async { self.respond(conn, status: 200, body: body, type: type, range: range, headOnly: isHead) }
            } catch {
                self.onError?(name, error)
                self.queue.async { self.respond(conn, status: 502, body: Data(error.localizedDescription.utf8)) }
            }
        }
    }

    private static func serve(_ name: String, session: SabrSession, videos: [DashFormat]) async throws -> (Data, String) {
        let playlistType = "application/vnd.apple.mpegurl"
        if name == "master.m3u8" {
            let text = SyntheticHLS.masterPlaylist(video: videos, audio: session.audio,
                                                   videoURI: { "v\($0.itag).m3u8" },
                                                   audioURI: { "a\($0.itag).m3u8" })
            return (Data(text.utf8), playlistType)
        }
        if name.hasSuffix(".m3u8"), let itag = Int(name.dropFirst().dropLast(5)) {
            let durations = try await session.segmentDurations(itag)
            var lines = ["#EXTM3U", "#EXT-X-VERSION:7",
                         "#EXT-X-TARGETDURATION:\(max(Int((durations.max() ?? 10).rounded(.up)), 1))",
                         "#EXT-X-MEDIA-SEQUENCE:0", "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-INDEPENDENT-SEGMENTS",
                         "#EXT-X-MAP:URI=\"i\(itag).mp4\""]
            for (i, d) in durations.enumerated() {
                lines.append("#EXTINF:\(String(format: "%.5f", d)),")
                lines.append("s\(itag)_\(i + 1).m4s")
            }
            lines.append("#EXT-X-ENDLIST")
            return (Data((lines.joined(separator: "\n") + "\n").utf8), playlistType)
        }
        if name.hasPrefix("i"), name.hasSuffix(".mp4"), let itag = Int(name.dropFirst().dropLast(4)) {
            let data = try await session.initSegment(itag)
            return (data, itag == session.audio.itag ? "audio/mp4" : "video/mp4")
        }
        if name.hasPrefix("s"), name.hasSuffix(".m4s") {
            let fields = name.dropFirst().dropLast(4).split(separator: "_")
            if fields.count == 2, let itag = Int(fields[0]), let n = Int(fields[1]) {
                let data = try await session.segment(itag, number: n)
                return (data, itag == session.audio.itag ? "audio/mp4" : "video/mp4")
            }
        }
        throw SabrSession.SabrFailure.noMedia
    }

    private func respond(_ conn: NWConnection, status: Int, body: Data, type: String = "text/plain",
                         range: String? = nil, headOnly: Bool = false) {
        var status = status
        var payload = body
        var extra = ""
        // Simple single byte range (bytes=a-b / bytes=a-), in case AVPlayer asks for one.
        if status == 200, let range, range.hasPrefix("bytes="), !body.isEmpty {
            let spec = range.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
            if let a = spec.first.flatMap({ Int($0) }), a < body.count {
                let b = min((spec.count > 1 ? Int(spec[1]) : nil) ?? body.count - 1, body.count - 1)
                if b >= a {
                    payload = body.subdata(in: a..<(b + 1))
                    status = 206
                    extra = "Content-Range: bytes \(a)-\(b)/\(body.count)\r\n"
                }
            }
        }
        let reason = [200: "OK", 206: "Partial Content", 400: "Bad Request", 404: "Not Found"][status] ?? "Bad Gateway"
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(payload.count)\r\n"
            + "Accept-Ranges: bytes\r\n\(extra)Cache-Control: no-cache\r\nConnection: close\r\n\r\n"
        var out = Data(header.utf8)
        if !headOnly { out.append(payload) }
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }
}
