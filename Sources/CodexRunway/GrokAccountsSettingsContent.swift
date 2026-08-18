import CodexRunwayCore
import SwiftUI

struct GrokAccountsSettingsContent: View {
    @ObservedObject var model: RunwayModel
    var l10n: L10n

    @State private var pendingDelete: GrokManagedAccount?
    @State private var pendingSwitch: GrokManagedAccount?
    @State private var editingAliasID: String?
    @State private var aliasDraft = ""

    var body: some View {
        Group {
            Text(l10n.text(.grokSwitchOnlyNewSessions))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.grokAccountState.accounts.isEmpty {
                Text(l10n.text(.grokAccountsEmpty))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 8) {
                    ForEach(orderedAccounts) { account in
                        accountRow(account)
                    }
                }
            }
            if let message = model.grokAccountOperationMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.grokLastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .sheet(isPresented: Binding(
            get: { pendingSwitch != nil },
            set: { if !$0 { pendingSwitch = nil } }))
        {
            GrokSwitchConfirmSheet(
                accountName: pendingSwitch?.resolvedDisplayName ?? "",
                l10n: l10n,
                onConfirm: {
                    if let id = pendingSwitch?.id { model.switchGrokAccount(id: id) }
                    pendingSwitch = nil
                },
                onCancel: { pendingSwitch = nil })
        }
        .alert(
            l10n.text(.grokAccountsDeleteConfirmTitle),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }))
        {
            Button(l10n.text(.grokAccountsRemove), role: .destructive) {
                if let id = pendingDelete?.id { model.deleteGrokAccount(id: id) }
                pendingDelete = nil
            }
            Button(l10n.text(.cancel), role: .cancel) { pendingDelete = nil }
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

    private var orderedAccounts: [GrokManagedAccount] {
        model.grokAccountState.accounts.sorted {
            if $0.sortIndex != $1.sortIndex { return $0.sortIndex < $1.sortIndex }
            return $0.resolvedDisplayName.localizedCaseInsensitiveCompare($1.resolvedDisplayName) == .orderedAscending
        }
    }

    private func accountRow(_ account: GrokManagedAccount) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(account.resolvedDisplayName)
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                        if isCurrent(account) { CurrentAccountTag(l10n: l10n) }
                        if account.cachedQuota?.plan != nil {
                            GrokSubscriptionTierTag(plan: account.cachedQuota?.plan, l10n: l10n)
                        }
                    }
                    if let email = account.email, email != account.resolvedDisplayName {
                        Text(email).font(.caption).foregroundStyle(.secondary)
                    }
                    if account.requiresReauth {
                        Text(l10n.text(.grokReauthenticationRequired))
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else if let error = account.lastError {
                        Text(GrokAccountLastErrorPresentation.text(for: error, l10n: l10n))
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                    } else if let quota = account.cachedQuota {
                        Text(GrokQuotaPresentation.accountSummary(snapshot: quota, l10n: l10n))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        if let resetsAt = quota.period?.resetsAt {
                            NextResetCountdownLabel(
                                resetsAt: resetsAt,
                                l10n: l10n,
                                font: .caption)
                        }
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    if !isCurrent(account) {
                        Button(l10n.text(.grokAccountsMakeCurrent)) {
                            pendingSwitch = account
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    HStack(spacing: 4) {
                        Button { model.moveGrokAccount(id: account.id, direction: -1) } label: {
                            Image(systemName: "arrow.up")
                        }
                        .help(l10n.text(.accountsMoveUp))
                        Button { model.moveGrokAccount(id: account.id, direction: 1) } label: {
                            Image(systemName: "arrow.down")
                        }
                        .help(l10n.text(.accountsMoveDown))
                        Button {
                            pendingSwitch = account
                        } label: {
                            Image(systemName: "checkmark.circle")
                        }
                        .help(l10n.text(.accountsForceCurrent))
                        .disabled(model.isGrokAccountOperationInProgress)
                        Button {
                            editingAliasID = account.id
                            aliasDraft = account.alias ?? ""
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .help(l10n.text(.alias))
                        Button(role: .destructive) { pendingDelete = account } label: {
                            Image(systemName: "trash")
                        }
                        .help(isCurrent(account)
                            ? l10n.text(.grokCurrentAccountCannotDelete)
                            : l10n.text(.grokAccountsRemove))
                        .disabled(isCurrent(account))
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
            if editingAliasID == account.id {
                HStack {
                    TextField(l10n.text(.alias), text: $aliasDraft)
                        .textFieldStyle(.roundedBorder)
                    Button(l10n.text(.ok)) {
                        model.updateGrokAccountAlias(id: account.id, alias: aliasDraft)
                        editingAliasID = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Button(l10n.text(.cancel)) { editingAliasID = nil }
                        .controlSize(.small)
                }
            }
        }
        .padding(10)
        .background(RunwaySurface.fill, in: RoundedRectangle(cornerRadius: RunwaySurface.cornerRadius))
    }

    private func isCurrent(_ account: GrokManagedAccount) -> Bool {
        account.id == model.grokAccountState.currentAccountID
    }
}
