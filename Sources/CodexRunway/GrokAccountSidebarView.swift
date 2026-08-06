import AppKit
import CodexRunwayCore
import SwiftUI

struct GrokAccountsDetailView: View {
    @ObservedObject var model: RunwayModel
    var l10n: L10n

    @State private var accountPendingSwitch: GrokManagedAccount?
    @State private var accountPendingDelete: GrokManagedAccount?
    @State private var editingAliasID: String?
    @State private var aliasDraft = ""
    @State private var showPasteSheet = false
    @State private var pasteText = ""
    @State private var pasteSheetError: String?
    @State private var isImportingPaste = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            toolbar
            PolishedScrollView(verticalPadding: 0, fadesEdges: false) {
                VStack(alignment: .leading, spacing: 8) {
                    if orderedAccounts.isEmpty {
                        Text(l10n.text(.grokAccountsEmpty))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RunwaySurface.fill,
                                in: RoundedRectangle(cornerRadius: RunwaySurface.cornerRadius))
                    } else {
                        ForEach(orderedAccounts) { account in
                            let isCurrent = account.id == model.grokAccountState.currentAccountID
                            GrokAccountDetailCard(
                                account: account,
                                isCurrent: isCurrent,
                                l10n: l10n,
                                isBusy: model.isGrokAccountOperationInProgress,
                                isRefreshing: model.isRefreshingGrokAccount(id: account.id),
                                capabilities: capabilities(for: account, isCurrent: isCurrent),
                                aliasDraft: editingAliasID == account.id ? $aliasDraft : nil,
                                onSwitch: { accountPendingSwitch = account },
                                onRefresh: { model.refreshGrokAccountQuota(id: account.id) },
                                onEditAlias: {
                                    editingAliasID = account.id
                                    aliasDraft = account.alias ?? ""
                                },
                                onSaveAlias: {
                                    model.updateGrokAccountAlias(id: account.id, alias: aliasDraft)
                                    editingAliasID = nil
                                },
                                onCancelAlias: { editingAliasID = nil },
                                onMoveUp: { model.moveGrokAccount(id: account.id, direction: -1) },
                                onMoveDown: { model.moveGrokAccount(id: account.id, direction: 1) },
                                onDelete: { accountPendingDelete = account })
                        }
                    }
                    if let message = model.grokAccountOperationMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }
                    if let error = model.grokLastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $showPasteSheet) {
            grokPasteImportSheet
        }
        .sheet(isPresented: Binding(
            get: { accountPendingSwitch != nil },
            set: { if !$0 { accountPendingSwitch = nil } }))
        {
            GrokSwitchConfirmSheet(
                accountName: accountPendingSwitch?.resolvedDisplayName ?? "",
                l10n: l10n,
                onConfirm: {
                    if let id = accountPendingSwitch?.id {
                        model.switchGrokAccount(id: id)
                    }
                    accountPendingSwitch = nil
                },
                onCancel: { accountPendingSwitch = nil })
        }
        .alert(
            l10n.text(.grokAccountsDeleteConfirmTitle),
            isPresented: Binding(
                get: { accountPendingDelete != nil },
                set: { if !$0 { accountPendingDelete = nil } }))
        {
            Button(l10n.text(.grokAccountsRemove), role: .destructive) {
                if let id = accountPendingDelete?.id {
                    model.deleteGrokAccount(id: id)
                }
                accountPendingDelete = nil
            }
            Button(l10n.text(.cancel), role: .cancel) {
                accountPendingDelete = nil
            }
        } message: {
            Text(l10n.text(.grokAccountsDeleteConfirmMessage))
        }
        .alert(
            l10n.text(.grokSwitchRunningTitle),
            isPresented: Binding(
                get: { model.grokRunningProcessWarningAccountID != nil },
                set: { if !$0 { model.grokRunningProcessWarningAccountID = nil } }))
        {
            Button(l10n.text(.grokAccountsMakeCurrent), role: .destructive) {
                model.confirmGrokSwitchWhileRunning()
            }
            Button(l10n.text(.cancel), role: .cancel) {
                model.grokRunningProcessWarningAccountID = nil
            }
        } message: {
            Text(l10n.text(.grokSwitchRunningMessage))
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            ToolbarGhostButton(
                title: l10n.text(.grokAccountsRefreshAll),
                systemImage: "arrow.clockwise",
                isLoading: model.isRefreshingGrok)
            {
                model.refreshAllGrokAccountQuotas()
            }
            if model.isGrokOAuthLoginInProgress {
                ToolbarGhostButton(
                    title: l10n.text(.cancel),
                    systemImage: "xmark")
                {
                    model.cancelGrokOAuthLogin()
                }
            }
            Spacer()
            ToolbarAccentMenu(
                title: l10n.text(.accountsAdd),
                systemImage: "plus",
                isDisabled: model.isGrokAccountOperationInProgress)
            {
                Button(l10n.text(.grokAccountsAddOAuth)) { model.startGrokOAuthLogin() }
                Button(l10n.text(.grokAccountsAddPaste)) {
                    pasteText = ""
                    pasteSheetError = nil
                    showPasteSheet = true
                }
                Button(l10n.text(.grokAccountsImportOfficial)) { model.importOfficialGrokAccount() }
            }
        }
    }

    private var grokPasteImportSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(l10n.text(.grokAccountsAddPaste)).font(.headline)
            Text(l10n.text(.grokAccountsPasteHint))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            PasteableTextEditor(text: $pasteText, monospaced: false)
                .frame(minHeight: 160)
                .disabled(isImportingPaste)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1))
            HStack {
                Button(l10n.text(.accountsPasteFromClipboard)) {
                    if let clip = NSPasteboard.general.string(forType: .string) {
                        pasteText = clip
                    }
                }
                .disabled(isImportingPaste)
                Spacer()
            }
            if let pasteSheetError {
                Text(pasteSheetError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(l10n.text(.cancel)) {
                    showPasteSheet = false
                    pasteSheetError = nil
                    isImportingPaste = false
                }
                .disabled(isImportingPaste)
                Button {
                    isImportingPaste = true
                    pasteSheetError = nil
                    Task {
                        let ok = await model.importPastedGrokCredentials(pasteText)
                        isImportingPaste = false
                        if ok {
                            pasteText = ""
                            pasteSheetError = nil
                            showPasteSheet = false
                        } else {
                            pasteSheetError = model.grokLastError
                                ?? l10n.text(.grokAccountsImportNoCredentials)
                        }
                    }
                } label: {
                    if isImportingPaste {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(l10n.text(.accountsAdd))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isImportingPaste
                    || pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 22)
        .frame(width: 480)
        .frame(minHeight: pasteSheetError == nil ? 360 : 400)
    }

    /// Current account first (same pin as Codex sidebar), then sortIndex / name.
    private var orderedAccounts: [GrokManagedAccount] {
        let currentID = model.grokAccountState.currentAccountID
        return model.grokAccountState.accounts.sorted {
            let lCurrent = $0.id == currentID
            let rCurrent = $1.id == currentID
            if lCurrent != rCurrent { return lCurrent && !rCurrent }
            if $0.sortIndex != $1.sortIndex { return $0.sortIndex < $1.sortIndex }
            return $0.resolvedDisplayName.localizedCaseInsensitiveCompare($1.resolvedDisplayName) == .orderedAscending
        }
    }

    /// Move up/down capabilities use sortIndex order (not the current-first display order).
    private func capabilities(for account: GrokManagedAccount, isCurrent: Bool) -> GrokAccountDetailCapabilities {
        let sortOrdered = model.grokAccountState.accounts.sorted {
            if $0.sortIndex != $1.sortIndex { return $0.sortIndex < $1.sortIndex }
            return $0.resolvedDisplayName.localizedCaseInsensitiveCompare($1.resolvedDisplayName) == .orderedAscending
        }
        let index = sortOrdered.firstIndex(where: { $0.id == account.id }) ?? 0
        return GrokAccountDetailCapabilities.make(
            index: index,
            count: sortOrdered.count,
            isCurrent: isCurrent)
    }
}

private struct GrokAccountDetailCard: View {
    var account: GrokManagedAccount
    var isCurrent: Bool
    var l10n: L10n
    var isBusy: Bool
    var isRefreshing: Bool
    var capabilities: GrokAccountDetailCapabilities
    var aliasDraft: Binding<String>?
    var onSwitch: () -> Void
    var onRefresh: () -> Void
    var onEditAlias: () -> Void
    var onSaveAlias: () -> Void
    var onCancelAlias: () -> Void
    var onMoveUp: () -> Void
    var onMoveDown: () -> Void
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow
            if let aliasDraft {
                HStack(spacing: 6) {
                    TextField(l10n.text(.alias), text: aliasDraft)
                        .textFieldStyle(.roundedBorder)
                    Button(l10n.text(.ok), action: onSaveAlias)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button(l10n.text(.cancel), action: onCancelAlias)
                        .controlSize(.small)
                }
            }
            if account.requiresReauth {
                statusLine(l10n.text(.grokReauthenticationRequired), color: Color(nsColor: .systemRed))
            } else if let error = account.lastError {
                statusLine(
                    GrokAccountLastErrorPresentation.text(for: error, l10n: l10n),
                    color: Color(nsColor: .systemOrange))
            }
            quotaBlock
            managementRow
        }
        .accountManagedCardChrome(isCurrent: isCurrent)
    }

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(account.resolvedDisplayName)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    if isCurrent {
                        CurrentAccountTag(l10n: l10n)
                    }
                    if account.cachedQuota?.plan != nil {
                        GrokSubscriptionTierTag(plan: account.cachedQuota?.plan, l10n: l10n)
                    }
                    if let email = account.email, email != account.resolvedDisplayName {
                        Text(email)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            Spacer(minLength: 6)
            HStack(spacing: 2) {
                AccountIconActionButton(
                    title: isCurrent
                        ? l10n.text(.grokAccountsCurrent)
                        : l10n.text(.grokAccountsMakeCurrent),
                    systemImage: isCurrent ? "checkmark.circle.fill" : "checkmark.circle",
                    isDisabled: isCurrent || isBusy || isRefreshing,
                    tone: isCurrent ? .current : .normal,
                    action: onSwitch)
                AccountIconActionButton(
                    title: l10n.text(.refresh),
                    systemImage: "arrow.clockwise",
                    isDisabled: isRefreshing,
                    isLoading: isRefreshing,
                    tone: .normal,
                    action: onRefresh)
            }
        }
    }

    private func statusLine(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .lineLimit(2)
    }

    @ViewBuilder
    private var quotaBlock: some View {
        if let snapshot = account.cachedQuota {
            let quota = GrokQuotaPresentation.make(snapshot: snapshot, l10n: l10n)
            if let meter = quota.meters.first {
                AccountMiniMeterRow(
                    title: meter.title,
                    remaining: meter.remainingPercent,
                    used: meter.usedPercent,
                    trailingValue: quota.includedUSDAllowance,
                    resetsAt: meter.resetsAt,
                    l10n: l10n,
                    isCurrent: isCurrent)
            }
        } else {
            Text(l10n.text(.grokNoQuotaData))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var managementRow: some View {
        HStack(spacing: 2) {
            Spacer()
            AccountIconActionButton(
                title: l10n.text(.alias),
                systemImage: "pencil",
                isDisabled: isBusy || isRefreshing,
                action: onEditAlias)
            AccountIconActionButton(
                title: l10n.text(.accountsMoveUp),
                systemImage: "arrow.up",
                isDisabled: !capabilities.canMoveUp || isBusy || isRefreshing,
                action: onMoveUp)
            AccountIconActionButton(
                title: l10n.text(.accountsMoveDown),
                systemImage: "arrow.down",
                isDisabled: !capabilities.canMoveDown || isBusy || isRefreshing,
                action: onMoveDown)
            AccountIconActionButton(
                title: capabilities.canDelete
                    ? l10n.text(.grokAccountsRemove)
                    : l10n.text(.grokCurrentAccountCannotDelete),
                systemImage: "trash",
                isDisabled: !capabilities.canDelete || isBusy || isRefreshing,
                action: onDelete)
        }
    }
}

struct GrokSwitchConfirmSheet: View {
    var accountName: String
    var l10n: L10n
    var onConfirm: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(l10n.text(.grokSwitchConfirmTitle))
                .font(.headline)
            Text(String(format: l10n.text(.grokSwitchConfirmMessage), accountName))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(l10n.text(.cancel), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(l10n.text(.grokAccountsMakeCurrent), action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 420)
    }
}
