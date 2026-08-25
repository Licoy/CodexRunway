import CryptoKit
import Foundation

struct UsageCostSourceIndexer {
    static let hashWindowBytes: UInt64 = 16 * 1_024
    private static let emptyHash = Data(SHA256.hash(data: Data()))

    let store: UsageCostIndexStore
    let parserVersion: Int
    private let stream: UsageCostLogStream

    init(store: UsageCostIndexStore, parserVersion: Int, calendar: Calendar) {
        self.store = store
        self.parserVersion = parserVersion
        stream = UsageCostLogStream(calendar: calendar)
    }

    func rebuild(
        file: UsageCostSourceFile,
        existing: UsageCostIndexedSource?,
        diagnostics: inout UsageCostRepositoryDiagnostics
    ) throws -> UsageCostScanAnomalies {
        let initial = initialSource(file: file, id: existing?.id)
        var metrics: ScanMetrics?
        _ = try store.rebuildOrAppend(
            initialSource: initial,
            replacingEventsFrom: 0
        ) { emit in
            let scanned = try scan(
                file: file,
                fromOffset: 0,
                model: "unknown-model",
                project: SessionProjectName.unknown,
                existing: nil,
                emit: emit)
            metrics = scanned.metrics
            return scanned.source
        }
        guard let metrics else { return .zero }
        diagnostics.record(metrics)
        diagnostics.rebuiltFiles += 1
        return metrics.provisionalAnomalies
    }

    func append(
        file: UsageCostSourceFile,
        existing: UsageCostIndexedSource,
        diagnostics: inout UsageCostRepositoryDiagnostics
    ) throws -> UsageCostScanAnomalies {
        var initial = existing
        initial.applyMetadata(from: file)
        var metrics: ScanMetrics?
        _ = try store.rebuildOrAppend(
            initialSource: initial,
            replacingEventsFrom: existing.completeOffset
        ) { emit in
            let scanned = try scan(
                file: file,
                fromOffset: existing.completeOffset,
                model: existing.currentModel,
                project: existing.currentProject,
                existing: existing,
                emit: emit)
            metrics = scanned.metrics
            return scanned.source
        }
        guard let metrics else { return .zero }
        diagnostics.record(metrics)
        diagnostics.appendedFiles += 1
        return metrics.provisionalAnomalies
    }

    func adopt(
        file: UsageCostSourceFile,
        existing: UsageCostIndexedSource
    ) throws {
        var adopted = existing
        adopted.applyMetadata(from: file)
        try store.adoptSource(adopted)
    }

    func canAdopt(
        file: UsageCostSourceFile,
        existing: UsageCostIndexedSource,
        diagnostics: inout UsageCostRepositoryDiagnostics
    ) throws -> Bool {
        guard file.size == existing.size,
              existing.completeOffset == existing.size,
              let fingerprint = existing.contentFingerprint
        else { return false }
        let result: UsageCostLogStreamResult
        do {
            result = try stream.read(
                file: file.url,
                expectedSource: file,
                requireStableSnapshot: true) { _ in }
        } catch UsageCostLogReaderError.sourceMetadataChanged {
            return false
        }
        diagnostics.validationBytesRead += result.bytesRead
        diagnostics.maxBufferedBytes = max(diagnostics.maxBufferedBytes, result.maxBufferedBytes)
        let malformed = result.malformedCandidateLines
            - result.incompleteMalformedCandidateLines
        let oversized = result.oversizedLines - result.incompleteOversizedLines
        return result.snapshotSize == file.size
            && result.lastCompleteOffset == result.snapshotSize
            && result.contentFingerprint == fingerprint
            && malformed == existing.malformedLines
            && oversized == existing.oversizedLines
    }

    func canAppend(
        file: UsageCostSourceFile,
        existing: UsageCostIndexedSource,
        diagnostics: inout UsageCostRepositoryDiagnostics
    ) throws -> Bool {
        guard existing.completeOffset <= file.size,
              existing.contentFingerprint != nil,
              existing.firstHashLength >= 0,
              existing.checkpointHashLength >= 0,
              UInt64(existing.firstHashLength) <= file.size,
              UInt64(existing.checkpointHashLength) <= existing.completeOffset
        else { return false }
        let first = try validate(
            file,
            range: 0..<UInt64(existing.firstHashLength),
            expected: existing.firstHash,
            diagnostics: &diagnostics)
        guard first else { return false }
        let checkpointLength = UInt64(existing.checkpointHashLength)
        return try validate(
            file,
            range: (existing.completeOffset - checkpointLength)..<existing.completeOffset,
            expected: existing.checkpointHash,
            diagnostics: &diagnostics)
    }

