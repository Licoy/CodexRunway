import Foundation

public struct SessionRepairService: Sendable {
    public var codexHome: URL

    public init(codexHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")) {
        self.codexHome = codexHome
    }

    public func dryRun() throws -> SessionRepairReport {
        let sessions = try scanSessions()
        let index = try readIndex()
        return report(sessions: sessions, index: index, backup: nil)
    }

    public func repair() throws -> SessionRepairReport {
        let sessions = try scanSessions()
        let index = try readIndex()
        let backup = try backupIndex()
        try writeIndex(sessions)
        return report(sessions: sessions, index: index, backup: backup)
    }

    private func report(sessions: [SessionIndexEntry], index: [SessionIndexEntry], backup: URL?) -> SessionRepairReport {
        let sessionIDs = Set(sessions.map(\.id))
        let indexIDs = index.map(\.id)
        let indexSet = Set(indexIDs)
        let duplicates = Dictionary(grouping: indexIDs, by: { $0 })
            .filter { $0.value.count > 1 }
            .keys
            .sorted()
        // Single dictionary pass: `first(where:)` per session made this O(sessions × index).
        let indexEntryByID = Dictionary(index.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let stale = sessions.filter { session in
            guard let indexTitle = indexEntryByID[session.id]?.threadName else { return false }
            return indexTitle != session.threadName
        }.map(\.id).sorted()
        return SessionRepairReport(
            missingIndexIDs: sessionIDs.subtracting(indexSet).sorted(),
            orphanIndexIDs: indexSet.subtracting(sessionIDs).sorted(),
            duplicateIndexIDs: duplicates,
            staleTitleIDs: stale,
            backupPath: backup,
            plannedEntries: sessions.count)
    }

    private func scanSessions() throws -> [SessionIndexEntry] {
        let roots = ["sessions", "archived_sessions"].map { codexHome.appendingPathComponent($0, isDirectory: true) }
        var entries: [SessionIndexEntry] = []
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in enumerator where file.pathExtension == "jsonl" {
                if let entry = try parseSession(file) { entries.append(entry) }
            }
        }
        return Dictionary(grouping: entries, by: \.id)
            .compactMap { $0.value.max(by: { $0.updatedAt < $1.updatedAt }) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func parseSession(_ file: URL) throws -> SessionIndexEntry? {
        let lines = try probeLines(file)
        var id: String?
        var title: String?
        var updatedAt: Date?
        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let stamp = object["timestamp"] as? String,
               let date = RunwayDates.parse(stamp)
            {
                updatedAt = max(updatedAt ?? date, date)
            }
            let payload = object["payload"] as? [String: Any]
            if object["type"] as? String == "session_meta" {
                id = id ?? payload?["id"] as? String ?? payload?["session_id"] as? String
            }
            if title == nil, payload?["type"] as? String == "message", payload?["role"] as? String == "user" {
                title = extractText(payload?["content"]).flatMap(cleanTitle)
            }
        }
        guard let id, let updatedAt else { return nil }
        return SessionIndexEntry(id: id, threadName: title ?? "Untitled", updatedAt: updatedAt)
    }

    private func probeLines(_ file: URL) throws -> [String] {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        let head = try handle.read(upToCount: 64 * 1024) ?? Data()
        let tailStart = end > 64 * 1024 ? end - UInt64(64 * 1024) : 0
        try handle.seek(toOffset: tailStart)
        let tail = try handle.readToEnd() ?? Data()
        let headLines = String(decoding: head, as: UTF8.self).split(separator: "\n").prefix(40)
        let tailLines = String(decoding: tail, as: UTF8.self).split(separator: "\n").suffix(80)
        return (headLines + tailLines).map(String.init)
    }

    private func readIndex() throws -> [SessionIndexEntry] {
        let url = indexURL
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try String(contentsOf: url).split(separator: "\n").compactMap { line in
            try? JSONDecoder().decode(SessionIndexEntry.self, from: Data(line.utf8))
        }
    }

    private func backupIndex() throws -> URL? {
        let url = indexURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let backup = codexHome.appendingPathComponent("session_index.backup-\(Int(Date().timeIntervalSince1970)).jsonl")
        try FileManager.default.copyItem(at: url, to: backup)
        return backup
    }

    private func writeIndex(_ entries: [SessionIndexEntry]) throws {
        let encoder = JSONEncoder()
        let lines = try entries.map { String(data: try encoder.encode($0), encoding: .utf8)! }.joined(separator: "\n") + "\n"
        let temporary = codexHome.appendingPathComponent(".session_index.jsonl.tmp-\(UUID().uuidString)")
        try lines.write(to: temporary, atomically: true, encoding: .utf8)
        if FileManager.default.fileExists(atPath: indexURL.path) {
            _ = try FileManager.default.replaceItemAt(indexURL, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: indexURL)
        }
    }

    private var indexURL: URL { codexHome.appendingPathComponent("session_index.jsonl") }
}

struct SessionIndexEntry: Codable, Sendable, Equatable {
    var id: String
    var threadName: String
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case threadName = "thread_name"
        case updatedAt = "updated_at"
    }

    init(id: String, threadName: String, updatedAt: Date) {
        self.id = id
        self.threadName = threadName
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        threadName = try container.decodeIfPresent(String.self, forKey: .threadName) ?? "Untitled"
        let text = try container.decode(String.self, forKey: .updatedAt)
        updatedAt = RunwayDates.parse(text) ?? .distantPast
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(threadName, forKey: .threadName)
        try container.encode(RunwayDates.string(updatedAt), forKey: .updatedAt)
    }
}

private func extractText(_ value: Any?) -> String? {
    if let text = value as? String { return text }
    if let array = value as? [[String: Any]] {
        return array.compactMap { $0["text"] as? String }.joined(separator: " ")
    }
    return nil
}

private func cleanTitle(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return String(trimmed.prefix(80))
}
