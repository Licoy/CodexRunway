import CodexRunwayCore
import SwiftUI

struct AccountTransferExportRow: Identifiable, Equatable {
    var id: String
    var title: String
    var subtitle: String?
}

struct AccountTransferExportSheet: View {
    var l10n: L10n
    var rows: [AccountTransferExportRow]
    @Binding var selectedIDs: Set<String>
    var isWorking: Bool = false
    var onCancel: () -> Void
    var onExport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(l10n.text(.accountsExportTitle))
                .font(.headline)
            Text(l10n.text(.accountsExportHint))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button(l10n.text(.accountsSelectAll)) {
                    selectedIDs = Set(rows.map(\.id))
                }
                .disabled(rows.isEmpty || isWorking)
                Button(l10n.text(.accountsDeselectAll)) {
                    selectedIDs = []
                }
                .disabled(selectedIDs.isEmpty || isWorking)
                Spacer()
            }
            .controlSize(.small)

            if rows.isEmpty {
                Text(l10n.text(.accountsExportEmpty))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(rows) { row in
                            Toggle(isOn: binding(for: row.id)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.title)
                                        .font(.body.weight(.medium))
                                        .lineLimit(1)
                                    if let subtitle = row.subtitle, !subtitle.isEmpty {
                                        Text(subtitle)
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

            Text(l10n.text(.accountsExportWarning))
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(l10n.text(.cancel), action: onCancel)
                    .disabled(isWorking)
                Button(action: onExport) {
                    if isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(l10n.text(.accountsExport))
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
}
