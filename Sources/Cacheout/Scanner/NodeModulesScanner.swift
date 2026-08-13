/// # NodeModulesScanner — Recursive node_modules Finder
///
/// An `actor` that recursively searches configured developer project
/// directories for `node_modules` folders. Designed to find abandoned or
/// stale dependencies that consume significant disk space.
///
/// ## Safety model (fn-1.2, R19)
///
/// This scanner's recursion is MANUAL — it is not the Foundation enumerator
/// and gets none of the enumerator's symlink guarantees. Three lstat gates
/// close the escape vectors:
///
/// 1. **Search roots** are admitted through `PathGuard.admitContainer(_:)`
///    (configured containers only) AND must themselves be real directories —
///    a symlink search root is never traversed.
/// 2. **Every manual descent** re-checks `provider.kind(of:) == .directory`
///    (lstat, no-follow) — a nested symlink to an external tree is never
///    followed.
/// 3. **Every `node_modules` CANDIDATE** is lstat-checked before it is sized
///    or returned — a symlink candidate handed to the sizer's `.scanRoot`
///    mode would enumerate its external target, so it is never sized and
///    never returned.
///
/// ## Search Strategy
///
/// 1. Scans the search roots in parallel using `TaskGroup`.
/// 2. Recursively descends into subdirectories up to `maxDepth` (default: 6).
///    Hidden directories ARE traversed (D3 — a 23G `.claude/worktrees` field
///    case was invisible purely because the dir is hidden); the skip list and
///    depth bound keep the walk tame.
/// 3. When a real `node_modules` directory is found, it is sized via the
///    shared `DirectorySizer` (hidden files included — pnpm keeps ~all bytes
///    under `.pnpm`) and recorded **without recursing further**.
/// 4. Skips noise directories (`.git`, `.build`, `DerivedData`, etc.).
///
/// ## Two result surfaces (fn-2.2)
///
/// The traversal produces RECOGNIZED CANDIDATES (`NodeModulesCandidate`,
/// carrying the whole `SizeReport` — the exact/estimated split is never
/// collapsed to one number) plus classified traversal issues. Two mappings
/// consume them:
///
/// - **Legacy** `scan(maxDepth:includeProtectedRoots:)` — the pre-unification
///   surface (`NodeModulesScanOutcome`): candidate denials surface as
///   outcome errors and only measurable candidates become items, exactly as
///   before. The GUI migrated off it in fn-2.4 and the CLI in fn-2.6 (both
///   consume the runtime's validated stream); it survives only for its own
///   tests and the cleaner's compatibility adapter, deletable once those
///   migrate onto the protocol surface.
/// - **Protocol** `scan(context:)` (`SpaceScanner`) — emits one
///   `ReclaimableItem` per recognized candidate under the epic's COMPLETE
///   truth table (`.measured`/`.empty`/`.partiallyDenied`/`.denied`):
///   candidate-attributable denials AND mount boundaries (which the
///   cleaner's R15 doctrine refuses at delete time) ride the ITEM's
///   `state`/`scanError`;
///   `ScanOutcome.errors` is reserved for refused search roots and traversal
///   failures with NO recognized candidate.
///
/// ## Deduplication
///
/// Candidates are deduplicated by absolute path (using `Set<String>`
/// insertion) to handle overlapping search roots, then sorted by measured
/// size descending — both surfaces inherit the same order.

import Foundation

// MARK: - Outcome types

/// A classified, non-fatal problem encountered during a node_modules scan.
struct NodeModulesScanIssue: Equatable {
    enum Kind: Equatable {
        /// `PathGuard.admitContainer` refused the search root — not one of
        /// the configured containers; never traversed.
        case containerRefused
        /// The search root is a symlink (or otherwise not a real directory)
        /// — never traversed.
        case symlinkRoot
        /// macOS TCC (privacy) denial — EPERM under the Cocoa error.
        case tccDenied
        /// BSD permission denial — EACCES.
        case permissionDenied
        /// Enumeration or metadata failure that is not a permission problem.
        case unreadable
    }

    let url: URL
    let kind: Kind
    let detail: String
}

/// What a node_modules scan produced: items plus classified errors (the
/// legacy pre-unification surface; the GUI no longer consumes it — fn-2.4).
struct NodeModulesScanOutcome {
    var items: [NodeModulesItem]
    var errors: [NodeModulesScanIssue]
}

