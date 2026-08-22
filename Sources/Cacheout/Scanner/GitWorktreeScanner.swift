/// # GitWorktreeScanner — discovery, tiers, emission (fn-5.5, R6/R7/R8/R10)
///
/// The per-item `SpaceScanner` (slug `git_worktrees`) that turns fn-5.1's git
/// plumbing, fn-5.2's staleness gates and fn-5.3's composite reclaim action
/// into `ReclaimableItem`s. It walks the configured dev roots as a
/// `ProjectTreeWalker` CONSUMER (fn-4.2), fetches each repository's porcelain
/// listing exactly once, assesses the linked worktrees, and emits TWO kinds of
/// item and nothing else:
///
/// - **stale candidates** — one item per merged-clean linked worktree, action
///   `.gitWorktreeReclaim` in stale mode;
/// - **the repo-level prune item** — ONE per repository with orphaned admin
///   directories, disclosing the PROVABLY-COMPLETE set the execution will
///   remove — and that set is EXACTLY what it removes: fn-5.4 deletes those
///   directories one by one and never runs a repository-wide
///   `git worktree prune`, whose set git would re-enumerate after every gate
///   had already answered (D14).
///
/// ## Discovery: `.git` is SEEN, never descended
///
/// The walker hard-prunes `.git` while still LISTING it in the event's
/// entries, which is exactly the discrimination this scanner needs: a `.git`
/// entry of kind DIRECTORY makes its parent a MAIN checkout, a REGULAR FILE
/// makes it a LINKED worktree, and a symlink is neither (lstat no-follow is
/// the discriminator — the classifier is never casefolded; only protective
/// refusals fold, per house doctrine). The retired NodeModulesScanner's
/// name-based skip list is deliberately NOT inherited: it contained `.git`,
/// which is one of the three ways the 23 GB field case stayed invisible.
/// Hidden parents ARE traversed (the field case lived under
/// `.claude/worktrees/`).
///
/// ## TWO TCC gates, both silent by policy (epic rounds 6-7)
///
/// 1. **The root gate** — `ScanContext.includeProtectedRoots` rides into the
///    walker, which skips protected roots on `.automatic` scans. Reused, never
///    re-derived: `ProjectTreeWalker.isProtectedRoot` is the ONE
///    prefix-under-protected-ancestor classification on the CANONICAL path.
/// 2. **The SECONDARY gate** — a repository's git data and its parent working
///    directory can sit OUTSIDE every dev root (a worktree inside a root whose
///    parent lives elsewhere), and `git -C …` traverses them. So before ANY
///    scan-time git command, the paths that command traverses are classified
///    with the SAME helper; on `.automatic` a protected path silently DEFERS
///    the affected work — no git runs against it and no issue is published
///    (D17 neutralizes locks and fsmonitor, not filesystem privacy). The gate
///    has a DISCOVERY-time face too: the gitdir resolver must follow a
///    worktree's `.git` pointer before that pointer's target is knowable, so on
///    `.automatic` it runs on a provider that reports deferred paths as absent
///    (`DeferringIdentityProvider`) — a git-argv assertion alone would never
///    have caught a protected admin directory being READ.
///
/// Policy skips stay SILENT (they are scanned when the user asks); genuine
/// access denials during the walk remain VISIBLE classified issues. The two
/// are never conflated.
///
/// ## THREE distinct identity keys (epic Phase 5 / F3)
///
/// | key | preimage | why |
/// |---|---|---|
/// | repo dedupe + fetch-once | canonical porcelain FIRST-RECORD path | one listing per repository |
/// | stale item `stableID` | canonical WORKTREE path | one item per worktree |
/// | prune item `stableID` | canonical ADMIN-CONTAINER path | one item per repository |
///
/// Conflating them (the earlier "dedupe AND stableID both on the parent-repo
/// path" scheme) gave every multi-item repository duplicate ids, which the
/// validator rejects WHOLESALE — one collision malforms the entire outcome.
///
/// A cheap PRE-FETCH grouping runs first, keyed on the canonical COMMON GIT
/// DIRECTORY: every worktree and main checkout of one repository resolves to
/// the same common git dir (the resolver's `commondir` for a linked worktree,
/// the lstat-proven `.git` directory for a main checkout), so the group IS the
/// repository and the listing is fetched once per group — including when the
/// walk reaches the repository through several root spellings. The
/// authoritative repo key stays the canonical first-record path, checked after
/// the fetch.
///
/// ## D15 — assessed NON-candidates are OMITTED from items
///
/// There is no display-only admission arm, and mapping a measured-but-refused
/// worktree to `.denied` would lie about what the scan did. Non-candidates
/// therefore produce NO item; their assessment rides `GitWorktreeAssessmentLog`
/// through the injected observer (default: one `os.Logger` line per scan plus
/// one per omitted worktree) — observable, never a lying row.
///
/// ## D13 — the mutation scope is bound to ONE declared root
///
/// Both modes mutate the PARENT repository's admin data, and since PR #460
/// codex r5 BOTH do it the same way — this process removes the directories
/// itself. Stale mode removes the checkout under
/// `DepthSafeRemoval`/`TrashDisposal` and then, gated, that worktree's own
/// admin entry; prune mode removes the disclosed admin directories directly.
/// There is no `worktree remove` argv and no `worktree prune` argv anywhere
/// in the app (PR #460 codex r1 / C4, r5 / D1). The contrast this paragraph
/// used to draw between the two modes' mutation MECHANISMS no longer exists;
/// the SCOPE argument below never depended on it. So an item may be emitted
/// only when the worktree target, the parent working directory AND
/// the resolver-carried admin container all lie inside the SAME declared dev
/// root — the parent alone may EQUAL the root (a
/// dev root that IS a repository is legal), everything else is a STRICT
/// descendant. A worktree outside every root, or a parent/admin container
/// outside the worktree's root, becomes a `.containerRefused` issue and NEVER
/// an item (D3: no display-only admission exists, and emitting one malforms
/// the whole outcome).
///
/// Because `GitWorktreeReclaimPlan.violation` checks containment LEXICALLY on
/// the verbatim spellings (a second resolution at validation time would race
/// the filesystem), every plan path is RE-SPELLED under the declared root
/// after containment is proven canonically — the same construction the walker
/// performs when it appends entry names to the declared root spelling. That is
/// what keeps an alias-declared root (`/tmp/dev` over `/private/tmp/dev`)
/// emitting valid items instead of malforming the outcome.
///
/// ## The admin container is DERIVED, never reconstructed
///
/// `<parentGitDir>/worktrees` — always, in both tiers, over a `parentGitDir`
/// obtained ONLY from the resolver's `commondir` resolution or from an
/// lstat-proven `.git` DIRECTORY, and in both cases CROSS-VALIDATED against
/// the porcelain first record by fn-5.1's own `crossValidate`. A
/// `<workingDir>/.git/worktrees` reconstruction appears nowhere: a bare
/// parent's git directory does not live at `<wd>/.git`, and a linked worktree
/// of a bare main is not itself `bare`, so no gate would catch the mis-pathing
/// (D13 revised).

import Foundation
import os

// MARK: - The secondary gate's discovery-time face

/// A provider that reports every DEFERRED path as absent.
///
/// It exists for one job: the gitdir resolver has to FOLLOW a worktree's `.git`
/// pointer to learn which repository the worktree belongs to, and the pointer
/// can name a path under a TCC-protected ancestor. The path is unknowable
/// before the pointer is read, so the gate cannot precede the resolution — it
/// is applied INSIDE it, by making the deferred paths look like they are not
/// there. The resolver probes each pointer target before it opens anything, so
/// on an automatic scan nothing under a protected ancestor is ever opened,
/// enumerated or read.
///
/// What DOES still happen on a deferred path is `canonicalize` — `realpath(3)`,
/// the same operation fn-4's pinned protected-root classification performs on a
/// protected root before skipping it (`ProjectTreeWalker.isProtectedRoot`
/// canonicalizes first, by design). The house doctrine already draws the line
/// there, and this wrapper does not move it.
///
/// `.absent` rather than `.failed` deliberately: a policy deferral is not a
/// problem to report (the walker skips a vanished entry quietly for the same
/// reason), and every consumer reads absence as "not attributable" — which is
/// precisely what a deferral means here.
private final class DeferringIdentityProvider: FileSystemIdentityProvider {

