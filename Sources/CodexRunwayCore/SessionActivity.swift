import Foundation

enum SessionProjectName {
    static let unknown = "Unknown project"

    static func displayName(for cwd: String?) -> String {
        guard let cwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty else {
            return unknown
        }
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? cwd : name
    }
}

public enum SessionActivityState: String, Codable, Sendable, Equatable {
    case recent
    case needsAttention
    case failed
}

public struct SessionActivityItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var projectName: String
    public var cwd: String?
    public var updatedAt: Date
    public var state: SessionActivityState
    public var totals: ApiEquivalentTotals
    public var estimatedUSD: Decimal?

    public init(
        id: String,
        title: String,
        projectName: String,
        cwd: String?,
        updatedAt: Date,
        state: SessionActivityState,
        totals: ApiEquivalentTotals,
        estimatedUSD: Decimal?)
    {
        self.id = id
        self.title = title
        self.projectName = projectName
        self.cwd = cwd
        self.updatedAt = updatedAt
        self.state = state
        self.totals = totals
        self.estimatedUSD = estimatedUSD
    }
}

public struct SessionActivitySummary: Codable, Sendable, Equatable {
    public var items: [SessionActivityItem]

    public init(items: [SessionActivityItem]) {
        self.items = items
    }
}

public struct SessionActivityScanner: Sendable {
    public var codexHome: URL
    private static let headProbeBytes = 512 * 1024
    private static let tailProbeBytes = 64 * 1024
    private static let smallFullScanBytes = 256 * 1024

    public init(codexHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")) {
        self.codexHome = codexHome
    }

    public func scan(limit: Int = 5) throws -> SessionActivitySummary {
        let limit = max(0, limit)
        guard limit > 0 else { return SessionActivitySummary(items: []) }
        let index = try readIndex()
        let titlesByID = Dictionary(index.map { ($0.id, $0.threadName) }, uniquingKeysWith: { _, new in new })
        var latestByID: [String: SessionActivityItem] = [:]
        for file in candidateFiles(index: index, limit: max(limit * 3, 15)) {
            guard var item = try parseSession(file) else { continue }
            if let title = titlesByID[item.id].flatMap(cleanSessionTitle) {
                item.title = title
            }
            if let existing = latestByID[item.id], existing.updatedAt >= item.updatedAt { continue }
            latestByID[item.id] = item
        }
        let items = latestByID.values
            .sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
            .prefix(limit)
        return SessionActivitySummary(items: Array(items))
    }

