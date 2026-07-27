import Foundation

struct UsageCostIndexRefresher {
    let codexHome: URL
    let store: UsageCostIndexStore
    let parserVersion: Int
    let calendar: Calendar

    func refresh(
        policy: UsageCostRefreshPolicy,
        diagnostics: inout UsageCostRepositoryDiagnostics,
        progress: CostScanProgressReporter? = nil
    ) throws -> [String] {
        switch policy {
        case .ifChanged, .force:
            break
        }
        try Task.checkCancellation()
        diagnostics.indexPasses += 1
        let indexed = try store.sourceRows()
        let indexedByName = Dictionary(uniqueKeysWithValues: indexed.map { ($0.basename, $0) })
        let selection = try selectSources(
            from: UsageCostSourceInventory.files(in: codexHome),
            indexedByName: indexedByName,
            diagnostics: &diagnostics)
        let indexer = UsageCostSourceIndexer(
            store: store,
            parserVersion: parserVersion,
            calendar: calendar)
        var provisionalAnomalies = UsageCostScanAnomalies.zero
        let sources = selection.sources.sorted(by: { $0.file.basename < $1.file.basename })
        let total = sources.count
        if total == 0 {
            progress?.report(.refreshingIndex(completed: 0, total: 0), force: true)
        }
        for (index, item) in sources.enumerated() {
            try Task.checkCancellation()
            progress?.report(
                .refreshingIndex(
                    completed: index,
                    total: total,
                    currentFile: item.file.basename),
                force: index == 0 || index + 1 == total)
            provisionalAnomalies = try provisionalAnomalies.adding(update(
                item,
                existing: indexedByName[item.file.basename],
                indexer: indexer,
                diagnostics: &diagnostics))
        }
        if total > 0 {
            progress?.report(.refreshingIndex(completed: total, total: total), force: true)
        }
        if selection.hashCacheChanged {
            try store.replaceSourceHashCache(with: selection.hashCacheRows)
        }
        let retained = Set(selection.sources.map(\.file.basename))
        diagnostics.removedFiles += try store.removeSources(exceptBasenames: retained)
        return try anomalyWarnings(provisional: provisionalAnomalies)
    }

    private func selectSources(
        from files: [UsageCostSourceFile],
        indexedByName: [String: UsageCostIndexedSource],
        diagnostics: inout UsageCostRepositoryDiagnostics
    ) throws -> SourceSelection {
        let cachedRows = try store.sourceHashCacheRows()
        let cachedByIdentity = Dictionary(uniqueKeysWithValues: cachedRows.map {
            ($0.identity, $0)
        })
        let groups = Dictionary(grouping: files, by: \.basename)
        var selected: [SelectedSource] = []
        var retainedHashes: [UsageCostSourceIdentity: UsageCostCachedFullHash] = [:]
        for basename in groups.keys.sorted() {
            try Task.checkCancellation()
            let candidates = groups[basename] ?? []
            guard candidates.count > 1 else {
                let file = candidates[0]
                let cached = cachedByIdentity[UsageCostSourceIdentity(file: file)]
                    .flatMap { $0.matches(file) ? $0 : nil }
                if let cached { retainedHashes[cached.identity] = cached }
                selected.append(SelectedSource(
                    file: file,
                    byteHash: cached?.digest,
                    indexedByteHash: cachedByteHash(
                        for: indexedByName[basename],
                        in: cachedByIdentity)))
                continue
            }
            var hashes: [(file: UsageCostSourceFile, digest: Data)] = []
            for file in candidates {
                let identity = UsageCostSourceIdentity(file: file)
                let cached = retainedHashes[identity]
                    ?? cachedByIdentity[identity].flatMap { $0.matches(file) ? $0 : nil }
                let row: UsageCostCachedFullHash
                if let cached {
                    row = cached
                } else {
                    let hash = try UsageCostFileHasher.fullSHA256(of: file)
                    diagnostics.validationBytesRead += hash.bytesRead
                    row = UsageCostCachedFullHash(file: file, digest: hash.digest)
                }
                retainedHashes[identity] = row
                hashes.append((file, row.digest))
            }
            guard Set(hashes.map(\.digest)).count == 1 else {
                throw UsageCostRepositoryError.duplicateConflict(basename: basename)
            }
            diagnostics.duplicateFiles += candidates.count - 1
            let preferred = preferredCandidate(
                hashes.map(\.file),
                indexed: indexedByName[basename]) ?? hashes[0].0
            selected.append(SelectedSource(
                file: preferred,
                byteHash: hashes[0].digest,
                indexedByteHash: cachedByteHash(
                    for: indexedByName[basename],
                    in: cachedByIdentity)))
        }
        return SourceSelection(
            sources: selected,
            hashCacheRows: Array(retainedHashes.values),
            hashCacheChanged: Set(retainedHashes.values) != Set(cachedRows))
    }

    private func preferredCandidate(
        _ candidates: [UsageCostSourceFile],
        indexed: UsageCostIndexedSource?
    ) -> UsageCostSourceFile? {
        guard let indexed else { return nil }
        return candidates.first { sameIdentity($0, indexed) }
    }