    private func validate(
        _ file: UsageCostSourceFile,
        range: Range<UInt64>,
        expected: Data,
        diagnostics: inout UsageCostRepositoryDiagnostics
    ) throws -> Bool {
        let hash = try UsageCostFileHasher.sha256(of: file, range: range)
        diagnostics.validationBytesRead += hash.bytesRead
        return hash.digest == expected
    }

    private func scan(
        file: UsageCostSourceFile,
        fromOffset: UInt64,
        model: String,
        project: String,
        existing: UsageCostIndexedSource?,
        emit: UsageCostIndexStore.EventEmitter
    ) throws -> (source: UsageCostIndexedSource, metrics: ScanMetrics) {
        var currentModel = model
        var currentProject = project
        var checkpointModel = model
        var checkpointProject = project
        let result = try stream.read(
            file: file.url,
            fromOffset: fromOffset,
            initialFingerprint: existing?.contentFingerprint,
            expectedSource: file) { line in
            let record = line.record
            if let cwd = record.sessionCWD {
                currentProject = SessionProjectName.displayName(for: cwd)
            }
            if let contextModel = record.contextModel { currentModel = contextModel }
            if let usage = record.lastTokenUsage {
                let cached = max(0, usage.cachedInputTokens)
                let uncached = usage.inputTokens >= cached
                    ? usage.inputTokens - cached
                    : 0
                try emit(UsageCostIndexedEvent(
                    fileID: existing?.id,
                    byteOffset: line.byteOffset,
                    timestamp: record.timestamp,
                    dayKey: record.dayKey,
                    model: record.model ?? currentModel,
                    project: currentProject,
                    uncachedInputTokens: uncached,
                    cachedInputTokens: cached,
                    outputTokens: max(0, usage.outputTokens),
                    turns: record.countsAsTurn ? 1 : 0))
            } else if record.countsAsTurn {
                try emit(UsageCostIndexedEvent(
                    fileID: existing?.id,
                    byteOffset: line.byteOffset,
                    timestamp: record.timestamp,
                    dayKey: record.dayKey,
                    model: record.model ?? currentModel,
                    project: currentProject,
                    uncachedInputTokens: 0,
                    cachedInputTokens: 0,
                    outputTokens: 0,
                    turns: 1))
            }
            if line.isLFComplete {
                checkpointModel = currentModel
                checkpointProject = currentProject
            }
        }
        let hashes = try hashes(
            file: file,
            snapshotSize: result.snapshotSize,
            completeOffset: result.lastCompleteOffset,
            existing: existing)
        var source = initialSource(file: file, id: existing?.id)
        source.device = result.snapshotDevice
        source.inode = result.snapshotInode
        source.birthTimeNanoseconds = result.snapshotBirthNanoseconds
        source.modificationTimeNanoseconds = result.snapshotModificationNanoseconds
        source.statusChangeTimeNanoseconds = result.snapshotStatusChangeNanoseconds
        source.size = result.snapshotSize
        source.completeOffset = result.lastCompleteOffset
        source.currentModel = checkpointModel
        source.currentProject = checkpointProject
        source.firstHash = hashes.first.digest
        source.firstHashLength = hashes.first.length
        source.checkpointHash = hashes.checkpoint.digest
        source.checkpointHashLength = hashes.checkpoint.length
        let malformedLines = result.malformedCandidateLines
            - result.incompleteMalformedCandidateLines
        let oversizedLines = result.oversizedLines - result.incompleteOversizedLines
        source.malformedLines = try checkedAdd(
            existing?.malformedLines ?? 0,
            malformedLines,
            field: "malformed line count")
        source.oversizedLines = try checkedAdd(
            existing?.oversizedLines ?? 0,
            oversizedLines,
            field: "oversized line count")
        source.contentFingerprint = result.contentFingerprint
        let metrics = ScanMetrics(stream: result, hashBytes: hashes.bytesRead)
        return (source, metrics)
    }

