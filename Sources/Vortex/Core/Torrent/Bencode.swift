import Foundation

public enum BencodeValue: Equatable, Sendable {
    case string(Data)
    case int(Int64)
    case list([BencodeValue])
    case dict([String: BencodeValue])

    public var stringValue: String? {
        if case .string(let data) = self {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    public var intValue: Int64? {
        if case .int(let v) = self { return v }
        return nil
    }

    public var listValue: [BencodeValue]? {
        if case .list(let v) = self { return v }
        return nil
    }

    public var dictValue: [String: BencodeValue]? {
        if case .dict(let v) = self { return v }
        return nil
    }
}

public struct BencodeParser {
    public static func parse(data: Data) throws -> BencodeValue {
        var index = 0
        return try parseValue(data: data, index: &index)
    }

    private static func parseValue(data: Data, index: inout Int) throws -> BencodeValue {
        guard index < data.count else {
            throw NSError(domain: "Bencode", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unexpected EOF"])
        }

        let byte = data[index]
        switch byte {
        case UInt8(ascii: "i"):
            // Integer: i<digits>e
            index += 1
            guard let eIndex = data[index...].firstIndex(of: UInt8(ascii: "e")) else {
                throw NSError(domain: "Bencode", code: -2, userInfo: [NSLocalizedDescriptionKey: "Malformed integer"])
            }
            let str = String(data: data[index..<eIndex], encoding: .ascii) ?? "0"
            index = eIndex + 1
            return .int(Int64(str) ?? 0)

        case UInt8(ascii: "l"):
            // List: l<items>e
            index += 1
            var list: [BencodeValue] = []
            while index < data.count && data[index] != UInt8(ascii: "e") {
                list.append(try parseValue(data: data, index: &index))
            }
            index += 1 // skip 'e'
            return .list(list)

        case UInt8(ascii: "d"):
            // Dictionary: d<key><val>e
            index += 1
            var dict: [String: BencodeValue] = [:]
            while index < data.count && data[index] != UInt8(ascii: "e") {
                let keyVal = try parseValue(data: data, index: &index)
                guard let keyStr = keyVal.stringValue else {
                    throw NSError(domain: "Bencode", code: -3, userInfo: [NSLocalizedDescriptionKey: "Dictionary key must be string"])
                }
                let val = try parseValue(data: data, index: &index)
                dict[keyStr] = val
            }
            index += 1 // skip 'e'
            return .dict(dict)

        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            // Byte string: <length>:<bytes>
            guard let colonIndex = data[index...].firstIndex(of: UInt8(ascii: ":")) else {
                throw NSError(domain: "Bencode", code: -4, userInfo: [NSLocalizedDescriptionKey: "Malformed byte string length"])
            }
            let lenStr = String(data: data[index..<colonIndex], encoding: .ascii) ?? "0"
            guard let len = Int(lenStr) else {
                throw NSError(domain: "Bencode", code: -5, userInfo: [NSLocalizedDescriptionKey: "Invalid length"])
            }
            let start = colonIndex + 1
            let end = start + len
            guard end <= data.count else {
                throw NSError(domain: "Bencode", code: -6, userInfo: [NSLocalizedDescriptionKey: "Byte string out of bounds"])
            }
            index = end
            return .string(data.subdata(in: start..<end))

        default:
            throw NSError(domain: "Bencode", code: -7, userInfo: [NSLocalizedDescriptionKey: "Invalid byte \(byte) at \(index)"])
        }
    }
}
