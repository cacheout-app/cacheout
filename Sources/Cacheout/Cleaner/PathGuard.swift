/// # PathGuard — Deletion-Target Admission & Containment (D4)
///
/// The single source of truth for "may I delete this URL?". Nothing in the
/// clean path may remove, trash, or hand to a subprocess any path that has not
/// passed through this type. Two admission layers exist:
///
/// 1. **Category-scoped deletion roots** (`admitDeletionRoot`): a URL is
///    admitted ONLY against the requesting category's own
///    `CategoryAdmissionPolicy` — the exact declared roots from all three
///    path-bearing discovery kinds (`.staticPath`, `.absolutePath`, `.probed`
///    fallbacks), or a constrained version drift of a static/probed root in
///    one of two shapes: a one-component SIBLING (same parent, basename
///    matching the declared stem modulo a trailing version suffix:
///    `store/v11` is fine when `v10` was declared) or a pure-version CHILD
///    directly below the declared root (`store/v10` when `store` was
///    declared — probes like `pnpm store path` return the versioned store
///    below the declared fallback, and the child is strictly inside a root
///    already admissible in full). Drift is never a parent grant — the
///    parent of `~/Library/Caches/Homebrew` is the whole cache namespace and
///    the parent of `~/.npm` is `$HOME` itself. `.absolutePath` roots admit
///    exactly, no drift.
/// 2. **Containers**, in TWO type-enforced modes (fn-3.4, R9): the
///    configured container roots (node_modules search roots, the
///    orphaned-caches sweep root), and only those. `admitSearchRoot` is the
///    scan-time, read-only traversal check; `admitContainer(_:snapshot:)`
///    is the delete-time check, identity-bound to the scan-session
///    `ContainerSnapshot` — and the only way to mint the deletion-capable
///    `AdmittedContainer` token. Deliberately split from deletion roots — a
///    search root like `~/Documents` is a valid place to LOOK for build
///    artifacts while remaining refused as a deletion target. BOTH modes run
///    the shared CONTAINER-ROOT ADMISSION POLICY on the matched configured
///    root (R16 layer (c), fn-4.5): a configured `/`, volume root, or
///    `$HOME` — in canonical or alias spelling — never admits, no matter
///    what configuration produced it.
///
/// A deny list applies regardless of policy: `/`, any volume root (device-id
/// change against the parent — this also catches the `/System/Volumes/Data`
/// firmlink), `$HOME` in any spelling, and the protected first-level `$HOME`
/// children (`Applications`, `Desktop`, `Documents`, `Downloads`, `Library`,
/// `Movies`, `Music`, `Pictures`, `Public` — dot-directories deliberately
/// unprotected; they are governed by category policy instead).
///
/// Validation modes for things INSIDE an admitted root/container:
/// - `validateContainedChild(_:of:)` — strict descendant of an admitted root,
///   compared as `pathComponents` arrays (never `hasPrefix`: `/a/bc` is not
///   inside `/a/b`). Ancestors of the child resolve; the leaf never does.
/// - `validateRemovableItem(_:inside:)` — strict descendant of an admitted
///   container PLUS the deny-list re-check (including volume-root/mount-point
///   and cross-device refusal, R15).
/// - `validateSubprocessTraversalDirectory(_:inside:containment:)` (fn-5.4,
///   D13) — for a directory handed to a SUBPROCESS that FOLLOWS it. The leaf
///   IS resolved here, deliberately: the two operations above leave it
///   unresolved because a deletion target must be removed as the link it is,
///   but git follows what it is handed, so an unresolved-leaf check would
///   pass a symlink-swapped leaf and point the subprocess outside the
///   container.
///
/// All location comparisons go through `FileSystemIdentityProvider` inodes,
/// never strings. Deletion itself always uses the UNRESOLVED URL (the caller's
/// `AdmittedRoot.requestedURL`) so a symlink is removed as a link.

import Foundation

// MARK: - Policy

/// The set of roots one category may delete, derived from its own discovery
/// declarations. Built per category — policies are never shared or unioned.
struct CategoryAdmissionPolicy {

    struct DeclaredRoot {
        /// Declared location (home-relative entries already resolved against
        /// the injectable home).
        let url: URL
        /// Version drift (one-component sibling or pure-version child)
        /// allowed? True for `.staticPath` and `.probed` fallbacks; false
        /// for `.absolutePath` (exact only).
        let allowsSiblingDrift: Bool
    }

    let declaredRoots: [DeclaredRoot]

    init(declaredRoots: [DeclaredRoot]) {
        self.declaredRoots = declaredRoots
    }

    /// Derive a policy from a category's discovery entries. Mirrors
    /// `CacheCategory.resolvedPaths(home:)` path construction — both anchor
    /// to the SAME injected home: `.staticPath` and
    /// non-`/`-prefixed probed fallbacks are home-relative; `.probed` COMMAND
    /// output contributes nothing (probe stdout is untrusted — it must be
    /// admitted against the declared roots like any other candidate).
    init(category: CacheCategory, home: URL) {
        var roots: [DeclaredRoot] = []
        for entry in category.discovery {
            switch entry {
            case .staticPath(let relative):
                roots.append(DeclaredRoot(
                    url: home.appendingPathComponent(relative),
                    allowsSiblingDrift: true
                ))
            case .absolutePath(let absolute):
                roots.append(DeclaredRoot(
                    url: URL(fileURLWithPath: absolute),
                    allowsSiblingDrift: false
                ))
            case .probed(_, _, let fallbacks):
                for fallback in fallbacks {
                    let url = fallback.hasPrefix("/")
                        ? URL(fileURLWithPath: fallback)
                        : home.appendingPathComponent(fallback)
                    roots.append(DeclaredRoot(url: url, allowsSiblingDrift: true))
                }
            }
        }
        self.declaredRoots = roots
    }
}

