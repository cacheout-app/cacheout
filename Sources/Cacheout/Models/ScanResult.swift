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
/// Returned by `CacheCleaner.clean()` after a cleanup operation. Contains two arrays:
/// - `cleaned`: Successfully cleaned items with bytes freed per category.
/// - `errors`: Failed items with error descriptions per category.
///
/// Provides `totalFreed` (sum of all freed bytes) and a formatted string version.

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
    let cleaned: [(category: String, bytesFreed: Int64)]
    let errors: [(category: String, error: String)]
    var totalFreed: Int64 { cleaned.reduce(0) { $0 + $1.bytesFreed } }
    var formattedTotal: String {
        ByteCountFormatter.sharedFile.string(fromByteCount: totalFreed)
    }
}
