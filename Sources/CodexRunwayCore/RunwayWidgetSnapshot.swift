import Darwin
import Foundation

public enum RunwayWidgetQuotaSource: String, Codable, Sendable {
    case standard
    case modelSpecific
}

public enum RunwayWidgetTokenSource: String, Codable, Sendable {
    case allDevices
    case thisMac
}

public enum RunwayWidgetAvailability: String, Codable, Sendable {
    case available
    case notLoggedIn
    case cliUnavailable
    case unavailable
}

public struct RunwayWidgetQuota: Codable, Equatable, Sendable {
    public var title: String
    public var windowMinutes: Int?
    public var source: RunwayWidgetQuotaSource
    public var usedPercent: Int
    public var remainingPercent: Int
    public var resetsAt: Date?

    public init(
        title: String,
        windowMinutes: Int?,
        source: RunwayWidgetQuotaSource,
        usedPercent: Int,
        remainingPercent: Int,
        resetsAt: Date?)
    {
        self.title = title
        self.windowMinutes = windowMinutes
        self.source = source
        self.usedPercent = max(0, min(100, usedPercent))
        self.remainingPercent = max(0, min(100, remainingPercent))
        self.resetsAt = resetsAt
    }
}

public struct RunwayWidgetDailyTokens: Codable, Equatable, Sendable {
    public var date: String
    public var tokens: Int

    public init(date: String, tokens: Int) {
        self.date = date
        self.tokens = max(0, tokens)
    }
}

public struct RunwayWidgetResetCredits: Codable, Equatable, Sendable {
    public var availableCount: Int
    public var expiringCount: Int

    public init(availableCount: Int, expiringCount: Int) {
        self.availableCount = max(0, availableCount)
        self.expiringCount = max(0, expiringCount)
    }
}

public struct RunwayWidgetProviderSnapshot: Codable, Equatable, Sendable {
    public var provider: RunwayProvider
    public var availability: RunwayWidgetAvailability
    public var plan: String?
    public var updatedAt: Date?
    public var quota: [RunwayWidgetQuota]
    public var balanceUSD: Decimal?
    public var apiEquivalentCostUSD: Decimal?
    public var tokenSource: RunwayWidgetTokenSource
    public var dailyTokens: [RunwayWidgetDailyTokens]
    public var resetCredits: RunwayWidgetResetCredits?

    public init(
        provider: RunwayProvider,
        availability: RunwayWidgetAvailability,
        plan: String?,
        updatedAt: Date?,
        quota: [RunwayWidgetQuota],
        balanceUSD: Decimal?,
        apiEquivalentCostUSD: Decimal?,
        tokenSource: RunwayWidgetTokenSource,
        dailyTokens: [RunwayWidgetDailyTokens],
        resetCredits: RunwayWidgetResetCredits?)
    {
        self.provider = provider
        self.availability = availability
        self.plan = plan
        self.updatedAt = updatedAt
        self.quota = Self.sortedQuota(quota)
        self.balanceUSD = balanceUSD
        self.apiEquivalentCostUSD = apiEquivalentCostUSD
        self.tokenSource = tokenSource
        self.dailyTokens = dailyTokens.sorted { $0.date < $1.date }
        self.resetCredits = resetCredits
    }

    public static func sortedQuota(_ quota: [RunwayWidgetQuota]) -> [RunwayWidgetQuota] {
        quota.sorted { lhs, rhs in
            switch (lhs.source, rhs.source) {
            case (.standard, .modelSpecific): return true
            case (.modelSpecific, .standard): return false
            default:
                return (lhs.windowMinutes ?? .max) < (rhs.windowMinutes ?? .max)
            }
        }
    }
}

public struct RunwayWidgetResetTodaySnapshot: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case yes
        case no
        case unknown
    }

    public var state: State
    public var resetType: RateLimitResetType?
    public var nextScheduledAt: Date?
    public var nextScheduledResetType: RateLimitResetType?
    public var lastSuccessfulCheckAt: Date?
    public var fetchedAt: Date

    public init(
        state: State,
        resetType: RateLimitResetType? = nil,
        nextScheduledAt: Date?,
        nextScheduledResetType: RateLimitResetType? = nil,
        lastSuccessfulCheckAt: Date?,
        fetchedAt: Date)
    {
        self.state = state
        self.resetType = resetType
        self.nextScheduledAt = nextScheduledAt
        self.nextScheduledResetType = nextScheduledResetType
        self.lastSuccessfulCheckAt = lastSuccessfulCheckAt
        self.fetchedAt = fetchedAt
    }
}

