/// # CategoryRow & RiskBadge — Cache Category Row Components
///
/// ## CategoryRow
///
/// Displays a single cache category in the results list with:
/// - Selection checkbox (blue circle when selected)
/// - Category icon (color-coded by risk level)
/// - Name and description (or "Not found" for missing categories)
/// - Size in human-readable format (e.g., "2.4 GB")
/// - Risk badge (Safe/Review/Caution capsule)
///
/// Empty categories (not found or zero size) are displayed at 50% opacity
/// with a disabled checkbox.
///
/// ## RiskBadge
///
/// A compact capsule-shaped badge showing the risk level text with
/// color-coded background: green (Safe), orange (Review), red (Caution).

import SwiftUI

struct CategoryRow: View {
    let result: ScanResult
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                // Checkbox
                Image(systemName: result.isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(result.isSelected ? .blue : .secondary)

                // Icon
            Image(systemName: result.category.icon)
                .font(.title3)
                .frame(width: 24)
                .foregroundStyle(iconColor)

            // Name + description
            VStack(alignment: .leading, spacing: 2) {
                Text(result.category.name)
                    .font(.body.weight(.medium))
                if result.isEmpty {
                    Text("Not found")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Text(result.category.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Size
            if !result.isEmpty {
                Text(result.formattedSize)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.primary)
            }

                // Risk badge
                if !result.isEmpty {
                    RiskBadge(level: result.category.riskLevel)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(result.isEmpty)
        .opacity(result.isEmpty ? 0.5 : 1)
        .accessibilityElement(children: .combine)
    }

    private var iconColor: Color {
        switch result.category.riskLevel {
        case .safe: return .green
        case .review: return .orange
        case .caution: return .red
        }
    }
}

struct RiskBadge: View {
    let level: RiskLevel

    var body: some View {
        Text(level.rawValue)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(backgroundColor.opacity(0.15), in: Capsule())
            .foregroundStyle(backgroundColor)
    }

    private var backgroundColor: Color {
        switch level {
        case .safe: return .green
        case .review: return .orange
        case .caution: return .red
        }
    }
}