// MARK: - Internal traversal currency (fn-2.2)

/// One RECOGNIZED node_modules candidate — the lstat gate proved it a real
/// directory and the sizer walked it. Carries the WHOLE `SizeReport`: the
/// exact/estimated/logical byte components survive to the emitted item
/// (epic byte-model contract — the old `measuredBytes` collapse is gone),
/// and the report's denials are what the protocol mapping folds into the
/// item's `state`/`scanError`.
struct NodeModulesCandidate {
    let projectName: String
    let projectPath: URL
    /// The candidate's UNRESOLVED path exactly as discovered (leaf never
    /// resolved — fn-1's dual-canonicalization doctrine). This spelling is
    /// the admission descriptor's `requestedTargetURL` and the root record's
    /// `requestedURL` — the one deletion input (destructive-target rule).
    let nodeModulesPath: URL
    /// The configured search root (container) this candidate was discovered
    /// under — origin provenance (R14), feeds `admitContainer` at clean time.
    let originContainer: URL
    let lastModified: Date?
    let report: SizeReport
}

/// What the shared traversal produced: recognized candidates plus
/// root/traversal-level issues (which NEVER include candidate-attributable
/// sizing denials — those ride each candidate's report).
struct NodeModulesTraversal {
    var candidates: [NodeModulesCandidate]
    var issues: [NodeModulesScanIssue]
}

// MARK: - Scanner

