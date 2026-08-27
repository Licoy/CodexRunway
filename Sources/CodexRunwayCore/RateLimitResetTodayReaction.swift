import Foundation

public struct RateLimitResetTodayReactionDelta: Sendable, Equatable {
    public var id: UUID
    public var amount: Int

    public init(amount: Int, id: UUID = UUID()) {
        self.id = id
        self.amount = amount
    }

    public static let none = RateLimitResetTodayReactionDelta(amount: 0, id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)
}

public enum RateLimitResetTodayReactionPolarity: String, Sendable, Equatable {
    case yes
    case no
}

public enum RateLimitResetTodayReactionError: Error, Equatable, Sendable {
    case disabled
    case forbidden
    case rateLimited
    case unavailable
    case invalidPayload
}

public struct RateLimitResetTodayReactionSnapshot: Sendable, Equatable {
    public var enabled: Bool
    public var ready: Bool
    public var polarity: RateLimitResetTodayReactionPolarity?
    public var epochId: String?
    public var seed: Int?
    public var count: Int?
    public var remaining: Int?
    public var dailyLimit: Int
    public var pollMs: Int

    public init(
        enabled: Bool,
        ready: Bool,
        polarity: RateLimitResetTodayReactionPolarity?,
        epochId: String?,
        seed: Int?,
        count: Int?,
        remaining: Int?,
        dailyLimit: Int,
        pollMs: Int)
    {
        self.enabled = enabled
        self.ready = ready
        self.polarity = polarity
        self.epochId = epochId
        self.seed = seed
        self.count = count
        self.remaining = remaining
        self.dailyLimit = dailyLimit
        self.pollMs = RateLimitResetTodayReaction.clampedPollMs(pollMs)
    }

    public static let disabled = RateLimitResetTodayReactionSnapshot(
        enabled: false,
        ready: false,
        polarity: nil,
        epochId: nil,
        seed: nil,
        count: nil,
        remaining: nil,
        dailyLimit: 0,
        pollMs: RateLimitResetTodayReaction.defaultPollMs)

    public var isVisible: Bool {
        enabled && ready && polarity != nil && count != nil
    }

    public var isExhausted: Bool {
        RateLimitResetTodayReaction.isExhausted(remaining: remaining, dailyLimit: dailyLimit)
    }

    public var pollInterval: TimeInterval {
        TimeInterval(pollMs) / 1_000
    }

    public static func devMock(
        kind: RateLimitResetTodaySnapshot.DevMockKind,
        count: Int = 266) -> RateLimitResetTodayReactionSnapshot
    {
        RateLimitResetTodayReactionSnapshot(
            enabled: true,
            ready: true,
            polarity: kind == .yes ? .yes : .no,
            epochId: "dev-mock-epoch",
            seed: count,
            count: count,
            remaining: nil,
            dailyLimit: 0,
            pollMs: RateLimitResetTodayReaction.defaultPollMs)
    }
}

public struct RateLimitResetTodayReactionLocal: Sendable, Equatable {
    public var epochId: String?
    public var previousCount: Int
    public var previousRemaining: Int?

    public init(epochId: String?, previousCount: Int, previousRemaining: Int?) {
        self.epochId = epochId
        self.previousCount = previousCount
        self.previousRemaining = previousRemaining
    }
}

public struct RateLimitResetTodayReactionPostResult: Sendable, Equatable {
    public var ok: Bool
    public var error: String?
    public var data: RateLimitResetTodayReactionSnapshot?

    public init(ok: Bool, error: String? = nil, data: RateLimitResetTodayReactionSnapshot? = nil) {
        self.ok = ok
        self.error = error
        self.data = data
    }
}

public struct RateLimitResetTodayReactionReconcile: Sendable, Equatable {
    public var count: Int
    public var remaining: Int?
    public var exhausted: Bool
    public var epochId: String?
    public var payload: RateLimitResetTodayReactionSnapshot?

    public init(
        count: Int,
        remaining: Int?,
        exhausted: Bool,
        epochId: String?,
        payload: RateLimitResetTodayReactionSnapshot?)
    {
        self.count = count
        self.remaining = remaining
        self.exhausted = exhausted
        self.epochId = epochId
        self.payload = payload
    }
}

public enum RateLimitResetTodayReaction {
    public static let cookieName = "hr_react"
    public static let origin = "https://www.codexrunway.com"
    public static let referer = "https://www.codexrunway.com/"
    public static let defaultPollMs = 5_000
    public static let reactionURL = URL(string: "https://www.codexrunway.com/api/reaction")!

    public static func parseVisitorID(_ value: String?) -> String? {
        guard let value else { return nil }
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard raw.count == 32, raw.unicodeScalars.allSatisfy(isHexScalar) else { return nil }
        return raw
    }

