/// # CacheScanner — Parallel Cache Category Scanner
///
/// An `actor` that scans all registered cache categories concurrently using
/// Swift's structured concurrency (`TaskGroup`). Each category is scanned in
/// its own child task for maximum parallelism.
///
/// ## Scan-time admission (R19)
///
/// Every resolved root is admitted through `PathGuard` against the category's
/// OWN `CategoryAdmissionPolicy` BEFORE it is measured. A refused root is
/// NEVER enumerated — refusal becomes a classified `ScanError` on the result
/// (`.denied`-family), not a walk. This is what keeps untrusted `.probed`
/// stdout from ever steering a filesystem walk (or, later, a deletion): the
/// probe's output must independently match the category's declared roots.
///
/// ## Sizing
///
/// All measurement goes through the shared `DirectorySizer` (D7) in
/// `.scanRoot` mode — hidden files and bundle descendants included (D2/D3),
/// enumerator errors classified and recorded (D6), hardlinked bytes split
/// into `estimatedUpToBytes` (D8 mitigation), mount boundaries respected.
///
/// ## State derivation
///
/// The scanner — not the UI — derives `ScanState`: no resolved paths →
/// `.missing`; admission refusals or walk denials with nothing measured →
/// `.denied`; with something measured → `.partiallyDenied`; clean walk of an
/// empty tree → `.empty`; otherwise `.measured`.
///
/// ## Results Ordering
///
/// Results are sorted by size descending so the largest categories appear
/// first in the UI, helping users prioritize cleanup.

import Foundation

actor CacheScanner {

    private let home: URL
    private let provider: FileSystemIdentityProvider

    /// - Parameters:
    ///   - home: home directory BOTH path discovery and admission policies
    ///     are anchored to (injectable — tests pass a fixture home;
    ///     production the real one).
    ///   - provider: identity provider shared with `PathGuard` and the sizer.
    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        provider: FileSystemIdentityProvider = FileSystemIdentityProvider()
    ) {
        self.home = home
        self.provider = provider
    }

    func scanAll(_ categories: [CacheCategory]) async -> [ScanResult] {
        await withTaskGroup(of: ScanResult.self) { group in
            for category in categories {
                group.addTask { await self.scanCategory(category) }
            }
            var results: [ScanResult] = []
            for await result in group {
                results.append(result)
            }
            // A TOTAL order, not a partial one (PR #459 review r3 — F10).
            // `results` is built in task-group COMPLETION order, which is
            // nondeterministic, so sorting on `sizeBytes` ALONE left every set
            // of equal-size categories in whatever order those tasks happened
            // to finish. Measured on a three-category fixture (one 4 KB, one
            // empty, one missing): 17 of 2000 scans returned the two 0-byte
            // rows in the minority order. Every missing and every empty
            // category ties at 0 bytes, so real installs have several tied
            // rows and the `categories` array of `--cli scan --format json`
            // and the app's category list reordered between consecutive scans.
            // No value was ever wrong — only the order — which is why this is
            // a disclosure wart and not a correctness one. The slug tie-break
            // is what makes `CLIHandler`'s "deterministic wire order" note
            // true, and it is the same shape `BuildArtifactsScanner` already
            // uses and `docs/v1/CATEGORIES.md` already documents.
            return results.sorted { left, right in
                left.sizeBytes == right.sizeBytes
                    ? left.category.slug < right.category.slug
                    : left.sizeBytes > right.sizeBytes
            }
        }
    }

    nonisolated func scanCategory(_ category: CacheCategory) async -> ScanResult {
        // Discovery and admission MUST anchor to the same home — resolving
        // against the real account home while admitting against an injected
        // one would refuse every home-relative root and defeat the seam.
        let resolvedPaths = category.resolvedPaths(home: home)
        guard !resolvedPaths.isEmpty else {
            // `.missing` carries an EMPTY root capture by contract (fn-2.1):
            // there is nothing deletable and nothing to re-admit.
            return ScanResult(
                category: category, state: .missing,
                exactBytes: 0, estimatedUpToBytes: 0,
                itemCount: 0, scanError: nil
            )
        }

        let policy = CategoryAdmissionPolicy(category: category, home: home)
        let provider = self.provider
        let pathGuard = PathGuard(home: home, provider: provider)
        let sizer = DirectorySizer(provider: provider)

        var exact: Int64 = 0
        var estimated: Int64 = 0
        var items = 0
        var denials: [SizeDenial] = []
        var refusals: [Error] = []
        var rootRecords: [RootScanRecord] = []

        for url in resolvedPaths {
            let admitted: AdmittedRoot
            do {
                admitted = try pathGuard.admitDeletionRoot(url, policy: policy)
            } catch {
                // Refused roots are NEVER walked (R19) — the refusal is the
                // scan outcome for this root. The record still carries the
                // canonical spelling: a refused root's resolved location is
                // honest display data (fn-2.1), just never a deletion input.
                refusals.append(error)
                rootRecords.append(RootScanRecord(
                    requestedURL: url,
                    resolvedURL: provider.canonicalize(url),
                    status: .refusedAdmission
                ))
                continue
            }

            let report = sizer.measure(at: admitted.resolvedURL, mode: .scanRoot)
            exact += report.exactAllocatedBytes
            estimated += report.estimatedUpToBytes
            items += report.itemCount
            denials.append(contentsOf: report.denials)

            // Per-root record capture (fn-2.1, FROZEN truth table): a walk
            // that measured ANYTHING — or walked cleanly, even to emptiness
            // — is `.measured` (deletable); an admitted root whose sizing
            // was denied before any measurement is `.deniedUnmeasured` (not
            // deletable). `requestedURL` keeps the UNRESOLVED spelling
            // deletion uses; `resolvedURL` the canonical spelling
            // containment compares against.
            let measuredAnythingAtRoot =
                report.itemCount > 0 || report.measuredBytes > 0
            rootRecords.append(RootScanRecord(
                requestedURL: admitted.requestedURL,
                resolvedURL: admitted.resolvedURL,
                status: (!measuredAnythingAtRoot && !report.denials.isEmpty)
                    ? .deniedUnmeasured
                    : .measured
            ))
        }

        let measuredAnything = items > 0 || (exact + estimated) > 0
        let state: ScanState
        let scanError: ScanError?
        if !refusals.isEmpty || !denials.isEmpty {
            state = measuredAnything ? .partiallyDenied : .denied
            scanError = Self.deriveScanError(refusals: refusals, denials: denials)
        } else if !measuredAnything {
            state = .empty
            scanError = nil
        } else {
            state = .measured
            scanError = nil
        }

        return ScanResult(
            category: category, state: state,
            exactBytes: exact, estimatedUpToBytes: estimated,
            itemCount: items, scanError: scanError,
            rootRecords: rootRecords
        )
    }

    /// First admission refusal wins (it means a root was never walked at
    /// all); otherwise the first classified walk denial.
    static func deriveScanError(
        refusals: [Error], denials: [SizeDenial]
    ) -> ScanError? {
        if let refusal = refusals.first {
            return ScanError(
                kind: .admissionRefused,
                message: refusal.localizedDescription
            )
        }
        if let denial = denials.first {
            return ScanError(
                kind: denial.kind.scanErrorKind,
                message: "\(denial.url.path): \(denial.detail)"
            )
        }
        return nil
    }
}