actor NodeModulesScanner {
    /// Stable scanner slug (fn-2.2) — the CLI address prefix
    /// (`node_modules:<item-id>`) and the GUI section key. PERMANENT
    /// external contract; matches the address grammar `[a-z0-9_]+`.
    static let registeredID = "node_modules"

    private let fileManager = FileManager.default
    private nonisolated let searchRoots: [URL]
    private nonisolated let home: URL
    private let provider: FileSystemIdentityProvider
    private let pathGuard: PathGuard

    /// Common directories where developers keep projects
    private static let searchRootNames: [String] = [
        "Documents",
        "Developer",
        "Projects",
        "Code",
        "Sites",
        "Desktop",
        "Dropbox",
        "repos",
        "src",
        "work",
    ]

    /// Directories to skip during recursive search
    private static let skipDirs: Set<String> = [
        ".Trash", ".git", ".hg", "node_modules", ".build",
        "DerivedData", "Pods", ".next", "dist", "build",
        "Library", ".cache", ".npm", ".yarn",
    ]

    /// Search-root folder names macOS gates behind a TCC consent prompt.
    /// Enumerating one of these from a fresh install is what fires the
    /// "Cacheout would like to access your Documents folder" dialog — so
    /// they are walked only on user-initiated scans (fn-1.4, R9). Matched
    /// by basename so injected fixture roots behave identically.
    static let tccProtectedRootNames: Set<String> = [
        "Documents", "Desktop", "Downloads",
    ]

    /// The default container roots for `home` — the single source
    /// `CacheCleaner` shares so delete-time `admitContainer` accepts exactly
    /// the roots discovery used (fn-1.3).
    static func defaultSearchRoots(home: URL) -> [URL] {
        searchRootNames.map { home.appendingPathComponent($0) }
    }

    /// - Parameters:
    ///   - home: home the default search roots resolve against (injectable).
    ///   - searchRoots: explicit container roots (tests); nil uses the
    ///     default home-relative list.
    ///   - provider: identity provider shared with `PathGuard` and the sizer.
    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        searchRoots: [URL]? = nil,
        provider: FileSystemIdentityProvider = FileSystemIdentityProvider()
    ) {
        let roots = searchRoots ?? Self.defaultSearchRoots(home: home)
        self.searchRoots = roots
        self.home = home
        self.provider = provider
        self.pathGuard = PathGuard(
            home: home, containerRoots: roots, provider: provider
        )
    }

    /// Legacy surface (pre-unification; no GUI caller since fn-2.4) —
    /// behavior preserved byte-for-byte: candidate sizing denials surface as
    /// OUTCOME errors, and only candidates with measurable bytes become
    /// items.
    ///
    /// - Parameters:
    ///   - maxDepth: recursion bound below each search root.
    ///   - includeProtectedRoots: when false (automatic/background scans),
    ///     TCC-prompting roots (`tccProtectedRootNames`) are skipped
    ///     entirely — deliberately silent, a policy skip is not a scan
    ///     problem (R9). User-initiated scans pass true.
    func scan(
        maxDepth: Int = 6,
        includeProtectedRoots: Bool = true
    ) async -> NodeModulesScanOutcome {
        let traversal = await traverse(
            maxDepth: maxDepth, includeProtectedRoots: includeProtectedRoots
        )
        var issues = traversal.issues
        var items: [NodeModulesItem] = []
        for candidate in traversal.candidates {
            // A denied node_modules root (or partially denied tree) is a
            // classified, visible outcome error on THIS surface (R14/D6) —
            // the protocol surface folds the same denials into the item's
            // state instead.
            issues.append(contentsOf: candidate.report.denials.map(Self.issue(from:)))
            let size = candidate.report.measuredBytes
            guard size > 0 else { continue }
            items.append(NodeModulesItem(
                projectName: candidate.projectName,
                projectPath: candidate.projectPath,
                nodeModulesPath: candidate.nodeModulesPath,
                sizeBytes: size,
                lastModified: candidate.lastModified,
                originContainer: candidate.originContainer
            ))
        }
        return NodeModulesScanOutcome(items: items, errors: issues)
    }

    // MARK: - Shared traversal core

    /// Admission + gating + parallel traversal, shared by both surfaces.
    /// Search roots pass the same three gates as always (fn-1.2, untouched):
    /// TCC policy skip, `admitContainer`, and the lstat directory gate.
    private func traverse(
        maxDepth: Int,
        includeProtectedRoots: Bool
    ) async -> NodeModulesTraversal {
        var allCandidates: [NodeModulesCandidate] = []
        var allIssues: [NodeModulesScanIssue] = []

        let currentFileManager = self.fileManager
        let provider = self.provider
        let sizer = DirectorySizer(provider: provider)

        // Scan each admitted search root in parallel
        await withTaskGroup(of: NodeModulesTraversal.self) { group in
            for root in searchRoots {
                // TCC gating (R9): a background rescan must never be the
                // thing that fires a macOS privacy prompt.
                if !includeProtectedRoots,
                   Self.tccProtectedRootNames.contains(root.lastPathComponent) {
                    continue
                }
                guard currentFileManager.fileExists(atPath: root.path) else { continue }

                // Container admission BEFORE any traversal (R19).
                do {
                    _ = try pathGuard.admitContainer(root)
                } catch {
                    allIssues.append(NodeModulesScanIssue(
                        url: root, kind: .containerRefused,
                        detail: error.localizedDescription
                    ))
                    continue
                }

                // lstat gate: an escaping-symlink search root is NEVER
                // traversed — its real target may sit anywhere. A root we
                // cannot even lstat is a classified, visible failure (D6).
                switch provider.probeKind(of: root) {
                case .kind(.directory):
                    break
                case .failed(let code):
                    allIssues.append(Self.issue(forFailedProbe: root, errno: code))
                    continue
                case .kind, .absent:
                    allIssues.append(NodeModulesScanIssue(
                        url: root, kind: .symlinkRoot,
                        detail: "search root is not a real directory"
                    ))
                    continue
                }

                group.addTask {
                    await Self.findNodeModules(
                        in: root,
                        originContainer: root,
                        fileManager: currentFileManager,
                        provider: provider,
                        sizer: sizer,
                        skipDirs: Self.skipDirs,
                        maxDepth: maxDepth
                    )
                }
            }
            for await outcome in group {
                allCandidates.append(contentsOf: outcome.candidates)
                allIssues.append(contentsOf: outcome.issues)
            }
        }

        // Deduplicate by CANONICAL path and sort by measured size — both
        // surfaces inherit this order. The key must be canonical (review
        // r2): two admitted spellings of the same root (/var/… and
        // /private/var/…) discover the same direct candidate under two
        // unresolved spellings, and the canonical-path-derived stable ids
        // would collide — a duplicate id renders the WHOLE outcome
        // malformed at the runtime validator. First discovery wins,
        // keeping its own unresolved spelling and origin provenance.
        var seen = Set<String>()
        let candidates = allCandidates
            .filter {
                seen.insert(provider.canonicalize($0.nodeModulesPath).path)
                    .inserted
            }
            .sorted { $0.report.measuredBytes > $1.report.measuredBytes }
        return NodeModulesTraversal(candidates: candidates, issues: allIssues)
    }

    private static func findNodeModules(
        in directory: URL,
        originContainer: URL,
        fileManager: FileManager,
        provider: FileSystemIdentityProvider,
        sizer: DirectorySizer,
        skipDirs: Set<String>,
        maxDepth: Int,
        currentDepth: Int = 0
    ) async -> NodeModulesTraversal {
        var outcome = NodeModulesTraversal(candidates: [], issues: [])
        guard currentDepth < maxDepth else { return outcome }

        // Cooperative cancellation (review P2): the runtime cancels the
        // producer task when the consumer's stream terminates, and every
        // result yielded after termination is discarded — but this walk
        // used to run its full 10-30s course anyway. Checking at every
        // node (recursion entry and, below, between siblings) bounds the
        // orphaned wind-down to roughly one candidate's sizing, which is
        // what keeps the ViewModel's honest "still scanning" guard-hold
        // short. Truncation is safe here: cancellation only ever reaches
        // this walk when nobody will read the result.
        guard !Task.isCancelled else { return outcome }

        let candidate = directory.appendingPathComponent("node_modules")

        // Candidate gate (lstat, no-follow): only a REAL directory is a find.
        // A symlink candidate is never sized and never returned — `.scanRoot`
        // resolves roots by design, so an unchecked symlink would enumerate
        // its external target. `.absent` is the normal "no node_modules here"
        // case and stays silent; a FAILED probe is a classified, recorded
        // issue, never a silent "not found" (D6/R14) — and NOT a recognized
        // candidate (nothing proved it a directory), so it stays a traversal
        // issue on both surfaces.
        let candidateProbe = provider.probeKind(of: candidate)
        if case .failed(let code) = candidateProbe {
            outcome.issues.append(Self.issue(forFailedProbe: candidate, errno: code))
        }
        if candidateProbe == .kind(.directory) {
            let report = sizer.measure(at: candidate, mode: .scanRoot)

            // EVERY recognized candidate is emitted — empty, denied, and
            // partially-denied included (the complete truth table is the
            // protocol mapping's job; the legacy mapping keeps its size>0
            // gate). The report rides whole: components never collapse to
            // one number here, and its denials stay ON the candidate.
            let modified = (try? candidate.resourceValues(
                forKeys: [.contentModificationDateKey]
            ))?.contentModificationDate
            outcome.candidates.append(NodeModulesCandidate(
                projectName: directory.lastPathComponent,
                projectPath: directory,
                nodeModulesPath: candidate,
                originContainer: originContainer,
                lastModified: modified,
                report: report
            ))
            // Don't recurse into projects that have node_modules — they won't
            // have nested projects.
            return outcome
        }

        // Recurse into subdirectories. Hidden directories are deliberately
        // NOT skipped (D3); the skip list and maxDepth bound the walk.
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )
        } catch {
            // Real capture, never a silent skip (D6).
            outcome.issues.append(
                Self.issue(from: DirectorySizer.classifyDenial(error, at: directory))
            )
            return outcome
        }

        for item in contents {
            // Same cooperative check between siblings — a wide directory
            // must not finish probing every child once the walk is dead.
            if Task.isCancelled { break }
            let name = item.lastPathComponent
            guard !skipDirs.contains(name) else { continue }
            // lstat gate before EVERY manual descent: a symlinked directory
            // is never followed. A listed entry whose metadata cannot be read
            // is a classified, recorded issue (D6); `.absent` is a benign
            // mid-scan deletion race.
            switch provider.probeKind(of: item) {
            case .kind(.directory):
                break
            case .failed(let code):
                outcome.issues.append(Self.issue(forFailedProbe: item, errno: code))
                continue
            case .kind, .absent:
                continue
            }
            let sub = await findNodeModules(
                in: item,
                originContainer: originContainer,
                fileManager: fileManager,
                provider: provider,
                sizer: sizer,
                skipDirs: skipDirs,
                maxDepth: maxDepth,
                currentDepth: currentDepth + 1
            )
            outcome.candidates.append(contentsOf: sub.candidates)
            outcome.issues.append(contentsOf: sub.issues)
        }

        return outcome
    }

    private static func issue(from denial: SizeDenial) -> NodeModulesScanIssue {
        let kind: NodeModulesScanIssue.Kind
        switch denial.kind {
        case .tcc: kind = .tccDenied
        case .permission: kind = .permissionDenied
        case .metadata, .other: kind = .unreadable
        }
        return NodeModulesScanIssue(
            url: denial.url, kind: kind, detail: denial.detail
        )
    }

    /// Classify a failed `lstat` probe by errno (EPERM → TCC, EACCES → BSD
    /// permissions) — same taxonomy as the sizer's denial classification.
    private static func issue(
        forFailedProbe url: URL, errno code: Int32
    ) -> NodeModulesScanIssue {
        issue(from: DirectorySizer.denial(forFailedProbe: url, errno: code))
    }
}

