import Foundation

/// One banked SuperGrok usage-reset card from official `ConsumerUiSvc/GetRemainingResets`.
public struct GrokResetToken: Codable, Sendable, Equatable, Identifiable {
    public var id: String { tokenID }
    public var tokenID: String
    public var validityStart: Date?
    public var validityEnd: Date?

    public init(tokenID: String, validityStart: Date?, validityEnd: Date?) {
        self.tokenID = tokenID
        self.validityStart = validityStart
        self.validityEnd = validityEnd
    }

    /// Official web UI keeps a card only while `validityEnd` is still in the future.
    public func isAvailable(now: Date) -> Bool {
        guard !tokenID.isEmpty else { return false }
        guard let validityEnd else { return false }
        return validityEnd > now
    }
}

public struct GrokResetCreditsSnapshot: Codable, Sendable, Equatable {
    public var availableCount: Int
    public var tokens: [GrokResetToken]
    public var updatedAt: Date

    public init(availableCount: Int, tokens: [GrokResetToken], updatedAt: Date) {
        self.availableCount = availableCount
        self.tokens = tokens
        self.updatedAt = updatedAt
    }

    public func asResetCreditsSnapshot(now: Date? = nil) -> ResetCreditsSnapshot {
        let clock = now ?? updatedAt
        return ResetCreditsSnapshot(
            availableCount: availableCount,
            credits: tokens.map { token in
                ResetCredit(
                    id: token.tokenID,
                    status: token.isAvailable(now: clock) ? "available" : "unavailable",
                    createdAt: token.validityStart,
                    expiresAt: token.validityEnd,
                    remainingSeconds: max(0, token.validityEnd?.timeIntervalSince(clock) ?? 0))
            },
            updatedAt: updatedAt)
    }

    /// Decode official `ConsumerGetRemainingResetsResp` (gRPC-Web / Connect proto or JSON).
    public static func decode(from data: Data, now: Date = Date()) throws -> Self {
        let payload = try unwrapEnvelope(data)
        if payload.isEmpty {
            return Self(availableCount: 0, tokens: [], updatedAt: now)
        }
        if looksLikeJSON(payload) {
            return try decodeJSON(payload, now: now)
        }
        return try decodeProto(payload, now: now)
    }

    public static func grpcWebRequest(message: Data = Data()) -> Data {
        frame(message, flags: 0)
    }
}

public enum GrokResetCreditsDecodingError: Error, Sendable, Equatable {
    case invalidFrame
    case compressedUnsupported
    case rpcFailed(String)
    case unknownStructure
}

// MARK: - JSON

private func decodeJSON(_ data: Data, now: Date) throws -> GrokResetCreditsSnapshot {
    let object: Any
    do {
        object = try JSONSerialization.jsonObject(with: data)
    } catch {
        throw GrokResetCreditsDecodingError.unknownStructure
    }
    if object is NSNull {
        return GrokResetCreditsSnapshot(availableCount: 0, tokens: [], updatedAt: now)
    }
    guard let root = object as? [String: Any] else {
        throw GrokResetCreditsDecodingError.unknownStructure
    }
    let rawTokens = root["tokens"] as? [Any] ?? []
    let tokens = rawTokens.compactMap { item -> GrokResetToken? in
        guard let object = item as? [String: Any] else { return nil }
        return decodeJSONToken(object)
    }
    return makeSnapshot(tokens: tokens, now: now)
}

private func decodeJSONToken(_ object: [String: Any]) -> GrokResetToken? {
    let tokenID = firstNonEmpty(
        object["tokenId"] as? String,
        object["token_id"] as? String) ?? ""
    guard !tokenID.isEmpty else { return nil }
    let start = decodeJSONDate(
        object["validityStart"] ?? object["validity_start"])
    let end = decodeJSONDate(
        object["validityEnd"] ?? object["validity_end"])
    guard end != nil else { return nil }
    return GrokResetToken(tokenID: tokenID, validityStart: start, validityEnd: end)
}

