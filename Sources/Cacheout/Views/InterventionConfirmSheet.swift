// InterventionConfirmSheet.swift
// SwiftUI confirmation sheet presented before Tier 2+ interventions execute.
//
// Shows intervention name, tier badge, estimated reclamation, risk description,
// and Cancel/Proceed buttons.

import SwiftUI

/// Data model describing an intervention pending user confirmation.
struct InterventionConfirmation: Identifiable {
    let id = UUID()

    /// Human-readable intervention name (e.g., "Jetsam High-Water Mark").
    let displayName: String

    /// Machine name for the intervention (e.g., "jetsam_hwm").
    let name: String

    /// The intervention tier.
    let tier: InterventionTier

    /// Estimated reclamation range (e.g., "500 MB - 2 GB").
    let estimate: String

    /// Human-readable risk description.
    let risk: String

    /// Target process PID for the intervention.
    let targetPID: Int32?

    /// Target process name for logging/display.
    let targetName: String?

    init(displayName: String, name: String, tier: InterventionTier,
         estimate: String, risk: String,
         targetPID: Int32? = nil, targetName: String? = nil) {
        self.displayName = displayName
        self.name = name
        self.tier = tier
        self.estimate = estimate
        self.risk = risk
        self.targetPID = targetPID
        self.targetName = targetName
    }
}

/// A modal sheet that asks the user to confirm a Tier 2+ intervention.
struct InterventionConfirmSheet: View {
    let confirmation: InterventionConfirmation

    /// Called with `true` if the user proceeds, `false` if cancelled.
    let onDecision: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            // Icon
            Image(systemName: iconName)
                .font(.system(size: 48))
                .foregroundStyle(iconColor)

            // Title
            Text(confirmation.displayName)
                .font(.title2.bold())

            // Tier badge
            tierBadge

            // Estimate
            HStack {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(.green)
                Text("Estimated reclamation: \(confirmation.estimate)")
                    .font(.body)
            }

            // Risk
            HStack(alignment: .top) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(confirmation.risk)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))

            // Buttons
            HStack(spacing: 12) {
                Button("Cancel") {
                    onDecision(false)
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Proceed") {
                    onDecision(true)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(buttonTint)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    // MARK: - Tier-specific styling

    private var iconName: String {
        switch confirmation.tier {
        case .safe:
            return "checkmark.shield.fill"
        case .confirm:
            return "exclamationmark.shield.fill"
        case .destructive:
            return "xmark.shield.fill"
        }
    }

    private var iconColor: Color {
        switch confirmation.tier {
        case .safe:
            return .green
        case .confirm:
            return .orange
        case .destructive:
            return .red
        }
    }

    private var buttonTint: Color {
        switch confirmation.tier {
        case .safe:
            return .accentColor
        case .confirm:
            return .orange
        case .destructive:
            return .red
        }
    }

    private var tierBadge: some View {
        let (label, color): (String, Color) = {
            switch confirmation.tier {
            case .safe:
                return ("Tier 1 — Safe", .green)
            case .confirm:
                return ("Tier 2 — Requires Confirmation", .orange)
            case .destructive:
                return ("Tier 3 — Destructive", .red)
            }
        }()

        return Text(label)
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
