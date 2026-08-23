/// # EphemeralTempRoots — Runtime Temp-Root Resolution & Sweep Config (fn-6.1, R2/R3/R7/R14)
///
/// The declaration and RUNTIME RESOLUTION of the three ephemeral temp roots
/// the `ephemeral_tmp` scanner works over, plus that scanner's two-knob
/// config surface. Pure declaration + resolution: no enumeration, no
/// staleness, no sizing, no deletion — fn-6.2 consumes the roots, fn-6.4
/// consumes the config for CLI overrides.
///
/// ## The three roots (exactly — the set is closed)
///
/// - `/private/tmp` — the shared, world-writable (sticky, 1777) temp dir.
/// - `confstr(_CS_DARWIN_USER_CACHE_DIR)` — the per-user `…/C` container.
/// - `confstr(_CS_DARWIN_USER_TEMP_DIR)` — the per-user `…/T` container.
///
/// `_CS_DARWIN_USER_DIR` (`…/0`) is deliberately NOT resolved and NOT in the
/// set (epic Boundaries; negative assertion in tests). Declaration order is
/// the epic's yield/risk priority (D7): durable payload (`/private/tmp`, `C`)
/// ahead of the OS-reaped, live-app-state container (`T`).
///
/// ## confstr(3), and why not a hardcoded `/var/folders/<bucket>`
///
/// The per-user bucket names are machine-specific, so they can only be
/// resolved at runtime. `confstrPath(_:)` uses the two-call sizing idiom
/// (authoritative Swift precedent: swift-nio `Sources/NIOFS/FileSystem.swift`
/// :708-723). Failure taxonomy, all treated identically: a return of 0 means
/// either a real error (`errno` `EIO` — dirhelper communication failure — or
/// `EINVAL` for a bad name) or "no defined value" (0 with `errno` untouched),
/// and a second-call return GREATER than the buffer means truncation. ANY of
/// these ⇒ that root is silently ABSENT from the resolved set. There is no
/// hardcoded substitute: a guessed `/var/folders/…` path would be a fiction.
///
/// SIDE EFFECT, documented: `confstr` on these names asks `dirhelper` for the
/// container and CREATES it when absent — so this app's own `T`/`C` always
/// exist right after resolution. The live output also carries a TRAILING
/// SLASH, normalized away here before any URL is built.
///
/// ## One-spelling discipline (R3), and why the LEAF stays unresolved
///
/// Every root is resolved EXACTLY ONCE, here, via
/// `FileSystemIdentityProvider.resolveTargetKeepingLeaf(_:)`: the PARENT
/// CHAIN is canonicalized (`/var/folders/…` becomes `/private/var/folders/…`)
/// and the LEAF — the container's own name — is appended UNRESOLVED. That ONE
/// spelling is what fn-6.2 declares as `trustedContainerRoots`, stamps into
/// every item's `originContainer`, and uses as the canonical PARENT chain of
/// item identity. A second spelling anywhere downstream makes the outcome
/// validator-rejected or deletion structurally unreachable, because
/// `ContainerSnapshot.capture` keys by the DECLARED spelling
/// (`PathGuard.swift:165-176`).
///
/// The leaf is left unresolved because this URL becomes a TRUSTED CONTAINER
/// ROOT, not a comparison value. `realpath(3)` resolves the leaf too, so a
/// symlink standing where `C`/`T` should be would silently register its
/// DESTINATION as a temp root — and the container-root policy only refuses
/// `/`, volume roots and `$HOME` itself (`PathGuard.swift:370` says so in
/// as many words: "`~/Documents` can be a container while `admitDeletionRoot`
/// refuses it"), so an arbitrary directory would be admitted, walked, listed
/// as cache-container payload and deleted. Keeping the leaf means the
/// declared spelling IS the link, so fn-6.2's no-follow root gate (an `lstat`
/// `probeKind`) sees a symlink and refuses the root with a VISIBLE
/// `.symlinkRoot` issue, and `ContainerSnapshot.capture` binds the LINK's own
/// identity at delete time.
///
/// On stock macOS this is a NO-OP: the symlink on the way to these containers
/// is `/var` → `private/var`, an ANCESTOR, which the parent chain still
/// resolves; `/private/tmp` is declared canonically for the same reason. Both
/// live-Mac cells below assert the resulting spellings.
///
/// ### RESIDUAL, at measured scope: this is closed AT THE LEAF only
///
/// Only the leaf is left unfollowed. Every INTERMEDIATE component is still
/// resolved, so the escalation above survives one component up, verbatim: a
/// symlink at an intermediate with a real directory behind it registers the
/// destination as a trusted container root. Measured end-to-end through the
/// real cleaner (r8) with `<base>/bucket` a symlink to `<home>/Documents`
/// and a confstr output of `<base>/bucket/C`: `resolve` registered
/// `<home>/Documents/C`, the no-follow root gate passed it, ZERO issues were
/// raised, and the permanent-disposal arm deleted
/// `<home>/Documents/C/Taxes-2019`.
///
/// It is a residual to DISCLOSE, not a hole an unprivileged process can
/// reach on the shipped roots, and the reason is ownership. Replacing a
/// component with a symlink requires write permission on that component's
/// PARENT, and on this machine every intermediate's parent is root-owned
/// (measured r8, `stat -f '%Sp %Su:%Sg'`): `/`, `/private`, `/private/var`,
/// `/private/var/folders` and `/private/var/folders/mq` are all
/// `drwxr-xr-x root:wheel`. The per-user bucket directory below them IS
/// user-owned (`drwxr-xr-x <user>:staff`) — but it is the parent of the
/// LEAF, so what an unprivileged process can swap there is `C`/`T`
/// themselves, which is exactly the case the leaf rule closes.
///
/// So the residual needs root, or a machine where confstr returns a
/// RELOCATED container whose chain has a user-writable intermediate parent.
///
/// NO RATIONALE IS RECORDED for the obvious alternative — leaving the parent
/// chain unresolved as well — because the one this file used to give was
/// false. It said `/var/folders/…` and `/private/var/folders/…` would then be
/// two REGISTERED spellings of one container; `resolve` appends exactly one
/// URL per declared definition, so that state cannot arise. What was measured
/// instead (r9), with a root declared unresolved end to end: ONE registered
/// root, the stale entry listed, the outcome validated, and the
/// permanent-disposal arm deleted it — while the item carried the canonical
/// identity `/private/var/…/<entry>` beside a declared `originContainer` of
/// `/var/…`. What that two-spelling split inside each item costs is NOT
/// measured, so this file claims nothing about it either way.
///
/// ## Nothing a symlink leaf points at is contacted (PR #459 codex r12)
///
/// Resolution runs synchronously inside `SpaceScannerRuntime.production()`,
/// which is ordinary app construction: the GUI evaluates it on the main
/// thread while building its `@StateObject`
/// (`CacheoutApp.swift:58` → `CacheoutViewModel.production()` →
/// `CacheoutViewModel.swift:541` → `SpaceScannerRuntime.production`,
/// `SpaceScanner.swift:2058`), long
/// before any trigger or `participates(in:)` gate exists to consult. The main
/// thread is not an inference: `CacheoutViewModel` is `@MainActor`
/// (`CacheoutViewModel.swift:264`), so its `production()` factory cannot be
/// called from anywhere else. So whatever this file does to a DECLARED path,
/// a user waits for — with the window frozen, not merely a scan delayed.
///
/// `C` and `T` sit in a user-owned bucket directory, so a same-UID process
/// can replace either with a symlink to any destination it likes. This file
/// therefore never resolves a leaf the `lstat` probe says is not a real
/// directory: `realpath(3)` on such a leaf names the DESTINATION, and naming
/// it is what blocks (an unresponsive volume) or reaches somewhere the app
/// has no business reaching. Measured at the r11 tip, before this rule:
/// `SpaceScannerRuntime.production()` canonicalized a symlinked `C` twice and
/// both calls returned the destination's own canonical path, and a 0.75 s
/// stall injected on calls naming the destination made `production()` take
/// 3.02 s.
///
/// An alias's target is instead READ, never followed — one `readlink(2)` of
/// the link's own content (`FileSystemIdentityProvider.symlinkTarget(of:)`),
/// folded to an absolute path by string arithmetic — and then COMPARED, as a
/// name, against the spellings resolution already holds. That is strictly
/// weaker than an inode comparison, and the residual is recorded below.
///
/// This is where the file DIVERGES from the two dev-root precedents it
/// otherwise follows: `DevRootsStore.swift:322` and
/// `SpaceScannerRuntime.suppressingAliasShadows`' probe pair
/// (`SpaceScanner.swift:1921-1925`)
/// both still build their comparison key with `provider.canonicalize`, on
/// every root including non-directory ones, at the same construction time.
/// Neither has been changed here.
///
/// ### RESIDUAL, at measured scope: the SECTION TITLE is about THIS FILE
///
/// It is not a claim about `production()` as a whole, and the difference is
/// measured. A symlink root this resolution cannot place is KEPT, so it
/// reaches the runtime's cross-scanner union and
/// `suppressingAliasShadows`' probe pair (`SpaceScanner.swift:1921-1925`)
/// canonicalizes it there — one leaf-following
/// `realpath(3)` on the destination, still during construction. Measured
/// through the shipped `??` arm with the same fixture, before and after this
/// change: leaf-following canonicalizations of a symlinked `C` went 2 → 1,
/// and `production()` under a 0.75 s stall on calls naming the destination
/// went 3.02 s → 0.76 s. Replacing that one line's `provider.canonicalize(
/// root).path` with `root.path` takes both to 0 and 0.0026 s, which is how
/// the surviving contact was attributed — NOT a proposed fix: that key is
/// what suppresses a shadowing alias ACROSS scanners
/// (`suppressingAliasShadows`' doc, `SpaceScanner.swift:1870-1881`), and
/// weakening it trades one hazard for
/// another. Closing it needs its own change, on fn-4.5's contract.
///
/// ## Nor is a root that IS a mount contacted (PR #459 codex r15)
///
/// The section above is about a root's DESTINATION. This one is about the
/// root itself: `C`, `T` and `/private/tmp` are all ordinary directories
/// anyone can mount a volume onto, and `lstat(2)` OF a mount point is served
/// by the mounted filesystem — the same mechanism fn-6.2's scan-time arm
/// exists for, one layer earlier and on the main thread. So the `lstat`
/// `probeKind` that decides `isDirectory` was the app's first contact with
/// that volume, and on an unresponsive hard mount it blocks construction
/// before any window exists.
///
/// `resolve` therefore reads the kernel mount table
/// (`FileSystemIdentityProvider.mountPointPaths`, :208-246 — `getfsstat(
/// MNT_NOWAIT)`, which touches no filesystem) before its first probe, and
/// DROPS a root the table names, disclosing it as
/// `.mountedVolumeRootAtRegistration`. Measured through the shipped `??` arm
/// with a table-injected fixture, before and after: calls naming the mounted
/// root went 3 → 0 in `resolve` (`probeKind`, then `identity` twice from the
/// de-dupe's `sameLocation`) and 5 → 0 across `production()`. Under a 0.75 s
/// stall injected on every such call — a MODEL of an unresponsive mount, not
/// a real dead one; a dead NFS mount cannot be staged on this machine —
/// `production()` went 3.79 s → 0.00023 s.
///
/// DROPPED, not kept-and-skipped, and that is the whole difference between a
/// fix and a relocation: the 2 of those 5 that `resolve` never made were
/// `suppressingAliasShadows` canonicalizing and probing the same root in the
/// cross-scanner union (`suppressingAliasShadows`' probe pair,
/// `SpaceScanner.swift:1921-1925`), which every KEPT
/// root reaches.
///
/// ### RESIDUAL, at measured scope: three cases this does not cover
///
/// - A mount landing AFTER the table read. Unclosable by any re-read; the
///   same racing class fn-6.2's arm records, and its arm is what catches a
///   mount that lands after construction.
/// - A volume mounted at an ANCESTOR of a declared root — the bucket
///   directory, say. The parent-chain `realpath(3)` that PRODUCES the
///   spelling runs before a table lookup for that spelling is possible, and
///   the table's canonical entries cannot be prefix-matched against a raw
///   confstr spelling like `/var/folders/<bucket>/C`. Not the case in the
///   finding, and not half-guarded here.
/// - A declared root that is a SYMLINK to a mounted volume. The table names
///   the mount, not the link, so the link is kept — and the r12 residual
///   above is then the contact: `suppressingAliasShadows` canonicalizes it,
///   naming the destination. Re-measured at this tip: `production()` makes
///   exactly 1 call naming the destination and takes 0.76 s under the same
///   injected 0.75 s stall. Same out-of-scope line, same fn-4.5 contract.
///
/// `confstr(3)` itself is upstream of all of this by necessity — it is what
/// produces the path, so no table check can precede it.
///
/// ## De-dupe and alias suppression — two halves, cited one at a time
///
/// One value is probed per declared root: whether the DECLARED spelling is
/// itself a real directory (`lstat` leaf, no follow), which is the
/// `isDirectory` half of the probe pair at `DevRootsStore.swift:320-324` and
/// `suppressingAliasShadows`' probe pair (`SpaceScanner.swift:1921-1925`).
/// The `key:` half of that pair is deliberately
/// NOT taken (see above). The two halves that consume the probe have
/// different precedents — do not read this as one pattern copied whole from
/// either:
///
/// - **De-dupe** — real directories only: a real-directory spelling of a
///   location already kept is dropped. Precedent is `DevRootsStore.swift`
///   alone (:361-364, `seenCanonicalKeys.insert`).
///   `SpaceScannerRuntime.suppressingAliasShadows` does NOT do this half — it
///   deliberately DECLINES it, and `suppressingAliasShadows`
///   (`SpaceScanner.swift:1931-1934`) says so:
///   "Two real-directory spellings of one location are NOT touched: both pass
///   the reality gate, so neither shadows the other, and dropping either would
///   change which declared spelling the identity binding keys off for no
///   safety gain." A maintainer reconciling the two files must not add
///   de-duping there.
///
///   The comparison here is INODE identity (`sameLocation`) of the declared
///   spellings, where that precedent compares canonical paths as STRINGS
///   (`DevRootsStore.swift:322` builds `.path`). Comparing the declared
///   spellings is sound only because both sides are real DIRECTORIES, whose
///   parent chain resolution already made them canonical: measured on this
///   machine (Darwin 25.5), `realpath(dir)` and `realpath(parent) + "/" +
///   leaf` are the same string for a real directory. Not that a string
///   compare would fail on these spellings either: measured, `$TMPDIR`,
///   `NSTemporaryDirectory()` and confstr `T` all realpath to the ONE string
///   `/private/var/folders/<bucket>/T`. No case is recorded here where the
///   two verdicts differ — inode identity is used because it is the stronger
///   of the two, and that is the whole reason.
/// - **Alias suppression** — a declared spelling that is NOT a real directory
///   but NAMES one that IS (its `readlink(2)` content, folded to an absolute
///   path, equals a real-directory root's parent-canonical spelling or the
///   raw source spelling that root came from) is DROPPED, and the drop is
///   disclosed as a `.symlinkRoot` issue naming the root that covers it. Both
///   spellings are compared because both really occur: confstr `T` answers
///   `/var/folders/<bucket>/T/` on this machine while the resolved root is
///   `/private/var/folders/<bucket>/T`, so a link written to either one
///   collapses. The
///   ALIAS goes, never the real directory: dropping the real root instead
///   loses the only spelling anything can be scanned or cleaned through,
///   while the alias could never be walked (fn-6.2's no-follow root gate
///   refuses it) nor admitted as a container. Keeping the alias AHEAD of the
///   real root is worse than useless — `PathGuard.matchConfiguredRoot`
///   returns the FIRST configured root that matches and `admitContainer`
///   refuses THAT spelling without trying the real one behind it.
///   `DevRootsStore.swift:326-332` names that shape "ACTIVELY HARMFUL";
///   `suppressingAliasShadows`' doc (`SpaceScanner.swift:1870-1881`)
///   records the breakage it caused when the
///   shadowed root came from another scanner.
///
///   BOTH files do this half — `DevRootsStore.swift:333-335` + :341-357 and
///   `suppressingAliasShadows` (`SpaceScanner.swift:1893-1933`) — but only
///   `DevRootsStore` classifies the
///   drop. `suppressingAliasShadows` returns roots plus their canonical keys
///   and NO issue channel of its own (`SpaceScanner.swift:1916-1918`; the
///   "bare `[URL]`" this sentence used to say stopped being true when the
///   keys were carried out of the same probe, PR #460 codex r4);
///   `suppressingAliasShadows`' doc (`SpaceScanner.swift:1910-1915`)
///   records what
///   reports its drops instead. The `.symlinkRoot` issue raised here follows
///   `DevRootsStore.swift:349-355`, not that function.
///
/// A non-directory spelling that NOTHING else covers passes through verbatim:
/// scan time is where absence and denial are told apart, and the no-follow
/// root gate classifies it there.
///
/// ### RESIDUAL, at measured scope: a name compare misses a third spelling
///
/// The alias comparison is by NAME, so it only collapses a link whose content
/// is one of the two spellings resolution holds. A link written through some
/// THIRD spelling of the same directory — an ancestor symlink other than
/// `/var`, a case variant on a case-insensitive volume — is no longer
/// recognised as an alias, where the leaf-resolving key it replaced would
/// have caught it by inode. That case is fail-safe and measured
/// (`testAliasWrittenThroughAThirdSpellingKeepsBothRootsRatherThanGuessing`):
/// BOTH roots are kept, the real one is scanned exactly as before, and the
/// alias is refused at scan time by fn-6.2's no-follow root gate with its own
/// `.symlinkRoot` issue. Nothing is silently dropped, and no REAL root is
/// ever dropped by this arm — only aliases are.
///
/// ## Resolution time vs SCAN time — two distinct layers, deliberately
///
/// This file is the RESOLUTION layer only: a root that cannot be resolved
/// (confstr failure, non-absolute or `/` output) never enters the set, and
/// nothing here probes existence, permissions or mode bits. What happens to a
/// resolved root that is MISSING or UNREADABLE when a scan actually runs is
/// fn-6.2's contract (epic R11): scan-time absence — including the
/// construction-to-scan disappearance race — is a SILENT skip, while a
/// present-but-denied root is a VISIBLE `ScanIssue`. Do not fold the two
/// layers together: a spurious issue for a root that legitimately vanished
/// trains users to ignore issues, and a silent zero for a denied root is the
/// fn-1 TCC-silent-zero defect class.
///
/// ## Declared writability class (R14, D12 — never probed)
///
/// Each root carries a STATIC, DECLARED writability class. It scopes exactly
/// one thing: fn-6.2's D12 ownership gate, which applies under the
/// world-writable root (sticky `/private/tmp`, where another user's entry is
/// undeletable) and is vacuous under the 0700 per-user containers. It does
/// NOT drive trigger behavior — since epic D11 (revised) the ENTIRE scanner
/// runs only on `.userInitiated` triggers. The class is a property of the
/// fixed 3-root definition, so probing mode bits would add failure modes for
/// zero information.
///
/// ## Evidence wording (D7 revised — non-contractual)
///
/// Per-root cleanup evidence is deliberately non-contractual about OS
/// behavior AND factually consistent with the engineering census: nothing
/// here promises what macOS will or will not delete. The observed reaping
/// mechanics of the per-user temp container (a shorter clock, aged by access
/// time) are ENGINEERING NOTES ONLY — Apple disclaims those values as
/// non-API, so a shipped string stating them as behavior becomes false the
/// release Apple changes them.
///
/// ## No own-process exclusion surface (D9)
///
/// There is deliberately NO own-temp identity/exclusion set here. This app is
/// not sandboxed, so `NSTemporaryDirectory()` IS the `T` root: a first-level
/// candidate can never share its parent container's inode, so such a set
/// could never fire — it would be false safety. The AGE gate (fn-6.2) is the
/// sole and sufficient own-process shield: anything this app or the current
/// session writes is fresh by construction.