// MARK: - SpaceScanner conformance (fn-2.2)

extension NodeModulesScanner: SpaceScanner {

    nonisolated var id: String { Self.registeredID }
    nonisolated var displayName: String { "Project node_modules" }

    /// The as-built container search set — declared at registration so the
    /// `SpaceScannerRuntime` union covers node_modules deletions (clean-time
    /// `admitContainer` never reads roots off items).
    nonisolated var trustedContainerRoots: [URL] { searchRoots }

    /// Protocol scan: the context's derived TCC flag maps onto the SAME gate
    /// the legacy surface uses (`.userInitiated` includes protected roots,
    /// `.automatic` skips them — the ViewModel's old call-site special-case,
    /// now carried by `ScanContext`). `categoryFilter` is ignored — it
    /// scopes CategoryScanner only.
    func scan(context: ScanContext) async -> ScanOutcome {
        let traversal = await traverse(
            maxDepth: 6, includeProtectedRoots: context.includeProtectedRoots
        )
        return ScanOutcome(
            items: traversal.candidates.map { reclaimableItem(from: $0) },
            // Exact 1:1 kind mapping — root-level and traversal issues ONLY
            // (candidate denials already rode their candidate's report).
            errors: traversal.issues.map(Self.scanIssue(from:))
        )
    }