// MARK: - Scan-session container snapshot (fn-3.4, R9)

/// The no-follow `(device, inode)` identity of each container root the
/// runtime's validated-scan entry point hands `capture`, taken BEFORE any
/// scanner task launches. Delete-time container admission is IDENTITY-BOUND
/// to this snapshot: cleaning a set of items must use the snapshot of the
/// session that PRODUCED them, so a container replaced between scan and
/// clean — symlink swap, rm+mkdir inode replacement, or an ancestor swap
/// redirecting the resolved location — mismatches and is refused.
///
/// WHICH roots those are is the caller's decision, and it is not every
/// registered one: `SpaceScannerRuntime.sessionContainerRoots` passes only
/// the roots the session's PARTICIPATING scanners can reach (PR #459 codex
/// r16), so a deferred or out-of-subset scanner's roots are never lstat'ed.
/// That function owns the argument that this cannot strand a clean.
///
/// Absent roots are OMITTED at capture: a root that did not exist when the
/// session started can never have produced items in it, and a root created
/// later is refused fail-closed until the next session re-captures
/// (self-healing). Capture is deliberately part of the SESSION, never of
/// runtime construction — a container created after app launch but before a
/// later scan must still be cleanable in that scan's session.
///
/// OVER-MOUNTED roots are omitted the same way (PR #459 review r6, codex
/// C2 — AVAILABILITY): a root the kernel mount table names EXACTLY is
/// skipped without the identity `lstat`, because that lstat is served by
/// the FOREIGN filesystem (an lstat of a mount point describes the mounted
/// root) — on an unresponsive hard mount it would park the session before
/// any scanner task launches, on EVERY trigger. The omission is fail-closed
/// by the same rule as absence: nothing under a mounted root is ever
/// admitted for deletion (and `admitContainer`'s deny list independently
/// refuses mount-point containers), while the scan side shows the root as
/// a visible refusal naming the unmount remedy. A mount landing between
/// this table read and a capture that already passed is the accepted
/// racing residual — the capture's own lstat can then block; no table
/// re-read closes it, but since fn-4.19 that block costs the session its
/// CAPTURE DEADLINE rather than parking it: `captureBounded` runs the
/// whole loop off the calling thread under a wall-clock budget, and an
/// expiry is reported by the session, never swallowed (a root INSIDE a
/// hung mount — which the table preflight cannot see — is covered by the
/// same budget).
struct ContainerSnapshot: Sendable {

    private let identities: [String: FileSystemIdentityProvider.Identity]

    private init(identities: [String: FileSystemIdentityProvider.Identity]) {
        self.identities = identities
    }

    /// Capture the current no-follow identity of each root (keyed by the
    /// root's declared path spelling). `lstat`-based: a symlink at a root's
    /// path snapshots as the LINK — delete-time admission independently
    /// refuses non-directory containers, so a link identity can never admit.
    ///
    /// The kernel-table preflight (`mountPointPaths`, `getfsstat` with
    /// `MNT_NOWAIT` — no filesystem contact) runs FIRST, so an over-mounted
    /// root is skipped without ever being lstat'ed (the type comment says
    /// why, and why skipping is fail-closed).
    static func capture(
        roots: [URL], provider: FileSystemIdentityProvider
    ) -> ContainerSnapshot {
        let mounted = Set(provider.mountPointPaths())
        var identities: [String: FileSystemIdentityProvider.Identity] = [:]
        for root in roots where !mounted.contains(root.path) {
            if let identity = provider.identity(of: root) {
                identities[root.path] = identity
            }
        }
        return ContainerSnapshot(identities: identities)
    }

    /// A snapshot that captured NOTHING. Admits no container — every
    /// delete-time lookup misses, which is the same fail-closed refusal an
    /// absent root gets — and exists so the session a timed-out capture
    /// produces (`scanValidatedSession`, fn-4.19) can still carry the
    /// non-optional snapshot its shape requires without inventing an
    /// identity nobody read.
    static let empty = ContainerSnapshot(identities: [:])

    /// The bounded capture's result. `.captured` and `.timedOut` are kept
    /// apart — the `BoundedDiskInfo.Outcome` discipline — so a cell cannot
    /// pass one while asserting the other.
    enum BoundedCapture: Sendable {
        case captured(ContainerSnapshot)
        case timedOut
    }

