import Foundation

struct Comment: Identifiable, Hashable {
    var id: String
    var author: String
    var avatar: URL?
    var authorChannelId: String?
    var text: String
    var published: String?
    var likes: String?
    var replyCount: Int
    var isCreator: Bool
    /// Token to load this thread's replies (top-level comments only).
    var repliesToken: String?
}

struct CommentPage {
    var comments: [Comment]
    var continuation: String?
}

/// Parses comment pages. YouTube ships comments as entity payloads keyed from the threads.
enum CommentParser {
    static func page(_ root: JSON) -> CommentPage {
        var payloads: [String: JSON] = [:]
        for p in root.findAll("commentEntityPayload") {
            if let k = p["key"].string { payloads[k] = p }
        }

        var comments: [Comment] = []
        var seen = Set<String>()
        // Each top-level thread wraps a view model that points at its payload, plus replies.
        for item in continuationItems(root) {
            let thread = item["commentThreadRenderer"]
            let vm = thread.isNull ? item["commentViewModel"] : thread.at("commentViewModel.commentViewModel")
            guard let key = vm["commentKey"].string, let p = payloads[key],
                  var c = comment(p), seen.insert(c.id).inserted else { continue }
            c.repliesToken = thread.at("replies.commentRepliesRenderer").first("continuationCommand")?["token"].string
            comments.append(c)
        }

        let token = continuationItems(root).last.flatMap { $0["continuationItemRenderer"].isNull ? nil : $0 }
            .flatMap { $0["continuationItemRenderer"].first("token")?.string
                ?? $0["continuationItemRenderer"].first("continuationCommand")?["token"].string }
        return CommentPage(comments: comments, continuation: token)
    }

    /// The items of the page, in order (threads, replies, then a continuation item).
    private static func continuationItems(_ root: JSON) -> [JSON] {
        var items: [JSON] = []
        for key in ["onResponseReceivedEndpoints", "onResponseReceivedActions"] {
            for ep in root[key].array {
                items += ep.first("continuationItems")?.array ?? []
            }
        }
        return items
    }

    private static func comment(_ p: JSON) -> Comment? {
        let props = p["properties"]
        guard let id = props["commentId"].string, let text = props.at("content.content").string else { return nil }
        let author = p["author"]
        let replies = Int(p.at("toolbar.replyCount").string?.filter(\.isNumber) ?? "") ?? 0
        var avatar = author["avatarThumbnailUrl"].string.flatMap(URL.init(string:))
        if let a = avatar, let r = a.absoluteString.range(of: "=s\\d+-", options: .regularExpression) {
            avatar = URL(string: a.absoluteString.replacingCharacters(in: r, with: "=s120-"))
        }
        let likes = p.at("toolbar.likeCountNotliked").string
        return Comment(id: id,
                       author: author["displayName"].string ?? "",
                       avatar: avatar,
                       authorChannelId: author["channelId"].string,
                       text: text,
                       published: props["publishedTime"].string,
                       likes: (likes?.isEmpty ?? true) ? nil : likes,
                       replyCount: replies,
                       isCreator: author["isCreator"].bool ?? false)
    }
}
