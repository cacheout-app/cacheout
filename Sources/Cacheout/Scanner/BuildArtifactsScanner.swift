/// # BuildArtifactsScanner — Rule Matching → Items (fn-4.3, R1/R2/R4/R10/R13/R15)
///
/// The scanner CORE: consume fn-4.2's `ProjectTreeWalker` events, match
/// fn-4.1's `BuildArtifactRules`, prune matched dirs via consumer verdicts,
/// collapse cross-walk overlap with the canonical-identity item dedupe (D7),
/// size what survives, derive staleness and evidence, and emit
/// validator-coherent `ReclaimableItem`s in a deterministic TOTAL order.
///
/// NOT here (deliberately): the valuables gate (fn-4.4), the pre-delete
/// revalidator (fn-4.8), production `SpaceScanner` CONFORMANCE and the
/// `production(devRoots:)` registration (fn-4.5), deletion, and any UI. The
/// type exposes `id` / `displayName` / `trustedContainerRoots` / `scan` as
/// plain members so fn-4.5's conformance is a one-line `extension
/// BuildArtifactsScanner: SpaceScanner {}` — but until that line exists this
/// scanner CANNOT be registered, so nothing it emits is addressable or
/// deletable. The R13 validator round-trips run through a TEST-ONLY adapter
/// (see `BuildArtifactsScannerTests`).
///
/// ## Matching + pruning (R1/R2)
/// The two rule SHAPES bind to different subjects of one event and therefore
/// demand two prune behaviors:
/// - **Sibling match → `child(name)`**: the matched CHILD is the artifact dir
///   and exactly that child is pruned. Never descend a matched `target/` —
///   thousands of vendored `Cargo.toml`s would false-positive.
/// - **Inside match → `currentDirectory`**: the event's OWN directory is the
///   artifact dir and ALL of its children are pruned — nothing beneath a
///   matched venv is walked.
/// Only MATCHED dirs are pruned (plus the walker's own `.git` hard prune) —
/// no name-based skip list, so the monorepo `packages/build/pkg/node_modules`
/// stays reachable (R2). Matching does not stop at the first hit per root:
/// nested workspaces list BOTH. In this scanner's SINGLE-consumer walk its
/// verdicts are decisive (the walker's unanimity rule has no second consumer
/// here).
///
/// ## Item dedupe (R4) — LOAD-BEARING under D7
/// Nested kept roots walk INDEPENDENTLY (an ancestor's depth-8 walk does not
/// reach what a nested root's own budget reaches), so overlapping walks CAN
/// and WILL produce multiple candidates for one artifact. Two ordered passes
/// over the UNION of all walks' candidates:
/// 1. **Ancestor drop** — a candidate strictly inside another candidate's
///    artifact dir is dropped, keyed on canonicalized `pathComponents`
///    prefixes, never string `hasPrefix` (PathGuard doctrine).
/// 2. **Canonical-identity collapse** — candidates sharing one identity path
///    (`resolveTargetKeepingLeaf`) collapse to ONE item; the DEEPEST
///    (most-specific) origin root wins, byte-wise `originRoot.path` breaking
///    ties. Both roots are declared, so either satisfies the validator's
///    origin binding — determinism is what matters, and the more specific
///    root is the user's deliberate addition.
/// Sizing runs AFTER the collapse: one artifact is never measured twice.
///
/// ## Item mapping (R10/R13/R15)
/// Cloned VERBATIM from the as-built `NodeModulesScanner` candidate truth
/// table (`NodeModulesScanner.swift:540-590`) and `OrphanedCachesScanner`'s
/// emission: `stableID` over the `resolveTargetKeepingLeaf` identity path,
/// exactly ONE `RootScanRecord` binding the UNRESOLVED requested target and
/// the resolved display URL, `.containerItem` origin = the winning declared
/// origin-root spelling, and the selection triple read OFF the matched rule
/// row (`defaultSelected: false`, `automaticCleanEligible: false` in v1 —
/// D3/R15). A `.denied` item publishes ZERO components and NO logical
/// figure; there is deliberately no unconditional `.measured` record — the
/// denied family requires a refused-or-denied record or the whole outcome
/// malforms.

import Foundation

// MARK: - Candidate