    /// `capture(roots:provider:)` under a wall-clock budget, OFF the calling
    /// thread — the `BoundedDiskInfo.current(within:)` shape (PR #460 codex
    /// r14, V2-1) applied to the capture fn-4.19 measured freezing the app:
    /// the synchronous loop ran on the MainActor's thread and each root's
    /// `lstat` was first contact with whatever answers for that path, so a
    /// hung network mount or unresponsive FUSE volume under ANY session root
    /// — including a root INSIDE a mount, which the `mountPointPaths()`
    /// preflight cannot see — froze the app unbounded and unreported
    /// (measured: a 6 s blocking `identity(of:)` gave a 6.03 s `scan` with
    /// `isMainThread == true`).
    ///
    /// The loop now runs in a detached task racing a `ScanSessionClock`
    /// timer — off the cooperative pool, because a `Task.sleep` deadline
    /// cannot resume while the pool is the thing that is starved — and the
    /// caller resumes on its own executor with whichever arrives first. The
    /// detached band is `.utility`, the SAME band-separation decision the
    /// session producer takes and for the same reason (PR #460 codex r13,
    /// B): this is scan work, and cooperative-pool width is per-band, so a
    /// saturated consumer band (the shape
    /// `testScanIsNotParkedByItsOwnDiskInfoPreambleWhenTheBandIsSaturated`
    /// drives) cannot stop the capture from even STARTING — measured in that
    /// cell: with the band unspecified here, the capture queued behind the
    /// holders and the scan rode this budget instead of finishing. A
    /// saturated `.utility` band (concurrent sessions' own walks) is the
    /// residual the timer still covers: “cannot start” reports exactly like
    /// “started and hung”.
    ///
    /// WHAT IS NOT CLOSED, stated rather than glossed: a losing capture is
    /// ABANDONED, not cancelled — `lstat` takes no deadline, so its thread
    /// stays parked until the volume answers, exactly as `BoundedDiskInfo`
    /// leaks its losing fetch. The bound converts the hang into a report; it
    /// cannot cure the hang. CAN A RETRY DIFFER? Yes — a mount answers or
    /// is unmounted, a saturated band frees — which is what makes reporting
    /// the expiry as retryable honest (`scanValidatedSession` says how it is
    /// reported).
    static func captureBounded(
        roots: [URL], provider: FileSystemIdentityProvider,
        within budget: Duration
    ) async -> BoundedCapture {
        let rendezvous = FirstWinsRendezvous<BoundedCapture>()
        let timer = ScanSessionClock.schedule(after: budget) {
            rendezvous.settle(.timedOut)
        }
        Task.detached(priority: .utility) {
            rendezvous.settle(
                .captured(capture(roots: roots, provider: provider))
            )
        }
        let outcome = await rendezvous.wait()
        timer.cancel()
        return outcome
    }

    /// The captured identity for a registered root's declared path spelling;
    /// nil when the root was absent at capture (refused downstream).
    func identity(
        forRootPath path: String
    ) -> FileSystemIdentityProvider.Identity? {
        identities[path]
    }
}

// MARK: - Admission tokens

/// Proof that a deletion root passed admission. Carries both spellings:
/// `requestedURL` (unresolved — what deletion must use) and `resolvedURL`
/// (canonical — what containment checks compare against).
struct AdmittedRoot {
    let requestedURL: URL
    let resolvedURL: URL
    let matchedDeclaredRoot: URL
    let viaSiblingDrift: Bool
}

/// Proof that a container passed SCAN-TIME (read-only) admission — the
/// traversal check scanners run before walking a search root. Deliberately
/// NOT a deletion capability: `validateRemovableItem` does not accept it.
struct AdmittedSearchRoot {
    let requestedURL: URL
    let resolvedURL: URL
}

/// Proof that a container passed DELETE-TIME, snapshot-bound admission.
/// The initializer is fileprivate (round 9, type-enforced): only
/// `PathGuard.admitContainer(_:snapshot:)` can mint one, so the deletion
/// path (`validateRemovableItem`) is structurally unreachable without a
/// scan-session snapshot — an unbound PathGuard can traverse, never delete.
struct AdmittedContainer {
    let requestedURL: URL
    let resolvedURL: URL

    fileprivate init(requestedURL: URL, resolvedURL: URL) {
        self.requestedURL = requestedURL
        self.resolvedURL = resolvedURL
    }
}

// MARK: - Errors

enum PathGuardError: Error, Equatable {
    /// The filesystem root `/`.
    case deniedFilesystemRoot(path: String)
    /// A volume root / mount point (device id differs from its parent's).
    case deniedVolumeRoot(path: String)
    /// `$HOME` itself, in any spelling.
    case deniedHomeDirectory(path: String)
    /// A protected first-level `$HOME` child (`~/Documents`, `~/Library`, …).
    case deniedProtectedChild(path: String, name: String)
    /// Not a declared root of the requesting category and not an admissible
    /// version-drift sibling.
    case outsideCategoryPolicy(path: String)
    /// Not one of the configured container search roots.
    case notAConfiguredContainer(path: String)
    /// Child validation: the URL is the root/container itself, not a descendant.
    case isRootItself(path: String)
    /// Child validation: not a strict descendant (includes name-prefix
    /// siblings and symlink-ancestor escapes).
    case notADescendant(path: String, root: String)
    /// Item sits on a different device than its container (R15).
    case crossDevice(path: String, containerPath: String)
    /// Delete-time container admission failed the identity gate (fn-3.4,
    /// R9): the container spelling is a symlink or non-directory, its
    /// no-follow (device, inode) no longer matches the scan-session
    /// snapshot, the root was absent at capture, or no snapshot exists for
    /// this clean at all. ONE case for the whole class — detail rides the
    /// message.
    case containerUnavailable(path: String)
    /// SUBPROCESS-TRAVERSAL refusal (fn-5.4, D13): a path a subprocess will
    /// FOLLOW does not `lstat` as a real directory — a symlink leaf, a
    /// regular file, or a leaf that cannot be inspected at all.
    case notATraversableDirectory(path: String)
}

