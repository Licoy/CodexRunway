import Foundation

/// Capability URLs identify registered update resources, never an arbitrary upstream URL.
struct UpdateProxyRoutes {
    private let token = UUID().uuidString.lowercased()
    private var resources: [String: URL] = [:]

    mutating func register(_ upstream: URL, port: UInt16) throws -> URL {
        guard Self.isAllowedSource(upstream) else { throw UpdateProxyBridgeError.unsupportedResource }
        let path = "/\(token)/\(UUID().uuidString.lowercased())"
        resources[path] = upstream
        return URL(string: "http://localhost:\(port)\(path)")!
    }

    func upstream(for request: Data, port: UInt16) -> URL? {
        guard let text = String(data: request, encoding: .utf8),
              let boundary = text.range(of: "\r\n\r\n"), boundary.upperBound == text.endIndex
        else { return nil }
        let lines = text[..<boundary.lowerBound].components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, first[0] == "GET", first[2] == "HTTP/1.1",
              first[1].hasPrefix("/"), !first[1].hasPrefix("//"),
              !first[1].contains("#")
        else { return nil }
        var hosts: [String] = []
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { return nil }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "host" { hosts.append(value.lowercased()) }
            if name == "transfer-encoding" || (name == "content-length" && value != "0") { return nil }
        }
        guard hosts == ["localhost:\(port)"] else { return nil }
        // Sparkle may append profile query parameters; they never reach the upstream.
        let path = String(first[1].split(separator: "?", maxSplits: 1)[0])
        return resources[path]
    }

    static func isAllowedSource(_ url: URL) -> Bool {
        guard hasAllowedAuthority(url), url.host?.lowercased() == "github.com" else { return false }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 7, parts[0].isEmpty,
              parts[1].lowercased() == "licoy", ["codex-runway", "codexrunway"].contains(parts[2].lowercased()),
              parts[3] == "releases", !parts[5].isEmpty, !parts[6].isEmpty,
              !parts.contains("."), !parts.contains(".."), !url.path.contains("\\")
        else { return false }
        return parts[4] == "download" || (parts[4] == "latest" && parts[5] == "download")
    }

    static func isAllowedRedirect(_ url: URL) -> Bool {
        guard hasAllowedAuthority(url) else { return false }
        if url.host?.lowercased() == "github.com" { return isAllowedSource(url) }
        return ["release-assets.githubusercontent.com", "objects.githubusercontent.com", "github-releases.githubusercontent.com"]
            .contains(url.host?.lowercased() ?? "")
    }

    private static func hasAllowedAuthority(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.user == nil && url.password == nil
            && url.fragment == nil && (url.port == nil || url.port == 443)
    }
}

public enum UpdateProxyBridgeError: Error, Sendable {
    case unavailable
    case unsupportedResource
    case invalidRequest
    case connectionClosed
    case invalidResponse
}
