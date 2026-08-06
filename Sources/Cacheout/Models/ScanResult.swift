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
/// fn-1.3 consumes `state` for deletion refusal; fn-1.4 builds selection
/// defaults and presentation (`statusLabel`, GUI, scan JSON) on top. The
/// selection default here intentionally preserves the pre-state behavior
/// (`defaultSelected && exists && sizeBytes > 0`) — reworking selection for
/// the denied states is fn-1.4's task.
///
/// ## CleanupReport
///
/// Returned by `CacheCleaner.clean()` after a cleanup operation (fn-1.3,
/// R11/R16). Entries carry SPLIT byte components: `exactBytes` (measured
/// unique-inode bytes whose deletion verifiably freed them) and
/// `estimatedUpToBytes` (hardlinked or command-freed bytes that MAY be
/// freed). Aggregates are pure sums of the entry components. The report also
/// carries its `disposal` mode, and `headline` derives from it — a Trash run
/// never claims "Freed" (the bytes return only when the Trash is emptied),
/// and a run where nothing succeeded never claims success.
///
/// `cleaned`/`totalFreed`/`formattedTotal` remain as a compatibility surface
/// for pre-split callers (CLI JSON until fn-1.5, the GUI sheet until fn-1.4).

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
        // Pre-state selection rule preserved verbatim; fn-1.4 owns the
        // denied-state selection behavior.
        self.isSelected = category.defaultSelected
            && state != .missing
            && (exactBytes + estimatedUpToBytes) > 0
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
        /// Compatibility sum for pre-split callers.
        var bytesFreed: Int64 { exactBytes + estimatedUpToBytes }
    }

    let disposal: Disposal
    let entries: [Entry]
    let errors: [(category: String, error: String)]

    /// Pure sum of entry `exactBytes` — no other math (R16).
    var totalFreedExact: Int64 { entries.reduce(0) { $0 + $1.exactBytes } }
    /// Pure sum of entry `estimatedUpToBytes` — no other math (R16).
    var totalEstimatedUpTo: Int64 { entries.reduce(0) { $0 + $1.estimatedUpToBytes } }

    /// Mode-driven one-line summary (R11): permanent → "Freed N", trash →
    /// "Moved N to Trash — empty Trash to reclaim". Never a success claim
    /// when nothing succeeded.
    var headline: String {
        guard !entries.isEmpty else {
            return errors.isEmpty
                ? "Nothing to clean"
                : "Nothing cleaned — every item failed"
        }
        switch disposal {
        case .permanent:
            return "Freed \(formattedTotal)"
        case .trash:
            return "Moved \(formattedTotal) to Trash — empty Trash to reclaim"
        }
    }

    // MARK: Compatibility surface (pre-split callers)

    var cleaned: [(category: String, bytesFreed: Int64)] {
        entries.map { ($0.category, $0.bytesFreed) }
    }
    var totalFreed: Int64 { totalFreedExact + totalEstimatedUpTo }
    var formattedTotal: String {
        ByteCountFormatter.sharedFile.string(fromByteCount: totalFreed)
    }
}
