import Darwin
import Foundation

final class UsageCostLogParser {
    private let decoder = JSONDecoder()
    private let fractionalTimestamp: ISO8601DateFormatter
    private let plainTimestamp: ISO8601DateFormatter
    private let dayFormatter: DateFormatter

    init(calendar: Calendar = .autoupdatingCurrent) {
        fractionalTimestamp = ISO8601DateFormatter()
        fractionalTimestamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        plainTimestamp = ISO8601DateFormatter()
        plainTimestamp.formatOptions = [.withInternetDateTime]
        dayFormatter = DateFormatter()
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = calendar.timeZone
        dayFormatter.dateFormat = "yyyy-MM-dd"
    }

    func parse(_ data: Data) throws -> UsageCostLogRecord {
        let encoded = try decoder.decode(EncodedUsageCostRecord.self, from: data)
        let parsedTimestamp = encoded.timestamp.flatMap(parseTimestamp)
        let timestamp = parsedTimestamp?.date ?? .distantPast
        let payload = encoded.payload
        let turnContext = encoded.turnContext
        let contextModel = encoded.type == "turn_context"
            ? payload?.model
            : turnContext?.model
        return UsageCostLogRecord(
            timestamp: timestamp,
            dayKey: parsedTimestamp?.dayKey ?? dayFormatter.string(from: timestamp),
            model: turnContext?.model ?? payload?.model,
            contextModel: contextModel,
            sessionCWD: payload?.cwd ?? turnContext?.cwd,
            lastTokenUsage: try payload?.info?.lastTokenUsage?.decodedUsage(),
            countsAsTurn: payload?.type == "task_complete")
    }

    private func parseTimestamp(_ text: String) -> ParsedTimestamp? {
        let bytes = Array(text.utf8)
        if let date = Self.parseZuluTimestamp(bytes) {
            return ParsedTimestamp(
                date: date,
                dayKey: dayFormatter.string(from: date))
        }
        guard let date = fractionalTimestamp.date(from: text) ?? plainTimestamp.date(from: text) else {
            return nil
        }
        return ParsedTimestamp(date: date, dayKey: dayFormatter.string(from: date))
    }

    private static func parseZuluTimestamp(_ bytes: [UInt8]) -> Date? {
        guard bytes.count >= 20,
              bytes[4] == 0x2D, bytes[7] == 0x2D, bytes[10] == 0x54,
              bytes[13] == 0x3A, bytes[16] == 0x3A,
              let year = decimal(bytes, at: 0, length: 4),
              let month = decimal(bytes, at: 5, length: 2),
              let day = decimal(bytes, at: 8, length: 2),
              let hour = decimal(bytes, at: 11, length: 2),
              let minute = decimal(bytes, at: 14, length: 2),
              let second = decimal(bytes, at: 17, length: 2)
        else { return nil }

        var fraction = 0.0
        if bytes.count == 20 {
            guard bytes[19] == 0x5A else { return nil }
        } else {
            guard bytes[19] == 0x2E, bytes.last == 0x5A else { return nil }
            let digitCount = bytes.count - 21
            guard (1...9).contains(digitCount) else { return nil }
            var scale = 0.1
            for byte in bytes[20..<(bytes.count - 1)] {
                guard byte >= 0x30, byte <= 0x39 else { return nil }
                fraction += Double(byte - 0x30) * scale
                scale *= 0.1
            }
        }

        var value = tm()
        value.tm_year = Int32(year - 1_900)
        value.tm_mon = Int32(month - 1)
        value.tm_mday = Int32(day)
        value.tm_hour = Int32(hour)
        value.tm_min = Int32(minute)
        value.tm_sec = Int32(second)
        value.tm_isdst = 0
        let expected = (
            value.tm_year, value.tm_mon, value.tm_mday,
            value.tm_hour, value.tm_min, value.tm_sec)
        let seconds = timegm(&value)
        guard expected.0 == value.tm_year,
              expected.1 == value.tm_mon,
              expected.2 == value.tm_mday,
              expected.3 == value.tm_hour,
              expected.4 == value.tm_min,
              expected.5 == value.tm_sec
        else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds) + fraction)
    }

    private static func decimal(_ bytes: [UInt8], at start: Int, length: Int) -> Int? {
        var value = 0
        for byte in bytes[start..<(start + length)] {
            guard byte >= 0x30, byte <= 0x39 else { return nil }
            value = value * 10 + Int(byte - 0x30)
        }
        return value
    }
}

private struct ParsedTimestamp {
    var date: Date
    var dayKey: String
}

private struct EncodedUsageCostRecord: Decodable {
    var timestamp: String?
    var type: String?
    var payload: EncodedUsagePayload?
    var turnContext: EncodedTurnContext?

    enum CodingKeys: String, CodingKey {
        case timestamp
        case type
        case payload
        case turnContext = "turn_context"
    }
}

private struct EncodedTurnContext: Decodable {
    var model: String?
    var cwd: String?
}

private struct EncodedUsagePayload: Decodable {
    var type: String?
    var model: String?
    var cwd: String?
    var info: EncodedUsageInfo?
}

private struct EncodedUsageInfo: Decodable {
    var lastTokenUsage: EncodedTokenUsage?

    enum CodingKeys: String, CodingKey {
        case lastTokenUsage = "last_token_usage"
    }
}

private struct EncodedTokenUsage: Decodable {
    var inputTokens: Int?
    var cachedInputTokens: Int?
    var outputTokens: Int?
    var reasoningOutputTokens: Int?

    func decodedUsage() throws -> TokenUsage {
        let input = inputTokens ?? 0
        let cached = cachedInputTokens ?? 0
        let output = outputTokens ?? 0
        let reasoning = reasoningOutputTokens ?? 0
        guard input >= 0, cached >= 0, output >= 0, reasoning >= 0, cached <= input else {
            throw UsageCostLogParserError.invalidTokenUsage
        }
        let (_, totalOverflow) = input.addingReportingOverflow(output)
        guard !totalOverflow else {
            throw UsageCostLogParserError.invalidTokenUsage
        }
        return TokenUsage(
            inputTokens: input,
            cachedInputTokens: cached,
            outputTokens: output)
    }

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case cachedInputTokens = "cached_input_tokens"
        case outputTokens = "output_tokens"
        case reasoningOutputTokens = "reasoning_output_tokens"
    }
}

private enum UsageCostLogParserError: Error {
    case invalidTokenUsage
}
