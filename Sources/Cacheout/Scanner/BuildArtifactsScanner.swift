/// # BuildArtifactsScanner — Rule Matching → Items (fn-4.3, R1/R2/R4/R10/R13/R15)
///
/// The scanner CORE: consume fn-4.2's `ProjectTreeWalker` events, match
/// fn-4.1's `BuildArtifactRules`, prune matched dirs via consumer verdicts,
/// collapse cross-walk overlap with the canonical-identity item dedupe (D7),
/// size what survives, derive staleness and evidence, and emit
/// validator-coherent `ReclaimableItem`s in a deterministic TOTAL order.
///
/// NOT here (deliberately): any UI. The valuables gate (fn-4.4) and the
/// pre-delete revalidator declaration (fn-4.8) landed BEFORE conformance on
/// purpose; fn-4.5 adds the one-line `extension BuildArtifactsScanner:
/// SpaceScanner {}` at the foot of this file plus the `production(devRoots:)`
/// registration — so from the FIRST moment a `build_artifacts` item is
/// addressable it is already revalidator-enforced (no enforcement gap, R17).
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
///    prefixes, never string `hasPrefix` (PathGuard doctrine) — UNLESS the
///    ancestor cannot REACH the descendant at all (`ancestorCannotReach`):
///    a mount boundary between them (review r3), or an unenumerable
///    directory on the chain such as a matched artifact dir at mode `0111`
///    (review r7). The drop exists to stop double-counting and nested
///    deletion, and either impediment already stops both (the ancestor's
///    sizing counts nothing past it and its removal cannot enumerate past it
///    either), so past one the drop only suppresses a reclaimable inner item
///    in favour of an outer one that is `.denied` for that very impediment.
/// 2. **Canonical-identity collapse** — candidates sharing one identity path
///    (`resolveTargetKeepingLeaf`) collapse to ONE item; the DEEPEST
///    (most-specific) origin root wins, byte-wise `originRoot.path` breaking
///    ties. Both roots are declared, so either satisfies the validator's
///    origin binding — determinism is what matters, and the more specific
///    root is the user's deliberate addition.
/// Sizing runs AFTER the collapse: one artifact is never measured twice.
///
/// ## The post-walk pass proves CONTAINMENT (PR #457 review r6)
/// Phase 3 runs after the ENTIRE walk, on candidates that are nothing but a
/// URL — and it used to re-derive every one of them from that absolute path:
/// a kind gate, a sizing, a valuables probe, and later a delete-time re-probe,
/// four independent re-resolutions of a spelling whose ancestors a concurrent
/// writer INSIDE the user's dev root can re-point in between. That is the
/// ancestor swap the walks themselves were hardened against, arriving through
/// the handoff instead: the walker held a vetted `SecureDirectory` for the
/// parent and this file discarded it. Because the valuables probe's output is
/// the acknowledgement token's ONLY preimage, the swap produced a non-nil
/// token over a foreign tree — a value that AUTHORIZES A DELETION.
///
/// So the walk's root anchors are RETAINED (`didAnchorRoot`) and phase 3
/// re-reaches each candidate by single-component `openat` from the root
/// descriptor it has held since admission (`anchoredArtifactDirectory`).
/// Safety is CONTAINMENT IN A HELD PARENT INODE, never a recorded identity —
/// a recorded identity cannot help, since a swap landing before the vetting
/// stat makes the "vetted" value the foreign object's already. Descriptor
/// cost: one per admitted dev root for the scan's duration, plus two
/// transients per descent. What the descent refuses, what it deliberately
/// does not, and what remains path-based (the sizer) are stated on
/// `anchoredArtifactDirectory` and in `DirectorySizer`'s header.
///
/// ## The census orders phase 3 (review r7)
/// Within one candidate the sizing runs BEFORE the valuables probe, because
/// the sizing walk is also that candidate's EXHAUSTIVE CENSUS and the probe's
/// entry budget is derived from it (`ValuablesProbeBudget`). A fixed budget
/// stranded the largest real trees permanently — incomplete ⇒ tokenless ⇒
/// filtered out of the GUI clean set and refused by the identical bounded
/// delete-time revalidation, for ever, on every re-scan. Ordering only:
/// both reads already happened here, and the probe is descriptor-anchored, so
/// neither one's safety depends on which runs first.
///
/// ## Item mapping (R10/R13/R15)
/// Cloned VERBATIM from the candidate truth table of the retired
/// `NodeModulesScanner` (subsumed by this scanner in fn-4.5, source deleted
/// in fn-4.7) and from `OrphanedCachesScanner`'s
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
    /// `[a-z0-9_]+`. Registered by `SpaceScannerRuntime.production(devRoots:)`
    /// (fn-4.5) — the SAME composition change that unregistered
    /// `NodeModulesScanner`.
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
    /// The valuables-probe ENTRY BOUND POLICY (fn-4.4; review r7) — ONE value
    /// consumed by BOTH faces of this scanner (the scan-time probe below and
    /// the `preDeleteRevalidator` this instance declares), so scan-time and
    /// delete-time bounds cannot drift. Injectable so tests can pin a fixed
    /// bound and prove the fail-closed truncation arm without
    /// hundred-thousand-file fixtures. See `ValuablesProbeBudget` for why the
    /// production policy is proportionate rather than a constant.
    private let valuablesProbeBudget: ValuablesProbeBudget
    /// Injected clock for staleness — a PROVIDER (not a `Date`) because the
    /// scanner is long-lived and each scan dates content against its own
    /// "now" (the `OrphanedCachesScanner` precedent).
    private let now: @Sendable () -> Date

    init(
        home: URL,
        devRoots: DevRootsResolution,
        provider: FileSystemIdentityProvider = FileSystemIdentityProvider(),
        maxDepth: Int = ProjectTreeWalker.defaultMaxDepth,
        valuablesProbeBudget: ValuablesProbeBudget = .censusProportionate(
            floor: ValuablesDetector.defaultProbeEntryLimit
        ),
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
        self.valuablesProbeBudget = valuablesProbeBudget
        self.now = now
    }

    // MARK: - Protocol surface (the `SpaceScanner` conformance is at the
    // foot of this file — these members ARE its witnesses)

    var id: String { Self.registeredID }
    var displayName: String { "Project Build Artifacts" }

    /// The KEPT effective dev roots, declared spellings verbatim — the union
    /// of these is what extends delete-time admission, and REGISTRATION is
    /// the only thing that does. Nothing item-side can widen it. Roots the
    /// R16 policy rejected are absent here by construction (they rode
    /// `devRoots.issues` instead), and PathGuard re-applies that same policy
    /// at admission, so an unsafe root cannot admit even if it reached this
    /// declaration.
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
        //
        // …and the walk's ROOT ANCHORS are RETAINED (PR #457 review r6). The
        // walker held an open, admitted, vetted descriptor for every root and
        // used to drop it the moment the recursion unwound, which left phase 3
        // below re-deriving every candidate from an ABSOLUTE PATH — four
        // re-resolutions of a spelling whose ancestors a concurrent writer
        // inside the user's own dev root (a `build.rs`, an npm postinstall)
        // can re-point in between. Keeping the anchor is what lets phase 3
        // prove containment instead of re-resolving. See
        // `anchoredArtifactDirectory` for the descent and the bound.
        var candidates: [BuildArtifactCandidate] = []
        var rootAnchors: [String: SecureDirectory] = [:]
        let walker = ProjectTreeWalker(
            home: home, pathGuard: pathGuard, provider: provider
        )
        let walkIssues = walker.walk(
            roots: devRoots.keptRoots,
            maxDepth: maxDepth,
            includeProtectedRoots: context.includeProtectedRoots,
            consumers: [{ event in
                Self.consume(event, into: &candidates)
            }],
            didAnchorRoot: { root, anchor in
                rootAnchors[root.path] = anchor
            }
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

            // THE CONTAINMENT RE-PROOF (PR #457 review r6), which REPLACES the
            // fresh `lstat` kind gate this pass used to open with. That gate
            // asked "is the object at this SPELLING still a directory?" — a
            // question about a path, answered by re-resolving every ancestor
            // of it, which is precisely what an ancestor swap subverts: the
            // gate, the sizer, the valuables probe and the delete-time
            // re-probe each re-resolved the same spelling independently, and a
            // symlink dropped in at `dev/proj` between the walk and here sent
            // all four somewhere else. The valuables probe's answer enters the
            // acknowledgement-token preimage, so that swap manufactured a
            // NON-NIL token over a tree the artifact dir does not contain.
            //
            // The question asked now is the doctrine's: is this subject
            // REACHABLE BY CONTAINMENT from the root descriptor we have held
            // open and vetted since admission? It is answered by walking down
            // to it one single-component `openat` at a time, so no ancestor is
            // ever named to the kernel as part of a longer path.
            switch Self.anchoredArtifactDirectory(
                candidate, rootAnchors: rootAnchors, provider: provider
            ) {
            case .vanished:
                // Gone, or no longer a directory reached by that name from
                // the root: the same answer the walker's matcher gives on a
                // re-scan, and the fail-closed one — nothing listed, nothing
                // offered, no token. This UNIFIES the old gate's absent arm
                // with its replaced arm, deliberately: the absent arm used to
                // emit a zero-byte `.empty` item for a directory that is not
                // there, which offers the user a row whose only possible
                // outcome is a clean-time ENOENT.
                continue

            case .obstructed(let report):
                // We could not re-prove containment for a reason that is NOT
                // a replacement (permissions, a mount that appeared over the
                // path, a descriptor we could not characterise). Never a
                // silent drop and never a silent trust: a classified, denied,
                // unmeasured item with an INCOMPLETE (therefore tokenless)
                // disclosure — clearable by fixing the impediment and
                // re-scanning.
                emissions.append(reclaimableItem(
                    from: candidate, report: report, disclosure: .incomplete
                ))

            case .anchored(let anchor):
                // SIZE FIRST (review r7), because the sizing walk is also the
                // subject's EXHAUSTIVE CENSUS and the probe's entry budget is
                // derived from it. Ordering only: both reads were already
                // happening in this iteration, and the probe is anchored, so
                // nothing about either one's safety depends on which runs
                // first.
                //
                // `.deletionTarget`, never `.scanRoot`: the sizing subject IS
                // the deletion target, so the identity doctrine applies to it
                // — canonical parent chain, leaf NEVER resolved.
                //
                // RESIDUAL, stated rather than hidden: this walk is still
                // path-based (`FileManager.enumerator`), so it is the one
                // phase-3 read an ancestor swap landing AFTER the descent
                // above can still redirect. What that buys an attacker is
                // BYTES, DATES and DENIAL CLASSIFICATIONS — figures the item
                // displays. It cannot mint a token (the disclosure above is
                // descriptor-anchored and is the token's sole preimage), it
                // cannot authorize a deletion, and it cannot move the deletion
                // target, which stays the unresolved spelling the cleaner
                // re-admits and the revalidator re-proves. The item's IDENTITY
                // path (and therefore its id and display url) is
                // `resolveTargetKeepingLeaf` and shares that residual exactly:
                // a swap after this point can misname the row. `F_GETPATH` on
                // the held anchor would close it and would also change the
                // identity doctrine for every scanner — a separate decision,
                // not a rider on this fix.
                let report = sizer.measure(
                    at: candidate.artifactDirectory, mode: .deletionTarget
                )
                // THE VALUABLES GATE, on the HELD descriptor. This is the
                // output that authorizes a deletion, so it is the one that
                // must never be re-derived from a path — and the bound it
                // spends is PROPORTIONATE to its subject rather than a
                // constant, so an ordinary large `node_modules` is PROVEN
                // instead of stranded (see `ValuablesProbeBudget`).
                //
                // The census above is the STARTING bound only (review r8): it
                // comes from a PATH-based walk that truncates where this
                // descriptor-anchored one does not — past `PATH_MAX` the sizer
                // stops with ENAMETOOLONG while the probe walks on — so twice
                // it can be an undercount, and an undercount used as the ONLY
                // bound made a STATIC tree deterministically incomplete,
                // tokenless, and falsely reported as "changing". What
                // finishes the walk is the doubling, which is derived from the
                // bound actually spent and so cannot be undercounted.
                //
                // The anchor is reused across passes: `ValuablesProbeWalk`
                // enumerates through `openat(fd, ".")` descriptions of its
                // own, never the anchor's, and holds only a reference to it.
                let probe = { (entryLimit: Int) in
                    ValuablesDetector.probe(
                        at: candidate.artifactDirectory, root: anchor,
                        provider: provider, entryLimit: entryLimit
                    )
                }
                let start = valuablesProbeBudget.limit(
                    census: report.enumeratedEntries
                )
                let disclosure = valuablesProbeBudget.escalating(
                    probe(start), spent: start, probe
                )
                emissions.append(reclaimableItem(
                    from: candidate, report: report, disclosure: disclosure
                ))
                // The anchor dies here, at the end of its candidate — the
                // phase-3 descriptor cost is per-candidate, never cumulative.
            }
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

    // MARK: - Containment re-proof for the post-walk pass (review r6)

    /// What re-establishing containment for one candidate produced.
    enum AnchoredArtifact {
        /// The artifact dir, OPEN and reached by single-component descent
        /// from the retained root anchor.
        case anchored(SecureDirectory)
        /// Not there any more under that name, or no longer a directory: a
        /// replacement or a benign vanish. Produces NO item — exactly what a
        /// re-scan would produce, and the fail-closed answer.
        case vanished
        /// Containment could not be re-proven for an impediment that is not a
        /// replacement. Carries the pre-filled report the denied item is
        /// mapped from, so the classification runs through the same seam every
        /// other denial does.
        case obstructed(SizeReport)
    }

    /// Re-reach `candidate.artifactDirectory` from the descriptor the walk
    /// opened for `candidate.originRoot` and this scan has held ever since.
    ///
    /// ## Why a descent and not a re-open
    /// Re-opening the artifact dir by its absolute path — even with
    /// `O_NOFOLLOW` — proves nothing: `O_NOFOLLOW` guards only the FINAL
    /// component, so every ancestor between the dev root and the artifact dir
    /// is still resolved by name at that instant, and any one of them may have
    /// become a symlink since the walk listed it. Re-opening the dev ROOT by
    /// path has the same defect one level up. Only a chain of
    /// single-component `openat`s from a descriptor that was never re-resolved
    /// establishes that the object we end up holding is the one the walk's
    /// spelling names — proof by CONTAINMENT, not by comparing a recorded
    /// identity (a recorded identity cannot help: if the swap preceded the
    /// vetting stat, the "vetted" value is already the foreign object's).
    ///
    /// ## What it refuses
    /// - a component swapped for a SYMLINK — `openat` with
    ///   `O_NOFOLLOW | O_DIRECTORY` reports ENOTDIR (measured on this OS);
    /// - a component swapped for a FILE or a special — ENOTDIR likewise;
    /// - a component that vanished — ENOENT;
    /// - a MOUNT that appeared anywhere along the chain — the descriptor's own
    ///   `f_fsid`/`st_dev` against the root anchor's, the same two signals the
    ///   walker descends by, and the arm no path spelling can be aliased past;
    /// - a candidate whose artifact path does not COMPONENT-WISE extend its
    ///   origin root, or whose origin root was never anchored (structurally
    ///   unreachable — every candidate came from a walk of that root — and
    ///   therefore refused rather than assumed).
    ///
    /// ## What it deliberately does NOT refuse
    /// An ancestor re-bound to a DIFFERENT REAL DIRECTORY that is still inside
    /// the dev root passes, and should: the chain is genuinely symlink-free,
    /// the object we hold is genuinely what the deletion target names, and the
    /// delete-time rule re-proof re-checks the marker on that same subject. It
    /// is a stale-provenance case, not an escape.
    ///
    /// ## Descriptor bound
    /// TWO live at once during the descent (the frame below and the child
    /// being opened), plus the ONE returned anchor, plus the retained root
    /// anchors. The chain is a loop, not a recursion, and each parent is
    /// released as soon as its child is open — depth costs syscalls, never
    /// descriptors. Retained root anchors are one per ADMITTED dev root, live
    /// from admission until `scan` returns; with the probe's own window
    /// (≤ 64, 48 in the shipped `.app`) the scan's peak is
    /// `keptRoots + window + 3`. A dev-root list long enough to exhaust
    /// `RLIMIT_NOFILE` surfaces as EMFILE here — a classified, visible,
    /// clearable obstruction on the affected items, never a silent trust.
    static func anchoredArtifactDirectory(
        _ candidate: BuildArtifactCandidate,
        rootAnchors: [String: SecureDirectory],
        provider: FileSystemIdentityProvider
    ) -> AnchoredArtifact {
        guard let rootAnchor = rootAnchors[candidate.originRoot.path] else {
            return .obstructed(Self.obstruction(
                at: candidate.artifactDirectory,
                detail: "the dev root this artifact was found under is no "
                    + "longer open for this scan"
            ))
        }

        // COMPONENT-WISE containment of the spelling, never a string prefix
        // (`/a/bc` must never read as inside `/a/b` — PathGuard doctrine).
        let rootComponents = candidate.originRoot.pathComponents
        let artifactComponents = candidate.artifactDirectory.pathComponents
        guard artifactComponents.count >= rootComponents.count,
              Array(artifactComponents.prefix(rootComponents.count))
                == rootComponents
        else {
            return .obstructed(Self.obstruction(
                at: candidate.artifactDirectory,
                detail: "this artifact directory is not spelled inside the "
                    + "dev root it was discovered under"
            ))
        }

        var anchor = rootAnchor
        var logical = candidate.originRoot
        for name in artifactComponents.dropFirst(rootComponents.count) {
            // MANDATORY before any syscall: a multi-component name defeats
            // `O_NOFOLLOW` outright (measured — `openat` opens a foreign file
            // through a symlinked intermediate component).
            guard FileSystemIdentityProvider.isSafeComponent(name) else {
                return .obstructed(Self.obstruction(
                    at: candidate.artifactDirectory,
                    detail: "'\(name)' is not a single safe path component"
                ))
            }
            logical.appendPathComponent(name)

            let fd = provider.openChildDirectory(
                inDirectory: anchor.fd, named: name, logical: logical
            )
            guard fd >= 0 else {
                let code = errno
                // ENOENT: gone. ENOTDIR: this name is no longer a directory —
                // swapped for a symlink, a file, or raced. ELOOP is not
                // reachable through `O_DIRECTORY` on this OS but is the same
                // event where it is. All three are "the matcher would not
                // match this any more", which is a drop, not a denial.
                if code == ENOENT || code == ENOTDIR || code == ELOOP {
                    return .vanished
                }
                return .obstructed(Self.obstruction(
                    at: logical, errno: code,
                    detail: "couldn't re-open '\(name)' from the dev root: "
                        + String(cString: strerror(code))
                ))
            }
            guard let child = SecureDirectory(fd: fd, provider: provider)
            else {
                return .obstructed(Self.obstruction(
                    at: logical,
                    detail: "couldn't characterise the directory descriptor "
                        + "for '\(name)'"
                ))
            }
            // MOUNT BOUNDARY ON THE CHAIN, on the CHILD'S OWN DESCRIPTOR. A
            // volume mounted over any component between the dev root and the
            // artifact dir since the walk would otherwise be descended into
            // silently. `f_fsid` is the arm that carries this: `st_dev` is
            // identical for every path in an APFS volume group (measured: `/`
            // and `/System/Volumes/Data` both report 16777230), so a firmlink-
            // shaped mount is invisible to a device comparison, and no path
            // spelling can be trusted here at all.
            guard child.mount.fsidMajor == rootAnchor.mount.fsidMajor,
                  child.mount.fsidMinor == rootAnchor.mount.fsidMinor,
                  child.mount.device == rootAnchor.mount.device
            else {
                var report = SizeReport()
                report.rootMountBoundary = true
                report.mountBoundaries = [logical]
                return .obstructed(report)
            }
            anchor = child
        }
        return .anchored(anchor)
    }

    /// A one-denial report for a containment impediment, classified on the
    /// SAME frozen taxonomy every other denial uses (EPERM → TCC, EACCES →
    /// BSD permissions, everything else a metadata failure).
    private static func obstruction(
        at url: URL, errno code: Int32 = EIO, detail: String
    ) -> SizeReport {
        var report = SizeReport()
        let kind: SizeDenial.Kind
        switch code {
        case EPERM: kind = .tcc
        case EACCES: kind = .permission
        default: kind = .metadata
        }
        report.denials.append(
            SizeDenial(url: url, kind: kind, detail: detail)
        )
        return report
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
            for length in 1..<max(components.count, 1) {
                let ancestor = Array(components.prefix(length))
                guard allKeys.contains(componentKey(ancestor)) else { continue }
                // AN ANCESTOR THAT CANNOT REACH ITS DESCENDANT DOES NOT DROP
                // IT (review r3 for the mount arm, review r7 for the
                // unreadable arm). The drop exists for exactly two reasons —
                // double-counting and nested deletion — and BOTH need the
                // ancestor's own walk to actually arrive at the descendant.
                // Where it cannot, the drop buys nothing and costs the user
                // everything: the ancestor is denied for the very same
                // impediment while the descendant — reachable under its OWN
                // configured root — would have been cleanable, and the only
                // row left is an undeletable one.
                //
                // Deletability itself cannot be consulted here (the drop
                // precedes sizing, by design: sizing after the collapse is
                // what stops one artifact being measured twice), so the
                // REACHABILITY of the descendant from the ancestor is
                // consulted instead — see `ancestorCannotReach`.
                guard !ancestorCannotReach(
                    ancestor: ancestor, descendant: components,
                    provider: provider
                ) else { continue }
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

    /// Is the descendant candidate UNREACHABLE from the ancestor candidate —
    /// by sizing, and by deletion?
    ///
    /// TWO impediments answer yes, and they are the same shape: whatever
    /// stops the ancestor's own walk on the chain between them stops the
    /// double-count and the nested deletion the drop exists to prevent.
    ///
    /// - **A MOUNT BOUNDARY** anywhere from the ancestor down to the
    ///   descendant (review r3). The house rule VERBATIM, no third notion
    ///   invented: device-id change against the ANCESTOR, plus the `statfs`
    ///   mount-root check that catches the same-`st_dev` firmlink mounts a
    ///   device comparison is blind to (`DirectorySizer.swift:287`,
    ///   `ProjectTreeWalker.swift:376`, `ValuablesDetector.swift`). The sizer
    ///   records the boundary and skips its subtree uncounted; the cleaner
    ///   refuses any tree containing one whole
    ///   (`CacheCleaner.swift:875,970`).
    /// - **AN UNENUMERABLE DIRECTORY** on that same chain — the ancestor
    ///   itself, or any directory strictly between it and the descendant
    ///   (review r7). Mode `0111` is the field shape: SEARCHABLE, so a root
    ///   configured beneath it resolves and walks perfectly well, but
    ///   UNREADABLE, so the ancestor's sizing yields a `.denied` item that
    ///   counted none of the descendant's bytes and its removal cannot
    ///   enumerate — and therefore cannot delete — anything past the barrier.
    ///   No mount separates the two, so the boundary arm above never saw
    ///   this, and the inner candidate was dropped in favour of an outer row
    ///   that can never be cleaned.
    ///
    /// The DESCENDANT's own enumerability is deliberately NOT consulted: it
    /// is the subject, not a step on the chain, and an unreadable subject is
    /// the ordinary denied-item case the sizer classifies.
    ///
    /// FAIL-SAFE FOR NON-EXISTENT PATHS, exactly as the boundary arm always
    /// was: a path that is not a directory at all reports nothing, so the drop
    /// stands and injected-synthetic candidates over paths no filesystem
    /// fixture can produce behave as they always did.
    ///
    /// This is a DISPLAY decision — which candidates survive to be sized —
    /// and never an authorization: every survivor is still re-proven by the
    /// containment descent, the sizer, the anchored valuables probe, and the
    /// delete-time revalidator. Called ONLY for a pair the lexical test
    /// already matched, so its cost is bounded by the depth between two
    /// overlapping candidates and is paid only when overlapping roots
    /// actually produced one.
    private static func ancestorCannotReach(
        ancestor: [String],
        descendant: [String],
        provider: FileSystemIdentityProvider
    ) -> Bool {
        guard let root = ancestor.first else { return false }
        var current = URL(fileURLWithPath: root)
        for component in ancestor.dropFirst() {
            current.appendPathComponent(component)
        }
        let ancestorDevice = provider.deviceID(of: current)
        // The ancestor's OWN readability first: it is the first link in the
        // chain, and the one the field case (a matched artifact dir at mode
        // 0111) actually breaks.
        if cannotEnumerate(current, provider: provider) { return true }
        let steps = descendant.count - ancestor.count
        for (offset, component) in
            descendant.dropFirst(ancestor.count).enumerated() {
            current.appendPathComponent(component)
            let device = provider.deviceID(of: current)
            if ancestorDevice != nil, device != nil, device != ancestorDevice {
                return true
            }
            if provider.isMountPoint(current) { return true }
            // STRICTLY between the two only — the last step IS the descendant.
            if offset < steps - 1,
               cannotEnumerate(current, provider: provider) {
                return true
            }
        }
        return false
    }

    /// Does an EXISTING directory at `url` refuse enumeration? A path that is
    /// absent, or is not a directory, answers `false` — "we could not tell"
    /// must never be read as "the ancestor cannot reach it", or every
    /// synthetic candidate would void its own drop.
    private static func cannotEnumerate(
        _ url: URL, provider: FileSystemIdentityProvider
    ) -> Bool {
        guard provider.kind(of: url) == .directory else { return false }
        return !provider.canEnumerateDirectory(url)
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
    ///
    /// ## The valuables gate (fn-4.4, R3/R17)
    /// EVERY item runs the bounded no-follow probe and carries its disclosure
    /// plus the `requiresPreDeleteRevalidation` marker — uniformly, including
    /// denied ones (a denied item is refused later for other reasons; the
    /// marker's meaning is "this item must be re-inspected", not "this item is
    /// deletable"). Any hit OR an incomplete probe forces the item off safe,
    /// forces selection false, and appends the warning evidence.
    ///
    /// ## The rule proof (review r3)
    /// EVERY item also carries its `BuildArtifactProof` — the matched rule
    /// SHAPE, structurally — because the marker, not the contents, is the
    /// safety property these ambiguous directory names have. Valuables are
    /// the SECONDARY property: re-checking them while trusting the rule is
    /// what let a `Cargo.toml`-less, repurposed `target/` full of ordinary
    /// files delete on a clean, complete probe.
    private func reclaimableItem(
        from candidate: BuildArtifactCandidate, report: SizeReport,
        disclosure: ValuablesDisclosure
    ) -> (item: ReclaimableItem, identityPath: String) {
        let hasBoundary = report.rootMountBoundary
            || !report.mountBoundaries.isEmpty
        let measuredAnything = report.itemCount > 0 || report.measuredBytes > 0

        let state: ScanState
        let scanError: ScanError?
        if hasBoundary {
            state = .denied
            scanError = Self.mountBoundaryScanError(
                from: report, candidate: candidate.artifactDirectory
            )
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

        // THE VALUABLES GATE runs in `scan`, on the HELD artifact-dir
        // descriptor, and arrives here as a value: this seam must never
        // re-derive it from a path, because a disclosure re-read through a
        // swapped ancestor is a token minted over someone else's tree. An
        // item whose containment could not be re-proven is handed
        // `.incomplete` — tokenless, forced to review, never "clean".
        // Sorted into the ONE canonical order inside the probe, so nothing
        // here (or downstream) re-sorts.
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
            // is data (D3/R15), never re-derived here — then NARROWED (never
            // widened) by the valuables gate.
            risk: Self.forcedRisk(
                candidate.rule.risk, disclosure: disclosure
            ),
            evidence: Self.evidence(
                for: candidate, days: days, disclosure: disclosure
            ),
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
            // Belt and braces (R3): v1's rows are all `false` already, so
            // this AND is a no-op TODAY — and load-bearing the day a row is
            // promoted. A valuable-bearing or un-inspectable item must never
            // arrive pre-selected.
            defaultSelected: candidate.rule.defaultSelected
                && !disclosure.forcesReview,
            automaticCleanEligible: candidate.rule.automaticCleanEligible,
            // Staleness is UNKNOWABLE when the walk dated no content (an
            // empty or wholly-denied tree) — nil, never a false "fresh".
            isStale: days.map {
                ReclaimableItem.isStale(daysSinceModified: $0)
            },
            // Structural DISCLOSURE (never consent) + the scanner-agnostic
            // revalidation marker: EVERY build-artifact item carries the
            // probe, so every one is marked (R17/D8).
            valuablesDisclosure: disclosure,
            requiresPreDeleteRevalidation: true,
            // The MATCHED RULE, carried STRUCTURALLY (review r3): the marker
            // is the safety property these ambiguous directory names have,
            // and the revalidator re-proves THIS shape at delete time rather
            // than guessing a rule from the name.
            artifactProof: BuildArtifactProof(
                shape: candidate.rule.shape, marker: candidate.marker
            )
        )
        return (item, identity.path)
    }

    // MARK: - Valuables gate (fn-4.4, R3/R17)

    /// DELETE-TIME REVALIDATION entry point (fn-4.8 wires it into the
    /// cleaner's chokepoint seam), following the
    /// `OrphanedCachesScanner.preDeleteUserDataProbe` precedent (`:571`)
    /// exactly: the SAME bounded core with the PRODUCTION caps, so scan-time
    /// and delete-time inspection bounds cannot drift. Reports the CURRENT
    /// probe's valuables (canonical order) + completeness — fn-4.8 compares
    /// that against the item's authorization entry and refuses fail-closed.
    ///
    /// Scan-time inspection alone is not enough: `ContainerSnapshot` binds the
    /// dev ROOT's identity, not the artifact dir's contents, so a DMG can
    /// appear after the scan (or mid-build).
    ///
    /// Kind gating mirrors the scan path and fn-3's precedent:
    /// - real directory → the bounded no-follow probe;
    /// - symlink / regular file / special → no contents of their own; the
    ///   deletion removes the leaf as-is, never a target's tree;
    /// - absent → nothing to disclose (the deletion path surfaces its own
    ///   ENOENT — the probe must not preempt it);
    /// - unprobeable → fail closed (incomplete ⇒ unauthorizable, tokenless).
    ///
    /// That gate now lives INSIDE the shared core (PR #457 review r3), which
    /// is why this face is a straight call-through: it used to be the only
    /// face that had it, and a check on one face of a two-faced walk is the
    /// scan/delete drift the one-core rule exists to prevent. This entry
    /// point stays because it NAMES the delete-time face — the production
    /// caps are the core's defaults, so the two inspections' bounds and now
    /// their kind gating are the same code, not the same intent.
    ///
    /// ## The budget is proportionate HERE TOO (review r7)
    /// The scan-time face has a census in hand before it probes (the sizing of
    /// the same candidate); this face is handed a bare URL and has none, so it
    /// earns one only when it needs one. It probes at the policy's FIRST-PASS
    /// bound, and ONLY when that bound — and nothing else — is what stopped
    /// the walk does it census the same subject and probe again
    /// proportionately, doubling from there until the walk finishes. A tree
    /// big enough to exhaust the floor pays one extra enumeration; every
    /// ordinary tree pays nothing. Without this the two faces would drift in
    /// the one direction that matters: the scan would prove a large
    /// `node_modules` clean and mint its token, and the delete-time
    /// revalidation would refuse it forever at a bound the scan no longer
    /// uses.
    ///
    /// The census is derived from a PATH-based walk, and that walk TRUNCATES
    /// WHERE THIS ONE DOES NOT (review r8): past `PATH_MAX` the sizer stops
    /// with ENAMETOOLONG after a few dozen entries while the descriptor-
    /// anchored probe walks the whole tree. So the census is taken for what it
    /// honestly is — a STARTING HINT that finishes an ordinary large tree in
    /// one extra pass — and the guarantee comes from the DOUBLING that
    /// follows it, which is derived from the bound actually spent and can
    /// therefore grow straight past a census that undercounts. Without that,
    /// a static tree with an over-long path was refused at every bound, for
    /// ever, with the one remedy ("let it settle and retry") that could not
    /// work.
    ///
    /// A wrong census is still safe in the only direction that matters: it can
    /// only make this probe do more work, never disclose less or authorize
    /// more (the probe's own reads are what they always were).
    static func preDeleteValuablesProbe(
        at target: URL, provider: FileSystemIdentityProvider,
        budget: ValuablesProbeBudget = .censusProportionate(
            floor: ValuablesDetector.defaultProbeEntryLimit
        )
    ) -> ValuablesDisclosure {
        let probe = { (entryLimit: Int) in
            ValuablesDetector.probe(
                at: target, provider: provider, entryLimit: entryLimit
            )
        }
        var bound = budget.firstPass
        var result = probe(bound)
        // The census is EARNED, not paid for up front: only a walk stopped by
        // the budget — and by nothing else — is worth an extra enumeration.
        guard result.incompleteness == .entryBudget else { return result }
        let census = DirectorySizer(provider: provider)
            .measure(at: target, mode: .deletionTarget).enumeratedEntries
        if let escalated = budget.escalation(census: census) {
            bound = escalated
            result = probe(bound)
        }
        return budget.escalating(result, spent: bound, probe)
    }

    // MARK: - Pre-delete revalidator (fn-4.8, R17/D8)

    /// This scanner's DELETE-TIME revalidator declaration. Read by fn-4.5's
    /// one-line `SpaceScanner` conformance (and, until it exists, by the
    /// TEST-ONLY adapter) — so `build_artifacts` items are enforced from
    /// their first addressable moment: the seam lands BEFORE registration on
    /// purpose, and registration never opens an enforcement gap.
    var preDeleteRevalidator: PreDeleteRevalidator? {
        // THIS instance's budget policy, never the bare default: the two
        // faces of one scanner spend the same bound by construction.
        Self.preDeleteRevalidator(
            provider: provider, budget: valuablesProbeBudget
        )
    }

    /// The revalidator VALUE, constructible without a scanner instance.
    ///
    /// APPLICABILITY (the pure predicate — no filesystem access, no state):
    /// EVERY build-artifact item. The scan probes them all, marks them all
    /// (`requiresPreDeleteRevalidation: true`), and none of them may be
    /// deleted on scan-time inspection alone — the artifact dir's CONTENTS
    /// are what a valuable appears in, and no snapshot binds those.
    ///
    /// VERDICT — the RULE first, then the contents (review r3). The item's
    /// structural `artifactProof` is re-proven against the CURRENT filesystem
    /// before anything is probed, because the marker is the PRIMARY safety
    /// property (`target/` and `build/` are ambiguous names; the rule table
    /// leans on the sibling/interior marker precisely because of that) while
    /// valuables are the secondary one. A revalidator that re-checked only
    /// the contents was trusting the property it exists to guard: a
    /// `Cargo.toml` deleted and the `target/` repurposed into ordinary files
    /// probes CLEAN and COMPLETE, and every one of those files would have
    /// been deleted. A missing or unprovable proof refuses fail-closed, and
    /// the refusal is CLEARABLE (restore the marker, or re-scan — a re-scan
    /// simply stops producing the item, since the walker's matcher rejects
    /// the same subject for the same reason).
    ///
    /// Then, from the CURRENT delete-time probe (production caps, the SAME
    /// bounded core the scan used) and the item's OWN authorization entry:
    /// - INCOMPLETE probe → refuse; the payload carries what was still seen
    ///   (a floor on the warning, never a basis for authorization) and NO
    ///   token — the uniform R17 rule that an unfinished inspection is
    ///   unauthorizable;
    /// - COMPLETE + EMPTY current set, when the item DISCLOSED valuables at
    ///   scan time → the VANISHED-SET refusal: refuse ONCE with no token
    ///   (there is nothing to acknowledge); the caller re-scans and retries
    ///   WITHOUT acknowledgement, since the item is then valuables-free;
    /// - COMPLETE + EMPTY current set with nothing disclosed → `.allow`
    ///   (the ordinary build directory);
    /// - COMPLETE + NON-EMPTY current set → the token recomputed from THIS
    ///   probe must EQUAL the authorization entry; anything else (a missing
    ///   entry, a stale entry, an entry for another item) refuses and hands
    ///   back the fresh token with the current valuables.
    ///
    /// Acknowledgement is never inferred: the item's structural
    /// `valuablesDisclosure` is read ONLY to detect the vanished set, never
    /// as consent.
    static func preDeleteRevalidator(
        provider: FileSystemIdentityProvider,
        budget: ValuablesProbeBudget = .censusProportionate(
            floor: ValuablesDetector.defaultProbeEntryLimit
        )
    ) -> PreDeleteRevalidator {
        PreDeleteRevalidator(
            requiresRevalidation: { _ in true },
            revalidate: { item, authorization in
                guard case .containerItem(_, let target) = item.admission else {
                    // Structurally unreachable (the validator and the
                    // cleaner both refuse a `.removeItem` item without the
                    // container descriptor) — fail closed rather than
                    // assume a target.
                    return .refuse(
                        reason: "refused: a build-artifact item without a "
                            + "container-item target cannot be re-inspected "
                            + "before deletion",
                        valuables: [], acknowledgementToken: nil
                    )
                }
                // THE RULE RE-PROOF, FIRST (review r3). The marker is the
                // PRIMARY safety property — these directory names are
                // ambiguous and only the sibling/interior marker separates
                // build output from someone's data — so it is re-proven
                // before the secondary (valuables) property is even probed.
                // Checking valuables while TRUSTING the rule is what let a
                // repurposed `target/` full of ordinary files delete on a
                // clean probe.
                guard let proof = item.artifactProof else {
                    // Structurally unreachable: this scanner stamps the proof
                    // on every item it emits. A mapping regression that
                    // dropped it must not delete on an unproven rule.
                    return .refuse(
                        reason: "\(target.path): this item carries no record "
                            + "of the build-artifact rule that matched it, so "
                            + "the rule cannot be re-proven before deletion — "
                            + "refused; re-scan required",
                        valuables: [], acknowledgementToken: nil
                    )
                }
                if let lost = proof.failureDetail(
                    target: target, provider: provider
                ) {
                    return .refuse(
                        reason: "\(target.path): \(lost) — this directory is "
                            + "no longer proven to be build output, so it is "
                            + "refused, nothing deleted; restore it or "
                            + "re-scan",
                        valuables: [], acknowledgementToken: nil
                    )
                }
                let current = preDeleteValuablesProbe(
                    at: target, provider: provider, budget: budget
                )
                guard current.probeComplete else {
                    // The two causes get two refusals: they differ in what
                    // clears them, and one message for both is what made
                    // "re-scan required" the printed advice for a condition
                    // no re-scan could change.
                    return .refuse(
                        reason: "\(target.path): "
                            + incompleteProbeRefusal(current.incompleteness),
                        valuables: current.valuables,
                        acknowledgementToken: nil
                    )
                }
                guard !current.valuables.isEmpty else {
                    let disclosed =
                        item.valuablesDisclosure?.valuables.isEmpty == false
                    guard disclosed else { return .allow }
                    return .refuse(
                        reason: "\(target.path): the release artifacts this "
                            + "item disclosed are no longer there — refused "
                            + "once; re-scan and clean again (nothing is "
                            + "left to acknowledge)",
                        valuables: [], acknowledgementToken: nil
                    )
                }
                // COMPLETE + non-empty: the token is derived from THIS
                // probe, so any membership/path/size/identity/mtime change
                // since the acknowledgement rotates it.
                let token = ValuablesDisclosure.acknowledgementToken(
                    scannerID: item.scannerID, itemID: item.id,
                    valuables: current.valuables, probeComplete: true
                )
                if let token, let authorization, authorization == token {
                    return .allow
                }
                let names = current.valuables.map(\.name)
                    .joined(separator: ", ")
                return .refuse(
                    reason: "\(target.path): release artifacts (\(names)) are "
                        + "inside this directory at delete time and are not "
                        + "covered by an acknowledgement — refused, nothing "
                        + "deleted",
                    valuables: current.valuables,
                    acknowledgementToken: token
                )
            }
        )
    }

    /// The delete-time refusal text for each incompleteness CAUSE, with the
    /// remedy that actually applies to it.
    ///
    /// - An OBSTRUCTION is cleared by fixing the impediment (permissions, a
    ///   mount, a foreign-encoded basename) — a re-scan then finishes.
    /// - The ENTRY BUDGET surviving every DOUBLING the policy grants means the
    ///   tree outgrew each of them while it was being inspected. A retry,
    ///   unaided, genuinely can clear that — so it says so, instead of
    ///   demanding a re-scan that cannot change anything.
    ///
    /// The "or could not be counted" hedge this message used to carry is gone
    /// (review r8): a subject the census could not count is exactly the case
    /// the doubling now finishes, so keeping the hedge would name a cause that
    /// can no longer produce this refusal — and pair it with a retry that
    /// would not have helped it.
    static func incompleteProbeRefusal(
        _ cause: ValuablesDisclosure.ProbeIncompleteness?
    ) -> String {
        switch cause {
        case .entryBudget:
            return "the release-artifact inspection ran out of its entry "
                + "budget — this directory is growing faster than it can be "
                + "read — refused, nothing deleted; retry when it settles"
        case .obstruction, .none:
            return "couldn't fully re-inspect the directory for release "
                + "artifacts at delete time — refused (an inspection that "
                + "could not finish is treated like a change since scan); "
                + "re-scan required"
        }
    }

    /// The forcing rule: a valuable hit OR an incomplete probe pushes a rule
    /// row OFF safe. Already-review (and caution) rows stay where they are —
    /// the gate NARROWS, never widens.
    static func forcedRisk(
        _ ruleRisk: RiskLevel, disclosure: ValuablesDisclosure
    ) -> RiskLevel {
        guard disclosure.forcesReview, ruleRisk == .safe else {
            return ruleRisk
        }
        return .review
    }

    /// The retired `NodeModulesScanner`'s logical-bytes predicate, MATCHED
    /// VERBATIM when that scanner was subsumed: publish iff the item is
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
    ///
    /// NON-OPTIONAL by construction (review r1): the `.denied` state this
    /// arm produces REQUIRES a scanError — a nil would malform the whole
    /// outcome at the validator and publish a silent zero-byte denied item.
    /// The sizer records the root in `mountBoundaries` whenever it sets
    /// `rootMountBoundary`, so the candidate fallback (the
    /// `OrphanedCachesScanner` precedent) normally never fires — it exists
    /// so no future sizer change can strip the message.
    private static func mountBoundaryScanError(
        from report: SizeReport, candidate: URL
    ) -> ScanError {
        let boundary = report.mountBoundaries.first ?? candidate
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
    ///
    /// The valuables gate APPENDS to that base (fn-4.4), in the pinned epic
    /// format and the ONE canonical order — never re-sorted here, never
    /// re-derived from prose downstream:
    ///
    ///     … — WARNING: contains Murmur_0.1.7_aarch64.dmg (42 MB) — verify
    ///     before deleting
    ///
    /// An INCOMPLETE probe carries the same weight as a hit and says so; when
    /// both apply, both clauses ride the one warning.
    static func evidence(
        for candidate: BuildArtifactCandidate,
        days: Int?,
        disclosure: ValuablesDisclosure = .clean
    ) -> String {
        let name = candidate.artifactDirectory.lastPathComponent
        let relation: String
        switch candidate.rule.shape {
        case .markerSibling: relation = "beside"
        case .markerInside: relation = "containing"
        }
        let base = "\(name)/ \(relation) \(candidate.marker); "
            + lastBuildPhrase(days: days)
        guard let warning = valuablesWarning(disclosure) else { return base }
        return base + " — " + warning
    }

    /// The warning clause set, or nil when the probe finished clean.
    static func valuablesWarning(_ disclosure: ValuablesDisclosure) -> String? {
        guard disclosure.forcesReview else { return nil }
        var clauses: [String] = []
        if !disclosure.valuables.isEmpty {
            let named = disclosure.valuables.map { valuable in
                "\(valuable.name) (\(ByteCountFormatter.sharedFile.string(fromByteCount: valuable.identity.allocatedBytes)))"
            }
            clauses.append("contains " + named.joined(separator: ", "))
        }
        // The CAUSE decides the clause: an obstruction and an exhausted entry
        // budget are cleared by different actions, so they may not share one
        // sentence (the flattening that let "re-scan" stand as the advice for
        // a bound no re-scan could move).
        switch disclosure.incompleteness {
        case .entryBudget:
            clauses.append(
                "couldn't finish inspecting this directory for release "
                    + "artifacts — it holds more entries than the inspection "
                    + "budget"
            )
        case .obstruction:
            clauses.append(
                "couldn't fully inspect this directory for release artifacts"
            )
        case .none:
            break
        }
        return "WARNING: " + clauses.joined(separator: "; ")
            + " — verify before deleting"
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

// MARK: - SpaceScanner conformance (fn-4.5, R6/R7)

/// PRODUCTION CONFORMANCE — the whole of it. Every requirement is already a
/// member above: the slug `id`, `displayName`, `trustedContainerRoots` (the
/// resolution's `keptRoots`, declared spellings verbatim), the
/// `preDeleteRevalidator` declaration fn-4.8's seam captures at
/// registration, and `scan(context:)`.
///
/// This empty extension is the epic's "implement the protocol + register,
/// nothing else" (R4) taken literally, and its ORDER against fn-4.8 is
/// deliberate (round 13/14): the revalidator declaration existed BEFORE this
/// line, so the first moment a `build_artifacts` item is addressable is also
/// the first moment it is fail-closed re-inspected before deletion — there
/// is no task ordering in which an unenforced build-artifact item can be
/// listed, addressed, or deleted.
extension BuildArtifactsScanner: SpaceScanner {}
