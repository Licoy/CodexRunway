import CryptoKit
import Darwin
import Foundation

struct UsageCostLogRecord: Sendable {
    var timestamp: Date
    var dayKey: String
    var model: String?
    var contextModel: String?
    var sessionCWD: String?
    var lastTokenUsage: TokenUsage?
}

struct UsageCostParsedLine: Sendable {
    var byteOffset: UInt64
    var isLFComplete: Bool
    var record: UsageCostLogRecord
}

struct UsageCostLogStreamResult: Equatable, Sendable {
    var snapshotSize: UInt64
    var snapshotDevice: Int64
    var snapshotInode: Int64
    var snapshotBirthNanoseconds: Int64
    var snapshotModificationNanoseconds: Int64
    var snapshotStatusChangeNanoseconds: Int64
    var bytesRead: Int
    var candidateLines: Int
    var decodedLines: Int
    var malformedCandidateLines: Int
    var incompleteMalformedCandidateLines: Int
    var oversizedLines: Int
    var incompleteOversizedLines: Int
    var maxBufferedBytes: Int
    var lastCompleteOffset: UInt64
    var trailingLineStartOffset: UInt64?
    var contentFingerprint: Data
}

struct UsageCostLogStream {
    static let chunkSize = 256 * 1_024
    static let maximumLineBytes = 8 * 1_024 * 1_024
    private static let fingerprintSeed = Data(SHA256.hash(
        data: Data("usage-cost-content-fingerprint-v2".utf8)))

    private let reader: UsageCostLogReader
    private let parser: UsageCostLogParser

    init(
        chunkSize: Int = UsageCostLogStream.chunkSize,
        maximumLineBytes: Int = UsageCostLogStream.maximumLineBytes,
        calendar: Calendar = .autoupdatingCurrent)
    {
        reader = UsageCostLogReader(chunkSize: chunkSize, maximumLineBytes: maximumLineBytes)
        parser = UsageCostLogParser(calendar: calendar)
    }

    func read(
        file: URL,
        fromOffset: UInt64 = 0,
        initialFingerprint: Data? = nil,
        expectedSource: UsageCostSourceFile? = nil,
        requireStableSnapshot: Bool = false,
        onRecord: (UsageCostParsedLine) throws -> Void) throws -> UsageCostLogStreamResult
    {
        var decodedLines = 0
        var malformedLines = 0
        var incompleteMalformedLines = 0
        var contentFingerprint = initialFingerprint ?? Self.fingerprintSeed
        let result = try reader.read(
            file: file,
            fromOffset: fromOffset,
            expectedSource: expectedSource,
            requireStableSnapshot: requireStableSnapshot) { line in
            if line.isLFComplete {
                contentFingerprint = Self.extendFingerprint(
                    contentFingerprint,
                    with: line.data)
            }
            let record: UsageCostLogRecord
            do {
                record = try autoreleasepool { try parser.parse(line.data) }
            } catch {
                malformedLines += 1
                if !line.isLFComplete { incompleteMalformedLines += 1 }
                return
            }
            decodedLines += 1
            try onRecord(UsageCostParsedLine(
                byteOffset: line.byteOffset,
                isLFComplete: line.isLFComplete,
                record: record))
        }
        return UsageCostLogStreamResult(
            snapshotSize: result.snapshotSize,
            snapshotDevice: result.snapshotDevice,
            snapshotInode: result.snapshotInode,
            snapshotBirthNanoseconds: result.snapshotBirthNanoseconds,
            snapshotModificationNanoseconds: result.snapshotModificationNanoseconds,
            snapshotStatusChangeNanoseconds: result.snapshotStatusChangeNanoseconds,
            bytesRead: result.bytesRead,
            candidateLines: result.candidateLines,
            decodedLines: decodedLines,
            malformedCandidateLines: malformedLines,
            incompleteMalformedCandidateLines: incompleteMalformedLines,
            oversizedLines: result.oversizedLines,
            incompleteOversizedLines: result.incompleteOversizedLines,
            maxBufferedBytes: result.maxBufferedBytes,
            lastCompleteOffset: result.lastCompleteOffset,
            trailingLineStartOffset: result.trailingLineStartOffset,
            contentFingerprint: contentFingerprint)
    }

    private static func extendFingerprint(_ fingerprint: Data, with line: Data) -> Data {
        var hasher = SHA256()
        hasher.update(data: fingerprint)
        hasher.update(data: line)
        return Data(hasher.finalize())
    }
}

private struct UsageCostCandidateLine {
    var byteOffset: UInt64
    var isLFComplete: Bool
    var data: Data
}

private struct UsageCostLogReadResult {
    var snapshotSize: UInt64
    var snapshotDevice: Int64
    var snapshotInode: Int64
    var snapshotBirthNanoseconds: Int64
    var snapshotModificationNanoseconds: Int64
    var snapshotStatusChangeNanoseconds: Int64
    var bytesRead = 0
    var candidateLines = 0
    var oversizedLines = 0
    var incompleteOversizedLines = 0
    var maxBufferedBytes = 0
    var lastCompleteOffset: UInt64
    var trailingLineStartOffset: UInt64?
}