    private let wrapped: FileSystemIdentityProvider
    private let isDeferred: (URL) -> Bool

    init(
        wrapping wrapped: FileSystemIdentityProvider,
        isDeferred: @escaping (URL) -> Bool
    ) {
        self.wrapped = wrapped
        self.isDeferred = isDeferred
        super.init()
    }

    override func probeKind(of url: URL) -> KindProbe {
        isDeferred(url) ? .absent : wrapped.probeKind(of: url)
    }

    override func identity(of url: URL) -> Identity? {
        isDeferred(url) ? nil : wrapped.identity(of: url)
    }

    override func leafMetadata(of url: URL) -> LeafMetadata? {
        isDeferred(url) ? nil : wrapped.leafMetadata(of: url)
    }

    override func linkCount(of url: URL) -> UInt64? {
        isDeferred(url) ? nil : wrapped.linkCount(of: url)
    }

    override func isMountPoint(_ url: URL) -> Bool {
        isDeferred(url) ? false : wrapped.isMountPoint(url)
    }

    // Path arithmetic is delegated UNCHANGED so an injected test provider's
    // aliasing still flows through (and so the deferral above is the only
    // behavioural difference).
    override func realPath(of path: String) -> String? { wrapped.realPath(of: path) }

    override func canonicalize(_ url: URL) -> URL { wrapped.canonicalize(url) }
}

// MARK: - Discovery

/// What a `.git` entry proved about the directory that holds it. Both kinds
/// come from ONE lstat no-follow probe the walker already performed.
enum GitWorktreeDiscoveryKind: Equatable, Sendable {
    /// `.git` is a DIRECTORY — the holder is a main checkout, and that
    /// directory IS the repository's git directory.
    case mainCheckout
    /// `.git` is a regular FILE — the holder is a linked worktree whose
    /// pointer the fn-5.1 resolver validates bidirectionally.
    case linkedWorktree
}

/// One directory the walk proved to be a checkout, in walk order.
struct GitWorktreeDiscovery: Equatable, Sendable {
    /// Spelled under the DECLARED root (the walker builds every URL by
    /// appending entry names to the declared spelling).
    let directory: URL
    let kind: GitWorktreeDiscoveryKind
}

// MARK: - Assessment observability (D15)

/// What the scan ASSESSED, whether or not an item came of it.
///
/// D15 omits assessed non-candidates from the item list, so this is the
/// surface that keeps the omission honest: a dirty or unmerged worktree is
/// still visibly assessed, with its canonical four-clause evidence, instead of
/// silently vanishing.
struct GitWorktreeAssessmentLog: Equatable, Sendable {

    struct Entry: Equatable, Sendable {
        let worktreePath: URL
        let isCandidate: Bool
        /// False for every non-candidate (D15) AND for a candidate whose
        /// containment was refused (D13).
        let emittedItem: Bool
        /// The assessor's canonical four-clause evidence string.
        let evidence: String
    }

    var entries: [Entry] = []

    var assessedCount: Int { entries.count }
    var candidateCount: Int { entries.filter(\.isCandidate).count }
    var emittedCount: Int { entries.filter(\.emittedItem).count }
    /// Assessed, not a candidate, therefore deliberately item-less (D15).
    var omittedNonCandidateCount: Int { entries.filter { !$0.isCandidate }.count }

    /// Non-candidate entries, in encounter order.
    var omittedNonCandidates: [Entry] { entries.filter { !$0.isCandidate } }
}

// MARK: - Scanner

/// `@unchecked Sendable` under the house scanner discipline (the
/// `BuildArtifactsScanner` precedent): every stored property is an immutable
/// `let`, the provider/guard/sizer/resolver/mapper hold no mutable state, the
/// runner is `Sendable` by protocol, and the stored closures are `@Sendable`.
struct GitWorktreeScanner: @unchecked Sendable {

    // MARK: Pinned constants

    /// Stable scanner slug — the CLI address prefix (`git_worktrees:<item-id>`),
    /// the GUI section key, and the `stableID` preimage's scanner half.
    /// Registered by fn-5.6; nothing here registers itself.
    static let registeredID = "git_worktrees"

    /// The DEFAULT assessment observer. `os.Logger` rather than the cleaner's
    /// deletion log on purpose: this is scan-time telemetry about work that
    /// produced no item, not a record of anything destructive.
    private static let logger = Logger(
        subsystem: "com.cacheout.app", category: registeredID
    )

    // MARK: Stored configuration

    /// The dev roots this scan walks plus the classified config issues their
    /// resolution produced — stored at CONSTRUCTION (fn-4's R16 contract): a
    /// policy-rejected persisted root is never registered and never walked,
    /// yet its issue rides EVERY outcome.
    let devRoots: DevRootsResolution
    /// Anchor for display shortening and for BOTH TCC gates' protected-ancestor
    /// determination (injectable — zero real-`$HOME` reads in tests).
    let home: URL

    private let provider: FileSystemIdentityProvider
    /// This scanner's OWN guard, whose `containerRoots` are exactly its
    /// declared `trustedContainerRoots` (epic D2: each scanner constructs its
    /// own; scan-time admission is read-only and snapshot-free).
    private let pathGuard: PathGuard
    private let sizer: DirectorySizer
    /// fn-5.1's SHARED oracle→admin mapper — the SAME component fn-5.4 calls at
    /// delete time. A second mapping implementation would let detection and
    /// execution disagree about which admin directories the removal destroys.
    private let mapper: GitWorktreeAdminMapper
    /// The SHARED runner. fn-5.6 hands this scanner the runtime's ONE instance:
    /// fn-5.1's availability cache is instance-scoped, so a second runner would
    /// probe (and cache) independently.
    private let runner: any GitCommandRunning
    private let assessor: WorktreeStalenessAssessor
    private let maxDepth: Int
    /// Per-invocation git budget; `nil` uses the runner's own scan default.
    private let gitTimeout: TimeInterval?
    /// Injected clock for staleness — a PROVIDER, not a `Date`: the scanner is
    /// long-lived and each scan dates content against its own "now".
    private let now: @Sendable () -> Date
    private let observeAssessments: @Sendable (GitWorktreeAssessmentLog) -> Void

    init(
        home: URL,
        devRoots: DevRootsResolution,
        runner: any GitCommandRunning,
        provider: FileSystemIdentityProvider = FileSystemIdentityProvider(),
        maxDepth: Int = ProjectTreeWalker.defaultMaxDepth,
        gitTimeout: TimeInterval? = nil,
        timeZone: TimeZone = .current,
        now: @escaping @Sendable () -> Date = { Date() },
        observeAssessments: (@Sendable (GitWorktreeAssessmentLog) -> Void)? = nil
    ) {
        self.home = home
        self.devRoots = devRoots
        self.runner = runner
        self.provider = provider
        self.pathGuard = PathGuard(
            home: home, containerRoots: devRoots.keptRoots, provider: provider
        )
        self.sizer = DirectorySizer(provider: provider)
        self.mapper = GitWorktreeAdminMapper(identity: provider)
        self.assessor = WorktreeStalenessAssessor(
            runner: runner, timeout: gitTimeout, timeZone: timeZone
        )
        self.maxDepth = maxDepth
        self.gitTimeout = gitTimeout
        self.now = now
        self.observeAssessments = observeAssessments ?? Self.defaultAssessmentObserver
    }

    // MARK: - Protocol surface (the conformance is at the foot of this file)

    var id: String { Self.registeredID }
    var displayName: String { "Stale Git Worktrees" }