    /// The COMPLETE recognized-candidate truth table (epic contract): every
    /// recognized candidate emits an item, no exceptions. Impediments split
    /// by what the CLEANER would do, not only by what the walk saw
    /// (PR #455 P2): a walk denial leaves a tree `removeItem` genuinely
    /// attempts and partially clears, while ANY mount boundary makes
    /// `removeGuardedItem` refuse the WHOLE target for as long as the
    /// boundary exists (R15) — so the two impediments must not share the
    /// cleanable-with-warning presentation.
    ///
    /// - clean walk + measurable content → `.measured` (nil `scanError`)
    /// - clean walk + NO measurable content → `.empty` (nil `scanError`,
    ///   zero components) — an honest terminal state, not a suppression
    /// - ANY recorded mount boundary — the candidate itself
    ///   (`rootMountBoundary`: the tree was never enumerated; the sizer
    ///   records the root in `mountBoundaries` for that case) or a mounted
    ///   subtree skipped mid-walk — → `.denied` REGARDLESS of measured
    ///   sibling bytes: `.denied` is the model's existing
    ///   visible-but-never-cleanable state (GUI renders it unselectably,
    ///   the CLI plan maps it to `refuse`, the cleaner surfaces the same
    ///   refusal as an item error), which is exactly the delete-time truth.
    ///   `.partiallyDenied` would promise a partial clean the confirmed run
    ///   categorically refuses. Zero components (the coherence table's
    ///   `.denied` shape — the byte components mean "deletion frees these",
    ///   and deletion frees nothing here); the readable siblings' measured
    ///   floor rides the synthesized `scanError` naming the boundary.
    /// - walk denial(s), NO boundary + SOME measurable content →
    ///   `.partiallyDenied` + classified `scanError`, carrying the readable
    ///   portion's components (deletion proceeds and partially succeeds —
    ///   the manual-selection warning is honest, R18)
    /// - walk denial(s), NO boundary + NO measurable content → `.denied` +
    ///   classified `scanError`, zero components
    ///
    /// All candidate-attributable outcomes are ITEM-level, never outcome
    /// errors. "Measurable content" is fn-1.2's rule verbatim
    /// (`CacheScanner.scanCategory`): any item counted or any byte measured.
    private func reclaimableItem(
        from candidate: NodeModulesCandidate
    ) -> ReclaimableItem {
        let report = candidate.report
        let measuredAnything = report.itemCount > 0 || report.measuredBytes > 0
        let state: ScanState
        let scanError: ScanError?
        if !report.mountBoundaries.isEmpty {
            // Boundary doctrine (R15, PR #455 P2): the whole target is
            // refused at delete time, so no measured sibling byte makes it
            // partially cleanable. The synthesized error ALWAYS names the
            // boundary — a coexisting walk denial's classification must not
            // mask the impediment that actually voids deletion (and no TCC
            // or permission grant would lift it).
            state = .denied
            scanError = Self.mountBoundaryScanError(from: report)
        } else if !report.denials.isEmpty {
            state = measuredAnything ? .partiallyDenied : .denied
            // Same classification path as category scans: kind from the
            // denial's classification (tcc/permission/other).
            scanError = CacheScanner.deriveScanError(
                refusals: [], denials: report.denials
            )
        } else {
            state = measuredAnything ? .measured : .empty
            scanError = nil
        }

        // A `.denied` item publishes ZERO components and no logical figure
        // (the frozen coherence shape). For the boundary-bearing case the
        // walk may honestly have measured readable siblings, but every
        // consumer reads the components as "deletion frees these" (GUI
        // totals, CLI rows, plan sums) — and deletion of a boundary-bearing
        // target frees NOTHING. The measured floor is preserved in the
        // scanError message, never summed into any reclaimable figure.
        let deletable = state != .denied

        // Dual canonicalization (fn-1 doctrine): `requestedURL` keeps the
        // unresolved discovered spelling (the deletion input), `resolvedURL`
        // the canonical spelling containment compares against — and the id
        // derives from the canonical form so a rescan through a different
        // spelling still yields the same id.
        let resolved = provider.canonicalize(candidate.nodeModulesPath)
        let record = RootScanRecord(
            requestedURL: candidate.nodeModulesPath,
            resolvedURL: resolved,
            // Frozen truth table: `.empty`/`.measured`/`.partiallyDenied`
            // candidates were admitted and walked (clean-empty and partial
            // walks count as measured); only `.denied` — admitted but
            // nothing DELETABLE established, whether denied at its own top
            // level, never enumerated behind a root mount boundary, or
            // voided whole by a nested boundary (R15) — is
            // `.deniedUnmeasured`. A refused search root never yields a
            // recognized candidate, so no candidate ever maps to
            // `.refusedAdmission`.
            status: state == .denied ? .deniedUnmeasured : .measured
        )

        let days = NodeModulesItem.daysSince(modified: candidate.lastModified)
        let shortPath = Self.displayPath(of: candidate.projectPath, home: home)
        var evidence = "node_modules of \(candidate.projectName) — \(shortPath)"
        if let age = NodeModulesItem.staleAge(daysSinceModified: days) {
            evidence += "; last touched \(age) ago"
        }

        return ReclaimableItem(
            // fn-2.1's SHARED full-hash id helper (R7) — never a second
            // derivation. Fixes the UUID-per-scan selection loss on rescan.
            id: ReclaimableItem.stableID(
                scannerID: Self.registeredID, canonicalPath: resolved.path
            ),
            scannerID: Self.registeredID,
            // The item's display identity today: the PROJECT name.
            displayName: candidate.projectName,
            // Split components preserved from SizeReport — never a
            // collapsed sum (epic byte-model contract) — except on
            // `.denied`, where nothing is deletable and the honest
            // reclaimable figure is zero (see `deletable` above).
            exactBytes: deletable ? report.exactAllocatedBytes : 0,
            estimatedUpToBytes: deletable ? report.estimatedUpToBytes : 0,
            // Carried only in the sparse-divergence direction that matters
            // for honest display: logical exceeding allocated means deletion
            // frees LESS than the apparent size (57.1G-logical vs
            // 31G-allocated field case). Block-rounding makes logical <
            // allocated for ordinary trees — that divergence is noise.
            logicalBytes: deletable && report.logicalBytes > report.measuredBytes
                ? report.logicalBytes : nil,
            itemCount: deletable ? report.itemCount : 0,
            // DISPLAY ONLY (destructive-target rule): the resolved location.
            url: resolved,
            declaredDisplayPath: shortPath,
            rootRecords: [record],
            state: state,
            scanError: scanError,
            // FROZEN mapping (epic round 11): NodeModulesItem carries no
            // risk today; `.review` is the only value consistent with the
            // never-auto-cleaned policy. User- and wire-visible.
            risk: .review,
            evidence: evidence,
            rebuildNote: nil,
            // node_modules cleans remove the directory itself. A target
            // missing at clean time surfaces as the cleaner's ITEM-KEYED
            // error (fn-2.3's ghost-item behavior), never a skip.
            action: .removeItem,
            // Frozen arm (epic round 6): origin container from fn-1.2's
            // provenance; `requestedTargetURL` is the candidate's OWN
            // unresolved discovered path — leaf never resolved, NOT the
            // display url — so fn-2.3 runs `admitContainer` +
            // `validateRemovableItem` and deletes the unresolved leaf
            // without guessing.
            admission: .containerItem(
                originContainer: candidate.originContainer,
                requestedTargetURL: candidate.nodeModulesPath
            ),
            // Structured selection policy (epic contract): node_modules is
            // never auto-selected and never enrolled in Quick Clean or
            // smart-clean automatic paths — CLI-visible is not
            // auto-cleanable.
            defaultSelected: false,
            automaticCleanEligible: false,
            isStale: NodeModulesItem.isStale(daysSinceModified: days)
        )
    }

