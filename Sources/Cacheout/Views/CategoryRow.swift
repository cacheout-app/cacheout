/// # CategoryRow & RiskBadge — Cache Category Row Components
///
/// ## CategoryRow
///
/// Displays a single cache category in the results list with:
/// - Selection checkbox (blue circle when selected)
/// - Category icon (color-coded by risk level)
/// - Name and a state-aware subtitle (`ScanResult.statusLabel` for the
///   non-measured states, category description otherwise)
/// - Size in human-readable format (e.g., "2.4 GB")
/// - Risk badge (Safe/Review/Caution capsule)
///
/// ## Scan-state presentation (fn-1.4, R6/R18)
///
/// The four non-measured states render DISTINCTLY — a TCC denial must never
/// read as "Not found" (D6):
/// - `.missing` / `.empty`: dimmed, disabled row (nothing to act on).
/// - `.denied`: full-opacity row with a lock, "Access denied — not
///   scanned", and (for TCC denials) a System Settings deep link. The row
///   stays interactive so the link works, but the view model refuses to
///   select a denied category — the checkbox shows a slashed circle.
/// - `.partiallyDenied`: normal row with an orange warning subtitle — the
///   size covers measured bytes only. Never auto-selected; manual toggle
///   allowed.
///
/// ## RiskBadge
///
/// A compact capsule-shaped badge showing the risk level text with
/// color-coded background: green (Safe), orange (Review), red (Caution).

import SwiftUI

struct CategoryRow: View {
    let result: ScanResult
    let onToggle: () -> Void

    /// Rows with nothing to act on — dimmed and disabled. `.denied` is
    /// deliberately NOT here: denial is information (D6), and the settings
    /// link must stay tappable.
    private var isInert: Bool {
        result.state == .missing || result.state == .empty
    }

    private var isDenied: Bool { result.state == .denied }

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                // Checkbox — slashed for unselectable denied rows (R18)
                Image(systemName: checkboxSymbol)
                    .font(.title3)
                    .foregroundStyle(result.isSelected ? .blue : .secondary)

                // Icon
                Image(systemName: result.category.icon)
                    .font(.title3)
                    .frame(width: 24)
                    .foregroundStyle(iconColor)

                // Name + state-aware subtitle
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.category.name)
                        .font(.body.weight(.medium))
                    if let status = result.statusLabel {
                        HStack(spacing: 6) {
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(statusColor)
                            if showsSettingsLink {
                                Link("Grant access…",
                                     destination: ScanError.fullDiskAccessSettingsURL)
                                    .font(.caption)
                            }
                        }
                    } else {
                        Text(result.category.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                // Size — denied rows show a lock instead of a misleading "Zero KB"
                if isDenied {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if !result.isEmpty {
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
        .disabled(isInert)
        .opacity(isInert ? 0.5 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(result.isSelected ? .isSelected : [])
    }

    private var checkboxSymbol: String {
        if isDenied { return "circle.slash" }
        return result.isSelected ? "checkmark.circle.fill" : "circle"
    }

    /// TCC denials have a user-side remedy; BSD-permission and admission
    /// refusals do not — no link that cannot help.
    private var showsSettingsLink: Bool {
        result.scanError?.kind == .tccDenied
    }

    private var statusColor: Color {
        switch result.state {
        case .denied: return .red
        case .partiallyDenied: return .orange
        default: return Color(.tertiaryLabelColor)
        }
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