public struct RunwayWidgetSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let staleAfter: TimeInterval = 60 * 60

    public var schemaVersion: Int
    public var generatedAt: Date
    public var language: ResolvedLanguage
    public var providers: [RunwayWidgetProviderSnapshot]
    public var resetToday: RunwayWidgetResetTodaySnapshot?

    public init(
        schemaVersion: Int = currentSchemaVersion,
        generatedAt: Date,
        language: ResolvedLanguage,
        providers: [RunwayWidgetProviderSnapshot],
        resetToday: RunwayWidgetResetTodaySnapshot?)
    {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.language = language
        self.providers = providers.sorted { $0.provider.rawValue < $1.provider.rawValue }
        self.resetToday = resetToday
    }

    public func isStale(at now: Date = Date()) -> Bool {
        now.timeIntervalSince(generatedAt) > Self.staleAfter
    }

    public func provider(_ provider: RunwayProvider) -> RunwayWidgetProviderSnapshot? {
        providers.first { $0.provider == provider }
    }
}

public enum RunwayWidgetSnapshotStoreError: Error, Equatable {
    case appGroupUnavailable(String)
    case missing
    case unsupportedSchemaVersion(Int)
}

public struct RunwayWidgetSnapshotStore: Sendable {
    public static let defaultAppGroupID = "group.com.github.codex-runway"
    public static let fileName = "widget-snapshot.json"
    public static let localDirectoryName = ".codex-runway"

    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public init(appGroupID: String = defaultAppGroupID, fileManager: FileManager = .default) throws {
        guard let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID)
        else {
            throw RunwayWidgetSnapshotStoreError.appGroupUnavailable(appGroupID)
        }
        self.init(fileURL: container.appendingPathComponent(Self.fileName, isDirectory: false))
    }

    public static func make(
        mode: RunwayWidgetStorageMode,
        appGroupID: String? = nil,
        homeDirectory: URL = systemUserHomeDirectory,
        fileManager: FileManager = .default
    ) throws -> Self {
        switch mode {
        case .appGroup:
            return try Self(
                appGroupID: appGroupID ?? defaultAppGroupID,
                fileManager: fileManager)
        case .localDevelopment:
            return Self(fileURL: homeDirectory
                .appendingPathComponent(localDirectoryName, isDirectory: true)
                .appendingPathComponent(fileName, isDirectory: false))
        }
    }

    public static var systemUserHomeDirectory: URL {
        guard let record = getpwuid(getuid()), let directory = record.pointee.pw_dir else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
    }

    public func save(_ snapshot: RunwayWidgetSnapshot, fileManager: FileManager = .default) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    public func load(fileManager: FileManager = .default) throws -> RunwayWidgetSnapshot {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw RunwayWidgetSnapshotStoreError.missing
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(RunwayWidgetSnapshot.self, from: Data(contentsOf: fileURL))
        guard snapshot.schemaVersion == RunwayWidgetSnapshot.currentSchemaVersion else {
            throw RunwayWidgetSnapshotStoreError.unsupportedSchemaVersion(snapshot.schemaVersion)
        }
        return snapshot
    }
}

/// Host-side snapshot locations chosen at launch.
///
/// Local/ad-hoc builds must not call `containerURL(forSecurityApplicationGroupIdentifier:)`.
/// That API touches `~/Library/Group Containers` and triggers
/// `kTCCServiceSystemPolicyAppData` on every launch.
public struct RunwayWidgetLaunchStorage: Sendable {
    public var store: RunwayWidgetSnapshotStore
    public var compatibilityStore: RunwayWidgetSnapshotStore?

    public static func resolve(
        mode: RunwayWidgetStorageMode,
        appGroupID: String? = nil,
        homeDirectory: URL = RunwayWidgetSnapshotStore.systemUserHomeDirectory,
        fileManager: FileManager = .default
    ) throws -> Self {
        let store = try RunwayWidgetSnapshotStore.make(
            mode: mode,
            appGroupID: appGroupID,
            homeDirectory: homeDirectory,
            fileManager: fileManager)
        return Self(store: store, compatibilityStore: nil)
    }
}