    /// The classified impediment for a boundary-bearing candidate. `.other`
    /// is the honest EXISTING kind: a boundary is neither a TCC nor a BSD
    /// permission problem and no admission was refused, and the frozen
    /// `ScanError.Kind` wire table (`wireString`) must not silently grow a
    /// new case — the message carries the specifics, mirroring the
    /// cleaner's delete-time refusal wording (R15). When the walk measured
    /// readable siblings beside a nested boundary, their floor is REAL
    /// information and it rides here — visible in the GUI's denied row and
    /// the CLI's `scan_error.message` — because the item's byte components
    /// must stay zero (they mean "deletion frees these", and the whole
    /// target is refused).
    private static func mountBoundaryScanError(
        from report: SizeReport
    ) -> ScanError? {
        guard let boundary = report.mountBoundaries.first else { return nil }
        var message = report.rootMountBoundary
            ? "\(boundary.path): item is a mount point — not measured; "
                + "deletion would be refused"
            : "mount boundary at \(boundary.path) — subtree not measured; "
                + "deletion would be refused"
        if report.itemCount > 0 || report.measuredBytes > 0 {
            let floor = CleanupReport.componentPhrase(
                exact: report.exactAllocatedBytes,
                estimatedUpTo: report.estimatedUpToBytes
            )
            message += " (\(floor) measured beside the boundary is not "
                + "reclaimable while the boundary remains)"
        }
        return ScanError(kind: .other, message: message)
    }

