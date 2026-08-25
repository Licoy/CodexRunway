import Foundation

enum UsageCostIndexStoreError: Error, Equatable {
    case schemaVersionMismatch(expected: Int, actual: Int?)
    case parserVersionMismatch(expected: Int, actual: Int?)
    case timeZoneMismatch(expected: String, actual: String?)
    case missingSourceID(basename: String)
    case sourceIdentityMismatch(basename: String)
    case integerOverflow(field: String)
    case corruptRow(field: String)
}

struct UsageCostIndexedSource: Sendable, Equatable {
    var id: Int64?
    var basename: String
    var root: String
    var path: String
    var device: Int64
    var inode: Int64
    var birthTimeNanoseconds: Int64
    var modificationTimeNanoseconds: Int64
    var statusChangeTimeNanoseconds: Int64
    var size: UInt64
    var completeOffset: UInt64
    var currentModel: String
    var currentProject: String
    var firstHash: Data
    var firstHashLength: Int
    var checkpointHash: Data
    var checkpointHashLength: Int
    var parserVersion: Int
    var malformedLines: Int
    var oversizedLines: Int
    var contentFingerprint: Data?
}

struct UsageCostIndexedEvent: Sendable, Equatable {
    var fileID: Int64?
    var byteOffset: UInt64
    var timestamp: Date
    var dayKey: String
    var model: String
    var project: String
    var uncachedInputTokens: Int
    var cachedInputTokens: Int
    var outputTokens: Int
    var turns: Int = 0
}

struct UsageCostSourceIdentity: Sendable, Hashable {
    var device: Int64
    var inode: Int64
    var birthTimeNanoseconds: Int64

    init(device: Int64, inode: Int64, birthTimeNanoseconds: Int64) {
        self.device = device
        self.inode = inode
        self.birthTimeNanoseconds = birthTimeNanoseconds
    }

    init(file: UsageCostSourceFile) {
        self.init(
            device: file.device,
            inode: file.inode,
            birthTimeNanoseconds: file.birthNanoseconds)
    }
}

struct UsageCostCachedFullHash: Sendable, Hashable {
    var identity: UsageCostSourceIdentity
    var size: UInt64
    var modificationTimeNanoseconds: Int64
    var statusChangeTimeNanoseconds: Int64
    var digest: Data

    init(
        identity: UsageCostSourceIdentity,
        size: UInt64,
        modificationTimeNanoseconds: Int64,
        statusChangeTimeNanoseconds: Int64,
        digest: Data)
    {
        self.identity = identity
        self.size = size
        self.modificationTimeNanoseconds = modificationTimeNanoseconds
        self.statusChangeTimeNanoseconds = statusChangeTimeNanoseconds
        self.digest = digest
    }

    init(file: UsageCostSourceFile, digest: Data) {
        identity = UsageCostSourceIdentity(file: file)
        size = file.size
        modificationTimeNanoseconds = file.modificationNanoseconds
        statusChangeTimeNanoseconds = file.statusChangeNanoseconds
        self.digest = digest
    }

    func matches(_ file: UsageCostSourceFile) -> Bool {
        identity == UsageCostSourceIdentity(file: file)
            && size == file.size
            && modificationTimeNanoseconds == file.modificationNanoseconds
            && statusChangeTimeNanoseconds == file.statusChangeNanoseconds
    }
}

enum UsageCostIndexSchema {
    static let version = 3

