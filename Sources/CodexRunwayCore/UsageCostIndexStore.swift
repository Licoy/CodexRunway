import Foundation
import SQLite3

final class UsageCostIndexStore {
    typealias EventEmitter = (UsageCostIndexedEvent) throws -> Void
    let database: SQLiteDatabase
    let timeZoneIdentifier: String
    private let parserVersion: Int

    init(url: URL, parserVersion: Int, timeZoneIdentifier: String) throws {
        database = try SQLiteDatabase(url: url)
        self.parserVersion = parserVersion
        self.timeZoneIdentifier = timeZoneIdentifier
        try initializeSchema()
    }

    func sourceRows() throws -> [UsageCostIndexedSource] {
        let sql = "SELECT id, \(UsageCostIndexSchema.sourceColumns) FROM source_files ORDER BY basename"
        return try database.withStatement(sql, operation: "read indexed sources") { statement in
            var rows: [UsageCostIndexedSource] = []
            while try statement.step() {
                if rows.count.isMultiple(of: 512) { try Task.checkCancellation() }
                rows.append(try decodeUsageCostSource(statement, parserVersion: parserVersion))
            }
            return rows
        }
    }

    @discardableResult
    func rebuildOrAppend(
        initialSource: UsageCostIndexedSource,
        replacingEventsFrom offset: UInt64,
        scan: (_ emit: EventEmitter) throws -> UsageCostIndexedSource
    ) throws -> UsageCostIndexedSource {
        try database.transaction {
            let fileID = try upsert(initialSource)
            try deleteEvents(fileID: fileID, from: offset)
            let insert = try database.prepare(Self.insertEventSQL, operation: "prepare usage event insert")
            let finalSource = try scan { event in
                try self.insert(event, fileID: fileID, using: insert)
            }
            guard finalSource.basename == initialSource.basename else {
                throw UsageCostIndexStoreError.sourceIdentityMismatch(basename: initialSource.basename)
            }
            var stored = finalSource
            stored.id = fileID
            _ = try upsert(stored)
            return stored
        }
    }

    func adoptSource(_ source: UsageCostIndexedSource) throws {
        guard let expectedID = source.id else {
            throw UsageCostIndexStoreError.missingSourceID(basename: source.basename)
        }
        try database.transaction {
            let actualID = try upsert(source)
            guard actualID == expectedID else {
                throw UsageCostIndexStoreError.sourceIdentityMismatch(basename: source.basename)
            }
        }
    }

    @discardableResult
    func removeSources(exceptBasenames retained: Set<String>) throws -> Int {
        try database.transaction {
            let stale = try sourceRows().filter { !retained.contains($0.basename) }
            let statement = try database.prepare(
                "DELETE FROM source_files WHERE id = ?",
                operation: "prepare stale source deletion")
            var removed = 0
            for source in stale {
                guard let id = source.id else { continue }
                try statement.bind(id, at: 1)
                _ = try statement.step()
                removed += Int(database.changes)
                try statement.reset()
            }
            return removed
        }
    }

    func events(in window: DateInterval) throws -> [UsageCostIndexedEvent] {
        let sql = """
            SELECT MIN(timestamp), day_key, model, project,
                   SUM(uncached_input_tokens), SUM(cached_input_tokens),
                   SUM(output_tokens), SUM(turns),
                   MAX(CASE WHEN
                       typeof(timestamp) NOT IN ('real', 'integer') OR
                       typeof(day_key) != 'text' OR typeof(model) != 'text' OR
                       typeof(project) != 'text' OR
                       typeof(uncached_input_tokens) != 'integer' OR
                       typeof(cached_input_tokens) != 'integer' OR
                       typeof(output_tokens) != 'integer' OR
                       typeof(turns) != 'integer'
                   THEN 1 ELSE 0 END)
            FROM usage_events
            WHERE timestamp >= ? AND timestamp <= ?
            GROUP BY day_key, model, project
            ORDER BY day_key, model, project
            """
        return try database.withStatement(sql, operation: "query usage events") { statement in
            try statement.bind(window.start.timeIntervalSince1970, at: 1)
            try statement.bind(window.end.timeIntervalSince1970, at: 2)
            var rows: [UsageCostIndexedEvent] = []
            while try statement.step() {
                if rows.count.isMultiple(of: 512) { try Task.checkCancellation() }
                rows.append(try decodeUsageCostAggregate(statement))
            }
            return rows
        }
    }

