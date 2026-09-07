import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Update proxy capability routes")
struct UpdateProxyRoutesTests {
    private let source = URL(string: "https://github.com/Licoy/CodexRunway/releases/download/v1/CodexRunway.zip")!

    @Test("only official repository release URLs can be registered")
    func sourceAllowlist() {
        #expect(UpdateProxyRoutes.isAllowedSource(source))
        #expect(UpdateProxyRoutes.isAllowedSource(URL(string: "https://github.com/Licoy/codex-runway/releases/latest/download/appcast-arm64.xml")!))
        for value in [
            "http://github.com/Licoy/CodexRunway/releases/download/v1/app.zip",
            "https://github.com/other/CodexRunway/releases/download/v1/app.zip",
            "https://github.com/Licoy/other/releases/download/v1/app.zip",
            "https://github.com.evil.invalid/Licoy/CodexRunway/releases/download/v1/app.zip",
            "https://user:password@github.com/Licoy/CodexRunway/releases/download/v1/app.zip",
            "https://github.com:8443/Licoy/CodexRunway/releases/download/v1/app.zip",
            "https://github.com/Licoy/CodexRunway/releases/download/%2e%2e/app.zip",
            "https://github.com/Licoy/CodexRunway/releases/download/v1/app.zip#fragment",
            "https://release-assets.githubusercontent.com/asset",
            "file:///tmp/app.zip",
        ] {
            #expect(!UpdateProxyRoutes.isAllowedSource(URL(string: value)!))
        }
    }

    @Test("redirects are HTTPS and restricted to the official repository or GitHub release CDNs")
    func redirectAllowlist() {
        #expect(UpdateProxyRoutes.isAllowedRedirect(source))
        #expect(UpdateProxyRoutes.isAllowedRedirect(URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset/123?signature=test")!))
        for value in [
            "http://release-assets.githubusercontent.com/asset",
            "https://release-assets.githubusercontent.com.evil.invalid/asset",
            "https://user:password@objects.githubusercontent.com/asset",
            "https://github.com/other/project/releases/download/v1/app.zip",
            "http://localhost:1234/redirect",
            "https://127.0.0.1/redirect",
        ] {
            #expect(!UpdateProxyRoutes.isAllowedRedirect(URL(string: value)!))
        }
    }

    @Test("a route requires its cycle token, GET, and the expected Host without a request body")
    func rejectsUnregisteredAndMalformedRequests() throws {
        var routes = UpdateProxyRoutes()
        let local = try routes.register(source, port: 49152)
        let request = "GET \(local.path) HTTP/1.1\r\nHost: localhost:49152\r\n\r\n"
        #expect(routes.upstream(for: Data(request.utf8), port: 49152) == source)
        for invalid in [
            request.replacingOccurrences(of: local.path, with: "/wrong-token/resource"),
            request.replacingOccurrences(of: "GET ", with: "POST "),
            request.replacingOccurrences(of: local.path, with: local.absoluteString),
            request.replacingOccurrences(of: "localhost:49152", with: "evil.invalid:49152"),
            request.replacingOccurrences(of: "\r\n\r\n", with: "\r\nHost: localhost:49152\r\n\r\n"),
            request.replacingOccurrences(of: "\r\n\r\n", with: "\r\nContent-Length: 1\r\n\r\nx"),
            request.replacingOccurrences(of: "\r\n\r\n", with: "\r\nTransfer-Encoding: chunked\r\n\r\n"),
            request + "GET /another HTTP/1.1\r\n\r\n",
        ] {
            #expect(routes.upstream(for: Data(invalid.utf8), port: 49152) == nil)
        }
        let anotherCycle = UpdateProxyRoutes()
        #expect(anotherCycle.upstream(for: Data(request.utf8), port: 49152) == nil)
        #expect(!local.absoluteString.contains("github.com"))
    }
}