    /// The KEPT effective dev roots, declared spellings VERBATIM — the
    /// validator's origin binding is exact string equality against these, and
    /// registration is the only thing that extends delete-time admission.
    var trustedContainerRoots: [URL] { devRoots.keptRoots }

    // MARK: - Scan

    /// One scan: walk → group → per-repository listing → assess → emit.
    ///
    /// Runs wherever its caller runs (never the main actor). Cancellation is
    /// checked between repositories and between records; partial results are
    /// returned rather than discarded.
    func scan(context: ScanContext) async -> ScanOutcome {
        // (1) WALK. The consumer only records `.git`-bearing directories; it
        // prunes NOTHING (the walker's own `.git` hard prune is the only prune
        // this scanner needs, and a name-based skip list is the anti-pattern
        // that made the field case invisible).
        var discoveries: [GitWorktreeDiscovery] = []
        let walker = ProjectTreeWalker(
            home: home, pathGuard: pathGuard, provider: provider
        )
        let walkIssues = walker.walk(
            roots: devRoots.keptRoots,
            maxDepth: maxDepth,
            includeProtectedRoots: context.includeProtectedRoots,
            consumers: [{ event in
                Self.consume(event, into: &discoveries)
            }]
        )

        // Config issues ride EVERY outcome (fn-4's R16 data path), then this
        // walk's per-root classified issues, then whatever the tiers add.
        var issues = devRoots.issues + walkIssues
        var emissions: [(item: ReclaimableItem, identityPath: String)] = []
        var log = GitWorktreeAssessmentLog()
        var processedRepoKeys = Set<String>()
        let bindings = rootBindings()
        // The resolver is PER-SCAN because the secondary gate is: on
        // `.automatic` it follows pointers through a provider that reports every
        // deferred path as absent (see `DeferringIdentityProvider`).
        let resolver = GitWorktreeGitdirResolver(identity: identityProvider(for: context))

        for group in Self.repositoryGroups(
            from: discoveries, resolver: resolver, provider: provider
        ) {
            if Task.isCancelled { break }
            let outcome = await process(
                group, context: context, bindings: bindings, resolver: resolver,
                processedRepoKeys: &processedRepoKeys,
                issues: &issues, emissions: &emissions, log: &log
            )
            switch outcome {
            case .processed:
                continue
            case .gitUnavailable:
                // D6/D12: a tool-less scan reporting zero findings is
                // indistinguishable from a clean machine, so EVERY item is
                // withdrawn and the unavailability is published instead. The
                // runner's availability verdict is instance-cached, so no
                // further repository could succeed anyway.
                observeAssessments(log)
                issues.append(Self.toolUnavailableIssue)
                return ScanOutcome(items: [], errors: issues)
            }
        }

        observeAssessments(log)
        return ScanOutcome(items: Self.ordered(emissions), errors: issues)
    }

    /// The FROZEN git-unavailable issue (D12 revised): the dedicated
    /// `.toolUnavailable` kind, a nil url (the problem is the toolchain, not a
    /// path — a fake path must never be invented) and a detail whose pinned
    /// prefix is "git unavailable".
    static let toolUnavailableIssue = ScanIssue(
        url: nil,
        kind: .toolUnavailable,
        detail: "git unavailable — the stale-worktree scan could not run git, "
            + "so it produced no results; a tool-less scan reporting zero "
            + "findings is indistinguishable from a clean machine"
    )

    // MARK: - Discovery consumer

    /// One walker event → its discoveries. Returns an EMPTY prune set: the
    /// walker already hard-prunes `.git`, and pruning anything else would hide
    /// the nested repositories and hidden parents this scanner exists to find.
    ///
    /// Static so the walk consumer captures no scanner state.
    private static func consume(
        _ event: ProjectTreeEvent, into discoveries: inout [GitWorktreeDiscovery]
    ) -> Set<String> {
        for entry in event.entries where entry.name == ".git" {
            // lstat identity is the discriminator — NEVER a casefolded name
            // match, and never a symlink (a symlinked `.git` is neither shape,
            // so it is not a checkout as far as this scanner is concerned).
            switch entry.kind {
            case .directory:
                discoveries.append(GitWorktreeDiscovery(
                    directory: event.directory, kind: .mainCheckout
                ))
            case .regularFile:
                discoveries.append(GitWorktreeDiscovery(
                    directory: event.directory, kind: .linkedWorktree
                ))
            case .symlink, .other:
                continue
            }
        }
        return []
    }

    // MARK: - Repository grouping (the PRE-FETCH half of the fetch-once rule)

    /// One repository's discovered checkouts, keyed on the canonical COMMON
    /// GIT DIRECTORY.
    struct RepositoryGroup: Equatable, Sendable {
        /// Canonical common git directory — the group key AND the single
        /// authority the admin container is derived from.
        let gitDirectory: URL
        /// Discovered checkouts of this repository, in walk order.
        let discoveries: [GitWorktreeDiscovery]
    }

    /// Group discoveries by the canonical common git directory they resolve
    /// to, so the porcelain listing is fetched ONCE per repository however many
    /// of its checkouts (or root spellings) the walk touched.
    ///
    /// A `.git` FILE that does NOT resolve to a validated worktree admin
    /// directory contributes NOTHING and produces NO issue. The resolution can
    /// fail in five ways — an unreadable/malformed pointer, a pointer to a
    /// non-directory, a pointer whose parent is not `worktrees` (the SUBMODULE
    /// shape: `<parent>/.git/modules/<name>`), a missing or non-regular
    /// back-link file, and a back-link that names a different worktree (the
    /// forged/stale shape) — and every one of them means the same thing HERE:
    /// this directory is not a linked worktree of a repository we can name, so
    /// it names no group. Nothing is suppressed by the silence: if the
    /// directory really is a worktree of a discoverable repository, that
    /// repository's own porcelain listing still reports it, and the failure is
    /// published THERE as a visible membership refusal (see `handle(record:)`).
    /// Publishing here instead would emit an issue for every checked-out
    /// submodule under every dev root on every scan.
    static func repositoryGroups(
        from discoveries: [GitWorktreeDiscovery],
        resolver: GitWorktreeGitdirResolver,
        provider: FileSystemIdentityProvider
    ) -> [RepositoryGroup] {
        var order: [String] = []
        var grouped: [String: (gitDirectory: URL, discoveries: [GitWorktreeDiscovery])] = [:]

        for discovery in discoveries {
            let gitDirectory: URL?
            switch discovery.kind {
            case .mainCheckout:
                // The entry lstat'd as a DIRECTORY named `.git`, which IS the
                // repository's git directory — an observation, not a
                // reconstruction (and cross-validated against the porcelain
                // first record before anything is derived from it).
                gitDirectory = provider.canonicalize(
                    discovery.directory.appendingPathComponent(".git")
                )
            case .linkedWorktree:
                gitDirectory = resolver
                    .adminDirectory(forWorktreeAt: discovery.directory)
                    .flatMap { resolver.commonGitDirectory(forAdminDirectory: $0) }
            }
            guard let gitDirectory else { continue }
            let key = gitDirectory.path
            if grouped[key] == nil {
                order.append(key)
                grouped[key] = (gitDirectory, [])
            }
            grouped[key]?.discoveries.append(discovery)
        }

        return order.compactMap { key in
            grouped[key].map {
                RepositoryGroup(gitDirectory: $0.gitDirectory, discoveries: $0.discoveries)
            }
        }
    }

    // MARK: - Per-repository processing

    private enum RepositoryOutcome {
        case processed
        /// git could not be run at all — the whole scan withdraws (D6/D12).
        case gitUnavailable
    }

