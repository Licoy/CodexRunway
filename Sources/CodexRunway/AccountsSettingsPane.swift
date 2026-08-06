import AppKit
import CodexRunwayCore
import SwiftUI
import UniformTypeIdentifiers

struct AccountsSettingsPane: View {
    @ObservedObject var model: RunwayModel
    var l10n: L10n

    @State private var showPasteSheet = false
    @State private var showAPIKeySheet = false
    @State private var pasteText = ""
    @State private var apiKeyText = ""
    @State private var pasteSheetError: String?
    @State private var isImportingPaste = false
    @State private var accountPendingDelete: ManagedAccount?
    @State private var accountPendingSwitch: ManagedAccount?
    @State private var restartAfterSwitch = true
    @State private var editingAliasId: String?
    @State private var aliasDraft = ""

    var body: some View {
        PreferencesPane {
            SettingsSection {
                platformToolbar

                if model.selectedProvider == .grok {
                    GrokAccountsSettingsContent(model: model, l10n: l10n)
                } else {
                    Text(l10n.text(.accountsSwitchRealHint))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if model.managedAccounts.isEmpty {
                        Text(l10n.text(.accountsEmpty))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 12)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(orderedAccounts) { account in
                                accountRow(account)
                                    .id("\(account.id)-\(account.resolvedDisplayName)-\(account.requiresReauth)")
                            }
                        }
                    }

                    if let message = model.accountOperationMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = model.lastError {
                        Text(error).font(.caption).foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .sheet(isPresented: $showPasteSheet) {
            importSheet(
                title: model.selectedProvider == .grok
                    ? l10n.text(.grokAccountsAddPaste)
                    : l10n.text(.accountsAddPaste),
                hint: model.selectedProvider == .grok
                    ? l10n.text(.grokAccountsPasteHint)
                    : l10n.text(.accountsPasteHint),
                text: $pasteText,
                sheetError: pasteSheetError,
                isWorking: isImportingPaste)
            {
                isImportingPaste = true
                pasteSheetError = nil
                Task {
                    let ok: Bool
                    if model.selectedProvider == .grok {
                        ok = await model.importPastedGrokCredentials(pasteText)
                    } else {
                        ok = await model.importPastedCredentials(pasteText)
                    }
                    isImportingPaste = false
                    if ok {
                        pasteText = ""
                        pasteSheetError = nil
                        showPasteSheet = false
                    } else if model.selectedProvider == .grok {
                        pasteSheetError = model.grokLastError ?? l10n.text(.grokAccountsImportNoCredentials)
                    } else {
                        pasteSheetError = model.lastError ?? l10n.text(.accountsImportNoCredentials)
                    }
                }
            }
        }
        .sheet(isPresented: $showAPIKeySheet) {
            importSheet(
                title: l10n.text(.accountsAddAPIKey),
                hint: l10n.text(.accountsAPIKeyHint),
                text: $apiKeyText,
                monospaced: true)
            {
                model.importAPIKey(apiKeyText)
                apiKeyText = ""
                showAPIKeySheet = false
            }
        }
        .alert(
            l10n.text(.accountsDeleteConfirmTitle),
            isPresented: Binding(
                get: { accountPendingDelete != nil },
                set: { if !$0 { accountPendingDelete = nil } }))
        {
            Button(l10n.text(.accountsDelete), role: .destructive) {
                if let id = accountPendingDelete?.id {
                    model.deleteAccount(id: id)
                }
                accountPendingDelete = nil
            }
            Button(l10n.text(.cancel), role: .cancel) {
                accountPendingDelete = nil
            }
        } message: {
            Text(l10n.text(.accountsDeleteConfirmMessage))
        }
        .sheet(isPresented: Binding(
            get: { accountPendingSwitch != nil },
            set: { if !$0 { accountPendingSwitch = nil } }))
        {
            AccountSwitchConfirmSheet(
                accountName: accountPendingSwitch?.resolvedDisplayName ?? "",
                l10n: l10n,
                restartAfterSwitch: $restartAfterSwitch,
                onConfirm: {
                    if let id = accountPendingSwitch?.id {
                        model.switchAccount(id: id, restartCodex: restartAfterSwitch)
                    }
                    accountPendingSwitch = nil
                },
                onCancel: {
                    accountPendingSwitch = nil
                })
        }
    }

    private var platformToolbar: some View {
        HStack(spacing: 8) {
            Picker("", selection: Binding(
                get: { model.selectedProvider },
                set: { model.selectProvider($0) }))
            {
                Text(l10n.text(.providerCodex)).tag(RunwayProvider.codex)
                Text(l10n.text(.providerGrok)).tag(RunwayProvider.grok)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()

            Spacer(minLength: 8)

            if model.selectedProvider == .grok {
                Menu {
                    Button(l10n.text(.grokAccountsAddOAuth)) { model.startGrokOAuthLogin() }
                    Button(l10n.text(.grokAccountsAddPaste)) {
                        pasteText = ""
                        pasteSheetError = nil
                        showPasteSheet = true
                    }
                    Button(l10n.text(.grokAccountsImportOfficial)) { model.importOfficialGrokAccount() }
                } label: {
                    Label(l10n.text(.accountsAdd), systemImage: "plus")
                }
                .disabled(model.isGrokAccountOperationInProgress)

                Button {
                    model.refreshAllGrokAccountQuotas()
                } label: {
                    Label(l10n.text(.grokAccountsRefreshAll), systemImage: "arrow.clockwise")
                }
                .disabled(model.isRefreshingGrok)

                if model.isGrokOAuthLoginInProgress {
                    Button(l10n.text(.cancel)) { model.cancelGrokOAuthLogin() }
                }
            } else {
                Menu {
                    Button(l10n.text(.accountsAddLocal)) { model.importOfficialAccount() }
                    Button(l10n.text(.accountsAddPaste)) { showPasteSheet = true }
                    Button(l10n.text(.accountsAddFile)) { pickFiles() }
                    Button(l10n.text(.accountsAddOAuth)) { model.startOAuthLogin() }
                    Button(l10n.text(.accountsAddAPIKey)) { showAPIKeySheet = true }
                } label: {
                    Label(l10n.text(.accountsAdd), systemImage: "plus")
                }

                Button {
                    model.refreshAllAccountQuotas()
                } label: {
                    Label(l10n.text(.accountsRefreshAll), systemImage: "arrow.clockwise")
                }
                .disabled(model.isRefreshingAccountQuotas)
            }
        }
    }

    private var orderedAccounts: [ManagedAccount] {
        model.sidebarAccounts
    }

    private func accountRow(_ account: ManagedAccount) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(account.resolvedDisplayName)
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                        if account.id == model.activeAccountId {
                            CurrentAccountTag(l10n: l10n)
                        }
                        SubscriptionTierTag(tier: account.subscriptionTier, l10n: l10n)
                    }
                    if let email = account.email, email != account.resolvedDisplayName {
                        Text(email).font(.caption).foregroundStyle(.secondary)
                    }
                    if account.requiresReauth {
                        Text(l10n.text(.accountsNeedsReauth))
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else if let error = account.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                    } else if let quota = account.cachedQuota {
                        Text("\(quota.primaryRemainingPercent)% · \(l10n.text(.lastUpdated)) \(quota.updatedAt.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let resetsAt = quota.primaryResetsAt {
                            NextResetCountdownLabel(
                                resetsAt: resetsAt,
                                l10n: l10n,
                                font: .caption)
                        }
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    if account.id != model.activeAccountId {
                        Button(l10n.text(.accountsMakeCurrent)) {
                            restartAfterSwitch = true
                            accountPendingSwitch = account
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    HStack(spacing: 4) {
                        Button {
                            model.moveAccount(id: account.id, direction: -1)
                        } label: {
                            Image(systemName: "arrow.up")
                        }
                        .help(l10n.text(.accountsMoveUp))
                        Button {
                            model.moveAccount(id: account.id, direction: 1)
                        } label: {
                            Image(systemName: "arrow.down")
                        }
                        .help(l10n.text(.accountsMoveDown))
                        Button {
                            editingAliasId = account.id
                            aliasDraft = account.alias ?? ""
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .help(l10n.text(.alias))
                        Button(role: .destructive) {
                            accountPendingDelete = account
                        } label: {
                            Image(systemName: "trash")
                        }
                        .help(l10n.text(.accountsDelete))
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
            if editingAliasId == account.id {
                HStack {
                    TextField(l10n.text(.alias), text: $aliasDraft)
                        .textFieldStyle(.roundedBorder)
                    Button(l10n.text(.ok)) {
                        model.updateAccountAlias(id: account.id, alias: aliasDraft)
                        editingAliasId = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Button(l10n.text(.cancel)) {
                        editingAliasId = nil
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(10)
        .background(RunwaySurface.fill, in: RoundedRectangle(cornerRadius: RunwaySurface.cornerRadius))
    }

    private func importSheet(
        title: String,
        hint: String,
        text: Binding<String>,
        monospaced: Bool = false,
        sheetError: String? = nil,
        isWorking: Bool = false,
        onSubmit: @escaping () -> Void) -> some View
    {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // PasteableTextView supports ⌘V in LSUIElement apps (SwiftUI TextEditor often does not).
            PasteableTextEditor(text: text, monospaced: monospaced)
                .frame(minHeight: monospaced ? 120 : 160)
                .disabled(isWorking)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1))
            HStack {
                Button(l10n.text(.accountsPasteFromClipboard)) {
                    if let clip = NSPasteboard.general.string(forType: .string) {
                        text.wrappedValue = clip
                    }
                }
                .disabled(isWorking)
                Spacer()
            }
            if let sheetError {
                Text(sheetError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(l10n.text(.cancel)) {
                    showPasteSheet = false
                    showAPIKeySheet = false
                    pasteSheetError = nil
                    isImportingPaste = false
                }
                .disabled(isWorking)
                Button(action: onSubmit) {
                    if isWorking {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(l10n.text(.accountsAdd))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking || text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 22)
        .frame(width: 480)
        .frame(minHeight: sheetError == nil ? 360 : 400)
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.json, .text, .plainText]
        panel.begin { response in
            guard response == .OK else { return }
            model.importCredentialFiles(panel.urls)
        }
    }
}
