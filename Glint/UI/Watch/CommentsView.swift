import SwiftUI

// MARK: Rich text (links + tappable timestamps)

enum SeekLink {
    static let scheme = "glint-seek"

    static func url(seconds: Int) -> URL { URL(string: "\(scheme)://t?s=\(seconds)")! }

    static func seconds(_ url: URL) -> Double? {
        guard url.scheme == scheme,
              let s = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "s" })?.value
        else { return nil }
        return Double(s)
    }
}

/// Links web addresses, and turns timestamps such as "2:15" or "1:02:30" into seek links.
func richText(_ s: String) -> AttributedString {
    var a = AttributedString(s)
    let ns = s as NSString
    let full = NSRange(location: 0, length: ns.length)

    func link(_ range: NSRange, _ url: URL) {
        guard let r = Range(range, in: s),
              let lower = AttributedString.Index(r.lowerBound, within: a),
              let upper = AttributedString.Index(r.upperBound, within: a) else { return }
        a[lower..<upper].link = url
    }

    if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
        for m in detector.matches(in: s, range: full) {
            if let url = m.url { link(m.range, url) }
        }
    }
    if let re = try? NSRegularExpression(pattern: #"(?<![\d:])(?:(\d{1,2}):)?(\d{1,2}):(\d{2})(?![\d:])"#) {
        for m in re.matches(in: s, range: full) {
            func part(_ i: Int) -> Int { m.range(at: i).location == NSNotFound ? 0 : Int(ns.substring(with: m.range(at: i))) ?? 0 }
            let total = part(1) * 3600 + part(2) * 60 + part(3)
            guard part(3) < 60 else { continue }
            link(m.range, SeekLink.url(seconds: total))
        }
    }
    return a
}

/// Opens timestamp links by seeking the player (and expanding it); everything else opens normally.
struct SeekLinkHandling: ViewModifier {
    @Environment(PlayerController.self) private var player

    func body(content: Content) -> some View {
        content.environment(\.openURL, OpenURLAction { url in
            guard let t = SeekLink.seconds(url) else { return .systemAction }
            player.seek(to: t)
            player.presentation = .expanded
            player.flash("Jumped to \(formatTime(t))")
            return .handled
        })
    }
}

extension View {
    func handlesSeekLinks() -> some View { modifier(SeekLinkHandling()) }
}

// MARK: Comments

/// Paged comments with expandable replies.
struct CommentsList: View {
    var token: String?
    @State private var comments: [Comment] = []
    @State private var continuation: String?
    @State private var loadedToken: String?
    @State private var failed = false

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            if token == nil {
                Label("Comments are turned off.", systemImage: "bubble.left.and.exclamationmark.bubble.right")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else if comments.isEmpty {
                if failed {
                    Text("Couldn't load comments.").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 20)
                }
            }
            ForEach(comments) { CommentRow(comment: $0) }
            if let next = continuation {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .task(id: next) { await loadMore(next) }
            }
        }
        .task(id: token) { await loadFirst() }
    }

    private func loadFirst() async {
        guard let token, loadedToken != token else { return }
        comments = []
        failed = false
        do {
            let page = try await YouTubeService.shared.comments(token)
            comments = page.comments
            continuation = page.continuation
            loadedToken = token
            failed = page.comments.isEmpty
        } catch {
            failed = true
        }
    }

    private func loadMore(_ next: String) async {
        guard let page = try? await YouTubeService.shared.comments(next) else { continuation = nil; return }
        let known = Set(comments.map(\.id))
        comments += page.comments.filter { !known.contains($0.id) }
        continuation = page.continuation == next ? nil : page.continuation
    }
}