import Foundation

// MARK: - Resolution result

/// What temp-root resolution produced: the roots fn-6.2 registers, plus the
/// classified issues for the spellings resolution DROPPED.
///
/// The issue list exists so alias suppression is never a silent drop — the
/// `DevRootsResolution { keptRoots, issues }` contract at the same layer
/// (`DevRootsStore.swift:28-38`). fn-6.2 stores these at construction and
/// appends them to every outcome of a scan that actually inspects, so a
/// dropped spelling stays visible while never registering or being walked.
struct EphemeralTempRootsResolution: Equatable, Sendable {
    /// The roots that survived, in declaration order, each carrying the ONE
    /// spelling fn-6.2 declares, stamps and derives identity from.
    let roots: [EphemeralTempRoot]
    /// Classified drops. Today exactly one shape: an alias spelling of a
    /// root that is declared separately as a real directory
    /// (`.symlinkRoot`).
    let issues: [ScanIssue]
}

// MARK: - Root model (R2/R3/R14)

/// One RESOLVED ephemeral temp root: the resolved URL — canonical PARENT
/// chain, leaf UNRESOLVED — plus the three declared facts fn-6.2 needs: a
/// human label, the truthful per-root OS-cleanup evidence line, and the
/// static writability class.
struct EphemeralTempRoot: Equatable, Sendable {

