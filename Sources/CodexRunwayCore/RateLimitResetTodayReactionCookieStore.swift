import Foundation

/// Persists the hosted `hr_react` visitor cookie. The ID is minted by the
/// server; this store never invents one.
public struct RateLimitResetTodayReactionCookieStore: Sendable {
    public var fileURL: URL

    public init(fileURL: URL = Self.defaultFileURL) {
        self.fileURL = fileURL
    }

    public static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex-runway", isDirectory: true)
            .appendingPathComponent("reaction-visitor.json")
    }

    public func loadVisitorID() -> String? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? decoder.decode(FilePayload.self, from: data)
        else { return nil }
        return RateLimitResetTodayReaction.parseVisitorID(payload.visitorId)
    }

    public func saveVisitorID(_ raw: String) {
        guard let visitorID = RateLimitResetTodayReaction.parseVisitorID(raw) else { return }
        if loadVisitorID() == visitorID { return }
        let payload = FilePayload(visitorId: visitorID, updatedAt: Date())
        let temporary = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(fileURL.lastPathComponent).tmp-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(payload)
            try data.write(to: temporary, options: .completeFileProtectionUntilFirstUserAuthentication)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600 as UInt16)],
                ofItemAtPath: temporary.path)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600 as UInt16)],
                ofItemAtPath: fileURL.path)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    public func saveVisitorID(from response: URLResponse) {
        guard let visitorID = RateLimitResetTodayReaction.visitorID(from: response) else { return }
        saveVisitorID(visitorID)
    }

    private struct FilePayload: Codable {
        var visitorId: String
        var updatedAt: Date
    }
}
