import Foundation

extension JSONEncoder.DateEncodingStrategy {
    static var grokAccountStoreDates: Self {
        .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(GrokAccountStoreDateFormat.string(from: date))
        }
    }
}

extension JSONDecoder.DateDecodingStrategy {
    static var grokAccountStoreDates: Self {
        .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = GrokAccountStoreDateFormat.date(from: raw) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date")
            }
            return date
        }
    }
}

private enum GrokAccountStoreDateFormat {
    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func date(from raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}
