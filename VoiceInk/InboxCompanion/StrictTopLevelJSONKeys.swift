import Foundation

struct StrictTopLevelJSONKeys {
    private let bytes: [UInt8]
    private var index = 0

    init(data: Data) { bytes = Array(data) }

    mutating func parse() -> [String]? {
        skipWhitespace()
        guard consume(0x7B) else { return nil }
        skipWhitespace()
        if consume(0x7D) { return [] }
        var keys: [String] = []
        while true {
            guard let key = parseString() else { return nil }
            keys.append(key)
            skipWhitespace()
            guard consume(0x3A), parseValue() else { return nil }
            skipWhitespace()
            if consume(0x7D) {
                skipWhitespace()
                return index == bytes.count ? keys : nil
            }
            guard consume(0x2C) else { return nil }
            skipWhitespace()
        }
    }

    private mutating func parseValue() -> Bool {
        skipWhitespace()
        guard index < bytes.count else { return false }
        switch bytes[index] {
        case 0x22: return parseString() != nil
        case 0x7B: return parseObject()
        case 0x5B: return parseArray()
        case 0x74: return consumeLiteral([0x74, 0x72, 0x75, 0x65])
        case 0x66: return consumeLiteral([0x66, 0x61, 0x6C, 0x73, 0x65])
        case 0x6E: return consumeLiteral([0x6E, 0x75, 0x6C, 0x6C])
        default: return parseNumber()
        }
    }

    private mutating func parseObject() -> Bool {
        guard consume(0x7B) else { return false }
        skipWhitespace()
        if consume(0x7D) { return true }
        while true {
            guard parseString() != nil else { return false }
            skipWhitespace()
            guard consume(0x3A), parseValue() else { return false }
            skipWhitespace()
            if consume(0x7D) { return true }
            guard consume(0x2C) else { return false }
            skipWhitespace()
        }
    }

    private mutating func parseArray() -> Bool {
        guard consume(0x5B) else { return false }
        skipWhitespace()
        if consume(0x5D) { return true }
        while true {
            guard parseValue() else { return false }
            skipWhitespace()
            if consume(0x5D) { return true }
            guard consume(0x2C) else { return false }
            skipWhitespace()
        }
    }

    private mutating func parseString() -> String? {
        guard index < bytes.count, bytes[index] == 0x22 else { return nil }
        let start = index
        index += 1
        while index < bytes.count {
            switch bytes[index] {
            case 0x22:
                index += 1
                return try? JSONDecoder().decode(String.self, from: Data(bytes[start ..< index]))
            case 0x5C:
                index += 2
            case 0x00 ... 0x1F:
                return nil
            default:
                index += 1
            }
        }
        return nil
    }

    private mutating func parseNumber() -> Bool {
        let start = index
        while index < bytes.count, ![0x2C, 0x5D, 0x7D, 0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) {
            index += 1
        }
        return index > start
    }

    private mutating func consumeLiteral(_ literal: [UInt8]) -> Bool {
        guard bytes[index...].starts(with: literal) else { return false }
        index += literal.count
        return true
    }

    private mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }
}