    /// The DECLARED write scope of a temp root — static, never probed
    /// (D12 scoping only; it does not drive triggers, D11 revised).
    enum Writability: Equatable, Sendable {
        /// Sticky, multi-writer (`/private/tmp`, mode 1777): another user's
        /// entry is readable but undeletable, so fn-6.2 applies the D12
        /// ownership gate here.
        case worldWritable
        /// Mode 0700, single-writer (`…/T`, `…/C`): every entry is the
        /// current user's by construction, so the ownership gate is vacuous.
        case perUser
    }

    /// The ONE spelling (R3) — canonical PARENT chain with the leaf left
    /// UNRESOLVED, NOT a fully canonical URL: `trustedContainerRoots`,
    /// `originContainer`, root records and item identity parent chains all
    /// derive from exactly this URL.
    ///
    /// Do not "fix" this into a `canonicalize` call. Resolving the leaf is
    /// what registers a symlinked container's DESTINATION as a trusted root,
    /// which the file header explains and which a live cell measures ending
    /// in a deleted `~/Documents` subtree
    /// (`EphemeralTempScannerTests.testResolvedSymlinkContainerIsRefusedAndItsTargetSurvives`).
    let url: URL
    /// Short human label — disambiguates the two per-user containers in
    /// item evidence and root records.
    let label: String
    /// The per-root OS-cleanup evidence line (D7 revised, non-contractual).
    /// fn-6.2 appends the per-item age to this; it never mutates it.
    let cleanupEvidence: String
    /// Declared writability class (R14/D12).
    let writability: EphemeralTempRoot.Writability
}

