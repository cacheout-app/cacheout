/// # CleanConfirmation — Cleanup Confirmation & Report Sheets
///
/// ## CleanConfirmationSheet
///
/// A modal sheet presented before cleanup begins. Shows:
/// - Total size and item count to be cleaned
/// - Itemized list of selected categories and node_modules with individual sizes
/// - Move-to-Trash toggle (recoverable vs. permanent deletion)
/// - Warning banner when "Caution" risk-level items are selected
/// - Cancel and Confirm buttons (confirm triggers cleanup and dismisses)
///
/// The sheet is limited to 200px height for the item list to prevent overflow
/// on machines with many selected categories.
///
/// ## CleanupReportSheet
///
/// A modal sheet presented after cleanup completes. Shows:
/// - Green checkmark with "Cleanup Complete!" heading
/// - Total freed space
/// - Per-category breakdown of freed bytes
/// - Error section (if any items failed) with red-highlighted messages
/// - Done button to dismiss

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

            Text("This will remove \(viewModel.formattedTotalSelectedSize) from \(viewModel.selectedResults.count + viewModel.nodeModulesItems.filter(\.isSelected).count) items.")
                .font(.body)
                .foregroundStyle(.secondary)
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
    // ⚡ Bolt: Cache Foundation formatters to prevent allocation overhead
    fileprivate static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    let report: CleanupReport
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("Cleanup Complete!")
                .font(.title2.bold())

            Text("Freed \(report.formattedTotal)")
                .font(.title3)
                .foregroundStyle(.secondary)

            if !report.cleaned.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(report.cleaned, id: \.category) { item in
                        HStack {
                            Text(item.category)
                            Spacer()
                            Text(Self.byteFormatter.string(fromByteCount: item.bytesFreed))
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
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