    func validateEventStorage() throws {
        let sql = """
            SELECT 1 FROM usage_events
            WHERE typeof(file_id) != 'integer'
               OR file_id <= 0
               OR typeof(byte_offset) != 'integer'
               OR byte_offset < 0
               OR typeof(timestamp) NOT IN ('real', 'integer')
               OR timestamp NOT BETWEEN -1.7976931348623157e308 AND 1.7976931348623157e308
               OR typeof(day_key) != 'text'
               OR typeof(model) != 'text'
               OR typeof(project) != 'text'
               OR typeof(uncached_input_tokens) != 'integer'
               OR uncached_input_tokens < 0
               OR typeof(cached_input_tokens) != 'integer'
               OR cached_input_tokens < 0
               OR typeof(output_tokens) != 'integer'
               OR output_tokens < 0
               OR typeof(turns) != 'integer'
               OR turns < 0
            LIMIT 1
            """
        try database.withStatement(sql, operation: "validate usage event storage") { statement in
            if try statement.step() {
                throw UsageCostIndexStoreError.corruptRow(field: "usage event storage")
            }
        }
    }

    private func initializeSchema() throws {
        guard try hasTable(named: "index_metadata") else {
            if try hasUserTables() {
                throw UsageCostIndexStoreError.schemaVersionMismatch(
                    expected: UsageCostIndexSchema.version,
                    actual: nil)
            }
            try createSchema()
            return
        }
        let metadata: (schema: Int?, parser: Int?, timeZone: String?)
        do {
            metadata = try storedMetadata()
        } catch let error as SQLiteError {
            guard Self.isSchemaError(error) else { throw error }
            throw UsageCostIndexStoreError.schemaVersionMismatch(
                expected: UsageCostIndexSchema.version,
                actual: nil)
        }
        guard metadata.schema == UsageCostIndexSchema.version else {
            throw UsageCostIndexStoreError.schemaVersionMismatch(
                expected: UsageCostIndexSchema.version,
                actual: metadata.schema)
        }
        guard metadata.parser == parserVersion else {
            throw UsageCostIndexStoreError.parserVersionMismatch(
                expected: parserVersion,
                actual: metadata.parser)
        }
        guard metadata.timeZone == timeZoneIdentifier else {
            throw UsageCostIndexStoreError.timeZoneMismatch(
                expected: timeZoneIdentifier,
                actual: metadata.timeZone)
        }
        do {
            try validateStorage()
        } catch let error as SQLiteError {
            guard Self.isSchemaError(error) else { throw error }
            throw UsageCostIndexStoreError.schemaVersionMismatch(
                expected: UsageCostIndexSchema.version,
                actual: metadata.schema)
        }
    }

    private func createSchema() throws {
        try database.transaction {
            try database.execute(UsageCostIndexSchema.create, operation: "create usage cost schema")
            try database.withStatement(
                """
                INSERT INTO index_metadata(
                    singleton, schema_version, parser_version, aggregation_time_zone
                ) VALUES (1, ?, ?, ?)
                """,
                operation: "prepare index metadata") { statement in
                try statement.bind(Int64(UsageCostIndexSchema.version), at: 1)
                try statement.bind(Int64(parserVersion), at: 2)
                try statement.bind(timeZoneIdentifier, at: 3)
                _ = try statement.step()
            }
        }
    }

    private func hasTable(named name: String) throws -> Bool {
        try database.withStatement(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
            operation: "inspect index schema") { statement in
            try statement.bind(name, at: 1)
            return try statement.step()
        }
    }

    private func hasUserTables() throws -> Bool {
        try database.withStatement(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' LIMIT 1",
            operation: "inspect database tables") { try $0.step() }
    }

