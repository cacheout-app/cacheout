/// # ProjectTreeWalkerTests — fn-4.2 (R2/R9/R11/R12)
///
/// The reusable walker's contract: event shape + origin-root provenance,
/// single- vs multi-consumer prune regimes (decisive vs unanimity), `.git`
/// hard prune, depth budgets, mount-boundary non-crossing, symlink safety
/// (leaf-root refused, child never descended, symlinked ANCESTORS legal),
/// per-root absence/error semantics on the frozen `ScanIssue` taxonomy, TCC
/// protection by canonical-path prefix (never basename), cancellation and
/// off-main execution.

import XCTest
@testable import Cacheout

final class ProjectTreeWalkerTests: XCTestCase {

    private var base: URL!
    private var home: URL!
    private let fm = FileManager.default

    /// chmod-000 fixtures registered for teardown restore (house rule:
    /// restore 0755 before removal).
    private var permsToRestore: [URL] = []

    override func setUpWithError() throws {
        base = fm.temporaryDirectory
            .appendingPathComponent("ProjectTreeWalkerTests-\(UUID().uuidString)")
        home = base.appendingPathComponent("home")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for url in permsToRestore {
            try? fm.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: url.path
            )
        }
        permsToRestore = []
        if let base {
            try? fm.removeItem(at: base)
        }
    }

    // MARK: - Helpers

    private func mkdir(_ url: URL) throws {
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    @discardableResult
    private func writeFile(_ url: URL, bytes: Int = 64) throws -> URL {
        try Data(repeating: 0xAB, count: bytes).write(to: url)
        return url
    }

    private func chmod000(_ url: URL) throws {
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        permsToRestore.append(url)
    }

    /// Walker whose guard's containerRoots == `roots` (the epic model: each
    /// scanner constructs its OWN PathGuard from its declared roots).
    private func makeWalker(
        roots: [URL],
        provider: FileSystemIdentityProvider = FileSystemIdentityProvider()
    ) -> ProjectTreeWalker {
        ProjectTreeWalker(
            home: home,
            pathGuard: PathGuard(
                home: home, containerRoots: roots, provider: provider
            ),
            provider: provider
        )
    }

    /// Run a walk with one recording consumer (plus optional extra
    /// consumers), returning the events it saw and the walk's issues.
    /// Asserts the reserved `.malformedOutcome` is never authored (R12).
    @discardableResult
    private func recordedWalk(
        roots: [URL],
        maxDepth: Int = ProjectTreeWalker.defaultMaxDepth,
        includeProtectedRoots: Bool = true,
        provider: FileSystemIdentityProvider = FileSystemIdentityProvider(),
        extraConsumers: [ProjectTreeConsumer] = [],
        file: StaticString = #filePath, line: UInt = #line
    ) -> (events: [ProjectTreeEvent], issues: [ScanIssue]) {
        var events: [ProjectTreeEvent] = []
        let walker = makeWalker(roots: roots, provider: provider)
        let issues = walker.walk(
            roots: roots, maxDepth: maxDepth,
            includeProtectedRoots: includeProtectedRoots,
            consumers: [{ events.append($0); return [] }] + extraConsumers
        )
        XCTAssertFalse(
            issues.contains { $0.kind == .malformedOutcome },
            "the reserved validator kind must never be authored by the walker",
            file: file, line: line
        )
        return (events, issues)
    }

    private func eventPaths(_ events: [ProjectTreeEvent]) -> [String] {
        events.map(\.directory.path)
    }

    private func event(
        _ events: [ProjectTreeEvent], at url: URL
    ) -> ProjectTreeEvent? {
        events.first { $0.directory.path == url.path }
    }

    // MARK: - R2: no name-based pruning; hidden dirs traversed

    func testMonorepoNestedArtifactReachedAndHiddenEntriesListed() throws {
        // packages/build/pkg/node_modules — every component of this chain is
        // on the OLD NodeModulesScanner skip list ("build", "node_modules"),
        // which is exactly the anti-pattern R2 bans.
        let root = base.appendingPathComponent("dev")
        let pkg = root.appendingPathComponent("packages/build/pkg")
        let nodeModules = pkg.appendingPathComponent("node_modules")
        try mkdir(nodeModules.appendingPathComponent("dep"))
        // A hidden PARENT project and a hidden entry beside it.
        let hiddenProject = root.appendingPathComponent(".hidden/proj")
        try mkdir(hiddenProject)
        try writeFile(root.appendingPathComponent(".hidden/.secretrc"))

        let (events, issues) = recordedWalk(roots: [root])

        XCTAssertTrue(issues.isEmpty)
        // The deep artifact dir is REACHED — an event exists for it.
        XCTAssertNotNil(event(events, at: nodeModules),
                        "no name-based skip list may hide packages/build/…")
        let pkgEvent = try XCTUnwrap(event(events, at: pkg))
        XCTAssertEqual(pkgEvent.entries,
                       [.init(name: "node_modules", kind: .directory)])
        // Hidden parents are traversed and hidden entries listed.
        XCTAssertNotNil(event(events, at: hiddenProject))
        let hiddenEvent = try XCTUnwrap(
            event(events, at: root.appendingPathComponent(".hidden"))
        )
        XCTAssertEqual(hiddenEvent.entries, [
            .init(name: ".secretrc", kind: .regularFile),
            .init(name: "proj", kind: .directory),
        ])
    }

    // MARK: - R9: deterministic event order (explicit sort, never FS order)

    func testEventOrderDeterministicParentBeforeChildByteWiseNames() throws {
        let root = base.appendingPathComponent("dev")
        // Created deliberately out of byte order.
        try mkdir(root.appendingPathComponent("zeta/inner"))
        try mkdir(root.appendingPathComponent("alpha"))
        try mkdir(root.appendingPathComponent("mid"))
        // "Z" (0x5A) precedes "a" (0x61) byte-wise — proves byte order, not
        // human-alphabetical or case-insensitive order.
        try mkdir(root.appendingPathComponent("Zupper"))

        let (events, _) = recordedWalk(roots: [root])

        XCTAssertEqual(eventPaths(events), [
            root.path,
            root.appendingPathComponent("Zupper").path,
            root.appendingPathComponent("alpha").path,
            root.appendingPathComponent("mid").path,
            root.appendingPathComponent("zeta").path,
            root.appendingPathComponent("zeta/inner").path,
        ])
        XCTAssertEqual(try XCTUnwrapElement(events, 0).entries.map(\.name),
                       ["Zupper", "alpha", "mid", "zeta"])
    }

    // MARK: - R9/R11: origin provenance verbatim through an alias-declared root

    func testOriginRootCarriedVerbatimUnderSymlinkedAncestorRoot() throws {
        // A root DECLARED beneath a symlinked ancestor (`/var`-style alias):
        // base/alias → base/realparent, declared root base/alias/dev. The
        // LEAF lstats real through the link, so the root IS walked — and
        // every event carries the alias spelling verbatim.
        let realParent = base.appendingPathComponent("realparent")
        try mkdir(realParent.appendingPathComponent("dev/proj/sub"))
        let alias = base.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: realParent)
        let declared = alias.appendingPathComponent("dev")

        let (events, issues) = recordedWalk(roots: [declared])

        XCTAssertTrue(issues.isEmpty)
        XCTAssertEqual(events.count, 3, "dev, proj, sub")
        for event in events {
            XCTAssertEqual(event.originRoot.path, declared.path,
                           "originRoot must be the DECLARED spelling, verbatim")
            XCTAssertTrue(
                event.directory.pathComponents.starts(
                    with: declared.pathComponents
                ),
                "directories carry the alias spelling too: \(event.directory.path)"
            )
        }
        XCTAssertEqual(events.map(\.depth), [0, 1, 2])
    }

    // MARK: - R11: symlink children listed, never descended

    func testSymlinkChildListedButNeverDescended() throws {
        let root = base.appendingPathComponent("dev")
        let target = base.appendingPathComponent("outside/payload")
        try mkdir(target.appendingPathComponent("inner"))
        try mkdir(root)
        let link = root.appendingPathComponent("linked")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)

        let (events, issues) = recordedWalk(roots: [root])

        XCTAssertTrue(issues.isEmpty)
        let rootEvent = try XCTUnwrap(event(events, at: root))
        XCTAssertEqual(rootEvent.entries,
                       [.init(name: "linked", kind: .symlink)],
                       "the symlink is SEEN with its no-follow kind")
        XCTAssertEqual(events.count, 1,
                       "no events beneath a symlink child — ever")
    }

    // MARK: - R11: the ENUMERATION itself is no-follow (PR #457 review r5)

    /// Collapses the swap RACE into a lie, so no timing is involved: it
    /// reports `.kind(.directory)` for a path that is REALLY a symlink —
    /// precisely the state the walk is in between its descent `lstat` and
    /// the enumeration that follows. No re-`lstat` can close that window
    /// (every path check re-opens it); only the open can refuse.
    private final class SwapSimulatingProvider: FileSystemIdentityProvider {
        var reportedAsDirectory: Set<String> = []
        private(set) var probedPaths: [String] = []

        override func probeKind(of url: URL) -> KindProbe {
            probedPaths.append(url.path)
            if reportedAsDirectory.contains(url.path) {
                return .kind(.directory)
            }
            return super.probeKind(of: url)
        }

        /// The same lie on the DESCRIPTOR seam the walk uses below its root:
        /// a directory kind for a name that is really a symlink, with the
        /// REAL identity kept so only the `openat` itself can refuse.
        override func probeKind(
            inDirectory parent: Int32, named name: String, logical url: URL
        ) -> DescriptorKindProbe {
            probedPaths.append(url.path)
            let real = super.probeKind(
                inDirectory: parent, named: name, logical: url
            )
            guard reportedAsDirectory.contains(url.path),
                  case .kind(_, let identity, let metadata) = real
            else { return real }
            return .kind(.directory, identity: identity, metadata: metadata)
        }

        func touches(below directory: URL) -> [String] {
            probedPaths.filter { $0.hasPrefix(directory.path + "/") }
        }
    }

    /// Reports a bogus INODE for chosen paths, real device intact so the
    /// mount arm stays silent: a directory replaced by a DIFFERENT
    /// directory, which passes every path check there is.
    private final class WrongIdentityProvider: FileSystemIdentityProvider {
        var bogusInodeFor: Set<String> = []
        private(set) var probedPaths: [String] = []

        override func identity(of url: URL) -> Identity? {
            guard let real = super.identity(of: url) else { return nil }
            guard bogusInodeFor.contains(url.path) else { return real }
            return Identity(device: real.device, inode: real.inode &+ 1)
        }

        override func probeKind(of url: URL) -> KindProbe {
            probedPaths.append(url.path)
            return super.probeKind(of: url)
        }

        /// The vetting stat reports an inode the real object does not have —
        /// the hermetic stand-in for a directory re-bound to a DIFFERENT real
        /// directory, which `O_NOFOLLOW` cannot see. Only comparing the
        /// OPENED descriptor against what was listed catches it.
        override func probeKind(
            inDirectory parent: Int32, named name: String, logical url: URL
        ) -> DescriptorKindProbe {
            probedPaths.append(url.path)
            let real = super.probeKind(
                inDirectory: parent, named: name, logical: url
            )
            guard bogusInodeFor.contains(url.path),
                  case .kind(let kind, let identity, let metadata) = real
            else { return real }
            return .kind(
                kind,
                identity: Identity(
                    device: identity.device, inode: identity.inode &+ 1
                ),
                metadata: metadata
            )
        }

        func touches(below directory: URL) -> [String] {
            probedPaths.filter { $0.hasPrefix(directory.path + "/") }
        }
    }

    func testEnumerationRefusesAChildSwappedForASymlinkAfterItsDescentGate()
        throws
    {
        // Left open, the walk enumerates a tree OUTSIDE the dev root and
        // emits its contents as events UNDER the in-tree spelling — so a
        // consumer matches artifact dirs in someone else's files, and every
        // item derived from them names a path the dev root does not own.
        let root = base.appendingPathComponent("dev")
        let outside = base.appendingPathComponent("outside-the-dev-root")
        try mkdir(outside.appendingPathComponent("Cargo-project/target"))
        try writeFile(outside.appendingPathComponent("secret.bin"))
        try mkdir(root)
        let swapped = root.appendingPathComponent("proj")
        try fm.createSymbolicLink(at: swapped, withDestinationURL: outside)

        let provider = SwapSimulatingProvider()
        provider.reportedAsDirectory.insert(swapped.path)

        let (events, issues) = recordedWalk(roots: [root], provider: provider)

        XCTAssertEqual(
            provider.touches(below: swapped), [],
            "the walk followed the swapped link and read outside the dev "
                + "root: \(provider.probedPaths)"
        )
        XCTAssertEqual(
            eventPaths(events), [root.path],
            "no event may describe a directory the walk could not vet"
        )
        // Never a silent skip: a refused enumeration is a classified,
        // visible per-root failure (R12).
        XCTAssertEqual(issues.map(\.kind), [.unreadable])
        XCTAssertEqual(issues.first?.url?.path, swapped.path)
    }

    func testEnumerationRefusesADirectorySwappedForADifferentDirectory()
        throws
    {
        let root = base.appendingPathComponent("dev")
        let sub = root.appendingPathComponent("proj")
        try mkdir(sub.appendingPathComponent("target"))

        let provider = WrongIdentityProvider()
        provider.bogusInodeFor.insert(sub.path)

        let (events, issues) = recordedWalk(roots: [root], provider: provider)

        XCTAssertEqual(
            provider.touches(below: sub), [],
            "nothing inside an unvetted directory may be enumerated: "
                + "\(provider.probedPaths)"
        )
        XCTAssertEqual(eventPaths(events), [root.path])
        XCTAssertEqual(issues.map(\.kind), [.unreadable])
        XCTAssertEqual(issues.first?.url?.path, sub.path)
    }

    func testEnumerationRefusesAROOTSwappedForASymlinkAfterItsKindGate()
        throws
    {
        // The root gate is an `lstat`; the enumeration that follows is a
        // path open. The gate stops a root that is ALREADY a symlink and
        // cannot stop one that BECOMES one.
        let outside = base.appendingPathComponent("outside-via-the-root")
        try mkdir(outside.appendingPathComponent("proj/target"))
        let root = base.appendingPathComponent("dev")
        try fm.createSymbolicLink(at: root, withDestinationURL: outside)

        let provider = SwapSimulatingProvider()
        provider.reportedAsDirectory.insert(root.path)

        let (events, issues) = recordedWalk(roots: [root], provider: provider)

        XCTAssertEqual(
            provider.touches(below: root), [],
            "not one path below a swapped ROOT may be read: "
                + "\(provider.probedPaths)"
        )
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(issues.map(\.kind), [.unreadable])
    }

    // MARK: - R11: root gates (symlink leaf, non-directory, absent, refused)

    func testSymlinkLeafRootRefusedWithClassifiedIssue() throws {
        let real = base.appendingPathComponent("realroot")
        try mkdir(real.appendingPathComponent("content"))
        let linkRoot = base.appendingPathComponent("linkroot")
        try fm.createSymbolicLink(at: linkRoot, withDestinationURL: real)

        let (events, issues) = recordedWalk(roots: [linkRoot])

        XCTAssertTrue(events.isEmpty, "a symlink-LEAF root is never traversed")
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.kind, .symlinkRoot)
        XCTAssertEqual(issues.first?.url?.path, linkRoot.path)
    }

    func testNonDirectoryRootRefusedWithClassifiedIssue() throws {
        let fileRoot = base.appendingPathComponent("actually-a-file")
        try writeFile(fileRoot)

        let (events, issues) = recordedWalk(roots: [fileRoot])

        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(issues.map(\.kind), [.symlinkRoot])
    }

    func testAbsentRootIsQuietOmissionWhileWalkContinues() throws {
        let missing = base.appendingPathComponent("not-there")
        let present = base.appendingPathComponent("present")
        try mkdir(present.appendingPathComponent("proj"))

        let (events, issues) = recordedWalk(roots: [missing, present])

        XCTAssertTrue(issues.isEmpty, "absent root: no issue, honest no-item")
        XCTAssertEqual(eventPaths(events), [
            present.path, present.appendingPathComponent("proj").path,
        ], "the walk continues to later roots")
    }

    func testAdmitSearchRootRefusalClassifiedZeroTraversal() throws {
        let configured = base.appendingPathComponent("configured")
        let unconfigured = base.appendingPathComponent("unconfigured")
        try mkdir(configured)
        try mkdir(unconfigured.appendingPathComponent("proj"))

        // Guard configured for a DIFFERENT root than the one walked.
        let walker = ProjectTreeWalker(
            home: home,
            pathGuard: PathGuard(home: home, containerRoots: [configured])
        )
        var events: [ProjectTreeEvent] = []
        let issues = walker.walk(
            roots: [unconfigured],
            consumers: [{ events.append($0); return [] }]
        )

        XCTAssertTrue(events.isEmpty, "refused root: zero traversal")
        XCTAssertEqual(issues.map(\.kind), [.containerRefused])
        XCTAssertEqual(issues.first?.url?.path, unconfigured.path)
    }

    // MARK: - R2/R9: single-consumer prune is decisive

    func testSingleConsumerPruneVerdictIsDecisive() throws {
        let root = base.appendingPathComponent("dev")
        let artifact = root.appendingPathComponent("proj/node_modules")
        try mkdir(artifact.appendingPathComponent("dep"))
        try mkdir(root.appendingPathComponent("proj/src"))

        var events: [ProjectTreeEvent] = []
        let walker = makeWalker(roots: [root])
        let issues = walker.walk(roots: [root], consumers: [{ event in
            events.append(event)
            return ["node_modules"]
        }])

        XCTAssertTrue(issues.isEmpty)
        XCTAssertNil(event(events, at: artifact),
                     "a pruned child emits no event")
        XCTAssertNil(event(events, at: artifact.appendingPathComponent("dep")),
                     "…and no descendant events")
        let projEvent = try XCTUnwrap(
            event(events, at: root.appendingPathComponent("proj"))
        )
        XCTAssertTrue(projEvent.entries.contains(
            .init(name: "node_modules", kind: .directory)
        ), "the pruned child is still LISTED in its parent's entries")
        XCTAssertNotNil(
            event(events, at: root.appendingPathComponent("proj/src")),
            "pruning one child never affects siblings"
        )
    }

    // MARK: - R9: two consumers — one walk, unanimity rule

    func testTwoConsumersReceiveIdenticalEventsAndPruneRequiresUnanimity() throws {
        let root = base.appendingPathComponent("dev")
        try mkdir(root.appendingPathComponent("both-pruned/inner"))
        try mkdir(root.appendingPathComponent("one-pruned/inner"))
        try mkdir(root.appendingPathComponent("kept/inner"))

        var eventsA: [ProjectTreeEvent] = []
        var eventsB: [ProjectTreeEvent] = []
        let walker = makeWalker(roots: [root])
        let issues = walker.walk(roots: [root], consumers: [
            { event in
                eventsA.append(event)
                return ["both-pruned", "one-pruned"]
            },
            { event in
                eventsB.append(event)
                return ["both-pruned"]
            },
        ])

        XCTAssertTrue(issues.isEmpty)
        XCTAssertEqual(eventsA, eventsB,
                       "both consumers see identical events from ONE walk")
        // Unanimously pruned: no events.
        XCTAssertNil(event(eventsA, at: root.appendingPathComponent("both-pruned")))
        XCTAssertNil(event(
            eventsA, at: root.appendingPathComponent("both-pruned/inner")
        ))
        // Disagreement: descends (one consumer's descend outvotes a prune).
        XCTAssertNotNil(
            event(eventsA, at: root.appendingPathComponent("one-pruned")),
            "descend-on-disagreement: pruning requires unanimity"
        )
        XCTAssertNotNil(event(
            eventsA, at: root.appendingPathComponent("one-pruned/inner")
        ))
        XCTAssertNotNil(event(eventsA, at: root.appendingPathComponent("kept/inner")))
    }

    // MARK: - R2/R9: .git walker-level hard prune

    func testGitDirectorySeenInEntriesButNeverDescendedRegardlessOfVerdicts() throws {
        let root = base.appendingPathComponent("dev")
        let proj = root.appendingPathComponent("proj")
        try mkdir(proj.appendingPathComponent(".git/refs"))
        try writeFile(proj.appendingPathComponent(".git/HEAD"))
        // A worktree-style `.git` FILE elsewhere: listed with its real kind
        // (fn-5's file-vs-directory discrimination rides these entries).
        let worktree = root.appendingPathComponent("worktree")
        try mkdir(worktree)
        try writeFile(worktree.appendingPathComponent(".git"))

        // Consumers return no verdicts (default descend) — the hard prune
        // must hold anyway.
        let (events, issues) = recordedWalk(roots: [root])

        XCTAssertTrue(issues.isEmpty)
        let projEvent = try XCTUnwrap(event(events, at: proj))
        XCTAssertEqual(projEvent.entries,
                       [.init(name: ".git", kind: .directory)])
        XCTAssertNil(event(events, at: proj.appendingPathComponent(".git")),
                     "no event for .git itself")
        XCTAssertNil(
            event(events, at: proj.appendingPathComponent(".git/refs")),
            "no events beneath .git"
        )
        let worktreeEvent = try XCTUnwrap(event(events, at: worktree))
        XCTAssertEqual(worktreeEvent.entries,
                       [.init(name: ".git", kind: .regularFile)])
    }

    // MARK: - R9: mount boundaries never crossed

    /// Marks chosen inodes as mount points / remaps devices — the house
    /// hermetic injection seam (DirectorySizerTests).
    private final class BoundaryInjectingProvider: FileSystemIdentityProvider {
        var deviceOverridesByInode: [UInt64: UInt64] = [:]
        var mountPointInodes: Set<UInt64> = []

        override func identity(of url: URL) -> Identity? {
            guard let id = super.identity(of: url) else { return nil }
            if let device = deviceOverridesByInode[id.inode] {
                return Identity(device: device, inode: id.inode)
            }
            return id
        }

        override func isMountPoint(_ url: URL) -> Bool {
            if let id = identity(of: url), mountPointInodes.contains(id.inode) {
                return true
            }
            return super.isMountPoint(url)
        }
    }

    func testMountBoundaryChildrenListedButNeverCrossed() throws {
        let root = base.appendingPathComponent("dev")
        let mounted = root.appendingPathComponent("mounted-volume")
        try mkdir(mounted.appendingPathComponent("beyond"))
        let foreign = root.appendingPathComponent("foreign-device")
        try mkdir(foreign.appendingPathComponent("beyond"))
        try mkdir(root.appendingPathComponent("normal"))

        let provider = BoundaryInjectingProvider()
        let mountedInode = try XCTUnwrap(provider.identity(of: mounted)?.inode)
        provider.mountPointInodes.insert(mountedInode)
        let foreignInode = try XCTUnwrap(provider.identity(of: foreign)?.inode)
        provider.deviceOverridesByInode[foreignInode] = 0xDEAD

        let (events, issues) = recordedWalk(roots: [root], provider: provider)

        XCTAssertTrue(issues.isEmpty,
                      "a boundary is a non-crossing, not a scan problem here")
        let rootEvent = try XCTUnwrap(event(events, at: root))
        XCTAssertEqual(rootEvent.entries.map(\.name),
                       ["foreign-device", "mounted-volume", "normal"],
                       "boundary children are still LISTED")
        XCTAssertNil(event(events, at: mounted),
                     "statfs mount-root signal: never descended")
        XCTAssertNil(event(events, at: foreign),
                     "device-change signal: never descended")
        XCTAssertNotNil(event(events, at: root.appendingPathComponent("normal")))
    }

    /// Mirrors the PRODUCTION `isMountPoint` contract instead of injecting by
    /// inode: `statfs` compares `f_mntonname` — ALWAYS canonical — against the
    /// path it is HANDED, so a real mount answers `true` only for its
    /// CANONICAL spelling. The inode seam above answers correctly for ANY
    /// spelling, which is why it cannot see a caller that passes an alias.
    /// Devices are left untouched, so the walk root and the mount share one
    /// `st_dev` and the device arm is genuinely silent too — the firmlink
    /// shape the `statfs` arm exists for.
    private final class CanonicalSpellingMountProvider:
        FileSystemIdentityProvider
    {
        var canonicalMountPaths: Set<String> = []

        override func isMountPoint(_ url: URL) -> Bool {
            if canonicalMountPaths.contains(url.path) { return true }
            return super.isMountPoint(url)
        }
    }

    func testMountBoundaryUnderAnAliasDeclaredRootIsStillNotCrossed() throws {
        // PR #457 review r4. The walker canonicalizes ONLY to compare against
        // the TCC-protected roots (`:152`) and then descends from the ORIGINAL
        // root spelling, so every child inherits whatever aliasing the
        // configured dev root has — a root like `/tmp/work`, or any home
        // reached through a symlink. Arm (a) is blind by construction on a
        // mount that shares the root's device; arm (b) was blind because the
        // aliased spelling never equalled `f_mntonname`. Both silent means
        // the walk descends into the mounted volume.
        let realParent = base.appendingPathComponent("realparent")
        try mkdir(realParent.appendingPathComponent("dev"))
        let alias = base.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: realParent)
        let root = alias.appendingPathComponent("dev")
        let mounted = root.appendingPathComponent("mounted-volume")
        try mkdir(mounted.appendingPathComponent("beyond"))
        try mkdir(root.appendingPathComponent("normal"))

        let provider = CanonicalSpellingMountProvider()
        provider.canonicalMountPaths = [
            FileSystemIdentityProvider().canonicalize(mounted).path
        ]
        XCTAssertFalse(
            provider.canonicalMountPaths.contains(mounted.path),
            "the fixture must really be aliased, or the test proves nothing"
        )

        let (events, issues) = recordedWalk(roots: [root], provider: provider)

        XCTAssertTrue(issues.isEmpty,
                      "a boundary is a non-crossing, not a scan problem here")
        let rootEvent = try XCTUnwrap(event(events, at: root))
        XCTAssertEqual(rootEvent.entries.map(\.name),
                       ["mounted-volume", "normal"],
                       "the boundary child is still LISTED")
        XCTAssertNil(event(events, at: mounted),
                     "…and never descended, alias spelling or not")
        XCTAssertNil(event(events, at: mounted.appendingPathComponent("beyond")))
        XCTAssertNotNil(event(events, at: root.appendingPathComponent("normal")),
                        "the boundary stops one branch, not the walk")

        // THE SEPARATION: canonicalization is an ARGUMENT to the mount check
        // and nothing more — the traversal keeps the spelling it was given.
        for walked in events {
            XCTAssertTrue(
                walked.directory.pathComponents.starts(with: root.pathComponents),
                "traversal still carries the alias: \(walked.directory.path)"
            )
            XCTAssertEqual(walked.originRoot.path, root.path)
        }
    }

    // MARK: - R9/R11: the DESCRIPTOR mount arm, on a REAL firmlink (T14)

    /// Blinds BOTH path mount arms and nothing else.
    ///
    /// This is not a convenience: it is the state the path arms are actually
    /// in whenever this walk matters. `isMountPoint` compares `f_mntonname` —
    /// always canonical — against the path it is HANDED, so it answers `false`
    /// for any aliased spelling; and the device arm is blind by construction
    /// on an APFS volume group, where every path shares one `st_dev`. Both are
    /// also answers about a PATH, which is precisely what an ancestor swap
    /// makes untrustworthy. Blinding them leaves exactly one guard standing —
    /// the child descriptor's own `f_fsid`/`st_dev` — which is the guard with
    /// no coverage at all before this test.
    private final class PathMountArmsBlindProvider: FileSystemIdentityProvider {
        override func isMountPoint(_ url: URL) -> Bool { false }
    }

    /// T14, on the real firmlink every macOS 11+ machine has.
    ///
    /// `/System/Volumes/Data` is a genuine mount root that SHARES `st_dev`
    /// with its parent (measured here: both `16777230`, `f_fsid`
    /// `{16777235,26}` vs `{16777230,26}`). With both path arms blind it is
    /// indistinguishable from an ordinary directory by every signal except the
    /// descriptor's own `f_fsid` — so if the walk descends into it, the whole
    /// user data volume is inside a "dev root" the user never configured.
    func testRealFirmlinkMountIsNeverDescendedWithBothPathArmsBlind() throws {
        let systemVolumes = URL(fileURLWithPath: "/System/Volumes")
        let data = systemVolumes.appendingPathComponent("Data")
        try XCTSkipUnless(
            fm.fileExists(atPath: data.path),
            "no /System/Volumes/Data firmlink on this machine"
        )

        // THE PLATFORM FACTS this arm exists for, asserted rather than
        // assumed — if they ever stop holding, this test must say so instead
        // of passing vacuously.
        let real = FileSystemIdentityProvider()
        XCTAssertEqual(
            real.deviceID(of: data), real.deviceID(of: systemVolumes),
            "the firmlink must share its parent's st_dev, or the device arm "
                + "would be doing this test's work"
        )
        let blind = PathMountArmsBlindProvider()
        XCTAssertFalse(blind.isMountPoint(blind.canonicalize(data)),
                       "fixture precondition: the statfs arm is blind")

        let (events, _) = recordedWalk(
            roots: [systemVolumes], maxDepth: 1, provider: blind
        )

        let rootEvent = try XCTUnwrap(
            event(events, at: systemVolumes),
            "precondition: the walk must actually have run"
        )
        XCTAssertTrue(
            rootEvent.entries.contains(.init(name: "Data", kind: .directory)),
            "precondition: the mount is LISTED, so the walk really had the "
                + "chance to descend it: \(rootEvent.entries.map(\.name))"
        )
        XCTAssertFalse(
            eventPaths(events).contains {
                $0 == data.path || $0.hasPrefix(data.path + "/")
            },
            "the walk crossed a real mount boundary into the data volume: "
                + eventPaths(events).description
        )
    }

    // MARK: - R11: the DESCENT is descriptor-relative (P2, review r6)

    /// Performs a REAL `rename(2)` + `symlink(2)` from the child-vetting seam
    /// itself, at the instant a directory's children are being probed — the
    /// exact window an ancestor swap lives in, with zero timing dependence.
    ///
    /// It fires through the seam BOTH shapes call, so the same test exercises
    /// the descriptor-relative walk and a path-resolving one: what changes
    /// between them is only whether the vetting stat and the descent open
    /// resolve `dev/proj` again.
    private final class MidEnumerationSwappingProvider:
        FileSystemIdentityProvider
    {
        /// Fire when a child OF THIS directory is being vetted.
        var armedUnder = ""
        var swap: (() -> Void)?
        private(set) var swapped = false

        override func probeKind(
            inDirectory parent: Int32, named name: String, logical url: URL
        ) -> DescriptorKindProbe {
            if !swapped, url.deletingLastPathComponent().path == armedUnder {
                swapped = true
                swap?()
            }
            return super.probeKind(
                inDirectory: parent, named: name, logical: url
            )
        }
    }

    /// THE ANCESTOR SWAP, against the walker itself. `dev/proj` is moved aside
    /// and replaced by a symlink out of the dev root while the walk is
    /// enumerating it — after `proj` was listed, vetted and opened.
    ///
    /// A path-resolving descent cannot survive this and no identity re-proof
    /// can save it: after the swap the vetting `lstat` of `dev/proj/target`
    /// and the `O_NOFOLLOW` open of it BOTH resolve through the new link
    /// (`O_NOFOLLOW` guards only the final component), so the recorded
    /// "vetted" identity is already the foreign directory's and the
    /// corroborator compares foreign against foreign and passes. The walk then
    /// emits the foreign tree's contents as events spelled INSIDE the dev
    /// root, and every consumer matches rules against someone else's files.
    ///
    /// A descriptor-anchored descent is immune by construction: `proj`'s
    /// descriptor is inode-pinned, so `fstatat`/`openat` through it keep
    /// reaching the real directory whatever its name now points at.
    func testAncestorSwappedMidEnumerationIsNeverFollowedByTheDescent() throws {
        let root = base.appendingPathComponent("dev")
        let outside = base.appendingPathComponent("outside-the-dev-root")
        // Named to COLLIDE with the real project's children, so a
        // path-resolving descent lands on foreign objects that pass every
        // name, kind and identity check there is.
        try mkdir(outside.appendingPathComponent("target/Foreign-Only-Dir"))
        try writeFile(outside.appendingPathComponent("Cargo.toml"))
        try writeFile(outside.appendingPathComponent("target/secret.bin"))

        let project = root.appendingPathComponent("proj")
        try mkdir(project.appendingPathComponent("target"))
        try writeFile(project.appendingPathComponent("Cargo.toml"))
        try writeFile(project.appendingPathComponent("target/payload.bin"))
        let relocated = root.appendingPathComponent("proj.real")

        let provider = MidEnumerationSwappingProvider()
        provider.armedUnder = project.path
        let manager = fm
        provider.swap = {
            try? manager.moveItem(at: project, to: relocated)
            try? manager.createSymbolicLink(
                at: project, withDestinationURL: outside
            )
        }

        let (events, _) = recordedWalk(roots: [root], provider: provider)

        XCTAssertTrue(provider.swapped,
                      "fixture precondition: the swap ran mid-enumeration")
        XCTAssertEqual(
            try fm.destinationOfSymbolicLink(atPath: project.path),
            outside.path,
            "fixture precondition: the ancestor is a symlink out of the tree"
        )

        let artifactEvent = try XCTUnwrap(
            event(events, at: project.appendingPathComponent("target")),
            "the walk keeps reading the inode it vetted — it does not lose "
                + "the subtree, it just refuses to be redirected"
        )
        XCTAssertEqual(
            artifactEvent.entries.map(\.name), ["payload.bin"],
            "the descent followed the swapped ancestor and listed a foreign "
                + "directory's children under an in-tree spelling: "
                + artifactEvent.entries.map(\.name).description
        )
        for walked in events {
            XCTAssertFalse(
                walked.entries.contains { $0.name == "secret.bin" }
                    || walked.entries.contains { $0.name == "Foreign-Only-Dir" },
                "foreign entries surfaced at \(walked.directory.path): "
                    + walked.entries.map(\.name).description
            )
        }
    }

    // MARK: - R9: maxDepth budget

    func testMaxDepthDefaultEightMeasuredFromRootAndConfigurable() throws {
        let root = base.appendingPathComponent("dev")
        // c1/c2/…/c10 — depths 1…10 below the root.
        var cursor = root
        for level in 1...10 {
            cursor = cursor.appendingPathComponent("c\(level)")
        }
        try mkdir(cursor)

        let (defaultEvents, _) = recordedWalk(roots: [root])
        XCTAssertEqual(defaultEvents.count, 9, "root (0) through c8 (depth 8)")
        XCTAssertEqual(defaultEvents.last?.depth, 8)
        XCTAssertEqual(defaultEvents.last?.directory.lastPathComponent, "c8")
        XCTAssertEqual(defaultEvents.last?.entries.map(\.name), ["c9"],
                       "the budget's deepest event still LISTS its entries")

        let (shallowEvents, _) = recordedWalk(roots: [root], maxDepth: 2)
        XCTAssertEqual(shallowEvents.map(\.depth), [0, 1, 2],
                       "maxDepth is configurable")
    }

    func testNestedRootsAreIndependentWalksWithOwnDepthBudgets() throws {
        // D7: path ancestry is never traversal equivalence — a nested root
        // re-walks with its own budget and its own origin provenance.
        let outer = base.appendingPathComponent("outer")
        let inner = outer.appendingPathComponent("a/b/inner")
        try mkdir(inner.appendingPathComponent("proj"))

        let (events, issues) = recordedWalk(roots: [outer, inner])

        XCTAssertTrue(issues.isEmpty)
        let fromOuter = events.filter { $0.originRoot.path == outer.path }
        let fromInner = events.filter { $0.originRoot.path == inner.path }
        XCTAssertEqual(
            fromOuter.map(\.depth), [0, 1, 2, 3, 4],
            "outer walk reaches inner/proj at depth 4"
        )
        XCTAssertEqual(fromInner.map(\.depth), [0, 1],
                       "the nested root restarts at depth 0 — its own budget")
        XCTAssertEqual(fromInner.first?.directory.path, inner.path)
    }

    // MARK: - R9: cancellation, prompt partial return, off the main actor

    func testCancellationMidWalkReturnsPartialResultsPromptlyOffMain() async throws {
        let root = base.appendingPathComponent("dev")
        // Plenty of dirs a full walk would visit.
        for index in 0..<12 {
            try mkdir(root.appendingPathComponent("proj\(index)/sub"))
        }
        let second = base.appendingPathComponent("dev2")
        try mkdir(second.appendingPathComponent("proj"))
        let roots = [root, second]

        let walker = makeWalker(roots: roots)
        let result = await Task.detached {
            var events: [ProjectTreeEvent] = []
            var sawMainThread = false
            let issues = walker.walk(roots: roots, consumers: [{ event in
                sawMainThread = sawMainThread || Thread.isMainThread
                events.append(event)
                // Cancel the walk's OWN task from inside the first event —
                // deterministic, no sleeps.
                withUnsafeCurrentTask { $0?.cancel() }
                return []
            }])
            return (events: events, issues: issues,
                    sawMainThread: sawMainThread)
        }.value

        XCTAssertEqual(result.events.count, 1,
                       "prompt partial return: nothing after the cancel — "
                       + "no descent, no second root")
        XCTAssertEqual(result.events.first?.directory.path, root.path)
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertFalse(result.sawMainThread,
                       "the walker never touches the main actor")
    }

    // MARK: - R12: the absence boundary

    func testEntryVanishingBetweenEnumerationAndDescentSkipsQuietly() throws {
        let root = base.appendingPathComponent("dev")
        let goner = root.appendingPathComponent("goner")
        try mkdir(goner.appendingPathComponent("inner"))
        try mkdir(root.appendingPathComponent("stays"))

        var events: [ProjectTreeEvent] = []
        let fileManager = fm
        let walker = makeWalker(roots: [root])
        let issues = walker.walk(roots: [root], consumers: [{ event in
            events.append(event)
            if event.directory.path == root.path {
                // Delete a LISTED child between its parent's event (post-
                // enumeration) and the descent probe — the benign race.
                try? fileManager.removeItem(at: goner)
            }
            return []
        }])

        XCTAssertTrue(issues.isEmpty, "a benign deletion race is QUIET")
        let rootEvent = try XCTUnwrap(event(events, at: root))
        XCTAssertTrue(rootEvent.entries.contains(
            .init(name: "goner", kind: .directory)
        ), "the entry was honestly listed when it existed")
        XCTAssertNil(event(events, at: goner), "no event for the vanished dir")
        XCTAssertNotNil(event(events, at: root.appendingPathComponent("stays")))
    }

    func testUnreadableSubtreeClassifiedPermissionDeniedWalkContinues() throws {
        try XCTSkipIf(geteuid() == 0, "root ignores permission bits")
        let root = base.appendingPathComponent("dev")
        let locked = root.appendingPathComponent("locked")
        try mkdir(locked.appendingPathComponent("hidden-from-walk"))
        try mkdir(root.appendingPathComponent("open/inner"))
        try chmod000(locked)

        let (events, issues) = recordedWalk(roots: [root])

        // Failure of the CURRENT enumerated directory: classified, loud.
        XCTAssertEqual(issues.map(\.kind), [.permissionDenied],
                       "EACCES → .permissionDenied (frozen taxonomy)")
        XCTAssertEqual(issues.first?.url?.path, locked.path)
        XCTAssertNil(event(events, at: locked),
                     "an unenumerable directory yields an issue, not an event")
        XCTAssertNotNil(
            event(events, at: root.appendingPathComponent("open/inner")),
            "the walk continues elsewhere"
        )
    }

    func testOriginRootFailingAfterAdmissionIsClassifiedNeverSilent() throws {
        try XCTSkipIf(geteuid() == 0, "root ignores permission bits")
        // The origin root itself becomes unreadable (the unmount/permission-
        // loss shape): admission passes (identity + canonical checks need no
        // read permission), enumeration fails → per-root classified issue.
        let root = base.appendingPathComponent("dev")
        try mkdir(root.appendingPathComponent("proj"))
        try chmod000(root)

        let (events, issues) = recordedWalk(roots: [root])

        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(issues.map(\.kind), [.permissionDenied])
        XCTAssertEqual(issues.first?.url?.path, root.path,
                       "the issue names the ROOT — never a silent zero (R12)")
    }

    // MARK: - R12: EPERM → TCC classification (injected — EPERM cannot be
    // fixtured from an unentitled process)

    private final class FailingKindProbeProvider: FileSystemIdentityProvider {
        var failingNames: [String: Int32] = [:]

        override func probeKind(of url: URL) -> KindProbe {
            if let code = failingNames[url.lastPathComponent] {
                return .failed(errno: code)
            }
            return super.probeKind(of: url)
        }

        /// The walk probes children descriptor-relatively, so the injection
        /// has to live on that seam too.
        override func probeKind(
            inDirectory parent: Int32, named name: String, logical url: URL
        ) -> DescriptorKindProbe {
            if let code = failingNames[name] { return .failed(errno: code) }
            return super.probeKind(
                inDirectory: parent, named: name, logical: url
            )
        }
    }

    func testInjectedEPERMProbeClassifiesAsTCCDenied() throws {
        let root = base.appendingPathComponent("dev")
        try mkdir(root.appendingPathComponent("tcc-locked"))
        try mkdir(root.appendingPathComponent("fine"))

        let provider = FailingKindProbeProvider()
        provider.failingNames["tcc-locked"] = EPERM

        let (events, issues) = recordedWalk(roots: [root], provider: provider)

        XCTAssertEqual(issues.map(\.kind), [.tccDenied],
                       "EPERM → .tccDenied, distinct from EACCES")
        XCTAssertEqual(issues.first?.url?.lastPathComponent, "tcc-locked")
        let rootEvent = try XCTUnwrap(event(events, at: root))
        XCTAssertEqual(rootEvent.entries, [.init(name: "fine", kind: .directory)],
                       "an unprobeable child is not listed — no kind was proven")
        XCTAssertNotNil(event(events, at: root.appendingPathComponent("fine")))
    }

    // MARK: - R12: TCC protection by canonical prefix, never basename

    /// Counts `realpath(3)` arguments — `canonicalize` funnels through
    /// `realPath(of:)`, so one seam counts every dereference the
    /// classification performs (fn-4.26).
    private final class RealpathRecordingProvider: FileSystemIdentityProvider {
        private(set) var realPathArguments: [String] = []

        override func realPath(of path: String) -> String? {
            realPathArguments.append(path)
            return super.realPath(of: path)
        }
    }

    func testDirectlyProtectedSpellingClassifiesWithoutDereferencing() throws {
        // The predicate is the secondary TCC gate's classification, so it
        // must answer for a spelling that ALREADY lies under a protected
        // ancestor without dereferencing it — `realpath(3)` on `~/Documents/…`
        // is itself a traversal of the protected path, and the previous
        // canonicalize-first body performed it on exactly the paths it was
        // about to rule untouchable (fn-4.26).
        let documents = home.appendingPathComponent("Documents")
        try mkdir(documents.appendingPathComponent("GitHub"))
        let recorder = RealpathRecordingProvider()

        XCTAssertTrue(ProjectTreeWalker.isProtectedRoot(
            documents.appendingPathComponent("GitHub"), home: home, provider: recorder
        ))
        XCTAssertEqual(
            recorder.realPathArguments, [],
            "classifying a directly-protected spelling must not traverse it"
        )
        // Lexical `.`/`..` folds stay lexical too — no filesystem access.
        XCTAssertTrue(ProjectTreeWalker.isProtectedRoot(
            home.appendingPathComponent("Desktop/./x"), home: home, provider: recorder
        ))
        XCTAssertEqual(recorder.realPathArguments, [])

        // CONTROL: an unprotected spelling still reaches the CANONICAL stage
        // (the alias shapes in the cell below depend on it) — so the zeros
        // above are a property of the lexical match, not of a dead seam.
        XCTAssertFalse(ProjectTreeWalker.isProtectedRoot(
            home.appendingPathComponent("work"), home: home, provider: recorder
        ))
        XCTAssertFalse(
            recorder.realPathArguments.isEmpty,
            "the canonical stage ran for the unmatched spelling"
        )
    }

    func testProtectedRootDeterminationIsCanonicalPrefixNotBasename() throws {
        let documents = home.appendingPathComponent("Documents")
        try mkdir(documents.appendingPathComponent("GitHub"))
        // A directory literally NAMED "Documents" outside home, and a
        // sibling whose name merely STARTS with "Documents".
        let elsewhere = base.appendingPathComponent("other/Documents")
        try mkdir(elsewhere)
        let lookalike = home.appendingPathComponent("DocumentsX")
        try mkdir(lookalike)
        // An alias spelling INTO ~/Documents via a symlinked ancestor.
        let docLink = home.appendingPathComponent("doclink")
        try fm.createSymbolicLink(at: docLink, withDestinationURL: documents)

        let provider = FileSystemIdentityProvider()
        func isProtected(_ url: URL) -> Bool {
            ProjectTreeWalker.isProtectedRoot(url, home: home, provider: provider)
        }

        XCTAssertTrue(isProtected(documents), "the ancestor itself")
        XCTAssertTrue(isProtected(documents.appendingPathComponent("GitHub")),
                      "an arbitrary root UNDER a protected ancestor — prefix")
        XCTAssertTrue(isProtected(docLink.appendingPathComponent("GitHub")),
                      "an alias spelling into ~/Documents classifies as "
                      + "protected — computed on the CANONICAL path")
        XCTAssertTrue(isProtected(home.appendingPathComponent("Desktop/x")))
        XCTAssertTrue(isProtected(home.appendingPathComponent("Downloads")))
        XCTAssertFalse(isProtected(elsewhere),
                       "basename matching would wrongly protect this")
        XCTAssertFalse(isProtected(lookalike),
                       "string hasPrefix would wrongly protect this")
        XCTAssertFalse(isProtected(home.appendingPathComponent("work")))
    }

    func testProtectedRootsSkippedSilentlyWhenExcluded() throws {
        let githubRoot = home.appendingPathComponent("Documents/GitHub")
        try mkdir(githubRoot.appendingPathComponent("proj"))
        let workRoot = home.appendingPathComponent("work")
        try mkdir(workRoot.appendingPathComponent("proj"))
        let roots = [githubRoot, workRoot]

        let excluded = recordedWalk(roots: roots, includeProtectedRoots: false)
        XCTAssertTrue(excluded.issues.isEmpty,
                      "a policy skip is not a scan problem — silent")
        XCTAssertEqual(eventPaths(excluded.events), [
            workRoot.path, workRoot.appendingPathComponent("proj").path,
        ], "only the unprotected root is walked")

        let included = recordedWalk(roots: roots, includeProtectedRoots: true)
        XCTAssertNotNil(event(included.events, at: githubRoot),
                        "user-initiated scans walk protected roots")
    }
}
