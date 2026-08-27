/// # CleanConfirmation — Cleanup Confirmation & Report Sheets
///
/// ## CleanConfirmationSheet
///
/// A modal sheet presented before cleanup begins. Shows:
/// - Total size and item count to be cleaned
/// - The D8 overcount caveat (fn-1.4, R8): APFS clones and cross-category
///   hardlinks mean the total is a ceiling, not a promise
/// - ONE unified itemization (fn-2.5): every selected item — category
///   aggregates and per-item scanner rows alike — through a single
///   `ConfirmationRowModel` ForEach, each row rendering its `evidence`
///   string (epic contract: evidence is first-class in this sheet)
/// - Move-to-Trash toggle (recoverable vs. permanent deletion)
/// - Warning banner when "Caution" risk-level items are selected
/// - The `.commands` disclosure (fn-2.5/P2): when command-backed items are
///   selected, `viewModel.commandsTrashDisclosure` names EXACTLY those
///   items — their cleanup commands run regardless of the toggle and place
///   nothing in the Trash
/// - The `git_worktree_reclaim` disclosures (fn-5.6/R11):
///   `viewModel.gitWorktreeTrashDisclosures` names the selected worktree
///   items, stale removals apart from repository prunes. The CHECKOUT
///   honours the toggle since PR #460 codex r5 (Cacheout removes it, not
///   git); the `worktrees/<id>` registry directory that follows it, and every
///   repository prune, are removed PERMANENTLY whatever the toggle says — so
///   without this the generic wording would falsely promise recoverability
///   for the part that has none
/// - Warning banner when a `.partiallyDenied` category is selected (R18):
///   unreadable contents — measured bytes only
/// - Per-row DISCLOSED release artifacts (fn-4.6, R3): each valuable's
///   name + size + modified date, consumed from fn-4.4's structured field
///   in its STORED canonical order (never re-probed, never re-sorted here)
///   with a reveal-in-Finder affordance over the UNRESOLVED display
///   spelling — a vanished valuable no-ops the reveal
/// - A row whose release-artifact inspection did NOT finish stays VISIBLE
///   and SELECTED in a blocked/warning state with rescan guidance (R17):
///   `confirmationRows` derives live from the selection, so deselecting
///   would hide the very warning — the confirm ACTION filters its key out
///   of both the authorization context and the clean set instead
/// - Cancel and Confirm buttons — confirm runs `confirmClean()`, which
///   builds the per-clean `[ItemKey: acknowledgement]` AUTHORIZATION
///   CONTEXT from exactly the displayed sets and passes it down the clean
///   path into the cleaner (R17), then dismisses
///
/// The item list scrolls inside a 200px cap to prevent overflow on machines
/// with many selected items.
///
/// ## CleanupReportSheet
///
/// A modal sheet presented after cleanup completes (fn-1.4, R11/R16).
/// Success is claimed only when something actually succeeded: the icon and
/// heading derive from `report.entries`/`report.errors`, and the amount line
/// is `report.headline` — disposal-aware and component-derived ("Freed X",
/// "+ up to Y more", "up to Z"). Entries render grouped per scanner
/// (fn-2.5): `report.scannerSections` pairs each scanner's rollup header
/// with its entry rows. Rows render `Entry.componentSummary`, never a single
/// laundered total, and carry `report.rowAnnotation(for:)` when a Trash-mode
/// run contains a command-erased entry whose bytes are NOT in the Trash
/// (P2). Failed items render from the SELF-CONTAINED
/// `CleanupReport.ItemError` records alone (`report.errorLines`) — a failed
/// item may no longer exist in any post-clean rescan, so nothing is ever
/// looked up.

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

            // CONFIRMABLE totals, not bare selection totals: the headline
            // must quote exactly what the confirm action will act on —
            // retained selections under a malformed rescan AND blocked
            // (incomplete-probed) rows are excluded from it.
            Text("This will remove \(viewModel.formattedConfirmableSelectedSize) from \(viewModel.confirmableSelectedCount) items.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // D8 disclosure (R8): the total is a ceiling, not a promise.
            Text(viewModel.overcountCaveat)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            // ONE unified itemization (fn-2.5): aggregates and per-item
            // scanner rows through the same ForEach, identity by composite
            // ItemKey, each row carrying its evidence string.
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(viewModel.confirmationRows) { row in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack {
                                Image(systemName: row.icon)
                                    .frame(width: 20)
                                Text(row.label)
                                Spacer()
                                Text(row.formattedSize)
                                    .foregroundStyle(.secondary)
                            }
                            // Evidence is first-class in the sheet (epic
                            // contract) — the "why is this safe to remove"
                            // line the follow-on scanner epics rest on.
                            Text(row.evidence)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 24)

                            // R3: the item's DISCLOSED release artifacts, in
                            // their stored canonical order — name, size,
                            // modified date, warning treatment, and reveal
                            // in Finder (the sheet's only filesystem touch).
                            ForEach(row.valuables) { valuable in
                                ValuableDisclosureRow(valuable: valuable)
                            }

                            // R17: an INCOMPLETE-probed row stays VISIBLE and
                            // SELECTED in a blocked state with rescan
                            // guidance; the confirm action filters its key
                            // from both the authorization context and the
                            // clean set.
                            if let blocked = row.blockedReason {
                                Label(blocked, systemImage: "exclamationmark.octagon.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                    .padding(.leading, 24)
                            }
                        }
                        .font(.caption)
                        .accessibilityElement(children: .combine)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .frame(maxHeight: 200)

            Toggle("Move to Trash (instead of permanent delete)", isOn: $viewModel.moveToTrash)
                .font(.caption)

            if viewModel.hasCautionSelection {
                Label("Caution items selected — these may require manual recovery", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            // P2 + fn-2.5: command-backed items execute their cleanup
            // commands regardless of the Move-to-Trash toggle. The
            // disclosure names EXACTLY those items (never their deletion-
            // cleaned neighbors) and renders whenever any are selected —
            // strictly more disclosure than fn-1.4's Trash-mode-only
            // banner, and it informs the toggle decision either way. The
            // toggle itself stays.
            if let disclosure = viewModel.commandsTrashDisclosure {
                Label(disclosure, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            // fn-5.6 (R11/F7): the SAME honesty for the composite reclaim.
            // Without this branch a selected worktree item would fall to the
            // sheet's generic wording, which covers only the CHECKOUT — and a
            // worktree reclaim also removes a `worktrees/<id>` registry
            // directory, permanently, whatever the toggle says (PR #460 codex
            // r5 corrects the old reason, "git unlinks, it does not trash":
            // no git removal runs here any more). Stale removals and
            // repo-level prunes are disclosed SEPARATELY — they are different
            // promises — so the enumeration is over the derived strings, not
            // one merged sentence.
            ForEach(Array(viewModel.gitWorktreeTrashDisclosures.enumerated()),
                    id: \.offset) { _, disclosure in
                Label(disclosure, systemImage: "exclamationmark.triangle.fill")
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

                // The AUTHORIZED confirm path (fn-4.6, R17): populates the
                // per-clean authorization context from exactly the displayed
                // sets, filters blocked rows out of the clean set, and
                // passes the context down to the cleaner.
                Button("Clean \(viewModel.formattedConfirmableSelectedSize)") {
                    dismiss()
                    Task { await viewModel.confirmClean() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(viewModel.confirmableSelectedCount == 0)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}

// MARK: - Valuables disclosure (fn-4.6, R3)

/// ONE disclosed release artifact under its item's confirmation row: name,
/// size, modified date (all derived from fn-4.4's stored integers — nothing
/// is re-probed at sheet time), warning treatment, and a reveal-in-Finder
/// affordance over the UNRESOLVED display spelling.
struct ValuableDisclosureRow: View {
    let valuable: ConfirmationValuableRowModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(valuable.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(valuable.formattedSize) · \(valuable.formattedModified)")
                .foregroundStyle(.secondary)
            Button("Reveal") { ValuableReveal.reveal(valuable.revealURL) }
                .buttonStyle(.link)
            Spacer(minLength: 0)
        }
        .font(.caption2)
        .padding(.leading, 24)
        .accessibilityElement(children: .combine)
    }
}

/// Reveal-in-Finder for a disclosed valuable — the sheet's ONLY filesystem
/// touch, and the one place the self-contained-row doctrine bends: a
/// valuable that VANISHED between scan and click is a NO-OP, never a Finder
/// error and never a re-resolution of the row.
enum ValuableReveal {
    /// - Returns: whether the reveal was attempted (false = the path is gone
    ///   and nothing happened).
    @discardableResult
    static func reveal(
        _ url: URL,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        revealer: (URL) -> Void = {
            NSWorkspace.shared.selectFile($0.path, inFileViewerRootedAtPath: "")
        }
    ) -> Bool {
        guard exists(url) else { return false }
        revealer(url)
        return true
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
                // Per-scanner rollup rendering (fn-2.5): one section per
                // scanner in first-appearance order — a rollup header (pure
                // sums, same R16 component phrase as the rows) above that
                // scanner's entry rows.
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(report.scannerSections, id: \.scannerID) { section in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(section.scannerID)
                                    .font(.caption.bold())
                                Spacer()
                                Text(section.rollup.componentSummary)
                                    .font(.caption.bold())
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)

                            ForEach(section.entries, id: \.key) { entry in
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack {
                                        Text(entry.displayName)
                                        Spacer()
                                        Text(entry.componentSummary)
                                            .foregroundStyle(.secondary)
                                    }
                                    // Row annotations come from the PURE
                                    // presentation helper (fn-5.4): the P2
                                    // disposal honesty marker (in a Trash
                                    // run, a command-erased entry put
                                    // nothing in the Trash) and the D11
                                    // warning an otherwise-successful entry
                                    // carries. The body renders, it never
                                    // derives — `rowAnnotations(for:)` is
                                    // the tested surface.
                                    ForEach(
                                        report.rowAnnotations(for: entry),
                                        id: \.self
                                    ) { note in
                                        Text(note)
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                    }
                                }
                                .font(.caption)
                                .accessibilityElement(children: .combine)
                            }
                        }
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
                    // Self-contained `ItemError` records (fn-2.3) render
                    // through `errorLines` — NO item lookup, ever: a failed
                    // item may have vanished from any post-clean rescan.
                    // Positional identity because one item may carry
                    // several error lines.
                    ForEach(Array(report.errorLines.enumerated()), id: \.offset) { _, line in
                        // THE MESSAGE IS THE WHOLE POINT, AND IT WAS
                        // UNREADABLE (field report on the 2.2.0 build).
                        //
                        // A bare `Text` inside this sheet's `.frame(width:
                        // 400)` truncates to ONE line with an ellipsis, so a
                        // refusal like "…: the folder that holds this item is
                        // no longer the one the safety check admitted"
                        // rendered as a cache name and three dots. Every
                        // refusal this app writes explains what it refused
                        // and what to do next, and the user could read none
                        // of it — which makes the careful wording upstream
                        // worthless at the one moment it matters.
                        //
                        // THREE MECHANISMS, DELIBERATELY, because the
                        // failing case is an UNBREAKABLE TOKEN. The reported
                        // line was `com.apple.SwiftUI.Drag-D21FA1F0-…` — a
                        // cache name with no spaces, so there is no wrap
                        // opportunity and plain `Text`, which wraps by
                        // default, truncated instead. `fixedSize(vertical:)`
                        // gives it the vertical room to break; `textSelection`
                        // lets it be copied into a bug report even if a
                        // future layout clips it again; `.help` puts the whole
                        // string in a tooltip, which no width can shorten.
                        //
                        // The sheet grows with a long error list. That is the
                        // right trade against hiding the text: this app does
                        // not shorten a refusal it has decided to show.
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .help(line)
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