/// One matched artifact directory, before dedupe and sizing. Carries the
/// UNRESOLVED discovered spelling (the deletion input and the identity
/// preimage source) and the DECLARED origin-root spelling verbatim (the
/// validator's origin binding string-compares it against the producing
/// scanner's `trustedContainerRoots`).
struct BuildArtifactCandidate: Equatable, Sendable {
    /// The artifact dir itself, spelled under `originRoot` — never resolved.
    let artifactDirectory: URL
    /// The declared dev-root spelling this candidate's walk started under.
    let originRoot: URL
    /// The rule row that claimed it — the selection triple is read off it.
    let rule: BuildArtifactRule
    /// The marker name that PROVED the match (evidence names it): the
    /// sibling file for `markerSibling`, the interior file for
    /// `markerInside`.
    let marker: String
}

// MARK: - Scanner

/// `@unchecked Sendable` under the house scanner discipline: every stored
/// property is an immutable `let`, `FileSystemIdentityProvider`/
/// `DirectorySizer`/`PathGuard` hold no mutable state, and the stored clock
/// is `@Sendable` by type.
struct BuildArtifactsScanner: @unchecked Sendable {

    /// Stable scanner slug — the CLI address prefix
    /// (`build_artifacts:<item-id>`), the GUI section key, and the
    /// `stableID` preimage's scanner half. Matches the address grammar
    /// `[a-z0-9_]+`. Registration itself lands in fn-4.5.
    static let registeredID = "build_artifacts"

    /// The dev roots this scan walks, plus the classified config issues
    /// their resolution produced — stored at CONSTRUCTION (R16): a
    /// policy-rejected persisted root is never registered and never walked,
    /// yet its issue rides EVERY outcome, so the fallback is never silent.
    let devRoots: DevRootsResolution
    /// Anchor for display shortening and the walker's TCC-protected-ancestor
    /// determination (injectable — zero real-`$HOME` reads in tests).
    let home: URL

    private let provider: FileSystemIdentityProvider
    /// The scanner's OWN guard, whose `containerRoots` are exactly its
    /// declared `trustedContainerRoots` (epic D2: each scanner constructs
    /// its own; scan-time admission is read-only and snapshot-free).
    private let pathGuard: PathGuard
    private let sizer: DirectorySizer
    private let maxDepth: Int
    /// Injected clock for staleness — a PROVIDER (not a `Date`) because the
    /// scanner is long-lived and each scan dates content against its own
    /// "now" (the `OrphanedCachesScanner` precedent).
    private let now: @Sendable () -> Date

    init(
        home: URL,
        devRoots: DevRootsResolution,
        provider: FileSystemIdentityProvider = FileSystemIdentityProvider(),
        maxDepth: Int = ProjectTreeWalker.defaultMaxDepth,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.home = home
        self.devRoots = devRoots
        self.provider = provider
        self.pathGuard = PathGuard(
            home: home, containerRoots: devRoots.keptRoots, provider: provider
        )
        self.sizer = DirectorySizer(provider: provider)
        self.maxDepth = maxDepth
        self.now = now
    }

    // MARK: - Protocol surface (conformance itself lands in fn-4.5)

    var id: String { Self.registeredID }
    var displayName: String { "Project Build Artifacts" }

    /// The KEPT effective dev roots, declared spellings verbatim — the union
    /// of these is what extends delete-time admission once fn-4.5 registers
    /// the scanner. Nothing item-side can widen it.
    var trustedContainerRoots: [URL] { devRoots.keptRoots }