    private func process(
        _ group: RepositoryGroup,
        context: ScanContext,
        bindings: [RootBinding],
        resolver: GitWorktreeGitdirResolver,
        processedRepoKeys: inout Set<String>,
        issues: inout [ScanIssue],
        emissions: inout [(item: ReclaimableItem, identityPath: String)],
        log: inout GitWorktreeAssessmentLog
    ) async -> RepositoryOutcome {
        // (a) SECONDARY TCC GATE, stage 1 — before the FIRST git command.
        //     `git -C <checkout> worktree list` follows the checkout's `.git`
        //     pointer INTO the common git directory, so both the `-C` target
        //     and the git directory are traversal-exposed here.
        if isDeferred(group.gitDirectory, context: context) {
            return .processed // silent by policy — scanned when user-initiated
        }
        let reachable = group.discoveries.filter {
            !isDeferred($0.directory, context: context)
        }
        // A main checkout is the friendliest `-C` target; a bare parent has
        // none, so its linked worktree is used instead.
        guard let listingTarget = (reachable.first { $0.kind == .mainCheckout }
                                   ?? reachable.first)?.directory else {
            return .processed // every reachable checkout is protected — deferred
        }

        // (b) THE ONE LISTING per repository. `-c gc.worktreePruneExpire=now`
        //     rides fn-5.1's shared oracle argv so the stale tier and the
        //     prune tier read the SAME answer git will act on (D10).
        let listing = await run(
            GitWorktreeOracle.listArguments(forRepositoryAt: listingTarget)
        )
        let stdout: Data
        switch listing.outcome {
        case .success(let data):
            stdout = data
        case .failure(let exitCode, let stderr):
            issues.append(ScanIssue(
                url: listingTarget, kind: .unreadable,
                detail: "git worktree list failed for this repository "
                    + "(\(GitCommandFailureSummary.describe(exitCode: exitCode, stderr: stderr)))"
                    + " — no worktrees of it were assessed"
            ))
            return .processed
        case .timeout:
            issues.append(ScanIssue(
                url: listingTarget, kind: .unreadable,
                detail: "git worktree list timed out for this repository — no "
                    + "worktrees of it were assessed"
            ))
            return .processed
        case .gitUnavailable:
            return .gitUnavailable
        }

        guard let inventory = GitWorktreeInventory.parse(stdout),
              let mainRecord = inventory.mainRecord else {
            issues.append(ScanIssue(
                url: listingTarget, kind: .unreadable,
                detail: "the porcelain -z listing for this repository could not "
                    + "be parsed faithfully — no worktrees of it were assessed"
            ))
            return .processed
        }

        // (c) SECONDARY TCC GATE, stage 2 — the parent working directory is
        //     the `-C` target of the D6 default-branch ladder and is only
        //     knowable AFTER the listing. It is checked HERE, before
        //     cross-validation, because cross-validation INSPECTS it
        //     (`<firstRecord>/.git`): on `.automatic` the deferring provider
        //     would report that path absent and the refusal below would publish
        //     a VISIBLE membership issue for what is actually a silent policy
        //     deferral. A protected parent defers the repository's REMAINING
        //     work entirely — every per-worktree conclusion below rests on an
        //     assessment we deliberately did not run, and the prune item's plan
        //     points git at this same deferred path.
        if isDeferred(mainRecord.path, context: context) { return .processed }

        // (d) CROSS-VALIDATION, fn-5.1's own rule (both branches — a bare repo
        //     has no `<bare>/.git`). Without it the group's git directory and
        //     the porcelain first record would be two unrelated claims, and the
        //     admin container derived from the former would mutate data the
        //     latter's `-C` target does not own.
        guard resolver.crossValidate(mainRecord: mainRecord, against: group.gitDirectory) else {
            issues.append(ScanIssue(
                url: listingTarget, kind: .unreadable,
                detail: "the porcelain first record '\(mainRecord.path.path)' "
                    + "could not be cross-validated against the resolved common "
                    + "git directory '\(group.gitDirectory.path)' — membership "
                    + "fails closed and no item is offered"
            ))
            return .processed
        }

        // (e) REPO DEDUPE on the canonical FIRST-RECORD path (the authoritative
        //     key; the git-directory grouping above is the fetch-once
        //     mechanism, not the identity).
        let parentRepoWorkingDir = mainRecord.path
        let repoKey = provider.canonicalize(parentRepoWorkingDir).path
        guard processedRepoKeys.insert(repoKey).inserted else { return .processed }

        // The ONE admin-container derivation: `<parentGitDir>/worktrees`,
        // matching `WorktreeMembership.parentAdminContainer` exactly. NEVER
        // `<workingDir>/.git/worktrees` — a bare parent's git directory does
        // not live there (D13 revised).
        let adminContainer = group.gitDirectory
            .appendingPathComponent(GitWorktreeGitdirResolver.adminContainerName)

        // (f) STALE TIER — driven by the porcelain records, which are git's own
        //     authority on what worktrees exist.
        for record in inventory.entries {
            if Task.isCancelled { return .processed }
            // The main record is structurally never a candidate (G1 refuses it
            // by definition), so it never pays for an assessment.
            if record.isMain { continue }
            // A prunable record has no checkout left to gate — the orphaned-
            // admin tier below owns that shape (the assessor refuses it for the
            // same reason).
            if record.isPrunable { continue }
            await handle(
                record: record, inventory: inventory,
                parentRepoWorkingDir: parentRepoWorkingDir,
                adminContainer: adminContainer,
                groupGitDirectory: group.gitDirectory,
                context: context, bindings: bindings, resolver: resolver,
                issues: &issues, emissions: &emissions, log: &log
            )
        }

        // (g) ORPHANED-ADMIN TIER.
        pruneTier(
            inventory: inventory,
            parentRepoWorkingDir: parentRepoWorkingDir,
            adminContainer: adminContainer,
            bindings: bindings,
            issues: &issues, emissions: &emissions
        )
        return .processed
    }

    // MARK: - Stale tier