extension PathGuardError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .deniedFilesystemRoot(let path):
            return "Refusing to touch the filesystem root: \(path)"
        case .deniedVolumeRoot(let path):
            return "Refusing to touch a volume root / mount point: \(path)"
        case .deniedHomeDirectory(let path):
            return "Refusing to touch the home directory: \(path)"
        case .deniedProtectedChild(let path, let name):
            return "Refusing to touch protected folder ~/\(name): \(path)"
        case .outsideCategoryPolicy(let path):
            return "Path is not a declared root of this category: \(path)"
        case .notAConfiguredContainer(let path):
            return "Path is not a configured search root: \(path)"
        case .isRootItself(let path):
            return "Path is the root itself, not a child: \(path)"
        case .notADescendant(let path, let root):
            return "Path is not strictly inside \(root): \(path)"
        case .crossDevice(let path, let containerPath):
            return "Path is on a different volume than its container \(containerPath): \(path)"
        case .containerUnavailable(let path):
            return "Container is unavailable or its identity changed since the scan: \(path)"
        case .notATraversableDirectory(let path):
            return "Path is not a real directory a subprocess may be pointed at: \(path)"
        }
    }
}

// MARK: - PathGuard

final class PathGuard {

    /// First-level `$HOME` children refused as deletion targets regardless of
    /// policy. Dot-directories (`~/.npm`, `~/.gradle`, …) are deliberately
    /// absent — they are governed by category policy.
    static let protectedFirstLevelChildren: Set<String> = [
        "Applications", "Desktop", "Documents", "Downloads",
        "Library", "Movies", "Music", "Pictures", "Public",
    ]

    private let provider: FileSystemIdentityProvider
    private let home: URL
    private let resolvedHome: URL
    private let containerRoots: [URL]

    /// - Parameters:
    ///   - home: the home directory admission is anchored to (injectable —
    ///     tests use a fixture home; production passes the real one).
    ///   - containerRoots: configured node_modules search roots for
    ///     `admitContainer`.
    ///   - provider: identity provider (tests may subclass to inject devices).
    init(
        home: URL,
        containerRoots: [URL] = [],
        provider: FileSystemIdentityProvider = FileSystemIdentityProvider()
    ) {
        self.provider = provider
        self.home = home
        self.resolvedHome = provider.canonicalize(home)
        self.containerRoots = containerRoots
    }

    // MARK: Deletion-root admission

    /// Admit `url` as a deletion root for the category described by `policy`.
    /// The URL is judged by its fully-resolved location (a symlink root is
    /// admitted or refused based on where it really points), but the returned
    /// token retains the unresolved `requestedURL` for the actual deletion.
    func admitDeletionRoot(
        _ url: URL, policy: CategoryAdmissionPolicy
    ) throws -> AdmittedRoot {
        let resolved = provider.canonicalize(url)
        try denyCheck(resolved)

        for declared in policy.declaredRoots {
            let declaredResolved = provider.canonicalize(declared.url)
            if provider.sameLocation(resolved, declaredResolved) {
                return AdmittedRoot(
                    requestedURL: url,
                    resolvedURL: resolved,
                    matchedDeclaredRoot: declared.url,
                    viaSiblingDrift: false
                )
            }
            if declared.allowsSiblingDrift,
               isVersionDrift(resolved, ofDeclared: declaredResolved) {
                return AdmittedRoot(
                    requestedURL: url,
                    resolvedURL: resolved,
                    matchedDeclaredRoot: declared.url,
                    viaSiblingDrift: true
                )
            }
        }
        throw PathGuardError.outsideCategoryPolicy(path: resolved.path)
    }

    // MARK: Container admission (two modes, type-enforced — fn-3.4 round 9)

    /// SCAN-TIME traversal admission: `url` must be one of the configured
    /// search roots (by inode identity). Containers are places to LOOK, not
    /// to delete — this check is read-only, snapshot-free (scanners never
    /// see snapshots; `ScanContext` cannot carry one), and its token is
    /// deliberately NOT accepted by `validateRemovableItem`. This is why
    /// `~/Documents` can be a container while `admitDeletionRoot` refuses it.
    func admitSearchRoot(_ url: URL) throws -> AdmittedSearchRoot {
        let resolved = try matchConfiguredRoot(url).resolved
        return AdmittedSearchRoot(requestedURL: url, resolvedURL: resolved)
    }

    /// DELETE-TIME container admission, IDENTITY-BOUND to the scan-session
    /// snapshot (fn-3.4, R9 — a NARROWING of the swap window, deliberately
    /// not full TOCTOU closure; see the epic's Decision Context). The
    /// as-built resolution alone canonicalizes AT DELETE TIME, so a
    /// container replaced by a symlink between scan and clean resolves both
    /// sides through the new link and matches — this gate closes every
    /// persistent-swap scenario:
    ///
    /// 1. `url` must match a configured root by inode identity (as before);
    /// 2. the CONFIGURED root's declared spelling AND the caller's origin
    ///    spelling must both `lstat` no-follow as REAL directories (a
    ///    symlink or non-directory container never admits);
    /// 3. the configured root's current no-follow `(device, inode)` must
    ///    EQUAL its snapshot capture — an rm+mkdir replacement (new inode)
    ///    and an ANCESTOR swap redirecting the resolved location (which a
    ///    leaf-only lstat would miss) both mismatch; a root ABSENT from the
    ///    snapshot is refused (fail-closed; the next session re-captures).
    ///
    /// Callers re-run this immediately before the destructive call. The
    /// window between that final check and the path-based `removeItem`
    /// remains open by explicit decision — the cleaner runs unprivileged as
    /// the user, so a same-user racer could delete the target directly.
    func admitContainer(
        _ url: URL, snapshot: ContainerSnapshot
    ) throws -> AdmittedContainer {
        let (matchedRoot, resolved) = try matchConfiguredRoot(url)

        // (2) No-follow reality gate on BOTH spellings: the configured
        // root's declared path and the origin claim's own spelling.
        for spelling in [matchedRoot, url]
        where provider.probeKind(of: spelling) != .kind(.directory) {
            throw PathGuardError.containerUnavailable(path: spelling.path)
        }

        // (3) Identity binding against the session snapshot, keyed by the
        // configured root's declared spelling (the same spelling the
        // runtime captured).
        guard let captured = snapshot.identity(forRootPath: matchedRoot.path),
              provider.identity(of: matchedRoot) == captured else {
            throw PathGuardError.containerUnavailable(path: matchedRoot.path)
        }

        return AdmittedContainer(requestedURL: url, resolvedURL: resolved)
    }

