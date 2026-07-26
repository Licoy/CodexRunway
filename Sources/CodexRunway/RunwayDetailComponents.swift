import AppKit
import SwiftUI

/// Stat tile shared by the reset-credits and api-cost detail pages:
/// dot + caption title on one line, mono-digit value below.
struct RunwayStatCard: View {
    var title: String
    var value: String
    var color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(value)
                .font(.body.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .runwayCard(.raised)
    }
}

/// Table chassis shared by every detail-page table: sunken container, hairline
/// stroke, contrast band behind the header row, inset row separators.
struct RunwayTableContainer<Header: View, Rows: View>: View {
    @ViewBuilder var header: () -> Header
    @ViewBuilder var rows: () -> Rows

    var body: some View {
        VStack(spacing: 0) {
            header()
                .frame(maxWidth: .infinity)
                .background(RunwaySurface.tableHead)
            rows()
        }
        .clipShape(RoundedRectangle(cornerRadius: RunwaySurface.radiusCard, style: .continuous))
        .runwayCard(.sunken)
    }
}

/// Inset separator drawn above a table row (skip on the first row).
struct RunwayTableRowRule: ViewModifier {
    var isFirst: Bool

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if !isFirst {
                Rectangle()
                    .fill(RunwaySurface.hairlineFaint)
                    .frame(height: 1)
                    .padding(.horizontal, 10)
            }
        }
    }
}

extension View {
    func tableRowRule(isFirst: Bool) -> some View {
        modifier(RunwayTableRowRule(isFirst: isFirst))
    }
}

/// Detail-page summary row: section label + meta caption leading, key figure trailing.
struct RunwayPageSummaryRow: View {
    var title: String
    var meta: String?
    var figure: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                if let meta, !meta.isEmpty {
                    Text(meta)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Text(figure)
                .font(.title3.weight(.semibold).monospacedDigit())
        }
    }
}
