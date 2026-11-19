import AVFoundation
import UniformTypeIdentifiers

/// Serves synthetic HLS playlists to AVPlayer through a custom URL scheme.
/// Media segments themselves are plain HTTPS byte ranges into YouTube's MP4s,
/// so AVPlayer downloads and buffers them natively (adaptive, seekable, PiP-friendly).
final class HLSLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let shared = HLSLoader()
    static let scheme = "glint-hls"

    let queue = DispatchQueue(label: "com.glint.hls-loader")

    private struct Session {
        var video: [DashFormat]
        var audio: DashFormat?
        var userAgent: String
        var liveMaster: String?
    }

    private var sessions: [String: Session] = [:]
    private var order: [String] = []
    private var cache: [String: String] = [:]
    /// Media playlists by stream URL, shared across sessions so quality switches skip the index fetch.
    private var mediaCache: [String: String] = [:]
    private var mediaOrder: [String] = []
    /// Requests waiting on an index fetch already in flight for the same stream URL.
    private var pending: [String: [(key: String, request: AVAssetResourceLoadingRequest)]] = [:]

    private static let playlistUTI = UTType(mimeType: "application/vnd.apple.mpegurl")?.identifier
        ?? "public.m3u-playlist"

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        return URLSession(configuration: c)
    }()

    // MARK: Registration

    func register(video: [DashFormat], audio: DashFormat?, userAgent: String) -> URL {
        let id = UUID().uuidString.lowercased()
        queue.sync { store(id, Session(video: video, audio: audio, userAgent: userAgent, liveMaster: nil)) }
        return URL(string: "\(Self.scheme)://\(id)/master.m3u8")!
    }

    func registerLive(master: String) -> URL {
        let id = UUID().uuidString.lowercased()
        queue.sync { store(id, Session(video: [], audio: nil, userAgent: "", liveMaster: master)) }
        return URL(string: "\(Self.scheme)://\(id)/master.m3u8")!
    }

    private func store(_ id: String, _ s: Session) {
        sessions[id] = s
        order.append(id)
        while order.count > 6 {
            let old = order.removeFirst()
            sessions[old] = nil
            cache = cache.filter { !$0.key.hasPrefix(old) }
        }
    }

    static func asset(for url: URL) -> AVURLAsset {
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(HLSLoader.shared, queue: HLSLoader.shared.queue)
        return asset
    }

    // MARK: AVAssetResourceLoaderDelegate

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loadingRequest.request.url, url.scheme == Self.scheme,
              let id = url.host, let s = sessions[id] else { return false }
        let name = url.lastPathComponent
        let key = id + "/" + name

        if let cached = cache[key] {
            respond(loadingRequest, cached)
            return true
        }

        if name == "master.m3u8" {
            let text: String
            if let live = s.liveMaster {
                text = live
            } else {
                text = SyntheticHLS.masterPlaylist(
                    video: s.video, audio: s.audio,
                    videoURI: { "\(Self.scheme)://\(id)/v\($0.itag).m3u8" },
                    audioURI: { "\(Self.scheme)://\(id)/a\($0.itag).m3u8" })
            }
            cache[key] = text
            respond(loadingRequest, text)
            return true
        }

        let isAudio = name.hasPrefix("a")
        let itag = Int(name.dropFirst().replacingOccurrences(of: ".m3u8", with: "")) ?? -1
        let format = isAudio ? (s.audio?.itag == itag ? s.audio : nil) : s.video.first { $0.itag == itag }
        guard let format else { return false }

        let mediaKey = format.url.absoluteString
        if let text = mediaCache[mediaKey] {
            cache[key] = text
            respond(loadingRequest, text)
            return true
        }

        if pending[mediaKey] != nil {
            pending[mediaKey]?.append((key: key, request: loadingRequest))
            return true
        }
        pending[mediaKey] = [(key: key, request: loadingRequest)]

        let ua = s.userAgent
        let urlSession = session
        Task {
            let result: Result<String, Error>
            do {
                result = .success(try await Self.playlist(format, session: urlSession, userAgent: ua))
            } catch {
                result = .failure(error)
            }
            self.queue.async {
                let waiting = self.pending.removeValue(forKey: mediaKey) ?? []
                switch result {
                case .success(let text):
                    self.mediaCache[mediaKey] = text
                    self.mediaOrder.append(mediaKey)
                    while self.mediaOrder.count > 24 { self.mediaCache[self.mediaOrder.removeFirst()] = nil }
                    for w in waiting {
                        self.cache[w.key] = text
                        self.respond(w.request, text)
                    }
                case .failure(let error):
                    for w in waiting where !w.request.isCancelled && !w.request.isFinished {
                        w.request.finishLoading(with: error)
                    }
                }
            }
        }
        return true
    }

    /// Fetches the stream index, retrying once on a network error or a server error.
    private static func playlist(_ f: DashFormat, session: URLSession, userAgent: String) async throws -> String {
        do {
            return SyntheticHLS.mediaPlaylist(f, segments: try await SyntheticHLS.fetchSegments(f, session: session, userAgent: userAgent))
        } catch let e as InnerTubeError {
            guard case .http(let code) = e, code >= 500 || code == 429 else { throw e }
        } catch is URLError {}
        try await Task.sleep(for: .milliseconds(400))
        return SyntheticHLS.mediaPlaylist(f, segments: try await SyntheticHLS.fetchSegments(f, session: session, userAgent: userAgent))
    }

    private func respond(_ req: AVAssetResourceLoadingRequest, _ text: String) {
        guard !req.isCancelled, !req.isFinished else { return }
        let data = Data(text.utf8)
        if let info = req.contentInformationRequest {
            info.contentType = Self.playlistUTI
            info.contentLength = Int64(data.count)
            info.isByteRangeAccessSupported = false
        }
        req.dataRequest?.respond(with: data)
        req.finishLoading()
    }
}