    private func cachedByteHash(
        for indexed: UsageCostIndexedSource?,
        in cache: [UsageCostSourceIdentity: UsageCostCachedFullHash]
    ) -> Data? {
        guard let indexed else { return nil }
        let identity = UsageCostSourceIdentity(
            device: indexed.device,
            inode: indexed.inode,
            birthTimeNanoseconds: indexed.birthTimeNanoseconds)
        guard let cached = cache[identity],
              cached.size == indexed.size,
              cached.modificationTimeNanoseconds == indexed.modificationTimeNanoseconds,
              cached.statusChangeTimeNanoseconds == indexed.statusChangeTimeNanoseconds
        else { return nil }
        return cached.digest
    }

    private func update(
        _ selected: SelectedSource,
        existing: UsageCostIndexedSource?,
        indexer: UsageCostSourceIndexer,
        diagnostics: inout UsageCostRepositoryDiagnostics
    ) throws -> UsageCostScanAnomalies {
        guard let existing else {
            return try indexer.rebuild(
                file: selected.file,
                existing: nil,
                diagnostics: &diagnostics)
        }
        if sameIdentity(selected.file, existing) {
            return try updateSameIdentity(
                selected,
                existing: existing,
                indexer: indexer,
                diagnostics: &diagnostics)
        }
        if canAdoptExactCopy(selected, existing: existing) {
            try indexer.adopt(file: selected.file, existing: existing)
            diagnostics.adoptedFiles += 1
            return .zero
        }
        return try indexer.rebuild(
            file: selected.file,
            existing: existing,
            diagnostics: &diagnostics)
    }

    private func updateSameIdentity(
        _ selected: SelectedSource,
        existing: UsageCostIndexedSource,
        indexer: UsageCostSourceIndexer,
        diagnostics: inout UsageCostRepositoryDiagnostics
    ) throws -> UsageCostScanAnomalies {
        let file = selected.file
        let sameSize = file.size == existing.size
        let pathChanged = file.url.path != existing.path || file.root.rawValue != existing.root
        let sameModificationTime = file.modificationNanoseconds == existing.modificationTimeNanoseconds
        if pathChanged, sameSize, sameModificationTime, existing.completeOffset == existing.size {
            if try canAdoptMove(
                selected,
                existing: existing,
                indexer: indexer,
                diagnostics: &diagnostics)
            {
                try indexer.adopt(file: file, existing: existing)
                diagnostics.adoptedFiles += 1
                return .zero
            }
            return try indexer.rebuild(
                file: file,
                existing: existing,
                diagnostics: &diagnostics)
        }
        let sameTimes = file.modificationNanoseconds == existing.modificationTimeNanoseconds
            && file.statusChangeNanoseconds == existing.statusChangeTimeNanoseconds
        if sameSize, sameTimes, existing.completeOffset == existing.size {
            diagnostics.cacheHits += 1
            return .zero
        }
        let mayAppend = (file.size > existing.size)
            || (sameSize && sameTimes && existing.completeOffset < existing.size)
        if mayAppend, try indexer.canAppend(
            file: file,
            existing: existing,
            diagnostics: &diagnostics)
        {
            return try indexer.append(file: file, existing: existing, diagnostics: &diagnostics)
        }
        return try indexer.rebuild(
            file: file,
            existing: existing,
            diagnostics: &diagnostics)
    }

    private func canAdoptMove(
        _ selected: SelectedSource,
        existing: UsageCostIndexedSource,
        indexer: UsageCostSourceIndexer,
        diagnostics: inout UsageCostRepositoryDiagnostics
    ) throws -> Bool {
        guard selected.file.size == existing.size,
              existing.completeOffset == existing.size
        else {
            return false
        }
        if let selectedHash = selected.byteHash,
           let indexedHash = selected.indexedByteHash
        {
            return selectedHash == indexedHash
        }
        return try indexer.canAdopt(
            file: selected.file,
            existing: existing,
            diagnostics: &diagnostics)
    }

    private func canAdoptExactCopy(
        _ selected: SelectedSource,
        existing: UsageCostIndexedSource
    ) -> Bool {
        guard selected.file.size == existing.size,
              existing.completeOffset == existing.size,
              let selectedHash = selected.byteHash,
              let indexedHash = selected.indexedByteHash
        else { return false }
        return selectedHash == indexedHash
    }

    private func sameIdentity(
        _ file: UsageCostSourceFile,
        _ indexed: UsageCostIndexedSource
    ) -> Bool {
        file.device == indexed.device
            && file.inode == indexed.inode
            && file.birthNanoseconds == indexed.birthTimeNanoseconds
    }

    private func anomalyWarnings(provisional: UsageCostScanAnomalies) throws -> [String] {
        let rows = try store.sourceRows()
        let malformed = try rows.reduce(provisional.malformedLines) {
            try checkedAdd($0, $1.malformedLines, field: "malformed line count")
        }
        let oversized = try rows.reduce(provisional.oversizedLines) {
            try checkedAdd($0, $1.oversizedLines, field: "oversized line count")
        }
        var warnings: [String] = []
        if malformed > 0 { warnings.append("malformed-jsonl-lines:\(malformed)") }
        if oversized > 0 { warnings.append("oversized-jsonl-lines:\(oversized)") }
        return warnings
    }
}

private struct SelectedSource {
    var file: UsageCostSourceFile
    var byteHash: Data?
    var indexedByteHash: Data?
}

private struct SourceSelection {
    var sources: [SelectedSource]
    var hashCacheRows: [UsageCostCachedFullHash]
    var hashCacheChanged: Bool
}
