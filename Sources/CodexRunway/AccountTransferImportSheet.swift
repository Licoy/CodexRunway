import CodexRunwayCore
import SwiftUI

struct AccountTransferImportSheet: View {
    var l10n: L10n
    var items: [AccountTransferPreviewItem]
    var failures: [String]
    @Binding var selectedIDs: Set<String>
    var isWorking: Bool = false
    var onCancel: () -> Void
    var onImport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(l10n.text(.accountsImportPreviewTitle))
                .font(.headline)
            Text(l10n.text(.accountsImportPreviewHint))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button(l10n.text(.accountsSelectAll)) {
                    selectedIDs = Set(items.map(\.id))
                }
                .disabled(items.isEmpty || isWorking)
                Button(l10n.text(.accountsDeselectAll)) {
                    selectedIDs = []
                }
                .disabled(selectedIDs.isEmpty || isWorking)
                Spacer()
            }
            .controlSize(.small)

            if items.isEmpty {
                Text(l10n.text(.accountsImportNoCredentials))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(items) { item in
                            Toggle(isOn: binding(for: item.id)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(item.displayName)
                                            .font(.body.weight(.medium))
                                            .lineLimit(1)
                                        Text(conflictLabel(item.conflict))
                                            .font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(
                                                conflictColor(item.conflict).opacity(0.15),
                                                in: Capsule())
                                            .foregroundStyle(conflictColor(item.conflict))
                                    }
                                    if let detail = item.detail, !detail.isEmpty {
                                        Text(detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            .toggleStyle(.checkbox)
                            .disabled(isWorking)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 160, maxHeight: 280)
            }

            if !failures.isEmpty {
                Text(failures.prefix(4).joined(separator: "\n"))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(l10n.text(.cancel), action: onCancel)
                    .disabled(isWorking)
                Button(action: onImport) {
                    if isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(l10n.text(.accountsImportSelected))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking || selectedIDs.isEmpty)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 22)
        .frame(width: 480)
        .frame(minHeight: 360)
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { selectedIDs.contains(id) },
            set: { isOn in
                if isOn {
                    selectedIDs.insert(id)
                } else {
                    selectedIDs.remove(id)
                }
            })
    }

    private func conflictLabel(_ conflict: AccountImportConflict) -> String {
        switch conflict {
        case .willAdd:
            return l10n.text(.accountsImportWillAdd)
        case .willUpdate:
            return l10n.text(.accountsImportWillUpdate)
        }
    }

    private func conflictColor(_ conflict: AccountImportConflict) -> Color {
        switch conflict {
        case .willAdd:
            return Color(nsColor: .systemGreen)
        case .willUpdate:
            return Color(nsColor: .systemOrange)
        }
    }
}
