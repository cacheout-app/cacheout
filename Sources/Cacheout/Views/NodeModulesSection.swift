/// # ScannerItemSection — Generic Per-Item Scanner Section (fn-2.4)
///
/// The node_modules section, generalized: ONE collapsible section per
/// registered non-category scanner, rendered from `ScannerSectionModel`.
/// Adding a per-item scanner (fn-3..fn-6) mounts a section here with ZERO
/// view edits — header, quick actions, rows, and issue surfacing all derive
/// from the scanner's registered identity and its `ReclaimableItem`s.
///
/// ## Header
/// Scanner `displayName` + item count + section total.
///
/// ## Quick Actions
/// - **Select Stale (30d+)**: only where staleness applies to the scanner's
///   items (`isStale == nil` = control hidden/inapplicable)
/// - **Select All** / **Deselect All**: section-scoped
///
/// ## Rows
/// Name, display path, stale badge (when `isStale == true`), size — with the
/// item's evidence string as a hover tooltip (the confirmation sheet renders
/// evidence in full, fn-2.5). List identity is the composite `ItemKey`,
/// never a bare item id (unique only within one scanner).
///
/// ## Issues (fn-1.4 R14/D6, generalized)
/// Classified scan problems render as a warning block — a TCC-denied
/// `~/Documents` search root is VISIBLE information ("access denied", with a
/// System Settings link), never an empty section. A synthesized
/// `malformedOutcome` issue (fail-closed validation, fn-2.4) renders
/// path-less — no fake location is ever invented.

import SwiftUI

struct ScannerItemSection: View {
    @EnvironmentObject var viewModel: CacheoutViewModel
    let section: ScannerSectionModel
    @State private var isExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            // Section header
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .frame(width: 16)
                    Image(systemName: "folder.fill.badge.gearshape")
                        .foregroundStyle(.purple)
                    Text(section.displayName)
                        .font(.headline)
                    Text("(\(section.items.count) found)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(viewModel.formattedTotalSize(forScanner: section.scannerID))
                        .font(.body.monospacedDigit().bold())
                        .foregroundStyle(.purple)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded && section.isScanning {
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Scanning \(section.displayName)...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }

            // Classified scan problems (R14/D6): a denied search root is
            // information, never a silent skip — and a malformed outcome is
            // a visible failure, never a silent retention.
            if isExpanded && !section.isScanning && !section.issues.isEmpty {
                ScanIssuesBlock(issues: section.issues)
            }

            if isExpanded && !section.items.isEmpty {
                // Quick actions (section-scoped)
                HStack(spacing: 12) {
                    if section.supportsStaleness {
                        Button("Select Stale (30d+)") {
                            viewModel.selectStale(inScanner: section.scannerID)
                        }
                        .font(.caption)
                    }
                    Button("Select All") {
                        viewModel.selectAll(inScanner: section.scannerID)
                    }
                    .font(.caption)
                    Button("Deselect All") {
                        viewModel.deselectAll(inScanner: section.scannerID)
                    }
                    .font(.caption)
                    Spacer()
                    if viewModel.selectedSize(forScanner: section.scannerID) > 0 {
                        Text("Selected: \(viewModel.formattedSelectedSize(forScanner: section.scannerID))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.purple)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 4)

                // Individual items — identity by composite ItemKey.
                LazyVStack(spacing: 2) {
                    ForEach(section.items, id: \.key) { item in
                        ScannerItemRow(
                            item: item,
                            isSelected: viewModel.selectedItemKeys.contains(item.key)
                        ) {
                            viewModel.toggleSelection(for: item.key)
                        }
                    }
                }
            }

            // "Found none" is claimed only when the scan had no classified
            // problems — a denied root is NOT "nothing there" (R14/D6).
            if isExpanded && !section.isScanning
                && section.items.isEmpty
                && section.issues.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "shippingbox")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text("Nothing found")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 24)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

// MARK: - Scan issues (shared by per-item sections and the category list)

struct ScanIssuesBlock: View {
    let issues: [ScanIssue]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text("\(Self.location(of: issue)) — \(Self.label(for: issue.kind))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(issue.detail)
                    if issue.kind == .tccDenied {
                        Link("Grant access…",
                             destination: ScanError.fullDiskAccessSettingsURL)
                            .font(.caption)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
    }

    /// `ScanIssue.url` is nil for `.malformedOutcome` — no filesystem
    /// location exists, and a fake path must never be invented.
    private static func location(of issue: ScanIssue) -> String {
        guard let url = issue.url else { return "Scanner output" }
        return url.path.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"
        )
    }

    private static func label(for kind: ScanIssue.Kind) -> String {
        switch kind {
        case .containerRefused: return "not a configured search root"
        case .symlinkRoot: return "symlinked — not searched"
        case .tccDenied: return "access denied by macOS privacy settings"
        case .permissionDenied: return "permission denied"
        case .unreadable: return "unreadable"
        case .malformedOutcome: return "rejected — malformed scanner output; previous results kept"
        }
    }
}

// MARK: - Row

struct ScannerItemRow: View {
    let item: ReclaimableItem
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? .purple : .secondary)

                Image(systemName: "shippingbox.fill")
                    .foregroundStyle(.purple.opacity(0.7))
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.displayName)
                        .font(.body.weight(.medium))
                    Text(item.declaredDisplayPath)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                // Stale badge — only where staleness applies AND holds.
                if item.isStale == true {
                    Text("Stale")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15), in: Capsule())
                        .foregroundStyle(.orange)
                }

                Text(ByteCountFormatter.sharedFile.string(fromByteCount: item.allocatedBytes))
                    .font(.body.monospacedDigit())
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The evidence string in brief — the confirmation sheet renders it
        // in full (fn-2.5).
        .help(item.evidence)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
