import Foundation

/// Just enough protobuf for SABR's messages (field numbers from LuanRT/googlevideo's protos).
struct ProtoWriter {
    private(set) var data = Data()

    mutating func varint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            data.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
    }

    private mutating func key(_ field: Int, _ wireType: Int) { varint(UInt64(field << 3 | wireType)) }

    mutating func int(_ field: Int, _ value: Int64?) {
        guard let value else { return }
        key(field, 0)
        varint(UInt64(bitPattern: value))
    }

    mutating func int(_ field: Int, _ value: Int?) { int(field, value.map(Int64.init)) }

    mutating func uint(_ field: Int, _ value: UInt64?) {
        guard let value else { return }
        key(field, 0)
        varint(value)
    }

    mutating func bool(_ field: Int, _ value: Bool?) {
        guard let value else { return }
        int(field, value ? 1 : 0)
    }

    mutating func bytes(_ field: Int, _ value: Data?) {
        guard let value else { return }
        key(field, 2)
        varint(UInt64(value.count))
        data.append(value)
    }

    mutating func string(_ field: Int, _ value: String?) { bytes(field, value.map { Data($0.utf8) }) }

    mutating func message(_ field: Int, _ build: (inout ProtoWriter) -> Void) {
        var inner = ProtoWriter()
        build(&inner)
        bytes(field, inner.data)
    }
}

/// Reads a message into field number → values (varints as UInt64, length-delimited as Data).
struct ProtoMessage {
    enum Value {
        case varint(UInt64)
        case bytes(Data)
    }

    private(set) var fields: [Int: [Value]] = [:]

    init(_ data: Data) {
        let b = [UInt8](data)
        var i = 0
        func readVarint() -> UInt64? {
            var result: UInt64 = 0, shift: UInt64 = 0
            while i < b.count {
                let x = b[i]; i += 1
                result |= UInt64(x & 0x7F) << shift
                if x & 0x80 == 0 { return result }
                shift += 7
                if shift > 63 { return nil }
            }
            return nil
        }
        while i < b.count {
            guard let k = readVarint() else { return }
            let field = Int(k >> 3), wire = Int(k & 7)
            switch wire {
            case 0:
                guard let v = readVarint() else { return }
                fields[field, default: []].append(.varint(v))
            case 2:
                guard let len = readVarint(), i + Int(len) <= b.count else { return }
                fields[field, default: []].append(.bytes(Data(b[i..<i + Int(len)])))
                i += Int(len)
            case 1: i += 8
            case 5: i += 4
            default: return
            }
        }
    }

    func int(_ field: Int) -> Int64? {
        if case .varint(let v)? = fields[field]?.first { return Int64(bitPattern: v) }
        return nil
    }

    func uint(_ field: Int) -> UInt64? {
        if case .varint(let v)? = fields[field]?.first { return v }
        return nil
    }

    func bool(_ field: Int) -> Bool { (uint(field) ?? 0) != 0 }

    func data(_ field: Int) -> Data? {
        if case .bytes(let d)? = fields[field]?.first { return d }
        return nil
    }

    func string(_ field: Int) -> String? { data(field).map { String(decoding: $0, as: UTF8.self) } }

    func message(_ field: Int) -> ProtoMessage? { data(field).map(ProtoMessage.init) }
}

/// YouTube's UMP container: a sequence of (part type, size, payload) with its own varints.
enum UMP {
    struct Part {
        var type: Int
        var payload: Data
    }

    static func parts(_ data: Data) -> [Part] {
        let b = [UInt8](data)
        var i = 0
        func readVarint() -> Int? {
            guard i < b.count else { return nil }
            let first = b[i]
            let n = first < 128 ? 1 : first < 192 ? 2 : first < 224 ? 3 : first < 240 ? 4 : 5
            guard i + n <= b.count else { return nil }
            var v: Int
            switch n {
            case 1: v = Int(first)
            case 2: v = Int(first & 0x3F) | Int(b[i + 1]) << 6
            case 3: v = Int(first & 0x1F) | Int(b[i + 1]) << 5 | Int(b[i + 2]) << 13
            case 4: v = Int(first & 0x0F) | Int(b[i + 1]) << 4 | Int(b[i + 2]) << 12 | Int(b[i + 3]) << 20
            default: v = Int(b[i + 1]) | Int(b[i + 2]) << 8 | Int(b[i + 3]) << 16 | Int(b[i + 4]) << 24
            }
            i += n
            return v
        }
        var out: [Part] = []
        while i < b.count {
            guard let type = readVarint(), let size = readVarint(), i + size <= b.count else { break }
            out.append(Part(type: type, payload: Data(b[i..<i + size])))
            i += size
        }
        return out
    }
}

/// UMP parsed as it arrives: feed chunks, get back every part that is complete so far.
struct UMPStreamParser {
    private var buffer: [UInt8] = []
    private var start = 0

    mutating func feed(_ chunk: Data) -> [UMP.Part] {
        buffer.append(contentsOf: chunk)
        var out: [UMP.Part] = []
        while true {
            var i = start
            guard let type = readVarint(&i), let size = readVarint(&i), i + size <= buffer.count else { break }
            out.append(UMP.Part(type: type, payload: Data(buffer[i..<i + size])))
            start = i + size
        }
        if start > 1 << 20 || start == buffer.count {
            buffer.removeFirst(start)
            start = 0
        }
        return out
    }

    private func readVarint(_ i: inout Int) -> Int? {
        guard i < buffer.count else { return nil }
        let b = buffer
        let first = b[i]
        let n = first < 128 ? 1 : first < 192 ? 2 : first < 224 ? 3 : first < 240 ? 4 : 5
        guard i + n <= b.count else { return nil }
        let v: Int
        switch n {
        case 1: v = Int(first)
        case 2: v = Int(first & 0x3F) | Int(b[i + 1]) << 6
        case 3: v = Int(first & 0x1F) | Int(b[i + 1]) << 5 | Int(b[i + 2]) << 13
        case 4: v = Int(first & 0x0F) | Int(b[i + 1]) << 4 | Int(b[i + 2]) << 12 | Int(b[i + 3]) << 20
        default: v = Int(b[i + 1]) | Int(b[i + 2]) << 8 | Int(b[i + 3]) << 16 | Int(b[i + 4]) << 24
        }
        i += n
        return v
    }
}