    /// Shared root matching for both admission modes: inode identity against
    /// each configured root, resolved forms compared.
    ///
    /// **R16 layer (c), fn-4.5** — the CONTAINER-ROOT ADMISSION POLICY runs
    /// HERE, on the MATCHED CONFIGURED ROOT (canonicalized first), so BOTH
    /// admission modes (`admitSearchRoot` and `admitContainer`) enforce it
    /// from one place: a dangerous root that slipped past every resolution
    /// layer (persisted config, CLI flag, Settings) still cannot admit.
    /// Without it, `matchConfiguredRoot` was inode-identity ONLY while
    /// `denyCheck` applied solely to `validateRemovableItem` TARGETS — a
    /// configured `/` container would have authorized deletion of nearly any
    /// same-device descendant that passed the target-level checks.
    ///
    /// The check is on the CANONICAL matched root (alias doctrine): a
    /// symlink alias of `/`, of a volume root, or of `$HOME` is caught,
    /// while a symlinked-ANCESTOR spelling of a legal root canonicalizes to
    /// its legal target and admits. Protected first-level children
    /// (`~/Documents`) stay admissible as containers — the policy is
    /// `denyCheck` MINUS the protected-children clause (the container-vs-
    /// deletion-target split `admitSearchRoot` documents), which is why
    /// every existing scanner's roots still admit.
    private func matchConfiguredRoot(
        _ url: URL
    ) throws -> (matched: URL, resolved: URL) {
        // THE KERNEL-TABLE PREFLIGHT (PR #459 review r6, codex C2 —
        // AVAILABILITY). `canonicalize` is realpath(3), whose resolution of
        // an over-mounted path's final component is served by the MOUNTED
        // filesystem — first contact, which on an unresponsive hard mount
        // parks the calling thread. Two arms, answered from the kernel's
        // own table (`getfsstat(MNT_NOWAIT)` — no filesystem contact)
        // BEFORE any canonicalization:
        //
        // 1. An over-mounted `url` is refused outright, with the SAME
        //    `.deniedVolumeRoot` the policy check would have reached after
        //    five foreign-fs syscalls — a mount-point container could never
        //    admit (`coreDenyCheck` refuses it), so nothing legitimate is
        //    lost, only the contact.
        // 2. An over-mounted CONFIGURED root is skipped in the loop, so
        //    admitting a healthy SIBLING never realpaths the mounted one —
        //    without this, one dead volume at any registered root wedged
        //    every other root's admission too.
        //
        // The filesystem root `/` is exempt from both: it is always in the
        // table, is not foreign, and must keep its own
        // `.deniedFilesystemRoot` classification. Residuals at measured
        // scope: a mounted ANCESTOR of `url` still resolves through
        // realpath, and an ALIAS spelling of an over-mounted root falls
        // through to the resolution it names (both refuse; the alias case
        // classifies as not-configured once the mounted root is skipped).
        let mounted = Set(provider.mountPointPaths())
        if url.path != "/", mounted.contains(url.path) {
            throw PathGuardError.deniedVolumeRoot(path: url.path)
        }
        let resolved = provider.canonicalize(url)
        for root in containerRoots
        where root.path == "/" || !mounted.contains(root.path) {
            let canonicalRoot = provider.canonicalize(root)
            if provider.sameLocation(resolved, canonicalRoot) {
                try containerRootPolicyCheck(canonical: canonicalRoot)
                return (root, resolved)
            }
        }
        throw PathGuardError.notAConfiguredContainer(path: resolved.path)
    }

    /// The shared container-root admission policy (`validateContainerRoot`)
    /// bound to THIS guard's already-canonical home and an already-canonical
    /// root — the identical policy body, zero re-canonicalization. One
    /// definition, three call sites (epic R16).
    private func containerRootPolicyCheck(canonical root: URL) throws {
        try Self.coreDenyCheck(
            root, resolvedHome: resolvedHome, provider: provider
        )
    }

    // MARK: Containment validation

    /// `child` must be a STRICT descendant of the admitted root. Ancestors of
    /// the child are resolved (a symlink ancestor that escapes the root makes
    /// the check fail); the leaf itself never is — a symlink child stays a
    /// link, and a non-existent leaf still validates (already-gone children
    /// are the caller's skip case). Comparison is by `pathComponents` arrays,
    /// never `hasPrefix`.
    func validateContainedChild(_ child: URL, of root: AdmittedRoot) throws {
        try requireStrictDescendant(child, of: root.resolvedURL)
    }

    /// `item` must be a strict descendant of the admitted container AND
    /// survive the deny-list re-check (volume roots / mount points included)
    /// AND sit on the container's device (R15 mount rule).
    func validateRemovableItem(
        _ item: URL, inside container: AdmittedContainer
    ) throws {
        let resolved = try requireStrictDescendant(item, of: container.resolvedURL)
        try denyCheck(resolved)
        if let itemDevice = provider.deviceID(of: resolved),
           let containerDevice = provider.deviceID(of: container.resolvedURL),
           itemDevice != containerDevice {
            throw PathGuardError.crossDevice(
                path: resolved.path, containerPath: container.resolvedURL.path
            )
        }
    }

