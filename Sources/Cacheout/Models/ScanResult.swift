/// # ScanResult & CleanupReport — Scan and Cleanup Data Models
///
/// ## ScanResult
///
/// The result of scanning a single cache category. Carries the full scan-state
/// model (fn-1.2, R6/R16):
///
/// - `state`: what the scan actually established — `missing` (no resolved
///   path), `empty` (resolved, walked clean, nothing there), `measured`,
///   `partiallyDenied` (measured bytes exist but parts of the tree were
///   refused/denied), `denied` (nothing measurable: admission refusal or a
///   root-level access denial). "Denied" is deliberately distinct from
///   "empty" — a TCC denial otherwise reads as "0 bytes found" (D6).
/// - `scanError`: the classified reason for `denied`/`partiallyDenied`
///   (admission refusal, TCC, BSD permissions, other). Always nil for the
///   clean states.
/// - Split byte components (R16): `exactBytes` (unique-inode bytes whose
///   deletion verifiably frees them) and `estimatedUpToBytes` (hardlinked
///   bytes that MAY be freed). `sizeBytes` is retained as their compatibility
///   sum — existing UI/CLI callers keep working unchanged.
///
/// fn-1.3 consumes `state` for deletion refusal; fn-1.4 owns what sits on
/// top: selection defaults (`.denied` unselectable, `.partiallyDenied` never
/// auto-selected — R18), the presentation `statusLabel` (R6), the D8
/// disclosure (`DiskSpaceCaveat`), and the scan-JSON wire mapping
/// (`ScanError.Kind.wireString`, reused by fn-1.5).
///
/// ## CleanupReport
///
/// Returned by `CacheCleaner.clean()` after a cleanup operation (fn-1.3,
/// R11/R16). Entries carry SPLIT byte components: `exactBytes` (measured
/// unique-inode bytes whose deletion verifiably freed them) and
/// `estimatedUpToBytes` (hardlinked or command-freed bytes that MAY be
/// freed). Aggregates are pure sums of the entry components. The report also
/// carries its REQUESTED `disposal` mode, and each entry carries what
/// ACTUALLY happened to its bytes — command-backed categories erase
/// permanently regardless of the Move-to-Trash toggle. `headline` derives
/// from the entry disposals: a Trash run never claims "Freed" for trashed
/// bytes (they return only when the Trash is emptied), command-erased bytes
/// are never claimed recoverable from the Trash, and a run where nothing
/// succeeded never claims success.
///
/// The pre-split compatibility surface (`cleaned`/`totalFreed`/
/// `formattedTotal`) was retired in fn-1.5 once the CLI JSON moved onto the
/// split entries — every consumer now derives from the components.

import Foundation

/// What a category scan established about its tree (fn-1.2, R6).
enum ScanState: String, Equatable {
    /// No resolved path exists for this category on this machine.
    case missing
    /// The tree resolved and walked cleanly and contains nothing.
    case empty
    /// The tree was fully walked and measured.
    case measured
    /// Some bytes were measured, but parts of the tree were denied or an
    /// admission refusal blocked one of several roots.
    case partiallyDenied
    /// Nothing was measurable: every root was refused at admission or denied
    /// at its own top level.
    case denied
}

/// The classified reason a scan is `denied`/`partiallyDenied`.
struct ScanError: Equatable {
    enum Kind: Equatable {
        /// PathGuard refused the root at scan-time admission (R19) — the tree
        /// was NEVER walked.
        case admissionRefused
        /// macOS TCC (privacy) denial — EPERM under the Cocoa error.
        case tccDenied
        /// BSD permission denial — EACCES.
        case permissionDenied
        case other
    }

    let kind: Kind
    let message: String

    /// Deep link to System Settings → Privacy & Security → Full Disk Access —
    /// the user-side remedy for TCC denials (R9). Anchor verified on macOS
    /// 15.x: the `com.apple.preference.security` pane still routes
    /// `Privacy_AllFiles` to the Full Disk Access list.
    static let fullDiskAccessSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}

extension ScanError.Kind {
    /// Stable wire string for CLI JSON (`scan_error.kind`). Hand-written
    /// mapping because the enum deliberately carries no raw value (fn-1.4);
    /// fn-1.5's clean JSON reuses it. Renaming a case must not silently
    /// change the wire format.
    var wireString: String {
        switch self {
        case .admissionRefused: return "admission_refused"
        case .tccDenied: return "tcc_denied"
        case .permissionDenied: return "permission_denied"
        case .other: return "other"
        }
    }
}

