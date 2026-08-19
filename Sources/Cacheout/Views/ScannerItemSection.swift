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
/// - **Select Stale**: only where staleness applies to the scanner's
///   items (`isStale == nil` = control hidden/inapplicable). The label makes
///   NO numeric claim on purpose (PR #459 review r4, codex C2): each scanner
///   judges staleness by its OWN configurable threshold (build_artifacts 30
///   days, orphaned_caches 60-day default, ephemeral_tmp 7-day default), and
///   the retired 30-day parenthetical was false in the shipped DEFAULT
///   configuration the moment a sub-30-day scanner registered. The per-item
///   age is stated where it is true: the row's evidence string and the
///   confirmation sheet.
/// - **Select All** / **Deselect All**: section-scoped
///
/// ## Rows
/// Name, display path, stale badge (when `isStale == true`), size — with the
/// item's evidence string as a hover tooltip (the confirmation sheet renders
/// evidence in full, fn-2.5). List identity is the composite `ItemKey`,
/// never a bare item id (unique only within one scanner).
///
/// Non-measured item states render EXPLICITLY (`CategoryRow` parity, D6): a
/// `.denied` item shows a slashed checkbox, "Access denied — not scanned", a
/// lock instead of a misleading zero size, and the Full Disk Access remedy
/// for TCC denials; `.partiallyDenied` shows its warning subtitle over the
/// measured floor. `ScannerItemRowPresentation` is the testable derivation —
/// the view model already refuses selection of `.denied` items everywhere
/// (round 9), so this is purely the honest-rendering half.
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
                        Button("Select Stale") {
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
    /// Injectable for tests only (zero real-`$HOME` reads); production
    /// collapses against the account home exactly as before.
    var home: URL = FileManager.default.homeDirectoryForCurrentUser

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                let row = ScanIssueRowPresentation(issue: issue, home: home)
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text(row.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(issue.detail)
                    if row.showsSettingsLink {
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
}

/// The testable derivation behind ONE issue row (fn-4.6, R12/R16) — SwiftUI
/// bodies are assertion-dead, so the wording, the location, and the
/// remedy-link decision live here (the `ScannerItemRowPresentation`
/// precedent). A denied dev root, a policy-refused configured root, and a
/// whole-value config parse failure all render through this one shape —
/// never as a zero-byte item row, never as an empty section.
struct ScanIssueRowPresentation: Equatable {
    /// The rendered line: location — classified reason.
    let text: String
    /// Where the problem is, home-collapsed. `ScanIssue.url` is nil for the
    /// non-filesystem kinds (`.malformedOutcome`, `.configInvalid`) — no
    /// filesystem location exists, and a fake path is never invented.
    let location: String
    let label: String
    /// TCC denials have a user-side remedy (System Settings deep link);
    /// BSD-permission denials, admission refusals, and config parse
    /// failures do not — no link that cannot help.
    let showsSettingsLink: Bool

    init(
        issue: ScanIssue,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        location = Self.location(of: issue, home: home)
        label = Self.label(for: issue.kind)
        text = "\(location) — \(label)"
        showsSettingsLink = issue.kind == .tccDenied
    }

    private static func location(of issue: ScanIssue, home: URL) -> String {
        guard let url = issue.url else { return "Scanner output" }
        return url.path.replacingOccurrences(of: home.path, with: "~")
    }

    private static func label(for kind: ScanIssue.Kind) -> String {
        switch kind {
        case .containerRefused: return "not a configured search root"
        case .symlinkRoot: return "symlinked — not searched"
        case .tccDenied: return "access denied by macOS privacy settings"
        case .permissionDenied: return "permission denied"
        case .unreadable: return "unreadable"
        case .configInvalid: return "invalid saved configuration — defaults in effect"
        case .malformedOutcome: return "rejected — malformed scanner output; previous results kept"
        }
    }
}

// MARK: - Row presentation (testable)

/// The testable presentation derivation for `ScannerItemRow` — SwiftUI views
/// are not unit-testable, so this struct is the assertion surface (the
/// `ScanResult.statusLabel` precedent). `CategoryRow` parity (fn-1.4
/// R6/R18, D6): a denied item is INFORMATION — slashed checkbox, explicit
/// status, a lock instead of a misleading "Zero KB", and the Full Disk
/// Access remedy for TCC denials — never an ordinary empty-looking row.
struct ScannerItemRowPresentation: Equatable {
    /// State-aware subtitle under the display path; nil for `.measured`
    /// (no status line needed). Wording matches `ScanResult.statusLabel`
    /// case-for-case — the parity test guards drift.
    let statusLabel: String?
    /// `.denied` rows show `circle.slash` — the view model refuses the
    /// toggle (round 9) and the checkbox must not pretend otherwise (R18).
    let checkboxSymbol: String
    /// Denied rows show a lock instead of a misleading zero size;
    /// `.partiallyDenied` keeps its size — the subtitle marks it a floor.
    let showsLockInsteadOfSize: Bool
    /// TCC denials have a user-side remedy (System Settings deep link);
    /// BSD-permission and admission refusals do not — no link that cannot
    /// help. `scanError` is nil for clean states by contract.
    let showsSettingsLink: Bool
    /// `.missing`/`.empty`: nothing to act on — dimmed, disabled. `.denied`
    /// is deliberately NOT inert: the settings link must stay tappable.
    let isInert: Bool

    init(item: ReclaimableItem, isSelected: Bool) {
        switch item.state {
        case .measured:
            statusLabel = nil
        case .missing:
            statusLabel = "Not found"
        case .empty:
            statusLabel = "Nothing to clean"
        case .partiallyDenied:
            statusLabel = "Partially unreadable — measured bytes only"
        case .denied:
            statusLabel = "Access denied — not scanned"
        }
        checkboxSymbol = item.state == .denied
            ? "circle.slash"
            : (isSelected ? "checkmark.circle.fill" : "circle")
        showsLockInsteadOfSize = item.state == .denied
        showsSettingsLink = item.scanError?.kind == .tccDenied
        isInert = item.state == .missing || item.state == .empty
    }
}

// MARK: - Row

struct ScannerItemRow: View {
    let item: ReclaimableItem
    let isSelected: Bool
    let onToggle: () -> Void

    private var presentation: ScannerItemRowPresentation {
        ScannerItemRowPresentation(item: item, isSelected: isSelected)
    }

    var body: some View {
        let presentation = self.presentation
        Button(action: onToggle) {
            HStack(spacing: 10) {
                // Checkbox — slashed for unselectable denied rows (R18);
                // the view model already refuses the toggle (round 9).
                Image(systemName: presentation.checkboxSymbol)
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
                    // State-aware status (CategoryRow parity, D6): a TCC
                    // denial must never read as an ordinary empty item.
                    if let status = presentation.statusLabel {
                        HStack(spacing: 6) {
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(statusColor)
                            if presentation.showsSettingsLink {
                                Link("Grant access…",
                                     destination: ScanError.fullDiskAccessSettingsURL)
                                    .font(.caption)
                            }
                        }
                    }
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

                // Size — denied rows show a lock instead of a misleading
                // "Zero KB" (CategoryRow parity).
                if presentation.showsLockInsteadOfSize {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text(ByteCountFormatter.sharedFile.string(fromByteCount: item.allocatedBytes))
                        .font(.body.monospacedDigit())
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(presentation.isInert)
        .opacity(presentation.isInert ? 0.5 : 1)
        // The evidence string in brief — the confirmation sheet renders it
        // in full (fn-2.5).
        .help(item.evidence)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var statusColor: Color {
        switch item.state {
        case .denied: return .red
        case .partiallyDenied: return .orange
        default: return Color(.tertiaryLabelColor)
        }
    }
}
