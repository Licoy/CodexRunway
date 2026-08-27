import Foundation

public struct RateLimitResetTodayReactionClient: Sendable {
    public var session: URLSession
    public var cookieStore: RateLimitResetTodayReactionCookieStore
    public var devMockKind: RateLimitResetTodaySnapshot.DevMockKind?
    private let mockCounter: MockCounter

    public init(
        session: URLSession = RateLimitResetTodayReactionClient.session,
        cookieStore: RateLimitResetTodayReactionCookieStore = RateLimitResetTodayReactionCookieStore(),
        devMockKind: RateLimitResetTodaySnapshot.DevMockKind? = RateLimitResetTodayClient.resolveDevMockKind())
    {
        self.session = session
        self.cookieStore = cookieStore
        self.devMockKind = devMockKind
        self.mockCounter = MockCounter(count: 266)
    }

    public static let session: URLSession = URLSession(configuration: sessionConfiguration())

    public static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        return configuration
    }

    public func fetch() async throws -> RateLimitResetTodayReactionSnapshot {
        if let devMockKind {
            return RateLimitResetTodayReactionSnapshot.devMock(
                kind: devMockKind,
                count: mockCounter.count)
        }
        let request = RateLimitResetTodayReaction.makeRequest(
            method: "GET",
            visitorID: cookieStore.loadVisitorID())
        let (data, response) = try await session.data(for: request)
        cookieStore.saveVisitorID(from: response)
        guard let http = response as? HTTPURLResponse else {
            throw RateLimitResetTodayReactionError.unavailable
        }
        if http.statusCode == 404 {
            throw RateLimitResetTodayReactionError.disabled
        }
        guard 200..<300 ~= http.statusCode else {
            throw RateLimitResetTodayReactionError.unavailable
        }
        let envelope = try RateLimitResetTodayReaction.decodeEnvelope(data)
        if envelope.error == "disabled" {
            throw RateLimitResetTodayReactionError.disabled
        }
        guard envelope.ok, let snapshot = envelope.data else {
            throw RateLimitResetTodayReactionError.invalidPayload
        }
        return snapshot
    }

    public func click() async throws -> RateLimitResetTodayReactionPostResult {
        if let devMockKind {
            mockCounter.count += 1
            return RateLimitResetTodayReactionPostResult(
                ok: true,
                data: RateLimitResetTodayReactionSnapshot.devMock(
                    kind: devMockKind,
                    count: mockCounter.count))
        }
        let request = RateLimitResetTodayReaction.makeRequest(
            method: "POST",
            visitorID: cookieStore.loadVisitorID())
        let (data, response) = try await session.data(for: request)
        cookieStore.saveVisitorID(from: response)
        let parsed: RateLimitResetTodayReactionPostResult
        do {
            parsed = try RateLimitResetTodayReaction.decodeEnvelope(data)
        } catch {
            return RateLimitResetTodayReactionPostResult(ok: false)
        }
        if let http = response as? HTTPURLResponse, !(200..<300 ~= http.statusCode) {
            return RateLimitResetTodayReactionPostResult(
                ok: false,
                error: parsed.error ?? statusError(http.statusCode),
                data: parsed.data)
        }
        return parsed
    }

    private func statusError(_ code: Int) -> String {
        switch code {
        case 403: return "forbidden"
        case 404: return "disabled"
        case 429: return "rate_limited"
        default: return "unavailable"
        }
    }
}

extension RateLimitResetTodayReactionClient {
    fileprivate final class MockCounter: @unchecked Sendable {
        var count: Int

        init(count: Int) {
            self.count = count
        }
    }
}