enum UsageCostLogReaderError: Error {
    case offsetBeyondSnapshot(offset: UInt64, snapshotSize: UInt64)
    case unexpectedEndOfFile(expected: UInt64, actual: UInt64)
    case invalidSourceFile
    case sourceIdentityChanged
    case sourceMetadataChanged
    case fileStatus(code: Int32)
}

private struct UsageCostLogReader {
    var chunkSize: Int
    var maximumLineBytes: Int

    func read(
        file: URL,
        fromOffset: UInt64,
        expectedSource: UsageCostSourceFile?,
        requireStableSnapshot: Bool,
        onCandidate: (UsageCostCandidateLine) throws -> Void) throws -> UsageCostLogReadResult
    {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var metadata = stat()
        guard Darwin.fstat(handle.fileDescriptor, &metadata) == 0 else {
            throw UsageCostLogReaderError.fileStatus(code: errno)
        }
        guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_size >= 0 else {
            throw UsageCostLogReaderError.invalidSourceFile
        }
        if let expectedSource {
            try validate(
                metadata,
                matches: expectedSource,
                requireStableSnapshot: requireStableSnapshot)
        }
        let snapshotSize = UInt64(metadata.st_size)
        guard fromOffset <= snapshotSize else {
            throw UsageCostLogReaderError.offsetBeyondSnapshot(
                offset: fromOffset,
                snapshotSize: snapshotSize)
        }
        try handle.seek(toOffset: fromOffset)

        var accumulator = LineAccumulator(
            lineStartOffset: fromOffset,
            maximumLineBytes: maximumLineBytes)
        var position = fromOffset
        var bytesRead = 0
        var maxBufferedBytes = 0
        while position < snapshotSize {
            try Task.checkCancellation()
            let remaining = snapshotSize - position
            let requestedBytes = min(chunkSize, Int(remaining))
            let consumed = try autoreleasepool { () throws -> Int in
                let chunk = try handle.read(upToCount: requestedBytes) ?? Data()
                guard !chunk.isEmpty else {
                    throw UsageCostLogReaderError.unexpectedEndOfFile(
                        expected: snapshotSize,
                        actual: position)
                }
                maxBufferedBytes = max(maxBufferedBytes, chunk.count)
                try accumulator.consume(chunk: chunk, at: position, onCandidate: onCandidate)
                maxBufferedBytes = max(maxBufferedBytes, accumulator.maxBufferedBytes)
                return chunk.count
            }
            position += UInt64(consumed)
            bytesRead += consumed
        }
        try accumulator.finish(onCandidate: onCandidate)
        if requireStableSnapshot {
            try validateStableSnapshot(handle: handle, initial: metadata)
        }
        maxBufferedBytes = max(maxBufferedBytes, accumulator.maxBufferedBytes)
        return UsageCostLogReadResult(
            snapshotSize: snapshotSize,
            snapshotDevice: Int64(metadata.st_dev),
            snapshotInode: Int64(bitPattern: UInt64(metadata.st_ino)),
            snapshotBirthNanoseconds: try nanoseconds(metadata.st_birthtimespec),
            snapshotModificationNanoseconds: try nanoseconds(metadata.st_mtimespec),
            snapshotStatusChangeNanoseconds: try nanoseconds(metadata.st_ctimespec),
            bytesRead: bytesRead,
            candidateLines: accumulator.candidateLines,
            oversizedLines: accumulator.oversizedLines,
            incompleteOversizedLines: accumulator.discardingOversizedLine ? 1 : 0,
            maxBufferedBytes: maxBufferedBytes,
            lastCompleteOffset: accumulator.lastCompleteOffset,
            trailingLineStartOffset: accumulator.lastCompleteOffset < snapshotSize
                ? accumulator.lastCompleteOffset
                : nil)
    }

    private func validate(
        _ metadata: stat,
        matches expected: UsageCostSourceFile,
        requireStableSnapshot: Bool
    ) throws {
        guard Int64(metadata.st_dev) == expected.device,
              Int64(bitPattern: UInt64(metadata.st_ino)) == expected.inode,
              try nanoseconds(metadata.st_birthtimespec) == expected.birthNanoseconds
        else { throw UsageCostLogReaderError.sourceIdentityChanged }
        guard requireStableSnapshot else { return }
        let modification = try nanoseconds(metadata.st_mtimespec)
        let statusChange = try nanoseconds(metadata.st_ctimespec)
        guard UInt64(metadata.st_size) == expected.size,
              modification == expected.modificationNanoseconds,
              statusChange == expected.statusChangeNanoseconds
        else { throw UsageCostLogReaderError.sourceMetadataChanged }
    }