// MARK: - Declaration + resolution (R2/R3)

/// The closed 3-root declaration and its runtime resolution.
enum EphemeralTempRoots {

    /// Injection seam for the confstr(3) lookup: a name → path resolver.
    /// Production is `confstrPath(_:)`; tests inject failures, alternative
    /// spellings and trailing slashes hermetically.
    typealias ConfstrResolver = (Int32) -> String?

    /// Where a declared root's raw path comes from.
    enum Source: Equatable, Sendable {
        /// A fixed absolute path (`/private/tmp`).
        case absolute(String)
        /// A `confstr(3)` name (`_CS_DARWIN_USER_TEMP_DIR` /
        /// `_CS_DARWIN_USER_CACHE_DIR`).
        case confstrName(Int32)
    }

    /// A root BEFORE resolution: its source plus the three declared facts
    /// that survive into `EphemeralTempRoot` verbatim.
    struct Definition: Equatable, Sendable {
        let source: Source
        let label: String
        let cleanupEvidence: String
        let writability: EphemeralTempRoot.Writability
    }

    // MARK: Evidence strings (D7 revised — shipped copy, asserted verbatim)

    /// The BSD `periodic`/`110.clean-tmps` reaper is gone from modern macOS
    /// (verified absent: `/etc/periodic/daily/`,
    /// `/etc/defaults/periodic.conf`, `com.apple.periodic-daily.plist`), and
    /// nothing replaced it for this location.
    static let sharedTempEvidence = "no periodic reaper on modern macOS"

