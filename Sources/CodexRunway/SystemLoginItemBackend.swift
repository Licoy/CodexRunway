import CodexRunwayCore
@preconcurrency import CoreServices
import Foundation
import ServiceManagement

struct SystemLoginItemBackend: LoginItemBackend {
    let appURL: URL

    init(appURL: URL = Bundle.main.bundleURL) {
        self.appURL = appURL
    }

    func status() throws -> LoginItemStatus {
        if #available(macOS 13.0, *) {
            switch SMAppService.mainApp.status {
            case .enabled: return .enabled
            case .notRegistered: return .notRegistered
            case .requiresApproval: return .requiresApproval
            case .notFound: throw LoginItemError.statusUnavailable
            @unknown default: throw LoginItemError.statusUnavailable
            }
        } else {
            return try SessionLoginItems.status(appURL)
        }
    }

    func register() throws {
        if #available(macOS 13.0, *) {
            try Self.registerMainApp()
        } else {
            try SessionLoginItems.insert(appURL)
        }
    }

    func unregister() throws {
        if #available(macOS 13.0, *) {
            try Self.unregisterMainApp()
        } else {
            try SessionLoginItems.remove(appURL)
        }
    }

    @available(macOS 13.0, *)
    private static func registerMainApp() throws {
        let service = SMAppService.mainApp
        if service.status == .enabled || service.status == .requiresApproval { return }
        do {
            try service.register()
        } catch {
            // A denied registration may still create an item awaiting user approval.
            if service.status == .requiresApproval { return }
            throw LoginItemError.registerFailed
        }
    }

    @available(macOS 13.0, *)
    private static func unregisterMainApp() throws {
        let service = SMAppService.mainApp
        if service.status == .notRegistered { return }
        do {
            try service.unregister()
        } catch {
            throw LoginItemError.unregisterFailed
        }
    }
}

extension LoginItemApplier {
    static func production(
        bundleURL: URL = Bundle.main.bundleURL,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> LoginItemApplier {
        LoginItemApplier(
            backend: SystemLoginItemBackend(appURL: bundleURL),
            canMutateSystem: supportsHost(bundleURL: bundleURL, bundleIdentifier: bundleIdentifier))
    }

    static func supportsHost(bundleURL: URL, bundleIdentifier: String?) -> Bool {
        bundleURL.pathExtension.lowercased() == "app"
            && bundleIdentifier != nil
            && bundleIdentifier != "com.github.codex-runway.swift-dev"
    }
}

/// Session login items for macOS 12. `SMAppService.mainApp` exists only on 13+.
private enum SessionLoginItems {
    static func status(_ url: URL) throws -> LoginItemStatus {
        try withList(or: .statusUnavailable) { list in
            try matchingItem(in: list, url: url) == nil ? .notRegistered : .enabled
        }
    }

    static func insert(_ url: URL) throws {
        try withList(or: .registerFailed) { list in
            if try matchingItem(in: list, url: url) != nil { return }
            guard LSSharedFileListInsertItemURL(
                list,
                kLSSharedFileListItemLast.takeUnretainedValue(),
                nil,
                nil,
                url as CFURL,
                nil,
                nil) != nil
            else { throw LoginItemError.registerFailed }
        }
    }

    static func remove(_ url: URL) throws {
        try withList(or: .unregisterFailed) { list in
            guard let item = try matchingItem(in: list, url: url) else { return }
            let status = LSSharedFileListItemRemove(list, item)
            guard status == noErr else { throw LoginItemError.unregisterFailed }
        }
    }

    private static func withList<T>(
        or error: LoginItemError,
        _ body: (LSSharedFileList) throws -> T
    ) throws -> T {
        nonisolated(unsafe) let listType = kLSSharedFileListSessionLoginItems
        guard let created = LSSharedFileListCreate(
            nil,
            listType.takeUnretainedValue(),
            nil)
        else { throw error }
        return try body(created.takeRetainedValue())
    }

    private static func matchingItem(
        in list: LSSharedFileList,
        url: URL
    ) throws -> LSSharedFileListItem? {
        let wanted = url.resolvingSymlinksInPath().path
        guard let snapshot = LSSharedFileListCopySnapshot(list, nil)?.takeRetainedValue() else {
            throw LoginItemError.statusUnavailable
        }
        let count = CFArrayGetCount(snapshot)
        for index in 0..<count {
            let value = CFArrayGetValueAtIndex(snapshot, index)
            let item = unsafeBitCast(value, to: LSSharedFileListItem.self)
            guard let resolved = LSSharedFileListItemCopyResolvedURL(
                item,
                LSSharedFileListResolutionFlags(
                    kLSSharedFileListNoUserInteraction | kLSSharedFileListDoNotMountVolumes),
                nil)?
                .takeRetainedValue()
            else { continue }
            let itemURL = (resolved as URL).resolvingSymlinksInPath()
            if itemURL.path == wanted { return item }
        }
        return nil
    }
}