    private func handle(
        record: GitWorktreeEntry,
        inventory: GitWorktreeInventory,
        parentRepoWorkingDir: URL,
        adminContainer: URL,
        groupGitDirectory: URL,
        context: ScanContext,
        bindings: [RootBinding],
        resolver: GitWorktreeGitdirResolver,
        issues: inout [ScanIssue],
        emissions: inout [(item: ReclaimableItem, identityPath: String)],
        log: inout GitWorktreeAssessmentLog
    ) async {
        // SECONDARY TCC GATE, stage 3: `git -C <worktree> status` traverses the
        // worktree itself.
        if isDeferred(record.path, context: context) { return }

        let worktreeIdentity = provider.resolveTargetKeepingLeaf(record.path)

        // D3: a worktree outside EVERY declared root can never be an item —
        // there is no display-only admission arm, and emitting one malforms the
        // whole outcome. It is refused BEFORE assessment: running git against a
        // path outside every root is exactly what the secondary gate exists to
        // limit, and no assessment of it could change the answer.
        guard !rootsStrictlyContaining(worktreeIdentity, in: bindings).isEmpty else {
            issues.append(ScanIssue(
                url: record.path, kind: .containerRefused,
                detail: "registered worktree '\(record.path.path)' is outside "
                    + "every configured dev root — it is never offered for "
                    + "removal (no display-only admission exists)"
            ))
            return
        }

        // MEMBERSHIP — the bidirectional back-link plus fn-5.1's first-record
        // cross-validation. A forged or stale pointer, and a `--separate-git-dir`
        // repository (git reports the EXTERNAL git dir as the first record, so
        // the non-bare branch finds no `<external>/.git`), both fail CLOSED
        // here, before any containment decision.
        guard let membership = resolver.membership(
            forWorktreeAt: record.path, in: inventory
        ) else {
            issues.append(ScanIssue(
                url: record.path, kind: .unreadable,
                detail: "worktree '\(record.path.path)' could not be attributed "
                    + "to its parent repository: the bidirectional gitdir "
                    + "back-link or the porcelain first-record cross-validation "
                    + "failed — membership fails closed and no item is offered"
            ))
            return
        }
        // The membership must describe the SAME repository the listing came
        // from; anything else means two claims about one worktree.
        guard provider.sameLocation(membership.parentGitDir, groupGitDirectory) else {
            issues.append(ScanIssue(
                url: record.path, kind: .unreadable,
                detail: "worktree '\(record.path.path)' resolves to common git "
                    + "directory '\(membership.parentGitDir.path)', not the "
                    + "listed repository's '\(groupGitDirectory.path)' — "
                    + "membership fails closed and no item is offered"
            ))
            return
        }

        // ASSESSMENT — runs even when containment will refuse the item (D13):
        // read-only git against a parent outside the roots is not gated by
        // `admitSearchRoot`, and the evidence is what makes the refusal
        // explicable. Only the SECONDARY TCC gate can suppress it.
        let result = await assessor.assess(
            entry: record, parentRepoWorkingDir: parentRepoWorkingDir
        )
        let assessment: WorktreeAssessment
        switch result {
        case .assessed(let value):
            assessment = value
        case .prunableNotAssessed:
            // Unreachable: prunable records were filtered out above. Handled
            // rather than force-unwrapped so the routing stays total.
            return
        }

        // The admin ENTRY (`<adminContainer>/<id>`) that fn-5.4's
        // post-removal prune gate identifies as the ONE entry it may sweep.
        guard let adminEntry = resolver.adminDirectory(forWorktreeAt: record.path) else {
            issues.append(ScanIssue(
                url: record.path, kind: .unreadable,
                detail: "worktree '\(record.path.path)' has no resolvable admin "
                    + "directory under '\(adminContainer.path)' — no item is "
                    + "offered"
            ))
            log.entries.append(GitWorktreeAssessmentLog.Entry(
                worktreePath: record.path, isCandidate: assessment.isCandidate,
                emittedItem: false, evidence: assessment.evidence
            ))
            return
        }

        // D13 CONTAINMENT: the worktree, the parent (or-equal) AND the admin
        // container/entry must all sit inside ONE declared root.
        let scope = mutationScope(
            parentRepoWorkingDir: parentRepoWorkingDir,
            strictPaths: [
                worktreeIdentity,
                provider.resolveTargetKeepingLeaf(adminContainer),
                provider.resolveTargetKeepingLeaf(adminEntry),
            ],
            bindings: bindings
        )
        guard case .bound(let root, let parent, let strict) = scope else {
            if case .unbound(let reason) = scope {
                issues.append(ScanIssue(
                    url: record.path, kind: .containerRefused,
                    detail: "worktree '\(record.path.path)' is inside a "
                        + "configured dev root but \(reason) — git mutates the "
                        + "parent repository's admin data, so the whole "
                        + "mutation scope must share one declared root; the "
                        + "worktree was assessed but is never offered for "
                        + "removal"
                ))
            }
            log.entries.append(GitWorktreeAssessmentLog.Entry(
                worktreePath: record.path, isCandidate: assessment.isCandidate,
                emittedItem: false, evidence: assessment.evidence
            ))
            return
        }

        // D15: assessed NON-candidates are OMITTED from items entirely. Their
        // assessment stays observable through the log below.
        guard assessment.isCandidate else {
            log.entries.append(GitWorktreeAssessmentLog.Entry(
                worktreePath: record.path, isCandidate: false,
                emittedItem: false, evidence: assessment.evidence
            ))
            return
        }

        // THE IDENTITY THE DELETE-TIME GATE IS ARMED WITH (PR #460 codex r4,
        // D6). r3 captured this inode inside `staleItem` with no `guard let`,
        // so an `lstat` failure yielded nil and silently DISABLED R1b's
        // same-path-re-add check — while two universals elsewhere asserted
        // that could not happen. `lstat` can fail: EPERM under a protected
        // root, or the directory vanishing between the resolve above and the
        // plan build. NO ITEM IS OFFERED in that state, and the issue says
        // why. It CLEARS: the next scan re-stats.
        guard let adminEntryIdentity = provider.identity(of: strict[2]) else {
            issues.append(ScanIssue(
                url: record.path, kind: .unreadable,
                detail: "worktree '\(record.path.path)' has an admin directory "
                    + "at '\(strict[2].path)' that could not be identified "
                    + "(lstat failed), so the delete-time gate that tells a "
                    + "re-created checkout from this one could not be armed — "
                    + "no item is offered"
            ))
            log.entries.append(GitWorktreeAssessmentLog.Entry(
                worktreePath: record.path, isCandidate: true,
                emittedItem: false, evidence: assessment.evidence
            ))
            return
        }

        let emission = staleItem(
            worktreePath: strict[0], adminContainer: strict[1], adminEntry: strict[2],
            adminEntryIdentity: adminEntryIdentity,
            parentRepoWorkingDir: parent, declaredRoot: root.declaredRoot,
            assessment: assessment
        )
        emissions.append(emission)
        log.entries.append(GitWorktreeAssessmentLog.Entry(
            worktreePath: record.path, isCandidate: true,
            emittedItem: true, evidence: assessment.evidence
        ))
    }

    /// One stale candidate → one `ReclaimableItem`.
    ///
    /// State follows the as-built candidate truth table VERBATIM, with the
    /// MOUNT-BOUNDARY row on top: the cleaner refuses any tree containing a
    /// boundary, so the scan must never promise those bytes — `.denied`, ZERO
    /// reclaimable components, zero `itemCount`, and an `.other` scanError
    /// naming the boundary.
    private func staleItem(
        worktreePath: URL,
        adminContainer: URL,
        adminEntry: URL,
        adminEntryIdentity: FileSystemIdentityProvider.Identity,
        parentRepoWorkingDir: URL,
        declaredRoot: URL,
        assessment: WorktreeAssessment
    ) -> (item: ReclaimableItem, identityPath: String) {
        let report = sizer.measure(at: worktreePath, mode: .scanRoot)
        let hasBoundary = report.rootMountBoundary || !report.mountBoundaries.isEmpty
        let measuredAnything = report.itemCount > 0 || report.measuredBytes > 0

        let state: ScanState
        let scanError: ScanError?
        if hasBoundary {
            state = .denied
            scanError = Self.mountBoundaryScanError(from: report, candidate: worktreePath)
        } else if !report.denials.isEmpty {
            state = measuredAnything ? .partiallyDenied : .denied
            scanError = CacheScanner.deriveScanError(refusals: [], denials: report.denials)
        } else {
            state = measuredAnything ? .measured : .empty
            scanError = nil
        }
        let deletable = state != .denied

        let identity = provider.resolveTargetKeepingLeaf(worktreePath)
        let record = RootScanRecord(
            requestedURL: worktreePath,
            resolvedURL: identity,
            status: state == .denied ? .deniedUnmeasured : .measured
        )
        let days = daysSinceNewestContent(report.newestContentDate)

        let item = ReclaimableItem(
            id: ReclaimableItem.stableID(
                // KEY 2 of 3: the stale item preimages the canonical WORKTREE
                // path, never the parent-repo path (which every item of one
                // repository would share).
                scannerID: Self.registeredID, canonicalPath: identity.path
            ),
            scannerID: Self.registeredID,
            displayName: worktreePath.lastPathComponent,
            exactBytes: deletable ? report.exactAllocatedBytes : 0,
            estimatedUpToBytes: deletable ? report.estimatedUpToBytes : 0,
            logicalBytes: Self.publishedLogicalBytes(deletable: deletable, report: report),
            itemCount: deletable ? report.itemCount : 0,
            url: identity,
            declaredDisplayPath: Self.displayPath(of: worktreePath, home: home),
            rootRecords: [record],
            state: state,
            scanError: scanError,
            // D2: a worktree removal is never automatic and never pre-selected.
            risk: .review,
            evidence: assessment.evidence,
            rebuildNote: nil,
            action: .gitWorktreeReclaim(
                GitWorktreeReclaimPlan.removeStaleWorktree(
                    worktreePath: worktreePath,
                    worktreeAdminEntry: adminEntry,
                    // D3 (PR #460 codex r3): the admin directory's INODE, not
                    // just its spelling. `remove` + `add` at the same path
                    // gives the new checkout the SAME admin directory NAME
                    // back, so a carried path alone cannot tell the two
                    // checkouts apart at delete time.
                    //
                    // NON-OPTIONAL, and proved by the caller (r4/D6): taken
                    // as a bare `provider.identity(of:)` here, an `lstat`
                    // failure produced a nil that silently disarmed the gate.
                    worktreeAdminEntryIdentity: adminEntryIdentity,
                    parentRepoWorkingDir: parentRepoWorkingDir,
                    adminContainer: adminContainer
                )
            ),
            admission: .containerItem(
                originContainer: declaredRoot, requestedTargetURL: worktreePath
            ),
            defaultSelected: false,
            automaticCleanEligible: false,
            isStale: days.map { ReclaimableItem.isStale(daysSinceModified: $0) }
        )
        return (item, identity.path)
    }