    /// EXACT 1:1 kind mapping for root-level and traversal issues (epic
    /// error-surface contract) — same `url`, same `detail`, case-for-case.
    /// Internal (not private) so the mapping is directly assertable.
    static func scanIssue(from issue: NodeModulesScanIssue) -> ScanIssue {
        let kind: ScanIssue.Kind
        switch issue.kind {
        case .containerRefused: kind = .containerRefused
        case .symlinkRoot: kind = .symlinkRoot
        case .tccDenied: kind = .tccDenied
        case .permissionDenied: kind = .permissionDenied
        case .unreadable: kind = .unreadable
        }
        return ScanIssue(url: issue.url, kind: kind, detail: issue.detail)
    }

    /// The display spelling the section row renders today: the project path,
    /// home-shortened to `~` (anchored to the scanner's injected home so
    /// hermetic fixtures behave like the real account home). Shortening
    /// requires a PATH-COMPONENT boundary — a sibling that merely
    /// string-prefixes the home path (`/Users/d-other` vs `/Users/d`) must
    /// never render as `~-other/…`, least of all beside a destructive
    /// `.removeItem` action (review r1).
    private static func displayPath(of url: URL, home: URL) -> String {
        let path = url.path
        let homePath = home.path
        if path == homePath { return "~" }
        let prefix = homePath.hasSuffix("/") ? homePath : homePath + "/"
        guard path.hasPrefix(prefix) else { return path }
        return "~/" + path.dropFirst(prefix.count)
    }
}