    /// EXACT wording pinned by D7 (r3, F2): "does not routinely prune …
    /// during normal operation" — never a "never prunes" absolute, which
    /// would contradict the container's removal on safe boot (engineering
    /// context, not shipped copy).
    static let userCacheEvidence =
        "macOS does not routinely prune this location during normal operation"

    /// Non-contractual "may", and no behavioral mechanics: the OS's own
    /// reaper for this container ages by ACCESS time on a shorter clock, but
    /// that figure is observed and non-API, so it stays an engineering note
    /// and never appears in shipped copy. The comparison holds at the
    /// shipped 7-day default (fn-6.4's CLI override is invocation-scoped and
    /// the wording stays a "may", never a guarantee about either side).
    static let userTempEvidence =
        "macOS may reap older untouched files here; this age gate is more conservative"

    // MARK: Declarations

    /// `/private/tmp` — declared in its canonical spelling (`/tmp` is a
    /// symlink to `private/tmp`).
    static let sharedTemp = Definition(
        source: .absolute("/private/tmp"),
        label: "Shared temp",
        cleanupEvidence: sharedTempEvidence,
        writability: .worldWritable
    )

    /// The per-user `…/C` container.
    static let userCache = Definition(
        source: .confstrName(_CS_DARWIN_USER_CACHE_DIR),
        label: "Per-user cache container (C)",
        cleanupEvidence: userCacheEvidence,
        writability: .perUser
    )

    /// The per-user `…/T` container.
    static let userTemp = Definition(
        source: .confstrName(_CS_DARWIN_USER_TEMP_DIR),
        label: "Per-user temp container (T)",
        cleanupEvidence: userTempEvidence,
        writability: .perUser
    )

    /// The closed set, in D7 yield/risk priority order. `_CS_DARWIN_USER_DIR`
    /// (`…/0`) is absent ON PURPOSE and must never be added here.
    static let definitions: [Definition] = [sharedTemp, userCache, userTemp]

    // MARK: Resolution

    /// The remedy sentence for a root the kernel table named at CONSTRUCTION,
    /// spelled ONCE (the deterministic-bound rule: a refusal's message must
    /// say whether a retry can differ). It says relaunch, not re-scan,
    /// because this verdict is stored and replayed — see
    /// `ScanIssue.Kind.mountedVolumeRootAtRegistration`. Deliberately not
    /// `EphemeralTempScanner.mountRemedy`: that sentence ends "then re-scan",
    /// which is the remedy for the arm that re-reads the table per scan.
    static let registrationMountRemedy =
        "Eject or unmount the volume, then relaunch Cacheout to see what "
        + "stands at this name"