    public static func isExhausted(remaining: Int?, dailyLimit: Int) -> Bool {
        if dailyLimit <= 0 { return false }
        guard let remaining else { return false }
        return remaining <= 0
    }

    public static func positiveDelta(
        previousCount: Int?,
        nextCount: Int?,
        previousEpoch: String?,
        nextEpoch: String?) -> Int
    {
        guard let previousEpoch, let nextEpoch, previousEpoch == nextEpoch else { return 0 }
        guard let previousCount, let nextCount else { return 0 }
        let delta = nextCount - previousCount
        return delta > 0 ? delta : 0
    }

    public static func optimisticClick(
        _ snapshot: RateLimitResetTodayReactionSnapshot) -> RateLimitResetTodayReactionSnapshot
    {
        var next = snapshot
        next.count = (snapshot.count ?? 0) + 1
        if snapshot.dailyLimit > 0, let remaining = snapshot.remaining {
            next.remaining = max(0, remaining - 1)
        }
        return next
    }

    public static func reconcileAfterPost(
        local: RateLimitResetTodayReactionLocal,
        response: RateLimitResetTodayReactionPostResult?) -> RateLimitResetTodayReactionReconcile
    {
        guard let response, response.ok, let data = response.data, data.ready else {
            return RateLimitResetTodayReactionReconcile(
                count: local.previousCount,
                remaining: local.previousRemaining,
                exhausted: response?.error == "daily_limit",
                epochId: local.epochId,
                payload: response?.data)
        }
        return RateLimitResetTodayReactionReconcile(
            count: data.count ?? local.previousCount,
            remaining: data.remaining ?? local.previousRemaining,
            exhausted: isExhausted(remaining: data.remaining, dailyLimit: data.dailyLimit),
            epochId: data.epochId,
            payload: data)
    }

    public static func clampedPollMs(_ value: Int) -> Int {
        min(max(value, 1_000), 10_000)
    }

    public static func formatCount(_ count: Int, language: ResolvedLanguage) -> String {
        let formatter = NumberFormatter()
        formatter.locale = language.locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: count)) ?? String(count)
    }

    public static func formatDelta(_ delta: Int, language: ResolvedLanguage) -> String {
        guard delta > 0 else { return "" }
        return "+\(formatCount(delta, language: language))"
    }

    public static func visitorID(from response: URLResponse) -> String? {
        guard let http = response as? HTTPURLResponse else { return nil }
        var fields: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            fields[String(describing: key)] = String(describing: value)
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: reactionURL)
        if let match = cookies.first(where: { $0.name == cookieName }) {
            return parseVisitorID(match.value)
        }
        if let raw = fields["Set-Cookie"] ?? fields["set-cookie"] {
            return visitorID(fromSetCookie: raw)
        }
        return nil
    }

    public static func decodeEnvelope(_ data: Data) throws -> RateLimitResetTodayReactionPostResult {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        return RateLimitResetTodayReactionPostResult(
            ok: envelope.ok,
            error: envelope.error,
            data: envelope.data.map(Self.snapshot(from:)))
    }

    static func makeRequest(method: String, visitorID: String?) -> URLRequest {
        var request = URLRequest(url: reactionURL)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let visitorID {
            request.setValue("\(cookieName)=\(visitorID)", forHTTPHeaderField: "Cookie")
        }
        if method == "POST" {
            request.setValue(origin, forHTTPHeaderField: "Origin")
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }
        return request
    }

    private static func visitorID(fromSetCookie raw: String) -> String? {
        let pair = raw.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? raw
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[0].trimmingCharacters(in: .whitespaces) == cookieName
        else { return nil }
        return parseVisitorID(String(parts[1]))
    }

    private static func snapshot(from payload: Payload) -> RateLimitResetTodayReactionSnapshot {
        RateLimitResetTodayReactionSnapshot(
            enabled: payload.enabled,
            ready: payload.ready,
            polarity: payload.polarity.flatMap(RateLimitResetTodayReactionPolarity.init(rawValue:)),
            epochId: payload.epochId,
            seed: payload.seed,
            count: payload.count,
            remaining: payload.remaining,
            dailyLimit: payload.dailyLimit,
            pollMs: payload.pollMs ?? defaultPollMs)
    }

    private static func isHexScalar(_ scalar: Unicode.Scalar) -> Bool {
        ("0"..."9").contains(scalar) || ("a"..."f").contains(scalar)
    }
}

private struct Envelope: Decodable {
    var ok: Bool
    var error: String?
    var data: Payload?
}

private struct Payload: Decodable {
    var enabled: Bool
    var ready: Bool
    var polarity: String?
    var epochId: String?
    var seed: Int?
    var count: Int?
    var remaining: Int?
    var dailyLimit: Int
    var pollMs: Int?
}
