import Foundation

/// A lightweight, forgiving JSON tree used to walk InnerTube responses.
/// YouTube's responses are huge, deeply nested and change shape often, so
/// instead of rigid Codable models we navigate them defensively.
enum JSON: Decodable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSON].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSON].self) { self = .object(o) }
        else { self = .null }
    }

    static func parse(_ data: Data) throws -> JSON {
        try JSONDecoder().decode(JSON.self, from: data)
    }

    // MARK: Access

    subscript(key: String) -> JSON {
        if case .object(let o) = self { return o[key] ?? .null }
        return .null
    }

    subscript(index: Int) -> JSON {
        if case .array(let a) = self, index >= 0, index < a.count { return a[index] }
        return .null
    }

    /// Follows a dotted path, e.g. `json.at("contents.twoColumnBrowseResultsRenderer")`.
    /// Numeric components index into arrays.
    func at(_ path: String) -> JSON {
        var cur = self
        for part in path.split(separator: ".") {
            if let i = Int(part) { cur = cur[i] } else { cur = cur[String(part)] }
            if case .null = cur { return .null }
        }
        return cur
    }

    var isNull: Bool { if case .null = self { return true }; return false }

    var string: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n.rounded() == n ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    var double: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    var int: Int? { double.map { Int($0) } }

    var bool: Bool? {
        switch self {
        case .bool(let b): return b
        case .string(let s): return s == "true"
        default: return nil
        }
    }

    var array: [JSON] {
        if case .array(let a) = self { return a }
        return []
    }

    var object: [String: JSON] {
        if case .object(let o) = self { return o }
        return [:]
    }

    /// Text from the many text shapes YouTube uses:
    /// `{simpleText}`, `{runs:[{text}]}`, `{content}` or a plain string.
    var text: String? {
        if let s = self.string { return s.isEmpty ? nil : s }
        if let s = self["simpleText"].string { return s }
        if let s = self["content"].string { return s }
        let runs = self["runs"].array
        if !runs.isEmpty {
            let joined = runs.compactMap { $0["text"].string }.joined()
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    // MARK: Recursive search

    /// Every value stored under `key` anywhere in the tree (depth-first, document order).
    func findAll(_ key: String, skipping blocked: Set<String> = []) -> [JSON] {
        var out: [JSON] = []
        collect(key, blocked, &out)
        return out
    }

    /// First value stored under `key` anywhere in the tree.
    func first(_ key: String) -> JSON? {
        switch self {
        case .object(let o):
            if let v = o[key] { return v }
            for (_, v) in o { if let f = v.first(key) { return f } }
        case .array(let a):
            for v in a { if let f = v.first(key) { return f } }
        default: break
        }
        return nil
    }

    private func collect(_ key: String, _ blocked: Set<String>, _ out: inout [JSON]) {
        switch self {
        case .object(let o):
            // Preserve document order as much as a dictionary allows: handle the
            // matched key, then recurse into the rest.
            if let v = o[key] { out.append(v) }
            for (k, v) in o where k != key && !blocked.contains(k) {
                v.collect(key, blocked, &out)
            }
        case .array(let a):
            for v in a { v.collect(key, blocked, &out) }
        default: break
        }
    }
}

/// Walks a tree in true document order calling `visit` for every (key, value)
/// pair. Returning `false` from `visit` stops descent into that value.
/// Arrays keep their order so feeds stay in the right sequence.
extension JSON {
    func walk(_ visit: (String, JSON) -> Bool) {
        switch self {
        case .object(let o):
            // Sort keys so siblings are deterministic; content order lives in arrays.
            for k in o.keys.sorted() {
                let v = o[k]!
                if visit(k, v) { v.walk(visit) }
            }
        case .array(let a):
            for v in a { v.walk(visit) }
        default: break
        }
    }
}