    /// Resolve the declared roots, in declaration order.
    ///
    /// Per definition: obtain the raw path (constant, or confstr) → drop it
    /// silently if the lookup failed or produced a non-absolute / bare-`/`
    /// value → normalize the trailing slash → resolve ONCE, parent chain
    /// only → drop it, with a classified issue, if the kernel mount table
    /// already names that spelling. The surviving spellings then go through
    /// the two halves documented at the head of this file: real-directory
    /// de-dupe by inode identity, then alias suppression with a classified
    /// issue.
    ///
    /// Existence and permissions are still not this layer's business (R11 —
    /// that is scan time, fn-6.2's contract). The probes here are the `lstat`
    /// kind of each declared LEAF and, for a leaf that is a symlink, ONE
    /// `readlink(2)` of that link's own content. They decide only which of
    /// two spellings of the same directory to keep: they never admit or
    /// refuse a root on their own, and a root nothing else covers survives
    /// whatever they say (including `.absent` and `.failed`).
    ///
    /// NOTHING a declared leaf points AT is touched (PR #459 codex r12) —
    /// see the file header's "Nothing a symlink leaf points at is contacted".
    ///
    /// The ONE case where a declared root is refused here is a volume mounted
    /// exactly at it (PR #459 codex r15) — refused from the kernel table,
    /// before either probe above runs, because both of them block on an
    /// unresponsive hard mount and this is app-construction time.
    static func resolve(
        provider: FileSystemIdentityProvider = FileSystemIdentityProvider(),
        confstrPath: ConfstrResolver = EphemeralTempRoots.confstrPath(_:)
    ) -> EphemeralTempRootsResolution {
        // THE KERNEL MOUNT TABLE, read FIRST — before this function names any
        // declared root to the kernel at all (PR #459 codex r15,
        // AVAILABILITY). `getfsstat(MNT_NOWAIT)` reads the kernel's own table
        // and touches no filesystem; `FileSystemIdentityProvider.
        // mountPointPaths` (:208-246) is the one detector, shared with
        // `DepthSafeRemoval`'s whole-tree preflight, `PathGuard`, and
        // fn-6.2's scan-time arms. Reading it here rather than after the
        // spelling stage below is what makes the ordering claim checkable:
        // the snapshot predates every filesystem call this resolution makes.
        let mountTable = Set(provider.mountPointPaths())

        // The declared SPELLINGS, before anything probes them. Nothing in
        // this stage names a declared LEAF to the kernel:
        // `resolveTargetKeepingLeaf` canonicalizes the PARENT and appends the
        // leaf as a string, so a volume mounted AT a root is not contacted by
        // it (a volume mounted at an ANCESTOR is — see the residual in the
        // file header).
        let declaredRoots = definitions.compactMap {
            definition -> (definition: Definition, rawPath: String,
                           declared: URL)? in
            guard let raw = rawPath(for: definition.source, confstrPath: confstrPath),
                  let usable = usableRawPath(raw),
                  let declared = resolvedRoot(fromRawPath: usable, provider: provider)
            else { return nil }
            return (definition: definition, rawPath: usable, declared: declared)
        }

        var issues: [ScanIssue] = []
        // THE OVER-MOUNTED-ROOT PREFLIGHT (PR #459 codex r15, AVAILABILITY).
        // A volume mounted EXACTLY at a declared root, answered from the
        // snapshot above by pure string membership — the kernel spells
        // `f_mntonname` canonically, which is the spelling above whenever the
        // root's own leaf is a real directory, and that is the only case
        // where a mount AT the root exists (mounting resolves its
        // mountpoint, so no mount is ever spelled AS a symlink).
        //
        // It must run BEFORE the probe below, because `lstat(2)` OF a mount
        // point crosses INTO the mounted filesystem — the getattr is served
        // by the foreign fs — so on an unresponsive hard mount that one
        // syscall blocks. And this is CONSTRUCTION, not scan time:
        // `EphemeralTempRoots.resolve` runs inside
        // `SpaceScannerRuntime.production`
        // (`SpaceScannerRuntime.production` (`SpaceScanner.swift:2058`)), which
        // the GUI calls from `CacheoutViewModel.production`
        // (`CacheoutViewModel.swift:533-552`) at the `@MainActor` view
        // model's construction (`CacheoutApp.swift:58`), so the block lands
        // on the main thread before any window, trigger gate or scan exists.
        // Measured through the shipped `??` arm with a table-injected
        // fixture: `resolve` made 3 calls naming the mounted root
        // (`probeKind` at the head of the probe below, then `identity` twice
        // from the de-dupe's `sameLocation`), and `production()` as a whole
        // made 5.
        //
        // The root is DROPPED, not kept-and-skipped, and that difference is
        // the fix: a kept root reaches the runtime's cross-scanner union,
        // where `suppressingAliasShadows`' probe pair
        // (`SpaceScanner.swift:1921-1925`) canonicalizes and probes it —
        // the remaining 2 of those 5 — still during construction. Dropping
        // is also fail-CLOSED in the same shape as alias suppression: the
        // root could not have been scanned (fn-6.2's own arm refuses it) and
        // nothing under it can be admitted for deletion.
        //
        // Never silent: a classified issue rides every inspecting outcome.
        // `.mountedVolumeRootAtRegistration`, NOT fn-6.2's
        // `.mountedVolumeRoot` — the GUI derives the visible row label from
        // the kind alone, and that kind's label ends "then re-scan", which is
        // a remedy the user could perform forever here. This verdict is made
        // once per runtime and replayed from stored `resolutionIssues`; only
        // re-running construction re-reads the table, so the label and the
        // remedy sentence both say relaunch.
        let unmounted = declaredRoots.filter { root in
            guard mountTable.contains(root.declared.path) else { return true }
            issues.append(ScanIssue(
                url: root.declared,
                kind: .mountedVolumeRootAtRegistration,
                detail: "\(root.definition.label) is a mounted volume — the "
                    + "root was not registered, so nothing under it is "
                    + "scanned; its contents belong to that volume. "
                    + registrationMountRemedy
            ))
            return false
        }

        // Probed ONCE per SURVIVING declared root: whether the DECLARED
        // spelling is itself a real directory (`lstat` leaf, no follow).
        // NOTHING here resolves a leaf the probe says is not a real directory
        // — that is the whole no-destination-contact rule, and the two
        // spellings each root is compared BY are the two it already came
        // with.
        let probed = unmounted.map { root in
            (definition: root.definition,
             rawPath: root.rawPath,
             declared: root.declared,
             isDirectory: provider.probeKind(of: root.declared)
                 == .kind(.directory))
        }
        // The REAL-DIRECTORY roots an alias can collapse onto.
        let realDirectories = probed.filter(\.isDirectory)

        var kept: [EphemeralTempRoot] = []
        // The real directories kept so far, parallel to `kept` — compared by
        // inode identity, never string equality.
        var seenRealRoots: [URL] = []
        for root in probed {
            let root0 = EphemeralTempRoot(
                url: root.declared,
                label: root.definition.label,
                cleanupEvidence: root.definition.cleanupEvidence,
                writability: root.definition.writability
            )
            guard root.isDirectory else {
                // Alias suppression. Strictly fail-CLOSED: the alias could
                // never be walked nor admitted as a container, and it is
                // dropped ONLY when a real-directory root it demonstrably
                // names survives — so every entry it could have covered is
                // still scanned, through the spelling that also passes the
                // gates. Never silent: the same `.symlinkRoot` kind the
                // walk-time gate would have produced, naming the covering
                // root.
                if let target = aliasTargetPath(of: root.declared,
                                                provider: provider),
                   let covering = realDirectories.first(where: {
                       $0.declared.path == target || $0.rawPath == target
                   }) {
                    issues.append(ScanIssue(
                        url: root.declared,
                        kind: .symlinkRoot,
                        detail: "\(root.definition.label) is not a real "
                            + "directory and aliases \(covering.declared.path), "
                            + "which is declared separately — the alias was "
                            + "dropped and that root is scanned instead"
                    ))
                    continue
                }
                // Named nothing this resolution holds: passes through
                // verbatim, and fn-6.2's no-follow root gate classifies it at
                // scan time.
                kept.append(root0)
                continue
            }
            guard !seenRealRoots.contains(
                where: { provider.sameLocation($0, root.declared) }
            ) else { continue } // exact duplicate of an earlier real root
            seenRealRoots.append(root.declared)
            kept.append(root0)
        }
        return EphemeralTempRootsResolution(roots: kept, issues: issues)
    }