    static let create = """
        CREATE TABLE index_metadata (
            singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
            schema_version INTEGER NOT NULL,
            parser_version INTEGER NOT NULL,
            aggregation_time_zone TEXT NOT NULL
        );
        CREATE TABLE source_files (
            id INTEGER PRIMARY KEY,
            basename TEXT NOT NULL UNIQUE,
            root TEXT NOT NULL,
            path TEXT NOT NULL,
            device INTEGER NOT NULL,
            inode INTEGER NOT NULL,
            birth_ns INTEGER NOT NULL,
            mtime_ns INTEGER NOT NULL,
            ctime_ns INTEGER NOT NULL,
            size INTEGER NOT NULL CHECK (size >= 0),
            complete_offset INTEGER NOT NULL CHECK (complete_offset >= 0 AND complete_offset <= size),
            current_model TEXT NOT NULL,
            current_project TEXT NOT NULL,
            first_hash BLOB NOT NULL CHECK (length(first_hash) = 32),
            first_hash_length INTEGER NOT NULL CHECK (first_hash_length >= 0 AND first_hash_length <= size),
            checkpoint_hash BLOB NOT NULL CHECK (length(checkpoint_hash) = 32),
            checkpoint_hash_length INTEGER NOT NULL CHECK (
                checkpoint_hash_length >= 0 AND checkpoint_hash_length <= complete_offset
            ),
            parser_version INTEGER NOT NULL,
            malformed_lines INTEGER NOT NULL CHECK (malformed_lines >= 0),
            oversized_lines INTEGER NOT NULL CHECK (oversized_lines >= 0),
            full_hash BLOB CHECK (full_hash IS NULL OR length(full_hash) = 32)
        );
        CREATE TABLE usage_events (
            file_id INTEGER NOT NULL,
            byte_offset INTEGER NOT NULL CHECK (byte_offset >= 0),
            timestamp REAL NOT NULL,
            day_key TEXT NOT NULL,
            model TEXT NOT NULL,
            project TEXT NOT NULL,
            uncached_input_tokens INTEGER NOT NULL CHECK (uncached_input_tokens >= 0),
            cached_input_tokens INTEGER NOT NULL CHECK (cached_input_tokens >= 0),
            output_tokens INTEGER NOT NULL CHECK (output_tokens >= 0),
            turns INTEGER NOT NULL CHECK (turns >= 0),
            PRIMARY KEY (file_id, byte_offset),
            FOREIGN KEY (file_id) REFERENCES source_files(id) ON DELETE CASCADE
        ) WITHOUT ROWID;
        CREATE TABLE source_hash_cache (
            device INTEGER NOT NULL,
            inode INTEGER NOT NULL,
            birth_ns INTEGER NOT NULL,
            size INTEGER NOT NULL CHECK (size >= 0),
            mtime_ns INTEGER NOT NULL,
            ctime_ns INTEGER NOT NULL,
            full_hash BLOB NOT NULL CHECK (length(full_hash) = 32),
            PRIMARY KEY (device, inode, birth_ns)
        ) WITHOUT ROWID;
        CREATE INDEX usage_events_timestamp_idx ON usage_events(timestamp);
        """

    static let sourceColumns = """
        basename, root, path, device, inode, birth_ns, mtime_ns, ctime_ns, size,
        complete_offset, current_model, current_project, first_hash, first_hash_length,
        checkpoint_hash, checkpoint_hash_length, parser_version, malformed_lines,
        oversized_lines, full_hash
        """

    static let sourceAssignments = """
        root = excluded.root, path = excluded.path, device = excluded.device,
        inode = excluded.inode, birth_ns = excluded.birth_ns, mtime_ns = excluded.mtime_ns,
        ctime_ns = excluded.ctime_ns, size = excluded.size,
        complete_offset = excluded.complete_offset, current_model = excluded.current_model,
        current_project = excluded.current_project, first_hash = excluded.first_hash,
        first_hash_length = excluded.first_hash_length,
        checkpoint_hash = excluded.checkpoint_hash,
        checkpoint_hash_length = excluded.checkpoint_hash_length,
        parser_version = excluded.parser_version, malformed_lines = excluded.malformed_lines,
        oversized_lines = excluded.oversized_lines, full_hash = excluded.full_hash
        """
}

extension SQLiteStatement {
    func bind(source: UsageCostIndexedSource) throws {
        try bind(source.basename, at: 1)
        try bind(source.root, at: 2)
        try bind(source.path, at: 3)
        try bind(source.device, at: 4)
        try bind(source.inode, at: 5)
        try bind(source.birthTimeNanoseconds, at: 6)
        try bind(source.modificationTimeNanoseconds, at: 7)
        try bind(source.statusChangeTimeNanoseconds, at: 8)
        try bind(sqliteInteger(source.size, field: "source size"), at: 9)
        try bind(sqliteInteger(source.completeOffset, field: "complete offset"), at: 10)
        try bind(source.currentModel, at: 11)
        try bind(source.currentProject, at: 12)
        try bind(source.firstHash, at: 13)
        try bind(Int64(source.firstHashLength), at: 14)
        try bind(source.checkpointHash, at: 15)
        try bind(Int64(source.checkpointHashLength), at: 16)
        try bind(Int64(source.parserVersion), at: 17)
        try bind(Int64(source.malformedLines), at: 18)
        try bind(Int64(source.oversizedLines), at: 19)
        if let contentFingerprint = source.contentFingerprint {
            try bind(contentFingerprint, at: 20)
        } else {
            try bindNull(at: 20)
        }
    }
}

func sqliteInteger(_ value: UInt64, field: String) throws -> Int64 {
    guard value <= UInt64(Int64.max) else {
        throw UsageCostIndexStoreError.integerOverflow(field: field)
    }
    return Int64(value)
}