/// D8 honesty disclosure (fn-1.4, R8): scan totals can overcount what
/// deletion actually returns. Shown beside every recoverable-bytes total
/// (`CacheoutViewModel.totalRecoverable`) and in the clean-confirmation
/// sheet.
enum DiskSpaceCaveat {
    /// Discloses BOTH mechanisms: APFS clones (invisible to any public API)
    /// and files hardlinked across categories (each walk counts its own
    /// link; within-walk dedupe cannot see the other category's copy).
    static let overcount = """
        Sizes can overcount: APFS clones share storage invisibly, and files \
        hardlinked across categories are counted in each — actual space \
        freed may be less.
        """
}

struct ScanResult: Identifiable {
    let id: UUID
    let category: CacheCategory
    let state: ScanState
    /// Bytes on unique inodes (`st_nlink == 1`) — deletion verifiably frees
    /// these.
    let exactBytes: Int64
    /// Bytes on hardlinked inodes — freed only if every other link goes too.
    let estimatedUpToBytes: Int64
    let itemCount: Int
    /// Why the scan is `denied`/`partiallyDenied`; nil for clean states.
    let scanError: ScanError?
    var isSelected: Bool

    /// Compatibility sum of the split components — what pre-split callers
    /// (UI rows, CLI JSON until fn-1.4/1.5) continue to display.
    var sizeBytes: Int64 { exactBytes + estimatedUpToBytes }

    /// Compatibility: "a resolved path existed" in the pre-state model.
    var exists: Bool { state != .missing }

    init(
        category: CacheCategory,
        state: ScanState,
        exactBytes: Int64,
        estimatedUpToBytes: Int64,
        itemCount: Int,
        scanError: ScanError?
    ) {
        self.id = category.id
        self.category = category
        self.state = state
        self.exactBytes = exactBytes
        self.estimatedUpToBytes = estimatedUpToBytes
        self.itemCount = itemCount
        self.scanError = scanError
        // Selection defaults (fn-1.4, R18): `.denied` is unselectable —
        // nothing was measurable and the cleaner refuses it regardless.
        // `.partiallyDenied` is NEVER auto-selected (its size is a floor,
        // not a promise) but stays manually toggleable in the UI. The sum
        // is inlined because `sizeBytes` is computed and unusable before
        // initialization completes.
        switch state {
        case .denied, .partiallyDenied:
            self.isSelected = false
        case .missing, .empty, .measured:
            self.isSelected = category.defaultSelected
                && state != .missing
                && (exactBytes + estimatedUpToBytes) > 0
        }
    }

    /// Compatibility initializer for pre-state callers (fixtures/tests):
    /// bytes land in `exactBytes`, state derives from `exists` + contents.
    init(category: CacheCategory, sizeBytes: Int64, itemCount: Int, exists: Bool) {
        let state: ScanState = !exists
            ? .missing
            : ((sizeBytes > 0 || itemCount > 0) ? .measured : .empty)
        self.init(
            category: category,
            state: state,
            exactBytes: sizeBytes,
            estimatedUpToBytes: 0,
            itemCount: itemCount,
            scanError: nil
        )
    }

    var formattedSize: String {
        ByteCountFormatter.sharedFile.string(fromByteCount: sizeBytes)
    }

    var isEmpty: Bool { !exists || sizeBytes == 0 }

    /// Presentation label for the non-measured states (fn-1.4, R6). SwiftUI
    /// views are not unit-testable, so this model property is the assertion
    /// surface: the four labels are pairwise distinct — a TCC denial must
    /// never read as "Not found" (the silent-8.0K field case, D6). `nil` for
    /// `.measured`, where the row shows the category description instead.
    var statusLabel: String? {
        switch state {
        case .measured:
            return nil
        case .missing:
            return "Not found"
        case .empty:
            return "Nothing to clean"
        case .partiallyDenied:
            return "Partially unreadable — measured bytes only"
        case .denied:
            return "Access denied — not scanned"
        }
    }
}

struct CleanupReport {
    /// What the operation did with the bytes. Rendering must never claim
    /// "Freed" for a Trash run — trashed bytes come back only when the
    /// Trash is emptied (R11).
    enum Disposal: Equatable {
        case permanent
        case trash
    }