struct CommentRow: View {
    var comment: Comment
    var isReply = false
    @State private var expanded = false
    @State private var replies: [Comment] = []
    @State private var repliesNext: String?
    @State private var loadingReplies = false
    @State private var showReplies = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Avatar(url: comment.avatar, size: isReply ? 26 : 34)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(comment.author)
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                    if comment.isCreator {
                        Text("Creator")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                            .foregroundStyle(.tint)
                    }
                    if let p = comment.published {
                        Text(p).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Text(richText(comment.text))
                    .font(.subheadline)
                    .lineLimit(expanded ? nil : 5)
                    .textSelection(.enabled)
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }
                HStack(spacing: 16) {
                    if let likes = comment.likes {
                        Label(likes, systemImage: "hand.thumbsup").font(.caption).foregroundStyle(.secondary)
                    }
                    if comment.replyCount > 0, comment.repliesToken != nil {
                        Button {
                            if showReplies { showReplies = false } else { Task { await openReplies() } }
                        } label: {
                            Label(showReplies ? "Hide replies" : "\(comment.replyCount) \(comment.replyCount == 1 ? "reply" : "replies")",
                                  systemImage: showReplies ? "chevron.up" : "chevron.down")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                    }
                }
                if showReplies {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(replies) { CommentRow(comment: $0, isReply: true) }
                        if loadingReplies {
                            ProgressView()
                        } else if let next = repliesNext {
                            Button("Show more replies") { Task { await loadReplies(next) } }
                                .font(.caption.weight(.semibold))
                                .buttonStyle(.plain)
                                .foregroundStyle(.tint)
                        }
                    }
                    .padding(.top, 6)
                }
            }
        }
    }

    private func openReplies() async {
        showReplies = true
        if replies.isEmpty, let t = comment.repliesToken { await loadReplies(t) }
    }

    private func loadReplies(_ token: String) async {
        loadingReplies = true
        defer { loadingReplies = false }
        guard let page = try? await YouTubeService.shared.comments(token) else { return }
        let known = Set(replies.map(\.id))
        replies += page.comments.filter { !known.contains($0.id) }
        repliesNext = page.continuation == token ? nil : page.continuation
    }
}

/// Compact entry point on narrow displays: a tappable card that opens all comments.
struct CommentsPreview: View {
    @Environment(PlayerController.self) private var player
    @State private var show = false
    @State private var top: Comment?

    var body: some View {
        Button { show = true } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Comments").font(.headline)
                    if let c = player.extras?.commentCount {
                        Text(c).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                if let top {
                    HStack(alignment: .top, spacing: 10) {
                        Avatar(url: top.avatar, size: 24)
                        Text(top.text)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                } else {
                    Text(player.extras == nil ? "Loading…"
                         : player.extras?.commentsToken == nil ? "Comments are turned off." : "Tap to read the conversation.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cardFill, in: RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(player.extras?.commentsToken == nil)
        .task(id: player.extras?.commentsToken) {
            top = nil
            guard let token = player.extras?.commentsToken else { return }
            top = try? await YouTubeService.shared.comments(token).comments.first
        }
        .sheet(isPresented: $show) {
            NavigationStack {
                ScrollView {
                    CommentsList(token: player.extras?.commentsToken).padding(16)
                }
                .navigationTitle("Comments")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarPinnedTrailing) {
                        Button("Done", systemImage: "checkmark") { show = false }
                    }
                }
                .handlesSeekLinks()
            }
            .presentationDetents([.medium, .large])
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
    }
}

/// Up next and Comments side by side in one column, switched with a segmented control.
struct WatchSidePanel: View {
    enum Tab: String, CaseIterable, Identifiable { case upNext = "Up next", comments = "Comments"; var id: String { rawValue } }
    @Environment(PlayerController.self) private var player
    @State private var tab: Tab = .upNext

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Show", selection: $tab) {
                ForEach(Tab.allCases) { t in
                    if t == .comments, let c = player.extras?.commentCount {
                        Text("Comments · \(c)").tag(t)
                    } else {
                        Text(t.rawValue).tag(t)
                    }
                }
            }
            .pickerStyle(.segmented)
            switch tab {
            case .upNext: UpNextList(showsTitle: false)
            case .comments: CommentsList(token: player.extras?.commentsToken)
            }
        }
        .onChange(of: player.current?.videoId) { _, _ in tab = .upNext }
    }
}
