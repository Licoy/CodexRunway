import Foundation
import SQLite3

func decodeUsageCostSource(
    _ row: SQLiteStatement,
    parserVersion: Int
) throws -> UsageCostIndexedSource {
    let sourceID = try requiredInt64(row, column: 0, field: "source id")
    let size = try nonnegativeUInt64(row, column: 9, field: "source size")
    let completeOffset = try nonnegativeUInt64(row, column: 10, field: "complete offset")
    let firstHash = try requiredHash(row, column: 13, field: "first hash")
    let firstLength = try nonnegativeInt(row, column: 14, field: "first hash length")
    let checkpointHash = try requiredHash(row, column: 15, field: "checkpoint hash")
    let checkpointLength = try nonnegativeInt(row, column: 16, field: "checkpoint hash length")
    guard completeOffset <= size,
          UInt64(firstLength) <= size,
          UInt64(checkpointLength) <= completeOffset
    else { throw UsageCostIndexStoreError.corruptRow(field: "source checkpoint") }
    let contentFingerprint = try requiredHash(
        row,
        column: 20,
        field: "content fingerprint")
    let malformedLines = try nonnegativeInt(row, column: 18, field: "malformed lines")
    let oversizedLines = try nonnegativeInt(row, column: 19, field: "oversized lines")
    guard UInt64(malformedLines) <= completeOffset,
          UInt64(oversizedLines) <= completeOffset
    else { throw UsageCostIndexStoreError.corruptRow(field: "source anomaly counts") }
    let source = UsageCostIndexedSource(
        id: sourceID,
        basename: try requiredString(row, column: 1, field: "source basename"),
        root: try requiredString(row, column: 2, field: "source root"),
        path: try requiredString(row, column: 3, field: "source path"),
        device: try requiredInt64(row, column: 4, field: "source device"),
        inode: try requiredInt64(row, column: 5, field: "source inode"),
        birthTimeNanoseconds: try requiredInt64(row, column: 6, field: "source birth time"),
        modificationTimeNanoseconds: try requiredInt64(row, column: 7, field: "source mtime"),
        statusChangeTimeNanoseconds: try requiredInt64(row, column: 8, field: "source ctime"),
        size: size, completeOffset: completeOffset,
        currentModel: try requiredString(row, column: 11, field: "current model"),
        currentProject: try requiredString(row, column: 12, field: "current project"),
        firstHash: firstHash, firstHashLength: firstLength,
        checkpointHash: checkpointHash, checkpointHashLength: checkpointLength,
        parserVersion: try nonnegativeInt(row, column: 17, field: "source parser version"),
        malformedLines: malformedLines,
        oversizedLines: oversizedLines,
        contentFingerprint: contentFingerprint)
    guard UsageCostSourceRoot(rawValue: source.root) != nil else {
        throw UsageCostIndexStoreError.corruptRow(field: "source root")
    }
    guard source.parserVersion == parserVersion else {
        throw UsageCostIndexStoreError.corruptRow(field: "source parser version")
    }
    return source
}

func decodeUsageCostAggregate(
    _ row: SQLiteStatement
) throws -> UsageCostIndexedEvent {
    guard try requiredInt64(row, column: 8, field: "event storage class") == 0 else {
        throw UsageCostIndexStoreError.corruptRow(field: "event storage class")
    }
    return UsageCostIndexedEvent(
        fileID: nil, byteOffset: 0,
        timestamp: Date(timeIntervalSince1970: try requiredDouble(
            row, column: 0, field: "event timestamp")),
        dayKey: try requiredString(row, column: 1, field: "event day key"),
        model: try requiredString(row, column: 2, field: "event model"),
        project: try requiredString(row, column: 3, field: "event project"),
        uncachedInputTokens: try nonnegativeInt(row, column: 4, field: "uncached tokens"),
        cachedInputTokens: try nonnegativeInt(row, column: 5, field: "cached tokens"),
        outputTokens: try nonnegativeInt(row, column: 6, field: "output tokens"),
        turns: try nonnegativeInt(row, column: 7, field: "turn count"))
}

func decodeUsageCostCachedFullHash(
    _ row: SQLiteStatement
) throws -> UsageCostCachedFullHash {
    let size = try nonnegativeUInt64(row, column: 3, field: "cached hash size")
    return UsageCostCachedFullHash(
        identity: UsageCostSourceIdentity(
            device: try requiredInt64(row, column: 0, field: "cached hash device"),
            inode: try requiredInt64(row, column: 1, field: "cached hash inode"),
            birthTimeNanoseconds: try requiredInt64(
                row, column: 2, field: "cached hash birth time")),
        size: size,
        modificationTimeNanoseconds: try requiredInt64(
            row, column: 4, field: "cached hash mtime"),
        statusChangeTimeNanoseconds: try requiredInt64(
            row, column: 5, field: "cached hash ctime"),
        digest: try requiredHash(row, column: 6, field: "cached full hash"))
}

func requiredString(
    _ row: SQLiteStatement,
    column: Int32,
    field: String
) throws -> String {
    guard row.columnType(column) == SQLITE_TEXT,
          let value = row.columnString(column)
    else {
        throw UsageCostIndexStoreError.corruptRow(field: field)
    }
    return value
}

private func requiredHash(
    _ row: SQLiteStatement,
    column: Int32,
    field: String
) throws -> Data {
    guard row.columnType(column) == SQLITE_BLOB,
          let value = row.columnData(column),
          value.count == 32
    else {
        throw UsageCostIndexStoreError.corruptRow(field: field)
    }
    return value
}

func requiredInt64(
    _ row: SQLiteStatement,
    column: Int32,
    field: String
) throws -> Int64 {
    guard row.columnType(column) == SQLITE_INTEGER else {
        throw UsageCostIndexStoreError.corruptRow(field: field)
    }
    return row.columnInt64(column)
}

private func nonnegativeUInt64(
    _ row: SQLiteStatement,
    column: Int32,
    field: String
) throws -> UInt64 {
    let value = try requiredInt64(row, column: column, field: field)
    guard value >= 0 else { throw UsageCostIndexStoreError.corruptRow(field: field) }
    return UInt64(value)
}

private func requiredDouble(
    _ row: SQLiteStatement,
    column: Int32,
    field: String
) throws -> Double {
    guard row.columnType(column) == SQLITE_FLOAT || row.columnType(column) == SQLITE_INTEGER else {
        throw UsageCostIndexStoreError.corruptRow(field: field)
    }
    let value = row.columnDouble(column)
    guard value.isFinite else { throw UsageCostIndexStoreError.corruptRow(field: field) }
    return value
}

private func nonnegativeInt(
    _ row: SQLiteStatement,
    column: Int32,
    field: String
) throws -> Int {
    let value = try nonnegativeUInt64(row, column: column, field: field)
    guard value <= UInt64(Int.max) else {
        throw UsageCostIndexStoreError.corruptRow(field: field)
    }
    return Int(value)
}