    // MARK: Subprocess-traversal validation (fn-5.4, D13)

    /// Which containment relationship a traversed path must hold to its
    /// admitted container.
    enum SubprocessTraversalContainment: Equatable {
        /// The default for every MUTATED path — the admin container, a
        /// worktree, an affected admin directory.
        case strictDescendant
        /// `parentRepoWorkingDir` ALONE (epic round 4): a dev root that IS a
        /// repository is a legal, common shape — git is pointed at it with
        /// `-C`, but only its strictly-contained admin data is mutated.
        case descendantOrEqual
    }

    /// Validate a directory that is about to be handed to a SUBPROCESS which
    /// FOLLOWS it (`git -C <dir>`, `git -C <dir> status`) — the D13
    /// guard.
    ///
    /// IT IS NOT RUN IMMEDIATELY BEFORE EVERY SUCH INVOCATION, and the
    /// wording that said so was retired from `WorktreeReclaimPerformer` as
    /// false (PR #460 codex r2) while surviving here (r3). What that file's
    /// guard-site table actually guarantees is weaker and true: every path a
    /// git invocation traverses is covered by a call to this function that
    /// ran after admission and before that invocation — one guard SITE can
    /// cover several invocations. A guard is a PATH check, not a lock and not
    /// a handle: it cannot bind what git resolves a microsecond later, so
    /// re-running it narrows a window and never closes one, and re-runs no
    /// cell can distinguish would only be unevidenced guards.
    ///
    /// `validateRemovableItem` is the WRONG check here and the difference is
    /// the whole point: it deliberately leaves the LEAF unresolved because a
    /// deletion target must be removed as the link it is. Git has no such
    /// rule — it follows the path it is handed — so a leaf swapped to a
    /// symlink after the scan would satisfy an unresolved-spelling
    /// containment check and still point git at another repository.
    ///
    /// Four gates, in order:
    /// 1. the LEAF must `lstat` (no-follow) as a REAL directory — a symlink,
    ///    a regular file, an absent path, and an un-inspectable one all
    ///    refuse;
    /// 2. the path is FULLY canonicalized (leaf included — the opposite of
    ///    `resolveTargetKeepingLeaf`);
    /// 3. the canonical form must sit inside the container's canonical
    ///    identity under `containment`, compared as `pathComponents` arrays
    ///    (never `hasPrefix`);
    /// 4. it must share the container's device — and, unlike
    ///    `validateRemovableItem`'s cross-device rule, an UNREADABLE device
    ///    id on either side refuses too: a path this guard cannot prove is
    ///    on-device is not a path a subprocess may be pointed at.
    ///
    /// The deny list is deliberately NOT re-run: `matchConfiguredRoot`
    /// already applied the container-root admission policy to the container
    /// itself, and the protected-first-level-children clause would refuse the
    /// LEGAL `parentRepoWorkingDir == ~/Documents` shape that
    /// `.descendantOrEqual` exists to allow (containers are places to look,
    /// deletion targets are not — PathGuard's standing split).
    func validateSubprocessTraversalDirectory(
        _ url: URL,
        inside container: AdmittedContainer,
        containment: SubprocessTraversalContainment = .strictDescendant
    ) throws {
        // (1) Real directory, no-follow, on the spelling git will receive.
        guard provider.probeKind(of: url) == .kind(.directory) else {
            throw PathGuardError.notATraversableDirectory(path: url.path)
        }

        // (2) Full canonicalization — the leaf too.
        let canonical = provider.canonicalize(url)

        // (3) Canonical containment.
        let canonicalComponents = canonical.pathComponents
        let containerComponents = container.resolvedURL.pathComponents
        let isEqual = canonicalComponents == containerComponents
        let isStrictDescendant =
            canonicalComponents.count > containerComponents.count
            && Array(canonicalComponents.prefix(containerComponents.count))
                == containerComponents
        switch containment {
        case .strictDescendant:
            if isEqual {
                throw PathGuardError.isRootItself(path: canonical.path)
            }
            guard isStrictDescendant else {
                throw PathGuardError.notADescendant(
                    path: canonical.path, root: container.resolvedURL.path
                )
            }
        case .descendantOrEqual:
            guard isEqual || isStrictDescendant else {
                throw PathGuardError.notADescendant(
                    path: canonical.path, root: container.resolvedURL.path
                )
            }
        }

        // (4) Same device, provably — FAIL CLOSED on an unreadable id.
        guard let device = provider.deviceID(of: canonical),
              let containerDevice = provider.deviceID(of: container.resolvedURL),
              device == containerDevice
        else {
            throw PathGuardError.crossDevice(
                path: canonical.path, containerPath: container.resolvedURL.path
            )
        }
    }

    // MARK: - Container-root admission policy (fn-4, R16)