    private func validateStableSnapshot(handle: FileHandle, initial: stat) throws {
        var final = stat()
        guard Darwin.fstat(handle.fileDescriptor, &final) == 0 else {
            throw UsageCostLogReaderError.fileStatus(code: errno)
        }
        let finalBirth = try nanoseconds(final.st_birthtimespec)
        let initialBirth = try nanoseconds(initial.st_birthtimespec)
        let finalModification = try nanoseconds(final.st_mtimespec)
        let initialModification = try nanoseconds(initial.st_mtimespec)
        let finalStatusChange = try nanoseconds(final.st_ctimespec)
        let initialStatusChange = try nanoseconds(initial.st_ctimespec)
        guard final.st_size == initial.st_size,
              final.st_dev == initial.st_dev,
              final.st_ino == initial.st_ino,
              finalBirth == initialBirth,
              finalModification == initialModification,
              finalStatusChange == initialStatusChange
        else { throw UsageCostLogReaderError.sourceMetadataChanged }
    }
}

private struct LineAccumulator {
    var lineStartOffset: UInt64
    var maximumLineBytes: Int
    var buffer = Data()
    var discardingOversizedLine = false
    var candidateLines = 0
    var oversizedLines = 0
    var maxBufferedBytes = 0
    var lastCompleteOffset: UInt64

    init(lineStartOffset: UInt64, maximumLineBytes: Int) {
        self.lineStartOffset = lineStartOffset
        self.maximumLineBytes = maximumLineBytes
        self.lastCompleteOffset = lineStartOffset
    }

    mutating func consume(
        chunk: Data,
        at chunkOffset: UInt64,
        onCandidate: (UsageCostCandidateLine) throws -> Void) throws
    {
        var segmentStart = chunk.startIndex
        while let newline = chunk[segmentStart...].firstIndex(of: 0x0A) {
            try consume(
                segment: chunk[segmentStart..<newline],
                isLFComplete: true,
                onCandidate: onCandidate)
            let afterNewline = chunk.index(after: newline)
            lineStartOffset = chunkOffset + UInt64(afterNewline - chunk.startIndex)
            lastCompleteOffset = lineStartOffset
            segmentStart = afterNewline
        }
        if segmentStart < chunk.endIndex {
            try consume(
                segment: chunk[segmentStart..<chunk.endIndex],
                isLFComplete: false,
                onCandidate: onCandidate)
        }
    }

    mutating func finish(onCandidate: (UsageCostCandidateLine) throws -> Void) throws {
        guard !discardingOversizedLine, !buffer.isEmpty else { return }
        try emit(buffer, isLFComplete: false, onCandidate: onCandidate)
        buffer = Data()
    }

    private mutating func consume(
        segment: Data.SubSequence,
        isLFComplete: Bool,
        onCandidate: (UsageCostCandidateLine) throws -> Void) throws
    {
        guard !discardingOversizedLine else {
            if isLFComplete { discardingOversizedLine = false }
            return
        }
        guard buffer.count + segment.count <= maximumLineBytes else {
            oversizedLines += 1
            buffer = Data()
            discardingOversizedLine = !isLFComplete
            return
        }
        if buffer.isEmpty, isLFComplete {
            try emit(segment, isLFComplete: true, onCandidate: onCandidate)
            return
        }
        buffer.append(contentsOf: segment)
        maxBufferedBytes = max(maxBufferedBytes, buffer.count)
        guard isLFComplete else { return }
        try emit(buffer, isLFComplete: true, onCandidate: onCandidate)
        buffer = Data()
    }

    private mutating func emit(
        _ bytes: Data.SubSequence,
        isLFComplete: Bool,
        onCandidate: (UsageCostCandidateLine) throws -> Void) throws
    {
        guard UsageCostLinePrefilter.isCandidate(bytes) else { return }
        candidateLines += 1
        var data = Data(bytes)
        if data.last == 0x0D { data.removeLast() }
        try onCandidate(UsageCostCandidateLine(
            byteOffset: lineStartOffset,
            isLFComplete: isLFComplete,
            data: data))
    }
}

private enum UsageCostLinePrefilter {
    private static let markers = [
        Data("token_count".utf8),
        Data("turn_context".utf8),
        Data("session_meta".utf8),
        Data("\"cwd\"".utf8),
    ]

    static func isCandidate(_ bytes: Data.SubSequence) -> Bool {
        markers.contains { bytes.range(of: $0) != nil }
    }
}

private func nanoseconds(_ time: timespec) throws -> Int64 {
    let (seconds, multipliedOverflow) = Int64(time.tv_sec)
        .multipliedReportingOverflow(by: 1_000_000_000)
    let (result, addedOverflow) = seconds.addingReportingOverflow(Int64(time.tv_nsec))
    guard !multipliedOverflow, !addedOverflow else {
        throw UsageCostLogReaderError.invalidSourceFile
    }
    return result
}