    // MARK: - Orphaned-admin tier (D14)

    /// The repository's ONE prune item, or nothing plus a visible issue.
    ///
    /// PROVABLY-COMPLETE-OR-NO-ITEM: the item speaks for a whole repository's
    /// registry, so a disclosure that cannot account for every prunable record
    /// — or for every entry of the container the mapper enumerates — would let
    /// the operation remove something nobody was told about. Every incompleteness
    /// therefore SUPPRESSES the item and publishes what could not be accounted
    /// for. LOCKED prunable entries are the deliberate exception, excluded by
    /// the mapper WITHOUT suppression: they are not in the removal set. That
    /// exclusion is the only lock check left in the pipeline (PR #460 codex
    /// r2 / D6) — the execution is a direct removal of the mapped directories
    /// and no longer a `git worktree prune` that would have skipped them
    /// anyway. It is defence in depth, not a live one-line-from-disaster
    /// path: measured on git 2.50.1, git never marks a LOCKED worktree
    /// `prunable`, so the first clause of the filter already excludes every
    /// such record and the covering cells inject the combination
    /// synthetically. `GitAdminMapper.map` carries the measurement.
    private func pruneTier(
        inventory: GitWorktreeInventory,
        parentRepoWorkingDir: URL,
        adminContainer: URL,
        bindings: [RootBinding],
        issues: inout [ScanIssue],
        emissions: inout [(item: ReclaimableItem, identityPath: String)]
    ) {
        let disclosedRecords = inventory.entries.filter { $0.isPrunable && !$0.isLocked }
        let directories: [URL]
        switch mapper.map(
            prunableRecordsIn: inventory.entries, adminContainer: adminContainer
        ) {
        case .complete(let mapped):
            directories = mapped
        case .incomplete(let reason):
            issues.append(ScanIssue(
                url: parentRepoWorkingDir, kind: .unreadable,
                detail: "orphaned worktree admin data in this repository cannot "
                    + "be offered for pruning: \(reason) — the complete set "
                    + "cannot be accounted for, so no prune item is published"
            ))
            return
        }
        guard !directories.isEmpty else { return } // nothing prunable — no item

        // Every disclosed directory is measured BEFORE anything is offered.
        // A boundary (epic round 9: the removal of an admin directory is a
        // recursive filesystem mutation, and the
        // boundary-bearing-recursive-delete doctrine covers it exactly as it
        // covers `removeItem`) or a sizing denial means the
        // directory cannot be safely characterized — and a `.measured` prune
        // item may carry no scanError, so the only honest answer is
        // suppression with a visible issue.
        var exactBytes: Int64 = 0
        var estimatedUpToBytes: Int64 = 0
        var logicalBytes: Int64 = 0
        for directory in directories {
            let report = sizer.measure(at: directory, mode: .scanRoot)
            if report.rootMountBoundary || !report.mountBoundaries.isEmpty {
                let boundary = report.mountBoundaries.first ?? directory
                issues.append(ScanIssue(
                    url: parentRepoWorkingDir, kind: .unreadable,
                    detail: "orphaned worktree admin directory "
                        + "'\(directory.path)' contains a mount boundary at "
                        + "'\(boundary.path)' — a boundary-bearing directory "
                        + "must never ride a recursive prune, so no prune item "
                        + "is published for this repository"
                ))
                return
            }
            if let denial = report.denials.first {
                issues.append(ScanIssue(
                    url: parentRepoWorkingDir, kind: .unreadable,
                    detail: "orphaned worktree admin directory "
                        + "'\(directory.path)' could not be measured "
                        + "(\(denial.url.path): \(denial.detail)) — the "
                        + "disclosure would be unverifiable, so no prune item "
                        + "is published for this repository"
                ))
                return
            }
            exactBytes += report.exactAllocatedBytes
            estimatedUpToBytes += report.estimatedUpToBytes
            logicalBytes += report.logicalBytes
        }

        // D13 containment for the repository-level operation.
        let scope = mutationScope(
            parentRepoWorkingDir: parentRepoWorkingDir,
            strictPaths: [provider.resolveTargetKeepingLeaf(adminContainer)]
                + directories.map { provider.resolveTargetKeepingLeaf($0) },
            bindings: bindings
        )
        guard case .bound(let root, let parent, let strict) = scope else {
            if case .unbound(let reason) = scope {
                issues.append(ScanIssue(
                    url: parentRepoWorkingDir, kind: .containerRefused,
                    detail: "orphaned worktree admin data in this repository "
                        + "cannot be offered for pruning because \(reason) — "
                        + "the whole mutation scope must share one declared "
                        + "dev root"
                ))
            }
            return
        }
        let respelledContainer = strict[0]
        let respelledDirectories = Array(strict.dropFirst())

        let identity = provider.resolveTargetKeepingLeaf(respelledContainer)
        let record = RootScanRecord(
            requestedURL: respelledContainer, resolvedURL: identity, status: .measured
        )
        // PRUNE-ITEM STATE (epic round 5): `.measured` ALWAYS, never `.empty` —
        // the cleaner's zero-byte `.empty` SKIP precedes action dispatch, so an
        // `.empty` prune item could never run. `itemCount` is the DISCLOSED
        // admin-directory count, which is both the honest figure and what keeps
        // the value-domain family satisfied for a zero-byte disclosure.
        let item = ReclaimableItem(
            id: ReclaimableItem.stableID(
                // KEY 3 of 3: the prune item preimages the canonical ADMIN
                // CONTAINER path — one per repository, and never colliding with
                // any worktree-keyed stale item of the same repository.
                scannerID: Self.registeredID, canonicalPath: identity.path
            ),
            scannerID: Self.registeredID,
            displayName: "\(parentRepoWorkingDir.lastPathComponent) — orphaned worktree registry",
            exactBytes: exactBytes,
            estimatedUpToBytes: estimatedUpToBytes,
            logicalBytes: logicalBytes > exactBytes + estimatedUpToBytes ? logicalBytes : nil,
            itemCount: respelledDirectories.count,
            url: identity,
            declaredDisplayPath: Self.displayPath(of: respelledContainer, home: home),
            rootRecords: [record],
            state: .measured,
            scanError: nil,
            // D2: metadata-only and branch refs survive, so `.safe` is honest —
            // but Quick Clean must never silently spawn git subprocesses.
            risk: .safe,
            evidence: Self.pruneEvidence(
                directories: respelledDirectories, records: disclosedRecords
            ),
            rebuildNote: nil,
            action: .gitWorktreeReclaim(
                GitWorktreeReclaimPlan.pruneOrphanedAdmin(
                    parentRepoWorkingDir: parent,
                    adminContainer: respelledContainer,
                    disclosedAdminDirectories: respelledDirectories
                )
            ),
            admission: .containerItem(
                originContainer: root.declaredRoot,
                requestedTargetURL: respelledContainer
            ),
            defaultSelected: false,
            automaticCleanEligible: false,
            // Staleness is not applicable: an orphaned admin directory's age
            // says nothing about whether it should be pruned.
            isStale: nil
        )
        emissions.append((item, identity.path))
    }