    /// The absolute path a DECLARED spelling's symlink content names, or
    /// `nil` when the spelling is not a symlink, the read fails, or the
    /// content cannot be turned into an absolute path WITHOUT touching what
    /// it names.
    ///
    /// One `readlink(2)` on the link itself
    /// (`FileSystemIdentityProvider.symlinkTarget(of:)`), then string
    /// arithmetic. The result is a NAME, never a resolved location: it is
    /// only ever compared, never registered, walked or opened.
    private static func aliasTargetPath(
        of declared: URL, provider: FileSystemIdentityProvider
    ) -> String? {
        guard let content = provider.symlinkTarget(of: declared) else {
            return nil
        }
        return lexicalTargetPath(ofLink: declared, content: content)
    }

    /// `content` as an absolute path, folded LEXICALLY — no syscall of any
    /// kind. A relative target is joined to the link's own directory (already
    /// parent-canonical, since `declared` came from `resolvedRoot`); `.` is
    /// dropped and `..` pops a component in the STRING, because popping it
    /// against the filesystem is precisely the resolution this avoids.
    ///
    /// `nil` for anything that is not a usable comparison subject: empty
    /// content, a `..` that walks off the root, and a target of `/` itself.
    static func lexicalTargetPath(ofLink link: URL, content: String) -> String? {
        guard !content.isEmpty else { return nil }
        let joined = content.hasPrefix("/")
            ? content
            : link.deletingLastPathComponent().path + "/" + content
        var components: [String] = []
        for component in joined.split(separator: "/") {
            switch component {
            case ".":
                continue
            case "..":
                guard !components.isEmpty else { return nil }
                components.removeLast()
            default:
                components.append(String(component))
            }
        }
        guard !components.isEmpty else { return nil }
        return "/" + components.joined(separator: "/")
    }

    /// The raw, un-normalized path for a source — `nil` when a confstr
    /// lookup failed (the root is then silently absent; never substituted).
    private static func rawPath(
        for source: Source, confstrPath: ConfstrResolver
    ) -> String? {
        switch source {
        case .absolute(let path): return path
        case .confstrName(let name): return confstrPath(name)
        }
    }

    /// Trailing-slash normalization + the ONE resolution (R3): canonical
    /// PARENT CHAIN, leaf appended UNRESOLVED. `nil` for anything that is not
    /// a usable root: an empty or relative path, or `/` itself — a filesystem
    /// root can never be a temp container, and registering it would hand the
    /// deletion layer the widest possible trusted root.
    ///
    /// NOT named `canonicalRoot` (r8, D5): the result is deliberately not
    /// canonical when the leaf is a link, and a name that says otherwise is
    /// how a maintainer talks themselves into `canonicalize`.
    ///
    /// The leaf is deliberately NOT followed. This URL becomes a trusted
    /// container root, so resolving a symlink leaf here would register the
    /// link's DESTINATION — an attacker-chosen or user-relocated directory —
    /// as a temp root, past every later gate (they all then inspect the real
    /// destination directory, which is genuine and stable). Preserved, the
    /// link is what fn-6.2's no-follow root gate sees, and it refuses it
    /// visibly. Probing nothing is still this layer's contract: this is a
    /// spelling transform, and whether the leaf IS a link is judged at scan
    /// time, where absence and denial are already told apart.
    static func resolvedRoot(
        fromRawPath raw: String,
        provider: FileSystemIdentityProvider = FileSystemIdentityProvider()
    ) -> URL? {
        guard let usable = usableRawPath(raw) else { return nil }
        return provider.resolveTargetKeepingLeaf(URL(fileURLWithPath: usable))
    }

    /// The trailing-slash normalization and the usability verdict on their
    /// own, so `resolve` can keep the SOURCE spelling beside the resolved one
    /// (an alias's link content is compared against both — see
    /// `aliasTargetPath`). Idempotent: its own output passes back through
    /// unchanged.
    static func usableRawPath(_ raw: String) -> String? {
        var trimmed = raw
        // Live confstr output ends in "/" — strip every trailing slash, but
        // never past the leading one.
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard trimmed.hasPrefix("/"), trimmed != "/" else { return nil }
        return trimmed
    }

    /// `confstr(3)` for a configuration name, two-call sizing idiom
    /// (swift-nio precedent). `nil` on EVERY failure shape — a 0 return
    /// (error `errno` EIO/EINVAL, or "no defined value" with `errno`
    /// untouched) and a truncating second call alike. Never traps, never
    /// guesses a path.
    static func confstrPath(_ name: Int32) -> String? {
        // Call 1: required buffer size, INCLUDING the NUL terminator.
        let sized = confstr(name, nil, 0)
        // A path can be at most PATH_MAX bytes with its terminator; anything
        // larger is not a path this process can use, and refusing to
        // allocate it keeps a syscall result from sizing our heap.
        guard sized > 0, sized <= Int(PATH_MAX) else { return nil }
        var buffer = [CChar](repeating: 0, count: sized)
        // Call 2: fill it. 0 ⇒ failure; > sized ⇒ the value was truncated.
        let written = confstr(name, &buffer, sized)
        guard written > 0, written <= sized else { return nil }
        return String(cString: buffer)
    }
}