    /// The ONE shared container-root admission policy: may `url` serve as a
    /// configured CONTAINER root (a dev root) at all? Rejects the dangerous
    /// containers — the filesystem root `/`, any volume root / mount point,
    /// and `$HOME` itself — each in canonical AND alias spellings.
    ///
    /// THE GATE ANSWERS BEFORE `realpath` (fn-4.11 — the fn-4.26 order at
    /// this policy's scope). This runs synchronously inside runtime
    /// construction, on the main thread, on paths the app does not control:
    /// a same-UID process can point a persisted dev root at an unresponsive
    /// mounted volume, and the previous canonicalize-first shape made
    /// `realpath(3)` — a traversal of everything it resolves, destination
    /// included — the app's first contact with that volume, freezing launch
    /// before any window existed. So:
    ///
    /// 1. KERNEL-TABLE PREFLIGHT (`mountPointPaths` — `getfsstat(MNT_NOWAIT)`,
    ///    no filesystem contact): a `url` that IS an over-mounted path is
    ///    refused with the same `.deniedVolumeRoot` the canonical check
    ///    reaches for a healthy mount, and with ZERO calls naming it —
    ///    `lstat` or `realpath` OF a mount point is served by the mounted
    ///    filesystem (the r15 finding's mechanism). `/` is exempt: always in
    ///    the table, not foreign, and it keeps `.deniedFilesystemRoot`.
    /// 2. PROBE AS SPELLED (`lstat`, no follow). Only a SYMLINK leaf can
    ///    make `realpath(3)` name a destination the spelling never wrote;
    ///    every other kind resolves over objects the probe or the parent
    ///    chain already touched, so those take the canonical check below
    ///    unchanged — same verdicts, same error paths.
    /// 3. A symlink leaf takes `symlinkContainerRootDenyCheck` — the deny
    ///    core re-stated over the link's own CONTENT, never its destination.
    ///
    /// This is `denyCheck`'s core MINUS the protected-first-level-children
    /// clause: `~/Documents` and `~/Documents/dev` are LEGAL dev roots (the
    /// seed list depends on this) even though they stay refused as DELETION
    /// targets. ONE definition, three call sites (epic R16):
    /// `DevRootsStore.effectiveRoots` (fn-4.1), CLI `--dev-root` resolution
    /// (fn-4.6), and PathGuard admission on the matched configured root
    /// (fn-4.5). Settings add-time validation calls this same policy —
    /// no UI-only duplicate anywhere.
    static func validateContainerRoot(
        _ url: URL, home: URL, provider: FileSystemIdentityProvider
    ) throws {
        let mounted = Set(provider.mountPointPaths())
        if url.path != "/", mounted.contains(url.path) {
            throw PathGuardError.deniedVolumeRoot(path: url.path)
        }
        guard provider.probeKind(of: url) == .kind(.symlink) else {
            try coreDenyCheck(
                provider.canonicalize(url),
                resolvedHome: provider.canonicalize(home),
                provider: provider
            )
            return
        }
        try symlinkContainerRootDenyCheck(
            url, home: home, provider: provider, mountTable: mounted
        )
    }

    /// The container-root deny core for a SYMLINK-LEAF spelling, decided
    /// WITHOUT naming the destination (fn-4.11): one `readlink(2)` of the
    /// link itself plus lexical folding at the link's parent-canonical
    /// position (the fn-6 `EphemeralTempRoots` technique —
    /// `FileSystemIdentityProvider.lexicalTargetPath` is the shared fold),
    /// compared against `/`, the kernel mount table, and both spellings of
    /// `$HOME`.
    ///
    /// What ACCEPTANCE means here is unchanged in effect: a symlink leaf can
    /// never be walked (the walker's no-follow root gate refuses it), never
    /// admits at delete time (`admitContainer`'s no-follow reality gate),
    /// and is visibly classified at scan time — acceptance only defers its
    /// classification to gates that already hold it inadmissible.
    ///
    /// RESIDUALS at measured scope, each fail-CLOSED for deletion by those
    /// same gates: (a) content that names `/`, `$HOME` or a mount through a
    /// spelling this fold cannot equate — a second symlink hop, a case or
    /// normalization variant, an unresolved `/var`-style alias — is ACCEPTED
    /// here where the old full resolution refused it; (b) a volume root
    /// visible only to the device-id signal is not refused (never a real
    /// mount — the table names every real mount; the signal exists for
    /// injected test devices and the firmlink case, whose mounts the table
    /// also names); (c) unreadable or empty link content classifies as
    /// naming nothing — the old `canonicalize` ENOENT-fallback accepted
    /// exactly the same way.
    private static func symlinkContainerRootDenyCheck(
        _ url: URL, home: URL, provider: FileSystemIdentityProvider,
        mountTable: Set<String>
    ) throws {
        guard let content = provider.symlinkTarget(of: url) else { return }
        let position = provider.canonicalize(url.deletingLastPathComponent())
            .appendingPathComponent(url.lastPathComponent)
        guard let target = FileSystemIdentityProvider.lexicalTargetPath(
            ofLink: position, content: content
        ) else {
            // Non-empty content with no foldable target: `/` itself, or
            // `..`s that walk off the root — both NAME the filesystem root,
            // and this is the same refusal the resolved spelling carried.
            throw PathGuardError.deniedFilesystemRoot(path: "/")
        }
        if mountTable.contains(target) {
            throw PathGuardError.deniedVolumeRoot(path: target)
        }
        if target == home.path || target == provider.canonicalize(home).path {
            throw PathGuardError.deniedHomeDirectory(path: target)
        }
    }

    // MARK: - Deny list

    /// Refusals that apply regardless of any policy. `resolved` must already
    /// be canonical (root- or target-resolved by the caller). The core
    /// (`/`, volume roots, `$HOME`) is shared with the container-root
    /// admission policy above; the protected-children clause is
    /// deletion-target-only.
    private func denyCheck(_ resolved: URL) throws {
        try Self.coreDenyCheck(
            resolved, resolvedHome: resolvedHome, provider: provider
        )

        // Protected first-level children. Inode identity when the child
        // exists; canonical-components fallback (inside sameLocation) covers
        // protected names that do not exist in this home.
        for name in Self.protectedFirstLevelChildren {
            let protectedChild = resolvedHome.appendingPathComponent(name)
            if provider.sameLocation(resolved, protectedChild) {
                throw PathGuardError.deniedProtectedChild(
                    path: resolved.path, name: name
                )
            }
        }
    }

