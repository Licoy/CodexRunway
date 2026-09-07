import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Local HTTP and SOCKS5 proxy integration")
struct NetworkProxyIntegrationTests {
    @Test("TLS payload reaches the target through the configured proxy",
          arguments: [NetworkProxyMode.http, .socks5], [false, true])
    func proxyCarriesTLS(mode: NetworkProxyMode, authentication: Bool) async throws {
        let fixture = try await NetworkProxyFixture.start(mode: mode, authentication: authentication)
        defer { fixture.stop() }
        let context = try makeContext(
            mode: mode, port: fixture.information.proxyPort, password: authentication ? "fixture-password" : nil)
        let session = try fixture.makeSession(context: context)
        defer { session.invalidateAndCancel() }

        let payload = try await requestPayload(session: session, url: virtualTarget)
        let state = try fixture.state()

        #expect(payload.ok)
        #expect(payload.transport == mode.rawValue)
        #expect(state.proxyConnections >= 1)
        #expect(state.tunneledRequests == 1)
        #expect(state.authorities.contains("proxy-target.invalid:443"))
        #expect(state.authenticationSuccesses == (authentication ? 1 : 0))
        #expect(!state.targetReceivedProxyAuthorization)
        #expect(!state.targetReceivedProxyCredentials)
        #expect(state.errors.isEmpty)
    }

    @Test("wrong proxy credentials are rejected before any TLS target request",
          arguments: [NetworkProxyMode.http, .socks5])
    func incorrectCredentialsAreRejected(mode: NetworkProxyMode) async throws {
        let fixture = try await NetworkProxyFixture.start(mode: mode, authentication: true)
        defer { fixture.stop() }
        let context = try makeContext(
            mode: mode, port: fixture.information.proxyPort,
            password: "wrong-fixture-password")
        let virtualFailure: (any Error)?
        do {
            _ = try await context.data(for: URLRequest(url: virtualTarget))
            virtualFailure = nil
        } catch {
            virtualFailure = error
        }
        let state = try fixture.state()

        #expect(virtualFailure != nil)
        if let virtualFailure {
            #expect(context.mappedError(virtualFailure) as? NetworkProxyError == .authenticationFailed)
        }
        #expect(state.proxyConnections >= 1)
        #expect(state.authenticationAttempts >= 1)
        #expect(state.authenticationSuccesses == 0)
        #expect(state.tunneledRequests == 0)
        #expect(!state.targetReceivedProxyAuthorization)
        #expect(!state.targetReceivedProxyCredentials)
        #expect(state.errors.isEmpty)
    }

    @Test("an unavailable proxy fails for the virtual target",
          arguments: [NetworkProxyMode.http, .socks5])
    func unavailableProxyReportsFailure(mode: NetworkProxyMode) async throws {
        let fixture = try await NetworkProxyFixture.start(mode: mode, authentication: false)
        defer { fixture.stop() }
        let context = try makeContext(mode: mode, port: fixture.information.unavailablePort)
        let session = try fixture.makeSession(context: context)
        defer { session.invalidateAndCancel() }

        let failure = await requestFailure(session: session, url: virtualTarget)
        let state = try fixture.state()

        #expect(failure != nil)
        #expect(state.proxyConnections == 0)
        #expect(state.tunneledRequests == 0)
        #expect(state.errors.isEmpty)
    }

    private var virtualTarget: URL { URL(string: "https://proxy-target.invalid/payload")! }

    private func makeContext(
        mode: NetworkProxyMode, port: Int, password: String? = nil) throws -> RunwayNetworkContext
    {
        try RunwayNetworkContext(
            configuration: .init(mode: mode, host: "127.0.0.1", port: port, usesAuthentication: password != nil),
            credentials: password.map { .init(username: "fixture-user", password: $0) })
    }

    private func requestFailure(session: URLSession, url: URL) async -> (any Error)? {
        do {
            _ = try await requestPayload(session: session, url: url)
            return nil
        } catch {
            return error
        }
    }

    private func requestPayload(session: URLSession, url: URL) async throws -> ProxyFixturePayload {
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(ProxyFixturePayload.self, from: data)
    }
}

private struct ProxyFixturePayload: Decodable {
    let ok: Bool
    let transport: String
}