    /// The prune item's disclosure, naming BOTH halves: the checkouts git
    /// reports as gone and the admin directories the prune will remove.
    static func pruneEvidence(
        directories: [URL], records: [GitWorktreeEntry]
    ) -> String {
        let checkouts = records.map { record -> String in
            guard let reason = record.prunableReason, !reason.isEmpty else {
                return record.path.path
            }
            return "\(record.path.path) (\(reason))"
        }
        var clauses = [
            "\(directories.count) orphaned worktree admin "
                + "\(directories.count == 1 ? "directory" : "directories") to prune: "
                + directories.map(\.lastPathComponent).joined(separator: ", "),
        ]
        if !checkouts.isEmpty {
            clauses.append("registered checkouts already gone: "
                + checkouts.joined(separator: "; "))
        }
        clauses.append(
            "removes exactly \(directories.count == 1 ? "this directory" : "these directories") "
                + "and nothing else — no repository-wide prune runs; branch "
                + "refs and repository objects are untouched"
        )
        return clauses.joined(separator: "; ")
    }

    // MARK: - Containment (D13)

    /// A declared dev root paired with its canonical form.
    struct RootBinding: Equatable, Sendable {
        /// VERBATIM declared spelling — the validator's origin binding is exact
        /// string equality against this.
        let declaredRoot: URL
        let canonicalRoot: URL
    }

    /// The declared roots this scan may bind items to.
    ///
    /// A declared root carrying a raw `..` component is skipped: the plan
    /// validator rejects any plan path containing one BEFORE standardization
    /// (epic round 9), so re-spelling under such a root would malform the whole
    /// outcome rather than produce one refused item.
    private func rootBindings() -> [RootBinding] {
        devRoots.keptRoots.compactMap { root in
            guard !root.pathComponents.contains("..") else { return nil }
            return RootBinding(
                declaredRoot: root, canonicalRoot: provider.canonicalize(root)
            )
        }
    }

    private enum MutationScopeResult {
        /// The chosen root plus every path RE-SPELLED under its declared
        /// spelling, `strictPaths` in the order they were supplied.
        case bound(root: RootBinding, parentRepoWorkingDir: URL, strictPaths: [URL])
        /// No declared root contains the whole mutation scope; the reason names
        /// the first path that fell outside.
        case unbound(reason: String)
    }

    /// Bind a mutation scope to ONE declared root.
    ///
    /// Containment is decided CANONICALLY (so alias-declared roots work), and
    /// the winning paths are then RE-SPELLED under the declared spelling so the
    /// plan validator's LEXICAL checks pass on the verbatim strings it will
    /// see. The deepest (most specific) canonical root wins, byte-wise declared
    /// path breaking ties — the `BuildArtifactsScanner` provenance rule.
    private func mutationScope(
        parentRepoWorkingDir: URL,
        strictPaths: [URL],
        bindings: [RootBinding]
    ) -> MutationScopeResult {
        let canonicalParent = provider.canonicalize(parentRepoWorkingDir)
        var failure: String?

        let ordered = bindings.sorted { lhs, rhs in
            let left = lhs.canonicalRoot.pathComponents.count
            let right = rhs.canonicalRoot.pathComponents.count
            if left != right { return left > right }
            return lhs.declaredRoot.path.utf8
                .lexicographicallyPrecedes(rhs.declaredRoot.path.utf8)
        }

        for binding in ordered {
            let root = binding.canonicalRoot
            // The parent alone may EQUAL the root: a dev root that IS a
            // repository is a legal, common shape (epic round 4) — only its
            // strictly-contained admin data is mutated.
            guard Self.isDescendantOrEqual(canonicalParent, of: root) else {
                failure = failure ?? "its parent repository "
                    + "'\(parentRepoWorkingDir.path)' is outside that root"
                continue
            }
            guard let respelledStrict = respell(strictPaths, under: binding) else {
                failure = failure ?? "part of the git data it would mutate is "
                    + "outside that root"
                continue
            }
            guard let respelledParent = Self.respell(
                canonicalParent, canonicalRoot: root, declaredRoot: binding.declaredRoot
            ) else {
                failure = failure ?? "its parent repository "
                    + "'\(parentRepoWorkingDir.path)' is outside that root"
                continue
            }
            return .bound(
                root: binding, parentRepoWorkingDir: respelledParent,
                strictPaths: respelledStrict
            )
        }
        return .unbound(
            reason: failure ?? "no configured dev root contains its whole "
                + "mutation scope"
        )
    }

    /// Every path re-spelled under `binding`, or nil if ANY is not a STRICT
    /// canonical descendant of its canonical root.
    private func respell(_ paths: [URL], under binding: RootBinding) -> [URL]? {
        var out: [URL] = []
        out.reserveCapacity(paths.count)
        for path in paths {
            guard Self.isStrictDescendant(path, of: binding.canonicalRoot),
                  let respelled = Self.respell(
                    path, canonicalRoot: binding.canonicalRoot,
                    declaredRoot: binding.declaredRoot
                  )
            else { return nil }
            out.append(respelled)
        }
        return out
    }

    /// Declared roots whose CANONICAL form strictly contains `canonical`.
    private func rootsStrictlyContaining(
        _ canonical: URL, in bindings: [RootBinding]
    ) -> [RootBinding] {
        bindings.filter { Self.isStrictDescendant(canonical, of: $0.canonicalRoot) }
    }

    /// Re-spell a canonical path under a DECLARED root spelling: the declared
    /// root plus the canonical tail. The result canonicalizes back to the input
    /// (only the spelling changes), which is what lets the verbatim strings the
    /// plan carries pass the validator's lexical containment while the
    /// filesystem identity stays exactly what containment was proven on.
    static func respell(
        _ canonical: URL, canonicalRoot: URL, declaredRoot: URL
    ) -> URL? {
        let components = canonical.pathComponents
        let rootComponents = canonicalRoot.pathComponents
        guard components.count >= rootComponents.count,
              Array(components.prefix(rootComponents.count)) == rootComponents
        else { return nil }
        var out = declaredRoot
        for component in components.dropFirst(rootComponents.count) {
            out.appendPathComponent(component)
        }
        return out
    }

    /// Strict path-COMPONENT containment — never string `hasPrefix` (`/a/bc`
    /// must never read as inside `/a/b`), the PathGuard doctrine.
    static func isStrictDescendant(_ candidate: URL, of ancestor: URL) -> Bool {
        let candidateComponents = candidate.pathComponents
        let ancestorComponents = ancestor.pathComponents
        guard candidateComponents.count > ancestorComponents.count else { return false }
        return Array(candidateComponents.prefix(ancestorComponents.count))
            == ancestorComponents
    }

    static func isDescendantOrEqual(_ candidate: URL, of ancestor: URL) -> Bool {
        let candidateComponents = candidate.pathComponents
        let ancestorComponents = ancestor.pathComponents
        guard candidateComponents.count >= ancestorComponents.count else { return false }
        return Array(candidateComponents.prefix(ancestorComponents.count))
            == ancestorComponents
    }

    // MARK: - The SECONDARY TCC gate (epic round 7)

    /// Must scan-time git (or the filesystem inspection feeding it) stay away
    /// from `path` on this trigger?
    ///
    /// The classification is fn-4's `ProjectTreeWalker.isProtectedRoot` — the
    /// ONE prefix-under-protected-ancestor rule on the CANONICAL path, REUSED
    /// rather than re-derived. On `.userInitiated` nothing is deferred (macOS
    /// may prompt once, which is exactly what the user asked for).
    private func isDeferred(_ path: URL, context: ScanContext) -> Bool {
        guard !context.includeProtectedRoots else { return false }
        return ProjectTreeWalker.isProtectedRoot(path, home: home, provider: provider)
    }