    /// One scan: walk → match → dedupe → size → map → order.
    ///
    /// Runs wherever its caller runs (never the main actor; the walker and
    /// the sizer are synchronous and isolation-inherited). Cancellation
    /// propagates from the walker and is re-checked between sizings —
    /// partial results are returned rather than discarded.
    ///
    /// `context.categoryFilter` is ignored (it scopes `CategoryScanner`
    /// only); `context.includeProtectedRoots` rides through to the walker's
    /// TCC policy gate unchanged.
    func scan(context: ScanContext) async -> ScanOutcome {
        // (1) WALK + MATCH. The consumer accumulates candidates and returns
        // prune verdicts for exactly the matched dirs.
        var candidates: [BuildArtifactCandidate] = []
        let walker = ProjectTreeWalker(
            home: home, pathGuard: pathGuard, provider: provider
        )
        let walkIssues = walker.walk(
            roots: devRoots.keptRoots,
            maxDepth: maxDepth,
            includeProtectedRoots: context.includeProtectedRoots,
            consumers: [{ event in
                Self.consume(event, into: &candidates)
            }]
        )

        // (2) DEDUPE — ancestor drop, then canonical-identity collapse. The
        // union of every walk's candidates, in one deterministic pass pair.
        let survivors = Self.deduplicated(candidates, provider: provider)

        // (3) SIZE + MAP. Sizing AFTER the collapse: one artifact is never
        // measured twice. Item construction lives in ONE seam
        // (`reclaimableItem`) so fn-4.4 can append valuables there.
        var emissions: [(item: ReclaimableItem, identityPath: String)] = []
        emissions.reserveCapacity(survivors.count)
        for candidate in survivors {
            // Cooperative cancellation between candidates: a cancelled scan
            // must not keep sizing multi-GB trees nobody will read.
            if Task.isCancelled { break }
            let report = sizer.measure(
                at: candidate.artifactDirectory, mode: .scanRoot
            )
            emissions.append(reclaimableItem(from: candidate, report: report))
        }

        // (4) ORDER — deterministic and TOTAL.
        return ScanOutcome(
            items: Self.ordered(emissions),
            // Config issues ride EVERY outcome (R16 data path), followed by
            // this walk's per-root classified issues. Candidate-attributable
            // impediments are NEVER here — they ride their item's
            // `state`/`scanError` (two-surface rule).
            errors: devRoots.issues + walkIssues
        )
    }

    // MARK: - Matching + prune verdicts (R1/R2)

    /// One event → its candidates, returning the child names to PRUNE.
    /// Static so the walk consumer captures no scanner state.
    private static func consume(
        _ event: ProjectTreeEvent,
        into candidates: inout [BuildArtifactCandidate]
    ) -> Set<String> {
        var pruned = Set<String>()
        for match in BuildArtifactRules.matches(in: event) {
            switch match.target {
            case .child(let name):
                // The matched CHILD is the artifact dir; prune exactly it.
                candidates.append(BuildArtifactCandidate(
                    artifactDirectory:
                        event.directory.appendingPathComponent(name),
                    originRoot: event.originRoot,
                    rule: match.rule,
                    marker: matchedMarker(for: match, in: event)
                ))
                pruned.insert(name)
            case .currentDirectory:
                // The event's OWN directory is the artifact dir; prune ALL
                // of its children so nothing beneath it is walked.
                candidates.append(BuildArtifactCandidate(
                    artifactDirectory: event.directory,
                    originRoot: event.originRoot,
                    rule: match.rule,
                    marker: matchedMarker(for: match, in: event)
                ))
                for entry in event.entries { pruned.insert(entry.name) }
            }
        }
        return pruned
    }

    /// The marker name evidence names. Chosen in RULE-DECLARATION order (not
    /// entry order) so a Gradle project carrying several declared markers
    /// always names the same one. The match already proved at least one is
    /// present; the fallbacks exist only so the return type stays total.
    private static func matchedMarker(
        for match: BuildArtifactMatch, in event: ProjectTreeEvent
    ) -> String {
        switch match.rule.shape {
        case .markerInside(let marker):
            return marker
        case .markerSibling(let artifactDirName, let markers):
            let present = markers.first { marker in
                event.entries.contains {
                    $0.name == marker && $0.name != artifactDirName
                        && $0.kind == .regularFile
                }
            }
            return present ?? markers.first ?? artifactDirName
        }
    }

    // MARK: - Dedupe (R4, D7 — the LOAD-BEARING post-pass)