    private func storedMetadata() throws -> (schema: Int?, parser: Int?, timeZone: String?) {
        try database.withStatement(
            """
            SELECT schema_version, parser_version, aggregation_time_zone
            FROM index_metadata WHERE singleton = 1
            """,
            operation: "read index metadata") { statement in
            guard try statement.step() else { return (nil, nil, nil) }
            let schema = try requiredInt64(statement, column: 0, field: "schema version")
            let parser = try requiredInt64(statement, column: 1, field: "parser version")
            let timeZone = try requiredString(
                statement,
                column: 2,
                field: "aggregation time zone")
            return (Int(exactly: schema), Int(exactly: parser), timeZone)
        }
    }

    func storageIsValid() throws -> Bool {
        do {
            try validateStorage()
            return true
        } catch is UsageCostIndexStoreError {
            return false
        } catch let error as SQLiteError
            where error.code & 0xFF == SQLITE_ERROR || error.code & 0xFF == SQLITE_SCHEMA
        {
            return false
        }
    }

    private func validateStorage() throws {
        _ = try sourceRows()
        _ = try sourceHashCacheRows()
        try validateEventStorage()
    }

    private func upsert(_ source: UsageCostIndexedSource) throws -> Int64 {
        let placeholders = Array(repeating: "?", count: 20).joined(separator: ", ")
        let sql = """
            INSERT INTO source_files(\(UsageCostIndexSchema.sourceColumns))
            VALUES (\(placeholders))
            ON CONFLICT(basename) DO UPDATE SET \(UsageCostIndexSchema.sourceAssignments)
            """
        try database.withStatement(sql, operation: "upsert indexed source") { statement in
            try statement.bind(source: source)
            _ = try statement.step()
        }
        return try sourceID(for: source.basename)
    }

    private func sourceID(for basename: String) throws -> Int64 {
        try database.withStatement(
            "SELECT id FROM source_files WHERE basename = ?",
            operation: "read indexed source id") { statement in
            try statement.bind(basename, at: 1)
            guard try statement.step() else {
                throw UsageCostIndexStoreError.missingSourceID(basename: basename)
            }
            return try requiredInt64(statement, column: 0, field: "source id")
        }
    }

    private func deleteEvents(fileID: Int64, from offset: UInt64) throws {
        try database.withStatement(
            "DELETE FROM usage_events WHERE file_id = ? AND byte_offset >= ?",
            operation: "delete replaced usage events") { statement in
            try statement.bind(fileID, at: 1)
            try statement.bind(sqliteInteger(offset, field: "event replacement offset"), at: 2)
            _ = try statement.step()
        }
    }

    private func insert(
        _ event: UsageCostIndexedEvent,
        fileID: Int64,
        using statement: SQLiteStatement
    ) throws {
        try statement.bind(fileID, at: 1)
        try statement.bind(sqliteInteger(event.byteOffset, field: "event byte offset"), at: 2)
        try statement.bind(event.timestamp.timeIntervalSince1970, at: 3)
        try statement.bind(event.dayKey, at: 4)
        try statement.bind(event.model, at: 5)
        try statement.bind(event.project, at: 6)
        try statement.bind(Int64(event.uncachedInputTokens), at: 7)
        try statement.bind(Int64(event.cachedInputTokens), at: 8)
        try statement.bind(Int64(event.outputTokens), at: 9)
        try statement.bind(Int64(event.turns), at: 10)
        _ = try statement.step()
        try statement.reset()
    }

    private static let insertEventSQL = """
        INSERT INTO usage_events(
            file_id, byte_offset, timestamp, day_key, model, project,
            uncached_input_tokens, cached_input_tokens, output_tokens, turns)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(file_id, byte_offset) DO UPDATE SET
            timestamp = excluded.timestamp, day_key = excluded.day_key,
            model = excluded.model, project = excluded.project,
            uncached_input_tokens = excluded.uncached_input_tokens,
            cached_input_tokens = excluded.cached_input_tokens,
            output_tokens = excluded.output_tokens,
            turns = excluded.turns
        """

    private static func isSchemaError(_ error: SQLiteError) -> Bool {
        let primaryCode = error.code & 0xFF
        return primaryCode == SQLITE_ERROR || primaryCode == SQLITE_SCHEMA
    }
}