    private func hashes(
        file: UsageCostSourceFile,
        snapshotSize: UInt64,
        completeOffset: UInt64,
        existing: UsageCostIndexedSource?
    ) throws -> (first: HashValue, checkpoint: HashValue, bytesRead: Int) {
        let firstLength = min(Self.hashWindowBytes, snapshotSize)
        let first: UsageCostFileHash
        if let existing, UInt64(existing.firstHashLength) == firstLength {
            first = UsageCostFileHash(digest: existing.firstHash, bytesRead: 0)
        } else {
            first = try UsageCostFileHasher.sha256(of: file, range: 0..<firstLength)
        }
        let checkpointLength = min(Self.hashWindowBytes, completeOffset)
        let checkpoint = try UsageCostFileHasher.sha256(
            of: file,
            range: (completeOffset - checkpointLength)..<completeOffset)
        return (
            HashValue(digest: first.digest, length: Int(firstLength)),
            HashValue(digest: checkpoint.digest, length: Int(checkpointLength)),
            first.bytesRead + checkpoint.bytesRead)
    }

    private func initialSource(file: UsageCostSourceFile, id: Int64?) -> UsageCostIndexedSource {
        UsageCostIndexedSource(
            id: id, basename: file.basename, root: file.root.rawValue, path: file.url.path,
            device: file.device, inode: file.inode, birthTimeNanoseconds: file.birthNanoseconds,
            modificationTimeNanoseconds: file.modificationNanoseconds,
            statusChangeTimeNanoseconds: file.statusChangeNanoseconds, size: file.size,
            completeOffset: 0, currentModel: "unknown-model",
            currentProject: SessionProjectName.unknown, firstHash: Self.emptyHash, firstHashLength: 0,
            checkpointHash: Self.emptyHash, checkpointHashLength: 0, parserVersion: parserVersion,
            malformedLines: 0, oversizedLines: 0, contentFingerprint: nil)
    }
}

private struct HashValue {
    var digest: Data
    var length: Int
}

struct ScanMetrics {
    var bytesRead: Int
    var validationBytesRead: Int
    var candidateLines: Int
    var decodedLines: Int
    var malformedCandidateLines: Int
    var oversizedLines: Int
    var incompleteMalformedLines: Int
    var incompleteOversizedLines: Int
    var maxBufferedBytes: Int
    var hasIncompleteTail: Bool

    init(stream: UsageCostLogStreamResult, hashBytes: Int) {
        bytesRead = stream.bytesRead
        validationBytesRead = hashBytes
        candidateLines = stream.candidateLines
        decodedLines = stream.decodedLines
        malformedCandidateLines = stream.malformedCandidateLines
        oversizedLines = stream.oversizedLines
        incompleteMalformedLines = stream.incompleteMalformedCandidateLines
        incompleteOversizedLines = stream.incompleteOversizedLines
        maxBufferedBytes = stream.maxBufferedBytes
        hasIncompleteTail = stream.trailingLineStartOffset != nil
    }

    var provisionalAnomalies: UsageCostScanAnomalies {
        UsageCostScanAnomalies(
            malformedLines: incompleteMalformedLines,
            oversizedLines: incompleteOversizedLines)
    }
}

struct UsageCostScanAnomalies: Equatable {
    var malformedLines: Int
    var oversizedLines: Int

    static let zero = UsageCostScanAnomalies(malformedLines: 0, oversizedLines: 0)

    func adding(_ other: UsageCostScanAnomalies) throws -> UsageCostScanAnomalies {
        UsageCostScanAnomalies(
            malformedLines: try checkedAdd(
                malformedLines,
                other.malformedLines,
                field: "malformed line count"),
            oversizedLines: try checkedAdd(
                oversizedLines,
                other.oversizedLines,
                field: "oversized line count"))
    }
}

private extension UsageCostIndexedSource {
    mutating func applyMetadata(from file: UsageCostSourceFile) {
        root = file.root.rawValue
        path = file.url.path
        device = file.device
        inode = file.inode
        birthTimeNanoseconds = file.birthNanoseconds
        modificationTimeNanoseconds = file.modificationNanoseconds
        statusChangeTimeNanoseconds = file.statusChangeNanoseconds
        size = file.size
    }
}

private extension UsageCostRepositoryDiagnostics {
    mutating func record(_ metrics: ScanMetrics) {
        bytesRead += metrics.bytesRead
        validationBytesRead += metrics.validationBytesRead
        candidateLines += metrics.candidateLines
        decodedLines += metrics.decodedLines
        malformedCandidateLines += metrics.malformedCandidateLines
        oversizedLines += metrics.oversizedLines
        maxBufferedBytes = max(maxBufferedBytes, metrics.maxBufferedBytes)
        if metrics.hasIncompleteTail { incompleteTailFiles += 1 }
    }
}