    /// Ancestor drop, then canonical-identity collapse. Internal so the
    /// injected-synthetic canonical-alias tests can drive it with candidates
    /// no filesystem fixture can produce.
    ///
    /// Output order follows FIRST-OCCURRENCE order of each surviving
    /// identity in the input (the final output sort is what user-visible
    /// order depends on; this only has to be deterministic).
    static func deduplicated(
        _ candidates: [BuildArtifactCandidate],
        provider: FileSystemIdentityProvider
    ) -> [BuildArtifactCandidate] {
        // The house identity: canonical PARENT chain + UNRESOLVED leaf. Two
        // spellings of one artifact (alias-declared root vs canonical root)
        // produce the SAME identity — which is exactly what must collapse,
        // since the id derives from it and duplicate ids malform the whole
        // outcome.
        let identities = candidates.map {
            provider.resolveTargetKeepingLeaf($0.artifactDirectory)
        }

        // PASS 1 — ancestor drop. Keyed on canonical `pathComponents`, never
        // string `hasPrefix` (PathGuard doctrine: `/a/bc` must never read as
        // inside `/a/b`). Components are joined with NUL — a component can
        // never contain NUL, so the encoding is injective, and the lookup is
        // an EXACT set membership of a prefix ARRAY, not a string prefix
        // test. Reachable in production: a dev root configured INSIDE an
        // artifact dir another walk matched.
        let componentKeys = identities.map { componentKey($0.pathComponents) }
        let allKeys = Set(componentKeys)
        var kept: [Int] = []
        for (index, identity) in identities.enumerated() {
            let components = identity.pathComponents
            var insideAnother = false
            // STRICT ancestors only (`1..<count`): an identical identity is
            // never its own ancestor — those collapse in pass 2 instead.
            for length in 1..<max(components.count, 1)
            where allKeys.contains(componentKey(Array(components.prefix(length)))) {
                insideAnother = true
                break
            }
            if !insideAnother { kept.append(index) }
        }

        // PASS 2 — canonical-identity collapse with DETERMINISTIC
        // provenance: deepest resolved origin root wins.
        var winnerByIdentity: [String: Int] = [:]
        var identityOrder: [String] = []
        for index in kept {
            let key = identities[index].path
            guard let incumbent = winnerByIdentity[key] else {
                winnerByIdentity[key] = index
                identityOrder.append(key)
                continue
            }
            if provenanceWins(
                candidates[index], over: candidates[incumbent],
                provider: provider
            ) {
                winnerByIdentity[key] = index
            }
        }
        return identityOrder.compactMap { key in
            winnerByIdentity[key].map { candidates[$0] }
        }
    }

    /// Injective encoding of a path-components ARRAY (NUL join — no path
    /// component can contain NUL), used only as a dictionary/set key for
    /// component-array equality.
    private static func componentKey(_ components: [String]) -> String {
        components.joined(separator: "\u{0}")
    }

    /// The pinned provenance rule when one canonical identity is reachable
    /// from several declared roots: the DEEPEST (most-specific) resolved
    /// origin root wins — it is the user's deliberate addition and the
    /// tightest container binding — with byte-wise `originRoot.path` as the
    /// tie-break and the requested artifact spelling as a final totality
    /// tie-break. Both roots are declared, so either satisfies the
    /// validator's origin binding; DETERMINISM is the property that matters.
    private static func provenanceWins(
        _ candidate: BuildArtifactCandidate,
        over incumbent: BuildArtifactCandidate,
        provider: FileSystemIdentityProvider
    ) -> Bool {
        let depth = provider.canonicalize(candidate.originRoot)
            .pathComponents.count
        let incumbentDepth = provider.canonicalize(incumbent.originRoot)
            .pathComponents.count
        if depth != incumbentDepth { return depth > incumbentDepth }
        if candidate.originRoot.path != incumbent.originRoot.path {
            return candidate.originRoot.path.utf8
                .lexicographicallyPrecedes(incumbent.originRoot.path.utf8)
        }
        return candidate.artifactDirectory.path.utf8
            .lexicographicallyPrecedes(incumbent.artifactDirectory.path.utf8)
    }

    // MARK: - Item mapping (the ONE construction seam — fn-4.4 extends HERE)

