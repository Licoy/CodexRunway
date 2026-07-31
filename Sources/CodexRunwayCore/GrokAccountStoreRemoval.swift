import Foundation

extension GrokAccountStore {
    public func remove(id: String) throws {
        let originalIndex = try loadIndex()
        guard originalIndex.account(id: id) != nil else {
            throw GrokAccountError.accountNotFound(id)
        }
        guard originalIndex.currentAccountID != id else {
            throw GrokAccountError.currentAccountCannotBeRemoved(id)
        }

        var nextIndex = originalIndex
        nextIndex.accounts.removeAll { $0.id == id }
        let directory = accountDirectory(id: id)
        let authURL = credentialURL(id: id)
        let originalCredentialData = try credentialSnapshotIfPresent(at: authURL)
        let tombstone = rootURL.appendingPathComponent(
            ".grok-remove-\(UUID().uuidString)",
            isDirectory: true)
        var movedCredentialDirectory = false

        do {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.moveItem(at: directory, to: tombstone)
                movedCredentialDirectory = true
            }
            try saveIndex(nextIndex)
            if movedCredentialDirectory {
                try FileManager.default.removeItem(at: tombstone)
            }
        } catch {
            do {
                try rollbackRemoval(
                    id: id,
                    originalIndex: originalIndex,
                    directory: directory,
                    tombstone: tombstone,
                    movedCredentialDirectory: movedCredentialDirectory,
                    originalCredentialData: originalCredentialData)
            } catch {
                throw GrokAccountError.partialWrite(
                    "The Grok account removal could not be rolled back safely.")
            }
            throw GrokAccountError.io("Unable to remove the Grok account.")
        }
    }

    private func rollbackRemoval(
        id: String,
        originalIndex: GrokAccountIndex,
        directory: URL,
        tombstone: URL,
        movedCredentialDirectory: Bool,
        originalCredentialData: Data?) throws
    {
        if movedCredentialDirectory, FileManager.default.fileExists(atPath: tombstone.path) {
            guard !FileManager.default.fileExists(atPath: directory.path) else {
                throw GrokAccountError.partialWrite("The Grok credential directory already exists.")
            }
            try FileManager.default.moveItem(at: tombstone, to: directory)
        }
        try saveIndex(originalIndex)
        if let originalCredentialData {
            try restoreCredentialSnapshot(id: id, data: originalCredentialData)
        } else if movedCredentialDirectory,
                  !FileManager.default.fileExists(atPath: directory.path)
        {
            throw GrokAccountError.partialWrite("The Grok credential directory rollback could not be verified.")
        }
        guard try loadIndex() == originalIndex else {
            throw GrokAccountError.partialWrite("The Grok account index rollback could not be verified.")
        }
    }

    private func credentialSnapshotIfPresent(at url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    private func restoreCredentialSnapshot(id: String, data: Data) throws {
        let url = credentialURL(id: id)
        let existingData = try? Data(contentsOf: url)
        let existingAttributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let existingPermissions = (existingAttributes?[.posixPermissions] as? NSNumber)?.uint16Value
        if existingData != data || existingPermissions != 0o600 {
            try saveCredentialData(id: id, data: data)
        }
        let restoredData = try loadCredentialData(id: id)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value
        guard restoredData == data, permissions == 0o600 else {
            throw GrokAccountError.partialWrite("The Grok credential rollback could not be verified.")
        }
    }
}