private func decodeJSONDate(_ value: Any?) -> Date? {
    switch value {
    case let text as String:
        return RunwayDates.parse(text)
    case let seconds as Double:
        return Date(timeIntervalSince1970: seconds)
    case let seconds as Int:
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    case let seconds as Int64:
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    case let object as [String: Any]:
        let seconds = int64Value(object["seconds"])
        let nanos = int64Value(object["nanos"]) ?? 0
        guard let seconds else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(nanos) / 1_000_000_000)
    default:
        return nil
    }
}

private func int64Value(_ value: Any?) -> Int64? {
    switch value {
    case let number as Int64:
        return number
    case let number as Int:
        return Int64(number)
    case let number as Double:
        return Int64(number)
    case let text as String:
        return Int64(text)
    default:
        return nil
    }
}

// MARK: - Proto (prod_mc_billing.ConsumerGetRemainingResetsResp)

private func decodeProto(_ data: Data, now: Date) throws -> GrokResetCreditsSnapshot {
    let fields = try ProtoReader.fields(in: data)
    let tokens = (fields[ProtoField.tokens] ?? []).compactMap { value -> GrokResetToken? in
        guard case let .bytes(payload) = value else { return nil }
        return decodeProtoToken(payload)
    }
    return makeSnapshot(tokens: tokens, now: now)
}

private func decodeProtoToken(_ data: Data) -> GrokResetToken? {
    guard let fields = try? ProtoReader.fields(in: data) else { return nil }
    let tokenID = (fields[ProtoField.tokenID] ?? []).compactMap { value -> String? in
        guard case let .bytes(payload) = value else { return nil }
        return String(data: payload, encoding: .utf8)
    }.first ?? ""
    guard !tokenID.isEmpty else { return nil }
    let start = (fields[ProtoField.validityStart] ?? []).compactMap { value -> Date? in
        guard case let .bytes(payload) = value else { return nil }
        return decodeProtoTimestamp(payload)
    }.first
    let end = (fields[ProtoField.validityEnd] ?? []).compactMap { value -> Date? in
        guard case let .bytes(payload) = value else { return nil }
        return decodeProtoTimestamp(payload)
    }.first
    guard end != nil else { return nil }
    return GrokResetToken(tokenID: tokenID, validityStart: start, validityEnd: end)
}

private func decodeProtoTimestamp(_ data: Data) -> Date? {
    guard let fields = try? ProtoReader.fields(in: data) else { return nil }
    let seconds = (fields[1] ?? []).compactMap { value -> Int64? in
        if case let .varint(raw) = value { return Int64(bitPattern: raw) }
        return nil
    }.first ?? 0
    let nanos = (fields[2] ?? []).compactMap { value -> Int64? in
        if case let .varint(raw) = value { return Int64(bitPattern: raw) }
        return nil
    }.first ?? 0
    return Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(nanos) / 1_000_000_000)
}

private enum ProtoField {
    /// `ConsumerGetRemainingResetsResp.tokens`
    static let tokens = 10
    /// `ConsumerResetToken.token_id`
    static let tokenID = 10
    /// `ConsumerResetToken.validity_start`
    static let validityStart = 20
    /// `ConsumerResetToken.validity_end`
    static let validityEnd = 30
}

private func makeSnapshot(tokens: [GrokResetToken], now: Date) -> GrokResetCreditsSnapshot {
    GrokResetCreditsSnapshot(
        availableCount: tokens.filter { $0.isAvailable(now: now) }.count,
        tokens: tokens,
        updatedAt: now)
}

// MARK: - gRPC-Web / Connect envelope