    /// The deny-list CORE — filesystem root, volume roots / mount points,
    /// `$HOME` — shared verbatim by the deletion-target `denyCheck` and the
    /// container-root admission policy (which deliberately excludes the
    /// protected-children clause). `resolved` and `resolvedHome` must
    /// already be canonical.
    private static func coreDenyCheck(
        _ resolved: URL, resolvedHome: URL,
        provider: FileSystemIdentityProvider
    ) throws {
        let components = resolved.pathComponents
        if components == ["/"] || components.isEmpty {
            throw PathGuardError.deniedFilesystemRoot(path: resolved.path)
        }

        // Volume root / mount point, two complementary signals:
        // (a) device-id change against the parent (also catches injected test
        //     devices and foreign volumes), and
        // (b) statfs mount-root detection — required because a unified APFS
        //     volume group presents ONE st_dev across the system/Data pair,
        //     so the /System/Volumes/Data firmlink mount is invisible to (a).
        // Identity is lstat-based, so a symlink LEAF pointing at a volume
        // root keeps the link's own device and passes — deleting it only
        // removes the link (statfs would follow the link, but its path never
        // equals the mount's f_mntonname).
        let parent = resolved.deletingLastPathComponent()
        if let device = provider.deviceID(of: resolved),
           let parentDevice = provider.deviceID(of: parent),
           device != parentDevice {
            throw PathGuardError.deniedVolumeRoot(path: resolved.path)
        }
        if provider.isMountPoint(resolved) {
            throw PathGuardError.deniedVolumeRoot(path: resolved.path)
        }

        // $HOME in any spelling: inode identity collapses direct, symlink-
        // alias, case-variant, and NFC/NFD spellings onto one object.
        if provider.sameLocation(resolved, resolvedHome) {
            throw PathGuardError.deniedHomeDirectory(path: resolved.path)
        }
    }

    // MARK: - Descendant check

    /// Target-resolve `url` (ancestors only; leaf untouched) and require its
    /// components to strictly extend `root`'s components.
    @discardableResult
    private func requireStrictDescendant(
        _ url: URL, of root: URL
    ) throws -> URL {
        let resolved = provider.resolveTargetKeepingLeaf(url)
        let childComponents = resolved.pathComponents
        let rootComponents = root.pathComponents

        if childComponents == rootComponents {
            throw PathGuardError.isRootItself(path: resolved.path)
        }
        guard childComponents.count > rootComponents.count,
              Array(childComponents.prefix(rootComponents.count)) == rootComponents
        else {
            throw PathGuardError.notADescendant(
                path: resolved.path, root: root.path
            )
        }
        return resolved
    }

    // MARK: - Version drift rule

    /// Constrained one-component version drift, two shapes:
    ///
    /// - **Sibling**: same parent (by inode identity) and same basename STEM
    ///   after stripping a trailing version suffix from each side.
    ///   `store/v11` matches declared `store/v10` (both stems empty, same
    ///   parent); `~/.ssh` never matches `~/.npm` (stems differ); DerivedData
    ///   never matches an npm root (parents differ).
    /// - **Version child**: the candidate's parent IS the declared root and
    ///   the candidate's basename is purely a version (`v10`, `3.1` — stem
    ///   empty after stripping). Probes return this shape: `pnpm store path`
    ///   yields `…/pnpm/store/v10` while the declared fallback is
    ///   `…/pnpm/store`. The child is strictly inside a root already
    ///   admissible in full, so this grants nothing new; named children
    ///   (`store/files`) and deeper descendants stay refused.
    private func isVersionDrift(
        _ candidate: URL, ofDeclared declared: URL
    ) -> Bool {
        guard candidate.pathComponents.count > 1,
              declared.pathComponents.count > 1 else { return false }
        let candidateParent = candidate.deletingLastPathComponent()

        // Version child: parent is the declared root itself, basename is
        // purely a version suffix.
        if provider.sameLocation(candidateParent, declared) {
            return Self.versionStem(of: candidate.lastPathComponent).isEmpty
        }

        // Sibling: same parent as the declared root, same stem.
        let declaredParent = declared.deletingLastPathComponent()
        guard provider.sameLocation(candidateParent, declaredParent) else {
            return false
        }
        return Self.versionStem(of: candidate.lastPathComponent)
            == Self.versionStem(of: declared.lastPathComponent)
    }

    /// Strip one trailing version suffix: optional `-`/`_`/`.` separator,
    /// optional `v`/`V`, then digits (dotted groups allowed).
    /// `"v10"` → `""`, `"store-2"` → `"store"`, `"cache_v3.1"` → `"cache"`,
    /// `".npm"` → `".npm"` (no digits — untouched).
    static func versionStem(of name: String) -> String {
        var s = name[...]
        var strippedDigits = false

        while let last = s.last, last.isASCII, last.isNumber {
            while let l = s.last, l.isASCII, l.isNumber {
                s = s.dropLast()
            }
            strippedDigits = true
            // Continue through dotted version groups ("3.1" after "cache_v").
            if s.last == ".", let beforeDot = s.dropLast().last,
               beforeDot.isASCII, beforeDot.isNumber {
                s = s.dropLast()
            } else {
                break
            }
        }
        guard strippedDigits else { return name }

        if s.last == "v" || s.last == "V" {
            s = s.dropLast()
        }
        if let l = s.last, l == "-" || l == "_" || l == "." {
            s = s.dropLast()
        }
        return String(s)
    }
}