// MARK: - Config surface (fn-6.1, R7)

/// The ephemeral-temp sweep's two knobs — minimum size (decimal MB) and age
/// (days) — layered defaults → UserDefaults → CLI override at the
/// COMPOSITION site (`SpaceScannerRuntime.production` / the CLI handlers),
/// exactly like `OrphanedCachesSweepConfig`. Fail-safe by contract:
/// conversions are overflow-checked and never trap; an invalid PERSISTED
/// value (≤ 0, non-numeric, non-integral, boolean, overflow) falls back to
/// the default for that scan and is NEVER rewritten — a value this build
/// cannot read may be meaningful to another build.
///
/// Deliberately a CLONE of the orphaned-caches template rather than a shared
/// generic: the two scanners' config surfaces version independently (their
/// keys, defaults and CLI flag families are separate user-visible contracts).
/// The clone is kept honest by a test that pins
/// `persistedPositiveInteger(_:)` to the template's verdicts input-by-input.
enum EphemeralTempSweepConfig {

    /// The resolved knobs handed to the scanner at construction (never
    /// context state — thresholds are construction state, `ScanContext`
    /// carries none).
    struct Thresholds: Equatable, Sendable {
        /// Candidate size floor: allocated bytes AT-OR-ABOVE this qualify.
        let sizeFloorBytes: Int64
        /// Staleness age: newest content STRICTLY older than this (against
        /// the scanner's injected clock) qualifies.
        let staleAge: TimeInterval
    }

    /// UserDefaults keys, per the `cacheout.<scanner>.<knob>` template.
    static let ageDaysKey = "cacheout.ephemeralTmp.ageDays"
    static let minSizeMBKey = "cacheout.ephemeralTmp.minSizeMB"

    /// 7 days: longer than any OS reaper's own clock for these locations,
    /// and long enough that a workspace paused for LESS THAN A WEEK stays
    /// untouched. Not an unbounded promise — a workspace nothing has written
    /// to for seven days is exactly what this scanner exists to list, however
    /// live the process holding it still is.
    static let defaultAgeDays: Int64 = 7
    /// 10 MB: small enough to surface real scratchpads, large enough that
    /// ordinary temp files never appear.
    static let defaultMinSizeMB: Int64 = 10

    /// 10 MB / 7 days, through the same checked conversions as every other
    /// value (the force-unwraps are compile-time constants proven finite).
    static let defaultThresholds = Thresholds(
        sizeFloorBytes: sizeFloorBytes(fromMB: defaultMinSizeMB)!,
        staleAge: staleAge(fromDays: defaultAgeDays)!
    )

    /// MB → bytes at ×1,000,000 — DECIMAL, matching the app's base-10
    /// `ByteCountFormatter` display convention. `nil` on non-positive or
    /// overflowing input (never traps).
    static func sizeFloorBytes(fromMB megabytes: Int64) -> Int64? {
        guard megabytes > 0 else { return nil }
        let (bytes, overflow) = megabytes
            .multipliedReportingOverflow(by: 1_000_000)
        return overflow ? nil : bytes
    }

    /// Days → seconds at ×86,400, overflow-checked in integer space before
    /// the `TimeInterval` conversion. `nil` on non-positive or overflowing
    /// input (never traps).
    static func staleAge(fromDays days: Int64) -> TimeInterval? {
        guard days > 0 else { return nil }
        let (seconds, overflow) = days.multipliedReportingOverflow(by: 86_400)
        return overflow ? nil : TimeInterval(seconds)
    }

    /// The layered resolution: an invocation-scoped OVERRIDE (CLI flag —
    /// already validated by the CLI's invalid-arguments gate) wins; else a
    /// VALID persisted value; else the default. Each half resolves
    /// independently, and nothing is ever written back to UserDefaults.
    static func resolvedThresholds(
        defaults: UserDefaults = .standard,
        minSizeMBOverride: Int64? = nil,
        ageDaysOverride: Int64? = nil
    ) -> Thresholds {
        let minSizeMB = minSizeMBOverride
            ?? persistedPositiveInteger(defaults.object(forKey: minSizeMBKey))
        let ageDays = ageDaysOverride
            ?? persistedPositiveInteger(defaults.object(forKey: ageDaysKey))
        // A value that parses but overflows its conversion is INVALID too —
        // same fallback, still no rewrite.
        return Thresholds(
            sizeFloorBytes: minSizeMB.flatMap(sizeFloorBytes(fromMB:))
                ?? defaultThresholds.sizeFloorBytes,
            staleAge: ageDays.flatMap(staleAge(fromDays:))
                ?? defaultThresholds.staleAge
        )
    }

    /// A persisted value read as a positive INTEGER, or nil when it is
    /// absent or invalid (non-numeric, non-integral, boolean, zero,
    /// negative, or past Int64). Both NSNumber (the normal
    /// `set(_:forKey:)` shapes) and numeric strings are accepted —
    /// nothing else.
    static func persistedPositiveInteger(_ stored: Any?) -> Int64? {
        if let number = stored as? NSNumber {
            // A persisted Bool bridges to NSNumber (`true` → 1) — a
            // boolean is not a positive-integer threshold, so it is
            // invalid like any other non-numeric value (falls back to the
            // default, never rewritten). CFBoolean is the toll-free type
            // a bridged Bool actually carries.
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else {
                return nil
            }
            let value = number.doubleValue
            guard value.isFinite, value > 0,
                  value == value.rounded(),
                  let integer = Int64(exactly: value.rounded())
            else { return nil }
            return integer
        }
        if let string = stored as? String {
            guard let integer = Int64(string), integer > 0 else { return nil }
            return integer
        }
        return nil
    }
}