    /// One cleaned category (or node_modules item) with split components
    /// (R16). A partially-failed category still yields ONE entry carrying
    /// only the bytes its successful children measured.
    struct Entry {
        let category: String
        /// Measured bytes on unique inodes — deletion verifiably freed them.
        let exactBytes: Int64
        /// Hardlinked bytes (freed only if every other link goes too) and
        /// command-category bytes (nothing measures what a command frees).
        let estimatedUpToBytes: Int64
        /// What ACTUALLY happened to this entry's bytes — not the requested
        /// mode. Command-backed categories run their argv regardless of the
        /// Move-to-Trash toggle and place nothing in the Trash, so their
        /// entries stay `.permanent` even in a Trash run.
        let disposal: Disposal
        /// Compatibility sum for pre-split callers.
        var bytesFreed: Int64 { exactBytes + estimatedUpToBytes }

        /// Component-derived row text (fn-1.4, R16): "X", "X + up to Y
        /// more", or "up to Z" — never a single number that launders
        /// estimates into certainty.
        var componentSummary: String {
            CleanupReport.componentPhrase(
                exact: exactBytes, estimatedUpTo: estimatedUpToBytes
            )
        }
    }

    /// The REQUESTED disposal mode for the run. Entries carry what actually
    /// happened — a command-backed entry is `.permanent` even when the run
    /// requested `.trash`, and `rowAnnotation(for:)` surfaces that mismatch.
    let disposal: Disposal
    let entries: [Entry]
    let errors: [(category: String, error: String)]

    /// Pure sum of entry `exactBytes` — no other math (R16).
    var totalFreedExact: Int64 { entries.reduce(0) { $0 + $1.exactBytes } }
    /// Pure sum of entry `estimatedUpToBytes` — no other math (R16).
    var totalEstimatedUpTo: Int64 { entries.reduce(0) { $0 + $1.estimatedUpToBytes } }

    /// Entry-disposal-driven one-line summary (R11), component-derived
    /// (R16, fn-1.4): permanent entries → "Freed X" / "Freed X + up to Y
    /// more" / "Freed up to Z"; trashed entries → the same amount phrase
    /// inside "Moved … to Trash — empty Trash to reclaim"; a mixed run
    /// renders both parts. Derives from what each entry ACTUALLY did, never
    /// the requested mode — trashed bytes are never claimed "Freed", and
    /// command-erased bytes are never claimed recoverable from the Trash.
    /// Never a success claim when nothing succeeded.
    var headline: String {
        guard !entries.isEmpty else {
            return errors.isEmpty
                ? "Nothing to clean"
                : "Nothing cleaned — every item failed"
        }
        let erased = entries.filter { $0.disposal == .permanent }
        let trashed = entries.filter { $0.disposal == .trash }
        if trashed.isEmpty {
            return "Freed \(Self.amountPhrase(for: erased))"
        }
        let moved =
            "\(Self.amountPhrase(for: trashed)) to Trash — empty Trash to reclaim"
        if erased.isEmpty {
            return "Moved \(moved)"
        }
        return "Freed \(Self.amountPhrase(for: erased)); moved \(moved)"
    }

    /// Row-level honesty marker: in a Trash-mode run, an entry whose bytes
    /// were erased permanently (command-backed categories) must say so —
    /// nothing of it sits in the Trash. `nil` whenever the entry's actual
    /// disposal matches the requested mode.
    func rowAnnotation(for entry: Entry) -> String? {
        guard disposal == .trash, entry.disposal == .permanent else { return nil }
        return "erased permanently — not in Trash"
    }

    /// R16 amount phrase over a subset of entries (one disposal's worth).
    private static func amountPhrase(for subset: [Entry]) -> String {
        componentPhrase(
            exact: subset.reduce(0) { $0 + $1.exactBytes },
            estimatedUpTo: subset.reduce(0) { $0 + $1.estimatedUpToBytes }
        )
    }

    /// R16 amount phrase, derived from the split components — exact bytes
    /// are stated plainly, hardlinked/command estimates are always hedged:
    /// - estimates absent → "X"
    /// - both present → "X + up to Y more"
    /// - exact zero → "up to Z"
    static func componentPhrase(exact: Int64, estimatedUpTo: Int64) -> String {
        let format = ByteCountFormatter.sharedFile
        guard estimatedUpTo > 0 else {
            return format.string(fromByteCount: exact)
        }
        guard exact > 0 else {
            return "up to \(format.string(fromByteCount: estimatedUpTo))"
        }
        return "\(format.string(fromByteCount: exact))"
            + " + up to \(format.string(fromByteCount: estimatedUpTo)) more"
    }
}
