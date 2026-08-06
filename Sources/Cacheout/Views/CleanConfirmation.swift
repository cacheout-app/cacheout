/// # CleanConfirmation — Cleanup Confirmation & Report Sheets
///
/// ## CleanConfirmationSheet
///
/// A modal sheet presented before cleanup begins. Shows:
/// - Total size and item count to be cleaned
/// - The D8 overcount caveat (fn-1.4, R8): APFS clones and cross-category
///   hardlinks mean the total is a ceiling, not a promise
/// - Itemized list of selected categories and node_modules with individual sizes
/// - Move-to-Trash toggle (recoverable vs. permanent deletion)
/// - Warning banner when "Caution" risk-level items are selected
/// - Warning banner when a `.partiallyDenied` category is selected (R18):
///   unreadable contents — measured bytes only
/// - Cancel and Confirm buttons (confirm triggers cleanup and dismisses)
///
/// The sheet is limited to 200px height for the item list to prevent overflow
/// on machines with many selected categories.
///
/// ## CleanupReportSheet
///
/// A modal sheet presented after cleanup completes (fn-1.4, R11/R16).
/// Success is claimed only when something actually succeeded: the icon and
/// heading derive from `report.entries`/`report.errors`, and the amount line
/// is `report.headline` — disposal-aware and component-derived ("Freed X",
/// "+ up to Y more", "up to Z"). Per-entry rows render
/// `Entry.componentSummary`, never a single laundered total.

import SwiftUI

struct CleanConfirmationSheet: View {
    @EnvironmentObject var viewModel: CacheoutViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "trash.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.red)

            Text("Clean Selected Caches?")
                .font(.title2.bold())

            // ⚡ Bolt: Use .lazy.filter for .count to avoid allocating an intermediate array
            Text("This will remove \(viewModel.formattedTotalSelectedSize) from \(viewModel.selectedResults.count + viewModel.nodeModulesItems.lazy.filter(\.isSelected).count) items.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // D8 disclosure (R8): the total is a ceiling, not a promise.
            Text(viewModel.overcountCaveat)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(viewModel.selectedResults) { result in
                    HStack {
                        Image(systemName: result.category.icon)
                            .frame(width: 20)
                        Text(result.category.name)
                        Spacer()
                        Text(result.formattedSize)
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .accessibilityElement(children: .combine)
                }

                // Node modules
                ForEach(viewModel.nodeModulesItems.filter(\.isSelected)) { item in
                    HStack {
                        Image(systemName: "shippingbox.fill")
                            .frame(width: 20)
                        Text("node_modules: \(item.projectName)")
                        Spacer()
                        Text(item.formattedSize)
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .frame(maxHeight: 200)

            Toggle("Move to Trash (instead of permanent delete)", isOn: $viewModel.moveToTrash)
                .font(.caption)

            let hasCaution = viewModel.selectedResults.contains { $0.category.riskLevel == .caution }
            if hasCaution {
                Label("Caution items selected — these may require manual recovery", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            // R18: explicit selection of a partially denied category is
            // allowed, but the sheet must say what the number means.
            if viewModel.hasPartiallyDeniedSelection {
                Label("Some selected items have unreadable contents — measured bytes only", systemImage: "lock.trianglebadge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 12) {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button("Clean \(viewModel.formattedTotalSelectedSize)") {
                    dismiss()
                    Task { await viewModel.clean() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}

struct CleanupReportSheet: View {
    let report: CleanupReport
    @Environment(\.dismiss) private var dismiss

    /// Something was actually cleaned — the only condition under which the
    /// sheet may claim success (R11).
    private var succeeded: Bool { !report.entries.isEmpty }
    private var allFailed: Bool { report.entries.isEmpty && !report.errors.isEmpty }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: allFailed ? "xmark.circle.fill" : (succeeded ? "checkmark.circle.fill" : "circle.dashed"))
                .font(.system(size: 48))
                .foregroundStyle(allFailed ? .red : (succeeded ? .green : .secondary))

            Text(allFailed ? "Cleanup Failed" : (succeeded ? "Cleanup Complete!" : "Nothing to Clean"))
                .font(.title2.bold())

            // Disposal-aware, component-derived amount line (R11/R16):
            // "Freed X [+ up to Y more]" or "Moved … to Trash — empty
            // Trash to reclaim"; never a success claim when nothing
            // succeeded.
            Text(report.headline)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if !report.entries.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(report.entries, id: \.category) { entry in
                        HStack {
                            Text(entry.category)
                            Spacer()
                            Text(entry.componentSummary)
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }

            if !report.errors.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Errors:")
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                    ForEach(report.errors, id: \.category) { item in
                        Text("\(item.category): \(item.error)")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding()
                .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }

            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(width: 400)
    }
}