    /// One sized candidate → one `ReclaimableItem` (+ its identity path, the
    /// output order's final tie-breaker).
    ///
    /// State AND record status follow the as-built NodeModules candidate
    /// truth table VERBATIM:
    /// - ANY mount boundary in the tree → `.denied`, and the scanError
    ///   ALWAYS names the boundary (a coexisting walk denial must not mask
    ///   the impediment that actually voids deletion — no grant lifts it);
    /// - else sizer `denials` non-empty → measured-anything ?
    ///   `.partiallyDenied` : `.denied`, scanError classified
    ///   tcc/permission/other from the denial (candidate-level denials are
    ///   NEVER dropped);
    /// - else → measured-anything ? `.measured` : `.empty`.
    /// Record status is `.deniedUnmeasured` exactly when the state is
    /// `.denied`, `.measured` otherwise (`.partiallyDenied` carries the
    /// honestly-`.measured` record — its denials sit INSIDE the tree;
    /// `.refusedAdmission` is for refused SEARCH ROOTS, which never yield
    /// candidates).
    private func reclaimableItem(
        from candidate: BuildArtifactCandidate, report: SizeReport
    ) -> (item: ReclaimableItem, identityPath: String) {
        let hasBoundary = report.rootMountBoundary
            || !report.mountBoundaries.isEmpty
        let measuredAnything = report.itemCount > 0 || report.measuredBytes > 0

        let state: ScanState
        let scanError: ScanError?
        if hasBoundary {
            state = .denied
            scanError = Self.mountBoundaryScanError(from: report)
        } else if !report.denials.isEmpty {
            state = measuredAnything ? .partiallyDenied : .denied
            scanError = CacheScanner.deriveScanError(
                refusals: [], denials: report.denials
            )
        } else {
            state = measuredAnything ? .measured : .empty
            scanError = nil
        }
        // A `.denied` item publishes ZERO components (the frozen coherence
        // shape): every consumer reads them as "deletion frees these", and a
        // denied/boundary-bearing target frees nothing. The boundary case's
        // measured floor rides the scanError message instead.
        let deletable = state != .denied

        // Dual canonicalization: `requestedURL` keeps the unresolved
        // discovered spelling (the deletion input), the identity is the
        // canonical parent + UNRESOLVED leaf — and the id derives from the
        // identity so a rescan through a different spelling yields the same
        // id.
        let identity = provider.resolveTargetKeepingLeaf(
            candidate.artifactDirectory
        )
        let record = RootScanRecord(
            requestedURL: candidate.artifactDirectory,
            resolvedURL: identity,
            status: state == .denied ? .deniedUnmeasured : .measured
        )

        let days = daysSinceNewestContent(report.newestContentDate)
        let item = ReclaimableItem(
            id: ReclaimableItem.stableID(
                scannerID: Self.registeredID, canonicalPath: identity.path
            ),
            scannerID: Self.registeredID,
            displayName: candidate.artifactDirectory.lastPathComponent,
            exactBytes: deletable ? report.exactAllocatedBytes : 0,
            estimatedUpToBytes: deletable ? report.estimatedUpToBytes : 0,
            logicalBytes: Self.publishedLogicalBytes(
                deletable: deletable, report: report
            ),
            itemCount: deletable ? report.itemCount : 0,
            // DISPLAY ONLY (destructive-target rule) — and the identity the
            // binding record resolves to, per the validator's
            // display-identity rule.
            url: identity,
            declaredDisplayPath: Self.displayPath(
                of: candidate.artifactDirectory, home: home
            ),
            rootRecords: [record],
            state: state,
            scanError: scanError,
            // The selection TRIPLE, read off the matched rule row — policy
            // is data (D3/R15), never re-derived here.
            risk: candidate.rule.risk,
            evidence: Self.evidence(for: candidate, days: days),
            rebuildNote: nil,
            // The artifact dir ITSELF is deleted (fn-4.5 wires the deletion
            // path); a target missing at clean time surfaces as the
            // cleaner's item-keyed error, never a skip.
            action: .removeItem,
            admission: .containerItem(
                // The WINNING declared origin-root spelling, verbatim: the
                // validator string-compares it against this scanner's
                // declared `trustedContainerRoots`.
                originContainer: candidate.originRoot,
                // The UNRESOLVED artifact spelling — leaf never resolved.
                requestedTargetURL: candidate.artifactDirectory
            ),
            defaultSelected: candidate.rule.defaultSelected,
            automaticCleanEligible: candidate.rule.automaticCleanEligible,
            // Staleness is UNKNOWABLE when the walk dated no content (an
            // empty or wholly-denied tree) — nil, never a false "fresh".
            isStale: days.map { NodeModulesItem.isStale(daysSinceModified: $0) }
        )
        return (item, identity.path)
    }

