/// # CategoryScanner — CacheCategory Registry Adapter (fn-2.1)
///
/// Wraps the data-driven `CacheCategory` registry as one `SpaceScanner`,
/// preserving current behavior byte-for-byte with ZERO churn to the category
/// entries: it delegates every scan to the existing `CacheScanner` actor
/// (admission, sizing, and state derivation stay fn-1.2's — nothing is
/// reimplemented here) and maps each `ScanResult` to one aggregate
/// `ReclaimableItem` per category.
///
/// ## Context handling
///
/// - The TRIGGER is ignored — category scans never touch TCC-prompting
///   search roots, so `.userInitiated` and `.automatic` produce identical
///   outcomes.
/// - `categoryFilter` is HONORED (this is the only scanner that does): with
///   a filter, ONLY the requested categories are scanned — unrequested
///   categories' resolvers/probes are never invoked (a one-category clean
///   must not walk the other 22). Nil = all.
///
/// ## Error surface
///
/// This scanner emits NO outcome-level errors: every category impediment is
/// already an item state (`.denied`/`.partiallyDenied` + classified
/// `ScanError`, fn-1.2's derivation) — the two-surface rule puts aggregate
/// problems on the item, never in `ScanOutcome.errors`.

import Foundation

struct CategoryScanner: SpaceScanner {

    /// FROZEN aggregate scanner id (epic wire contract). Registered and
    /// namespace-checked by the runtime; NOT a valid bare CLI address token
    /// (category aggregates are addressed by category slug only — fn-2.6
    /// enforces).
    static let registeredID = "categories"

    var id: String { Self.registeredID }
    var displayName: String { "Cache Categories" }
    /// Aggregate admission is category-policy, not container-based — this
    /// scanner contributes nothing to the runtime's container-root union.
    var trustedContainerRoots: [URL] { [] }

    private let categories: [CacheCategory]
    private let scanner: CacheScanner

    /// - Parameters:
    ///   - categories: the registry to adapt (tests pass fixtures;
    ///     production `CacheCategory.allCategories`).
    ///   - scanner: the existing category scanner, injected so admission and
    ///     sizing anchor to the same home/provider the runtime composes.
    init(categories: [CacheCategory], scanner: CacheScanner) {
        self.categories = categories
        self.scanner = scanner
    }

    func scan(context: ScanContext) async -> ScanOutcome {
        // Category-granular scoping happens HERE, before any resolver or
        // probe runs — filtering the RESULTS would still have walked (and
        // probed) every category.
        let selected: [CacheCategory]
        if let filter = context.categoryFilter {
            selected = categories.filter { filter.contains($0.slug) }
        } else {
            selected = categories
        }

        let results = await scanner.scanAll(selected)
        return ScanOutcome(
            items: results.map { Self.item(from: $0) },
            errors: []
        )
    }

    // MARK: - Mapping

    /// One aggregate item per category. Byte components, state, error, and
    /// the per-root records come STRAIGHT from the `ScanResult` — no
    /// re-measurement and, critically, no re-evaluation of
    /// `CacheCategory.resolvedPaths` (a second evaluation could resolve
    /// differently and break the root-capture invariant).
    private static func item(from result: ScanResult) -> ReclaimableItem {
        let category = result.category
        let action: ReclaimAction
        if let commands = category.cleanCommands {
            // argv arrays pass through VERBATIM — execution stays behind the
            // cleaner's admission chokepoint (fn-2.3).
            action = .commands(commands)
        } else {
            action = .removeContents
        }

        return ReclaimableItem(
            // Slugs are the stable CLI contract — a canonical path would be
            // wrong for multi-path categories, and `CacheCategory.id` is a
            // per-launch UUID.
            id: category.slug,
            scannerID: registeredID,
            displayName: category.name,
            exactBytes: result.exactBytes,
            estimatedUpToBytes: result.estimatedUpToBytes,
            // ScanResult does not carry a logical-bytes figure; aggregates
            // report no divergence.
            logicalBytes: nil,
            itemCount: result.itemCount,
            // Display only: the first RESOLVED root regardless of status —
            // a denied root's resolved location is still honest display
            // data. Nil for `.missing` (no fake resolution).
            url: result.rootRecords.first { $0.resolvedURL != nil }?.resolvedURL,
            declaredDisplayPath: declaredDisplayPath(of: category),
            rootRecords: result.rootRecords,
            state: result.state,
            scanError: result.scanError,
            risk: category.riskLevel,
            // Aggregate evidence is the category description; per-item
            // scanners provide real content in fn-3+.
            evidence: category.description,
            rebuildNote: category.rebuildNote,
            action: action,
            admission: .category(category),
            defaultSelected: category.defaultSelected,
            automaticCleanEligible: true,
            isStale: nil
        )
    }

    /// The category's DECLARED spelling, for presenting unresolved/missing
    /// items honestly: the first discovery entry, home-relative entries
    /// spelled `~/…`. Falls back to the category name for a (nonexistent in
    /// production) entry-less category.
    static func declaredDisplayPath(of category: CacheCategory) -> String {
        guard let first = category.discovery.first else { return category.name }
        switch first {
        case .staticPath(let relative):
            return "~/" + relative
        case .absolutePath(let absolute):
            return absolute
        case .probed(_, _, let fallbacks):
            guard let fallback = fallbacks.first else { return category.name }
            return fallback.hasPrefix("/") ? fallback : "~/" + fallback
        }
    }
}