private func unwrapEnvelope(_ data: Data) throws -> Data {
    if data.isEmpty || looksLikeJSON(data) {
        return data
    }
    guard data.count >= 5, data[0] == 0 || data[0] == 0x80 || data[0] == 1 else {
        return data
    }
    var offset = 0
    var message = Data()
    var status: Int?
    var statusMessage: String?
    while offset + 5 <= data.count {
        let flags = data[offset]
        let length = Int(data[offset + 1]) << 24
            | Int(data[offset + 2]) << 16
            | Int(data[offset + 3]) << 8
            | Int(data[offset + 4])
        offset += 5
        guard offset + length <= data.count else {
            throw GrokResetCreditsDecodingError.invalidFrame
        }
        let payload = data.subdata(in: offset..<(offset + length))
        offset += length
        if flags & 0x80 != 0 {
            parseTrailers(payload, status: &status, message: &statusMessage)
            continue
        }
        if flags & 0x01 != 0 {
            throw GrokResetCreditsDecodingError.compressedUnsupported
        }
        message.append(payload)
    }
    if let status, status != 0 {
        throw GrokResetCreditsDecodingError.rpcFailed(statusMessage ?? "grpc-status \(status)")
    }
    return message
}

private func parseTrailers(
    _ payload: Data,
    status: inout Int?,
    message: inout String?)
{
    let text = String(data: payload, encoding: .utf8) ?? ""
    for rawLine in text.split(whereSeparator: \.isNewline) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = line.firstIndex(of: ":") else { continue }
        let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
        let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        if name == "grpc-status" {
            status = Int(value)
        } else if name == "grpc-message" {
            message = value.removingPercentEncoding ?? value
        }
    }
}

private func frame(_ message: Data, flags: UInt8) -> Data {
    var data = Data(count: 5 + message.count)
    data[0] = flags
    let length = UInt32(message.count).bigEndian
    withUnsafeBytes(of: length) { buffer in
        data.replaceSubrange(1..<5, with: buffer)
    }
    if !message.isEmpty {
        data.replaceSubrange(5..<(5 + message.count), with: message)
    }
    return data
}

private func looksLikeJSON(_ data: Data) -> Bool {
    var index = data.startIndex
    while index < data.endIndex, data[index] == 0x20 || data[index] == 0x09
        || data[index] == 0x0A || data[index] == 0x0D
    {
        index = data.index(after: index)
    }
    guard index < data.endIndex else { return false }
    return data[index] == 0x7B || data[index] == 0x5B
}

// MARK: - Minimal protobuf reader

private enum ProtoValue {
    case varint(UInt64)
    case bytes(Data)
}

private enum ProtoReader {
    static func fields(in data: Data) throws -> [Int: [ProtoValue]] {
        var result: [Int: [ProtoValue]] = [:]
        var offset = 0
        while offset < data.count {
            let tag: UInt64
            do {
                (tag, offset) = try readVarint(data, offset: offset)
            } catch {
                throw GrokResetCreditsDecodingError.unknownStructure
            }
            let field = Int(tag >> 3)
            let wire = Int(tag & 0x7)
            switch wire {
            case 0:
                let value: UInt64
                (value, offset) = try readVarint(data, offset: offset)
                result[field, default: []].append(.varint(value))
            case 1:
                guard offset + 8 <= data.count else {
                    throw GrokResetCreditsDecodingError.unknownStructure
                }
                offset += 8
            case 2:
                let length: UInt64
                (length, offset) = try readVarint(data, offset: offset)
                let count = Int(length)
                guard count >= 0, offset + count <= data.count else {
                    throw GrokResetCreditsDecodingError.unknownStructure
                }
                result[field, default: []].append(.bytes(data.subdata(in: offset..<(offset + count))))
                offset += count
            case 5:
                guard offset + 4 <= data.count else {
                    throw GrokResetCreditsDecodingError.unknownStructure
                }
                offset += 4
            default:
                throw GrokResetCreditsDecodingError.unknownStructure
            }
        }
        return result
    }

    private static func readVarint(_ data: Data, offset: Int) throws -> (UInt64, Int) {
        var value: UInt64 = 0
        var shift = 0
        var index = offset
        while index < data.count {
            let byte = data[index]
            index += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte < 0x80 {
                return (value, index)
            }
            shift += 7
            if shift > 63 {
                throw GrokResetCreditsDecodingError.unknownStructure
            }
        }
        throw GrokResetCreditsDecodingError.unknownStructure
    }
}