    /// The as-built `NodeModulesScanner` logical-bytes predicate, MATCHED
    /// VERBATIM (`NodeModulesScanner.swift:618-619`): publish iff the item is
    /// deletable AND logical exceeds measured. That is the only divergence
    /// direction worth showing — deletion frees LESS than the apparent size
    /// (the 57.1G-logical vs 31G-allocated sparse `target/` field case);
    /// block rounding makes logical < allocated for ordinary trees, which is
    /// noise. Denied items publish no figure at all (the frozen `.denied`
    /// coherence shape). Cross-scanner JSON consistency wins over any
    /// threshold formula.
    static func publishedLogicalBytes(
        deletable: Bool, report: SizeReport
    ) -> Int64? {
        deletable && report.logicalBytes > report.measuredBytes
            ? report.logicalBytes : nil
    }

    /// The classified impediment for a boundary-bearing candidate, cloned
    /// from the as-built doctrine: `.other` is the honest EXISTING kind (a
    /// boundary is neither TCC nor BSD permissions, and no grant lifts it),
    /// the message NAMES the boundary, and when the walk measured readable
    /// content beside it that floor rides the message — because the item's
    /// byte components must stay zero.
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

    // MARK: - Staleness + evidence (R10)

    /// Days between the tree's newest REGULAR-FILE content date (bounded by
    /// the SAME sizing walk — never a second traversal) and this scan's
    /// "now". nil when no regular file's date could be read.
    private func daysSinceNewestContent(_ date: Date?) -> Int? {
        guard let date else { return nil }
        return Calendar.current
            .dateComponents([.day], from: date, to: now()).day
    }

    /// Human evidence: the artifact dir, the MARKER that proved it, and an
    /// age phrase — "target/ beside Cargo.toml; last build 34 days ago".
    /// The marker-inside shape reads "containing" instead of "beside"
    /// (`env/ containing pyvenv.cfg`). Age variants are total: unknown dates
    /// say so rather than implying freshness, and a same-day or
    /// future-dated tree reads "today" rather than a negative age.
    static func evidence(
        for candidate: BuildArtifactCandidate, days: Int?
    ) -> String {
        let name = candidate.artifactDirectory.lastPathComponent
        let relation: String
        switch candidate.rule.shape {
        case .markerSibling: relation = "beside"
        case .markerInside: relation = "containing"
        }
        return "\(name)/ \(relation) \(candidate.marker); "
            + lastBuildPhrase(days: days)
    }

    private static func lastBuildPhrase(days: Int?) -> String {
        guard let days else { return "last build date unknown" }
        if days <= 0 { return "last build today" }
        if days == 1 { return "last build 1 day ago" }
        return "last build \(days) days ago"
    }

    // MARK: - Output order (R10 — deterministic and TOTAL)

    /// `allocatedBytes` desc, then display name asc byte-wise, then the
    /// canonical IDENTITY PATH asc byte-wise as the FINAL tie-breaker.
    ///
    /// The last key is what makes the order total: equal-size equal-name
    /// ties are common (many empty or identically-sized `target`/
    /// `node_modules` dirs) and must never depend on traversal or completion
    /// order. Identity paths are unique after the canonical-identity
    /// collapse, so the comparator is a strict total order. Stale-first is
    /// expressed via `isStale` + GUI sort, never a second order here.
    private static func ordered(
        _ emissions: [(item: ReclaimableItem, identityPath: String)]
    ) -> [ReclaimableItem] {
        emissions.sorted { lhs, rhs in
            if lhs.item.allocatedBytes != rhs.item.allocatedBytes {
                return lhs.item.allocatedBytes > rhs.item.allocatedBytes
            }
            if lhs.item.displayName != rhs.item.displayName {
                return lhs.item.displayName.utf8
                    .lexicographicallyPrecedes(rhs.item.displayName.utf8)
            }
            return lhs.identityPath.utf8
                .lexicographicallyPrecedes(rhs.identityPath.utf8)
        }.map(\.item)
    }

    // MARK: - Display

    /// The declared display spelling: the artifact's unresolved path,
    /// home-shortened to `~` on a PATH-COMPONENT boundary (a sibling that
    /// merely string-prefixes the home path — `/Users/d-other` vs
    /// `/Users/d` — must never render as `~-other/…`, least of all beside a
    /// destructive `.removeItem` action).
    private static func displayPath(of url: URL, home: URL) -> String {
        let path = url.path
        let homePath = home.path
        if path == homePath { return "~" }
        let prefix = homePath.hasSuffix("/") ? homePath : homePath + "/"
        guard path.hasPrefix(prefix) else { return path }
        return "~/" + path.dropFirst(prefix.count)
    }
}