    /// The provider the per-scan RESOLVER runs on.
    ///
    /// The gate above can only be applied to a path once the path is KNOWN, and
    /// a linked worktree's admin directory is not knowable until its `.git`
    /// pointer has been followed — which is itself an access. The parent
    /// repository of a worktree in an unprotected dev root very often lives in
    /// `~/Documents`, so following that pointer with an ungated provider would
    /// let an AUTOMATIC scan read protected git admin files: the exact prompt
    /// the doctrine exists to prevent, and one no `git argv` assertion would
    /// ever catch.
    ///
    /// So on `.automatic` the resolver runs on a provider that reports every
    /// deferred path as ABSENT. The resolver is fail-closed by construction —
    /// it `probeKind`s each pointer target BEFORE reading it — so the deferral
    /// lands before any `open`, and the worktree simply attributes nowhere
    /// (silent, exactly like every other policy skip).
    private func identityProvider(for context: ScanContext) -> FileSystemIdentityProvider {
        guard !context.includeProtectedRoots else { return provider }
        let home = self.home
        let base = provider
        return DeferringIdentityProvider(wrapping: base) { url in
            ProjectTreeWalker.isProtectedRoot(url, home: home, provider: base)
        }
    }

    // MARK: - Item mapping helpers

    /// The retired NodeModulesScanner's logical-bytes predicate, cloned
    /// VERBATIM (the `BuildArtifactsScanner` clone of the same rule): publish
    /// iff the item is deletable AND logical exceeds measured — the sparse
    /// field case (57.1 GB logical vs 31 GB allocated) is the only divergence
    /// direction worth showing. Denied items publish no figure at all.
    static func publishedLogicalBytes(deletable: Bool, report: SizeReport) -> Int64? {
        deletable && report.logicalBytes > report.measuredBytes
            ? report.logicalBytes : nil
    }

    /// The classified impediment for a boundary-bearing candidate, cloned from
    /// the as-built doctrine: `.other` is the honest kind (a boundary is
    /// neither TCC nor BSD permissions, and no grant lifts it), the message
    /// NAMES the boundary, and a measured floor rides the message because the
    /// item's byte components must stay ZERO.
    static func mountBoundaryScanError(from report: SizeReport, candidate: URL) -> ScanError {
        let boundary = report.mountBoundaries.first ?? candidate
        var message = report.rootMountBoundary
            ? "\(boundary.path): worktree is a mount point — not measured; "
                + "removal would be refused"
            : "mount boundary at \(boundary.path) — subtree not measured; "
                + "removal would be refused"
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

    /// Days between the tree's newest REGULAR-FILE content date (produced by
    /// the SAME sizing walk — never a second traversal) and this scan's "now".
    private func daysSinceNewestContent(_ date: Date?) -> Int? {
        guard let date else { return nil }
        return Calendar.current.dateComponents([.day], from: date, to: now()).day
    }

    /// Deterministic and TOTAL output order: allocated bytes desc, display name
    /// asc byte-wise, canonical identity path asc byte-wise as the final
    /// tie-breaker (identity paths are unique across both tiers, so the
    /// comparator is a strict total order).
    static func ordered(
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

    /// Home-shortened display spelling, on a PATH-COMPONENT boundary (a sibling
    /// that merely string-prefixes the home path must never render as `~-…`).
    static func displayPath(of url: URL, home: URL) -> String {
        let path = url.path
        let homePath = home.path
        if path == homePath { return "~" }
        let prefix = homePath.hasSuffix("/") ? homePath : homePath + "/"
        guard path.hasPrefix(prefix) else { return path }
        return "~/" + path.dropFirst(prefix.count)
    }

    // MARK: - Runner plumbing

    private func run(_ arguments: [String]) async -> GitCommandInvocation {
        if let gitTimeout { return await runner.run(arguments, timeout: gitTimeout) }
        return await runner.run(arguments)
    }

    /// The DEFAULT assessment observer (D15): a per-scan tally plus one line
    /// per omitted non-candidate, so an assessment that produced no item is
    /// still visible to anyone asking why.
    static let defaultAssessmentObserver: @Sendable (GitWorktreeAssessmentLog) -> Void = { log in
        guard log.assessedCount > 0 else { return }
        logger.debug(
            """
            assessed \(log.assessedCount, privacy: .public) worktree(s): \
            \(log.candidateCount, privacy: .public) candidate(s), \
            \(log.emittedCount, privacy: .public) emitted, \
            \(log.omittedNonCandidateCount, privacy: .public) non-candidate(s) omitted
            """
        )
        for entry in log.omittedNonCandidates {
            logger.debug(
                """
                omitted (not a candidate): \(entry.worktreePath.path, privacy: .private) \
                — \(entry.evidence, privacy: .private)
                """
            )
        }
    }
}

// MARK: - SpaceScanner conformance

/// PRODUCTION CONFORMANCE — every requirement is already a member above: the
/// slug `id`, `displayName`, `trustedContainerRoots` (the resolution's
/// `keptRoots`, declared spellings verbatim), and `scan(context:)`. No
/// `preDeleteRevalidator` is declared: this scanner runs no scan-time content
/// probe whose result a delete-time re-inspection could contradict — the
/// composite performer's own re-checks are the delete-time gates for its
/// items, and the performer is where they are enumerated:
/// `reestablishStaleGates` (R0 repository identity, R1 the re-read porcelain
/// record's G1/G4 plus the registration, R2 the shared G3 ancestry check),
/// the G2 clean re-check as the LAST git call before the removal, the
/// LAST-INSTANT filesystem re-proof immediately before the ONE destructive
/// act (which checkout, the lock file, the HEAD file — PR #460 codex r4; one
/// act rather than two since r5 collapsed the arms), the oracle
/// recompute in prune mode, and the D13 traversal guard, which covers every
/// path a git invocation traverses with a check that ran after admission and
/// before that invocation — NOT one guard per invocation, a universal retired
/// as false in the performer and at `PathGuard` in r2/r3 and here in r4
/// (`WorktreeReclaimPerformer`'s guard-site table is the authority).
///
/// `participates(in:)` IS NOT OVERRIDDEN, and that is a decision rather than an
/// omission (fn-6 reconciliation). fn-6 added the member so a scanner can
/// decline a TRIGGER outright, and `ephemeral_tmp` declines every
/// `.automatic` one. This scanner takes the default — it runs in every
/// session — for two reasons:
///
///  1. DECLINING IS ALL-OR-NOTHING, AND THIS SCANNER'S POLICY IS NOT. A
///     non-participating scanner publishes no outcome at all, deliberately, so
///     an auto-refresh cannot erase prior findings or the user's ticks. This
///     scanner's trigger sensitivity is per-ROOT and per-ITEM instead: it skips
///     PROTECTED roots on `.automatic` (`ProjectTreeWalker.isProtectedRoot`,
///     the one definition) and defers protected-PARENT assessment on the same
///     trigger, while still walking the ordinary dev roots. Whole-scanner
///     deferral would throw away the part that is safe to do in the background
///     along with the part that is not.
///  2. A GENUINE DENIAL MUST STAY VISIBLE ON A BACKGROUND SCAN, which is a
///     thing only a PARTICIPATING scanner can do —
///     `testGenuineWalkDenialStaysVisibleUnderBothTriggers` asserts the
///     `.tccDenied` issue arrives under `.automatic` as well as
///     `.userInitiated`. Declining would make that cell unsatisfiable: no
///     event, so no issue, and the R9 freshness gate would strand the retained
///     rows instead.
///
/// Nothing here fires a subprocess speculatively: the runner is inert until a
/// repository is actually discovered, so participating costs a background scan
/// nothing on a machine with no worktrees.
///
/// Registration is fn-5.6's single-site change; conformance lands here so the
/// outcome can be round-tripped through the runtime's validator by tests before
/// any user-facing surface can address an item.
///
/// NO ViewModel busy-flag wiring is needed and none is added: this scanner
/// joins the GENERIC validated-scan session, whose progress is tracked per
/// scanner id (`CacheoutViewModel.scanningScannerIDs`, folded into
/// `isAnyScanInProgress`) — there is no new scan PHASE to OR in.
extension GitWorktreeScanner: SpaceScanner {}
