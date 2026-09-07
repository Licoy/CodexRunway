import Darwin
import Foundation
import Security
@testable import CodexRunwayCore

struct ProxyFixtureInformation: Decodable {
    let proxyPort: Int
    let unavailablePort: Int
}

struct ProxyFixtureState: Decodable {
    let proxyConnections: Int
    let authenticationAttempts: Int
    let authenticationSuccesses: Int
    let tunneledRequests: Int
    let targetReceivedProxyAuthorization: Bool
    let targetReceivedProxyCredentials: Bool
    let authorities: [String]
    let errors: [String]
}

enum ProxyFixtureError: Error {
    case startup(String)
    case invalidCertificate
}

final class NetworkProxyFixture: @unchecked Sendable {
    let information: ProxyFixtureInformation
    let certificate: Data
    private let process: Process
    private let directory: URL

    private init(process: Process, directory: URL, information: ProxyFixtureInformation) throws {
        self.process = process
        self.directory = directory
        self.information = information
        self.certificate = try Data(contentsOf: directory.appendingPathComponent("certificate.der"))
    }

    static func start(mode: NetworkProxyMode, authentication: Bool) async throws -> NetworkProxyFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-runway-proxy-integration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let process = Process()
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/network_proxy_fixture.py")
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-B", script.path, "--directory", directory.path, "--mode", mode.rawValue]
            + (authentication ? ["--authentication"] : [])
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errorURL = directory.appendingPathComponent("stderr.txt")
        FileManager.default.createFile(atPath: errorURL.path, contents: Data())
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        process.standardError = errorHandle
        do {
            try process.run()
            try errorHandle.close()
            let information = try await waitUntilReady(process: process, directory: directory)
            return try NetworkProxyFixture(process: process, directory: directory, information: information)
        } catch {
            stop(process: process, directory: directory)
            throw error
        }
    }

    func state() throws -> ProxyFixtureState {
        try Self.decode(ProxyFixtureState.self, from: directory.appendingPathComponent("state.json"))
    }

    func makeSession(context: RunwayNetworkContext) throws -> URLSession {
        context.makeSession(delegate: try ProxyFixtureTrustDelegate(context: context, certificate: certificate))
    }

    func stop() { Self.stop(process: process, directory: directory) }
    deinit { stop() }

    private static func waitUntilReady(process: Process, directory: URL) async throws -> ProxyFixtureInformation {
        let deadline = Date().addingTimeInterval(20)
        let ready = directory.appendingPathComponent("ready.json")
        while Date() < deadline {
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: ready.path) {
                return try decode(ProxyFixtureInformation.self, from: ready)
            }
            if !process.isRunning {
                let diagnostic = (try? String(
                    contentsOf: directory.appendingPathComponent("stderr.txt"), encoding: .utf8)) ?? ""
                throw ProxyFixtureError.startup(String(diagnostic.prefix(1_000)))
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw ProxyFixtureError.startup("Local proxy fixture did not become ready within 20 seconds")
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: Data(contentsOf: url))
    }

    private static func stop(process: Process, directory: URL) {
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(1)
            while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        }
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class ProxyFixtureTrustDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let context: RunwayNetworkContext
    private let certificate: SecCertificate
    private let certificateData: Data

    init(context: RunwayNetworkContext, certificate: Data) throws {
        guard let decoded = SecCertificateCreateWithData(nil, certificate as CFData) else {
            throw ProxyFixtureError.invalidCertificate
        }
        self.context = context
        self.certificate = decoded
        self.certificateData = certificate
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void)
    {
        let result = response(to: challenge)
        completionHandler(result.0, result.1)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void)
    {
        let result = response(to: challenge)
        completionHandler(result.0, result.1)
    }

    private func response(
        to challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?)
    {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            return context.authenticationResponse(for: challenge)
        }
        guard space.host == "proxy-target.invalid",
              let trust = space.serverTrust,
              let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = certificates.first,
              SecCertificateCopyData(leaf) as Data == certificateData,
              SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess,
              SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, space.host as CFString)) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [certificate] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil)
        else { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }
}