    private func candidateFiles(index: [SessionIndexEntry], limit: Int) -> [URL] {
        let files = jsonlFileCandidates()
        let filesByID = Dictionary(files.compactMap { file in
            file.id.map { ($0, file) }
        }, uniquingKeysWith: { existing, new in
            existing.activityDate >= new.activityDate ? existing : new
        })
        var result: [URL] = []
        var seen = Set<String>()
        func append(_ file: SessionFileCandidate) {
            guard seen.insert(file.url.path).inserted else { return }
            result.append(file.url)
        }

        files.sorted(by: isNewerCandidate).prefix(limit).forEach(append)
        index.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit).forEach { entry in
            if let file = filesByID[entry.id] { append(file) }
        }
        return result
    }

    private func parseSession(
        _ file: URL,
        title providedTitle: String? = nil,
        updatedAt providedUpdatedAt: Date? = nil)
        throws -> SessionActivityItem?
    {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
        var state = SessionParseState(title: providedTitle.flatMap(cleanSessionTitle), updatedAt: providedUpdatedAt)
        for line in try probeLines(file, size: size) {
            try applySessionLine(line, to: &state, includesLastUsage: false)
        }
        if state.byModel.isEmpty, size <= Self.smallFullScanBytes {
            state.byModel = [:]
            for line in try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init) {
                try applySessionLine(line, to: &state, includesLastUsage: true)
            }
        }
        guard let id = state.id, let updatedAt = state.updatedAt else { return nil }
        let totals = try ApiEquivalentTotals.sum(state.byModel.values)
        return SessionActivityItem(
            id: id,
            title: state.title ?? "Untitled",
            projectName: SessionProjectName.displayName(for: state.cwd),
            cwd: state.cwd,
            updatedAt: updatedAt,
            state: state.activityState,
            totals: totals,
            estimatedUSD: estimatedCost(state.byModel))
    }

    private func probeLines(_ file: URL, size: Int) throws -> [String] {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        if size <= Self.headProbeBytes + Self.tailProbeBytes {
            try handle.seek(toOffset: 0)
            return lines(try handle.readToEnd() ?? Data())
        }

        try handle.seek(toOffset: 0)
        let head = try handle.read(upToCount: Self.headProbeBytes) ?? Data()
        let tailStart = end > UInt64(Self.tailProbeBytes) ? end - UInt64(Self.tailProbeBytes) : 0
        try handle.seek(toOffset: tailStart)
        let tail = try handle.readToEnd() ?? Data()
        let tailLines = lines(tail).dropFirst(tailStart > 0 ? 1 : 0)
        return lines(head) + tailLines
    }

    private func lines(_ data: Data) -> [String] {
        String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    private func applySessionLine(
        _ line: String,
        to state: inout SessionParseState,
        includesLastUsage: Bool
    ) throws {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return }
        let payload = object["payload"] as? [String: Any]
        if let stamp = object["timestamp"] as? String, let date = RunwayDates.parse(stamp) {
            state.updatedAt = max(state.updatedAt ?? date, date)
        }
        if object["type"] as? String == "session_meta" {
            state.id = state.id ?? payload?["id"] as? String ?? payload?["session_id"] as? String
            state.cwd = state.cwd ?? payload?["cwd"] as? String
        }
        if state.title == nil, payload?["type"] as? String == "message", payload?["role"] as? String == "user" {
            state.title = sessionText(payload?["content"]).flatMap(cleanSessionTitle)
        }
        state.activityState = stronger(state.activityState, detectedState(object: object, payload: payload))
        if object["type"] as? String == "turn_context", let model = payload?["model"] as? String {
            state.currentModel = model
        }
        let turnContext = object["turn_context"] as? [String: Any]
        let model = turnContext?["model"] as? String ?? payload?["model"] as? String ?? state.currentModel
        if let usage = try tokenUsage(from: payload, key: "total_token_usage") {
            state.byModel[model] = try ApiEquivalentTotals(validating: usage, turns: 1, threads: 0)
        } else if includesLastUsage,
                  let usage = try tokenUsage(from: payload, key: "last_token_usage")
        {
            let totals = try ApiEquivalentTotals(validating: usage, turns: 1, threads: 0)
            state.byModel[model, default: .zero] = try state.byModel[model, default: .zero]
                .adding(totals)
        }
    }

    private func jsonlFileCandidates() -> [SessionFileCandidate] {
        ["sessions", "archived_sessions"].flatMap { folder in
            let root = codexHome.appendingPathComponent(folder, isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else {
                return [SessionFileCandidate]()
            }
            return enumerator.compactMap { item -> SessionFileCandidate? in
                guard let url = item as? URL, url.pathExtension == "jsonl" else { return nil }
                return SessionFileCandidate(
                    url: url,
                    id: sessionID(from: url),
                    activityDate: fileActivityDate(url))
            }
        }
    }

    private func fileActivityDate(_ file: URL) -> Date {
        (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? dayFromPath(file)
            ?? .distantPast
    }

    private func readIndex() throws -> [SessionIndexEntry] {
        let url = codexHome.appendingPathComponent("session_index.jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").compactMap { line in
            try? JSONDecoder().decode(SessionIndexEntry.self, from: Data(line.utf8))
        }
    }

    private func estimatedCost(_ byModel: [String: ApiEquivalentTotals]) -> Decimal? {
        var result = Decimal(0)
        var priced = false
        for item in byModel {
            guard let cost = PricingTable.cost(model: item.key, totals: item.value) else {
                continue
            }
            priced = true
            result += cost
        }
        return priced ? result : nil
    }
}

private struct SessionFileCandidate {
    var url: URL
    var id: String?
    var activityDate: Date
}

private struct SessionParseState {
    var id: String?
    var cwd: String?
    var title: String?
    var updatedAt: Date?
    var activityState = SessionActivityState.recent
    var currentModel = "unknown-model"
    var byModel: [String: ApiEquivalentTotals] = [:]
}

private func isNewerCandidate(_ lhs: SessionFileCandidate, _ rhs: SessionFileCandidate) -> Bool {
    lhs.activityDate == rhs.activityDate ? lhs.url.path < rhs.url.path : lhs.activityDate > rhs.activityDate
}

private func sessionID(from file: URL) -> String? {
    let name = file.deletingPathExtension().lastPathComponent
    guard name.hasPrefix("rollout-") else { return nil }
    let raw = String(name.dropFirst("rollout-".count))
    let id = raw.count > 36 ? String(raw.suffix(36)) : raw
    return id.isEmpty ? nil : id
}

private func tokenUsage(from payload: [String: Any]?, key: String) throws -> TokenUsage? {
    guard let info = payload?["info"] as? [String: Any],
          let usage = info[key] as? [String: Any]
    else { return nil }
    let input = try tokenInteger(usage, key: "input_tokens")
    let cached = try tokenInteger(usage, key: "cached_input_tokens")
    let output = try tokenInteger(usage, key: "output_tokens")
    let reasoning = try tokenInteger(usage, key: "reasoning_output_tokens")
    guard input >= 0, cached >= 0, output >= 0, reasoning >= 0, cached <= input else {
        throw UsageCostArithmeticError.invalidValue(field: "session token usage")
    }
    return TokenUsage(inputTokens: input, cachedInputTokens: cached, outputTokens: output)
}

private func tokenInteger(_ usage: [String: Any], key: String) throws -> Int {
    guard let raw = usage[key] else { return 0 }
    guard let value = raw as? Int else {
        throw UsageCostArithmeticError.invalidValue(field: "session token usage")
    }
    return value
}

private func dayFromPath(_ file: URL) -> Date? {
    let components = file.pathComponents
    for index in 0..<(max(0, components.count - 2)) {
        guard components[index].count == 4,
              let year = Int(components[index]),
              let month = Int(components[index + 1]),
              let day = Int(components[index + 2])
        else { continue }
        return Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: day))
    }
    return nil
}

private func detectedState(object: [String: Any], payload: [String: Any]?) -> SessionActivityState {
    let text = [
        object["type"] as? String,
        payload?["type"] as? String,
        payload?["status"] as? String,
    ].compactMap(\.self).joined(separator: " ").lowercased()
    if text.contains("error") || text.contains("failed") { return .failed }
    if text.contains("approval") || text.contains("permission") || text.contains("waiting") { return .needsAttention }
    return .recent
}

private func stronger(_ lhs: SessionActivityState, _ rhs: SessionActivityState) -> SessionActivityState {
    if lhs == .failed || rhs == .failed { return .failed }
    if lhs == .needsAttention || rhs == .needsAttention { return .needsAttention }
    return .recent
}

private func sessionText(_ value: Any?) -> String? {
    if let text = value as? String { return text }
    if let array = value as? [[String: Any]] {
        return array.compactMap { $0["text"] as? String }.joined(separator: " ")
    }
    return nil
}

private func cleanSessionTitle(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return String(trimmed.prefix(80))
}
