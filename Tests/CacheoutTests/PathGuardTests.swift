import XCTest
@testable import Cacheout

/// Hermetic tests for `PathGuard` + `FileSystemIdentityProvider` (fn-1.1, D4).
///
/// Every test runs against a UUID-derived fixture home under the system temp
/// directory — zero reads of the real `$HOME`, zero writes outside the fixture
/// root. The only real-filesystem assertions are read-only and conditional
/// (`/System/Volumes/Data` firmlink, case-/normalization-insensitive volume
/// probes, which skip on filesystems that do not exhibit the trait).
final class PathGuardTests: XCTestCase {

    private var base: URL!
    private var fixtureHome: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = fm.temporaryDirectory
            .appendingPathComponent("PathGuardTests-\(UUID().uuidString)")
        fixtureHome = base.appendingPathComponent("home")
        try fm.createDirectory(at: fixtureHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let base {
            try? fm.removeItem(at: base)
        }
    }

    // MARK: - Helpers

    private func mkdir(_ url: URL) throws {
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func makeGuard(
        containers: [URL] = [],
        provider: FileSystemIdentityProvider = FileSystemIdentityProvider()
    ) -> PathGuard {
        PathGuard(home: fixtureHome, containerRoots: containers, provider: provider)
    }

    /// A scan-session snapshot over the given roots — what the runtime's
    /// validated-scan entry point captures before launching scanners
    /// (fn-3.4, R9). Delete-time container admission requires one.
    private func snapshot(
        of roots: [URL],
        provider: FileSystemIdentityProvider = FileSystemIdentityProvider()
    ) -> ContainerSnapshot {
        ContainerSnapshot.capture(roots: roots, provider: provider)
    }

    /// Policy with home-relative declared roots (drift allowed), mirroring
    /// `.staticPath` / `.probed`-fallback declarations.
    private func driftPolicy(_ relatives: [String]) -> CategoryAdmissionPolicy {
        CategoryAdmissionPolicy(declaredRoots: relatives.map {
            .init(url: fixtureHome.appendingPathComponent($0), allowsSiblingDrift: true)
        })
    }

    private var emptyPolicy: CategoryAdmissionPolicy {
        CategoryAdmissionPolicy(declaredRoots: [])
    }

    private func assertRefused(
        _ url: URL, policy: CategoryAdmissionPolicy, guard pathGuard: PathGuard,
        _ expected: PathGuardError? = nil, message: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try pathGuard.admitDeletionRoot(url, policy: policy),
            "expected refusal of \(url.path) \(message)", file: file, line: line
        ) { error in
            if let expected {
                XCTAssertEqual(error as? PathGuardError, expected, file: file, line: line)
            }
        }
    }

    // MARK: - Deny list: /, $HOME, protected children

    func testRejectsFilesystemRoot() {
        let pathGuard = makeGuard()
        assertRefused(
            URL(fileURLWithPath: "/"), policy: emptyPolicy, guard: pathGuard,
            .deniedFilesystemRoot(path: "/")
        )
    }

    func testRejectsHomeDirectlyAndViaSymlinkAlias() throws {
        let pathGuard = makeGuard()
        // Even a policy that literally declares $HOME must be refused.
        let homePolicy = CategoryAdmissionPolicy(declaredRoots: [
            .init(url: fixtureHome, allowsSiblingDrift: true)
        ])

        assertRefused(fixtureHome, policy: homePolicy, guard: pathGuard,
                      message: "(direct spelling)")

        let alias = base.appendingPathComponent("homelink")
        try fm.createSymbolicLink(at: alias, withDestinationURL: fixtureHome)
        assertRefused(alias, policy: homePolicy, guard: pathGuard,
                      message: "(symlink alias)")
    }

    func testRejectsHomeCaseVariant() throws {
        // "home" fixture dir spelled "HOME" — same inode on the (default)
        // case-insensitive APFS Data volume; skip on case-sensitive setups.
        let variant = base.appendingPathComponent("HOME")
        try XCTSkipUnless(
            fm.fileExists(atPath: variant.path),
            "case-sensitive volume: case-variant spelling does not resolve"
        )
        assertRefused(variant, policy: emptyPolicy, guard: makeGuard(),
                      message: "(case-variant spelling)")
    }

    func testRejectsEveryProtectedFirstLevelChild() throws {
        let pathGuard = makeGuard()
        for name in PathGuard.protectedFirstLevelChildren {
            let child = fixtureHome.appendingPathComponent(name)
            try mkdir(child)
            // Even when declared by a (hostile/buggy) policy.
            let policy = CategoryAdmissionPolicy(declaredRoots: [
                .init(url: child, allowsSiblingDrift: true)
            ])
            assertRefused(child, policy: policy, guard: pathGuard,
                          .deniedProtectedChild(
                              path: pathGuard_canonicalPath(child), name: name
                          ))
        }
    }

    func testRejectsProtectedChildThatDoesNotExist() throws {
        // Lexical fallback: a protected name is refused even when the
        // directory is absent from this home.
        let home2 = base.appendingPathComponent("home2")
        try mkdir(home2)
        let pathGuard = PathGuard(home: home2, containerRoots: [])
        let ghostDocuments = home2.appendingPathComponent("Documents")
        XCTAssertThrowsError(
            try pathGuard.admitDeletionRoot(ghostDocuments, policy: emptyPolicy)
        ) { error in
            guard case .deniedProtectedChild(_, let name)? = error as? PathGuardError else {
                return XCTFail("expected deniedProtectedChild, got \(error)")
            }
            XCTAssertEqual(name, "Documents")
        }
    }

    func testRejectsNonApprovedHomeDescendant() throws {
        let policy = driftPolicy([".npm/_cacache", ".npm"])
        let stranger = fixtureHome.appendingPathComponent("some-random-dir")
        try mkdir(stranger)
        assertRefused(stranger, policy: policy, guard: makeGuard(),
                      message: "(non-approved $HOME descendant)")
    }

    // MARK: - Sibling rule

    func testSiblingRuleNegatives() throws {
        let pathGuard = makeGuard()

        // Homebrew policy refuses a different-stem sibling under ~/Library/Caches.
        let homebrewPolicy = driftPolicy(["Library/Caches/Homebrew"])
        try mkdir(fixtureHome.appendingPathComponent("Library/Caches/Homebrew"))
        let yarnShaped = fixtureHome.appendingPathComponent("Library/Caches/Yarn")
        try mkdir(yarnShaped)
        assertRefused(yarnShaped, policy: homebrewPolicy, guard: pathGuard,
                      message: "(stem mismatch under ~/Library/Caches)")

        // npm policy refuses ~/.ssh-shaped sibling (same parent, wrong stem).
        let npmPolicy = driftPolicy([".npm/_cacache", ".npm"])
        try mkdir(fixtureHome.appendingPathComponent(".npm"))
        let ssh = fixtureHome.appendingPathComponent(".ssh")
        try mkdir(ssh)
        assertRefused(ssh, policy: npmPolicy, guard: pathGuard,
                      message: "(~/.ssh stem mismatch)")

        // npm policy refuses DerivedData-shaped path (different parent entirely).
        let derived = fixtureHome
            .appendingPathComponent("Library/Developer/Xcode/DerivedData")
        try mkdir(derived)
        assertRefused(derived, policy: npmPolicy, guard: pathGuard,
                      message: "(DerivedData parent mismatch)")
    }

    func testSiblingRulePositives() throws {
        let pathGuard = makeGuard()

        // Version drift: store/v11 admitted when store/v10 declared.
        let store = fixtureHome.appendingPathComponent("Library/pnpm/store")
        let v10 = store.appendingPathComponent("v10")
        let v11 = store.appendingPathComponent("v11")
        try mkdir(v10)
        try mkdir(v11)
        let pnpmPolicy = driftPolicy(["Library/pnpm/store/v10"])

        let drifted = try pathGuard.admitDeletionRoot(v11, policy: pnpmPolicy)
        XCTAssertTrue(drifted.viaSiblingDrift)
        XCTAssertEqual(drifted.requestedURL, v11)

        // Exact declared root admitted, not via drift.
        let exact = try pathGuard.admitDeletionRoot(v10, policy: pnpmPolicy)
        XCTAssertFalse(exact.viaSiblingDrift)

        // Suffix drift on a named stem: Homebrew-2 next to declared Homebrew.
        let brew = fixtureHome.appendingPathComponent("Library/Caches/Homebrew")
        let brew2 = fixtureHome.appendingPathComponent("Library/Caches/Homebrew-2")
        try mkdir(brew)
        try mkdir(brew2)
        let homebrewPolicy = driftPolicy(["Library/Caches/Homebrew"])
        let admitted = try pathGuard.admitDeletionRoot(brew2, policy: homebrewPolicy)
        XCTAssertTrue(admitted.viaSiblingDrift)
    }

    func testVersionChildOfDeclaredRootAdmitted() throws {
        let pathGuard = makeGuard()

        // Production pnpm shape: Categories declares the unversioned store
        // root as the probed fallback, while `pnpm store path` returns the
        // versioned child below it (`…/pnpm/store/v10`).
        let store = fixtureHome.appendingPathComponent(".local/share/pnpm/store")
        let v10 = store.appendingPathComponent("v10")
        try mkdir(v10)
        let policy = driftPolicy([".local/share/pnpm/store"])

        let admitted = try pathGuard.admitDeletionRoot(v10, policy: policy)
        XCTAssertTrue(admitted.viaSiblingDrift)
        XCTAssertEqual(admitted.requestedURL, v10)

        // The declared root itself still admits exactly, not via drift.
        let exact = try pathGuard.admitDeletionRoot(store, policy: policy)
        XCTAssertFalse(exact.viaSiblingDrift)

        // Named (non-version) children stay refused — the child shape admits
        // pure-version basenames only.
        let files = store.appendingPathComponent("files")
        try mkdir(files)
        assertRefused(files, policy: policy, guard: pathGuard,
                      message: "(named child of declared root)")

        // Grandchildren stay refused — one component below the root only.
        let deep = v10.appendingPathComponent("files")
        try mkdir(deep)
        assertRefused(deep, policy: policy, guard: pathGuard,
                      message: "(grandchild of declared root)")
    }

    func testVersionStemExtraction() {
        XCTAssertEqual(PathGuard.versionStem(of: "v10"), "")
        XCTAssertEqual(PathGuard.versionStem(of: "v11"), "")
        XCTAssertEqual(PathGuard.versionStem(of: "store-2"), "store")
        XCTAssertEqual(PathGuard.versionStem(of: "cache_v3.1"), "cache")
        XCTAssertEqual(PathGuard.versionStem(of: "name.2"), "name")
        XCTAssertEqual(PathGuard.versionStem(of: ".npm"), ".npm")
        XCTAssertEqual(PathGuard.versionStem(of: ".ssh"), ".ssh")
        XCTAssertEqual(PathGuard.versionStem(of: "Homebrew"), "Homebrew")
        XCTAssertEqual(PathGuard.versionStem(of: "DerivedData"), "DerivedData")
    }

    // MARK: - .absolutePath: exact admission, no drift

    func testAbsolutePathPolicyAdmitsExactlyWithNoDrift() throws {
        // Fixture-shaped: exactly how CacheCleanerTests.makeCategory declares
        // itself, and how any future absolute-path category will.
        let cacheRoot = base.appendingPathComponent("abs-cache")
        try mkdir(cacheRoot)
        let category = CacheCategory(
            name: "fixture", slug: "fixture", description: "test", icon: "trash",
            discovery: [.absolutePath(cacheRoot.path)],
            riskLevel: .safe, rebuildNote: "", defaultSelected: true
        )
        let policy = CategoryAdmissionPolicy(category: category, home: fixtureHome)
        let pathGuard = makeGuard()

        let admitted = try pathGuard.admitDeletionRoot(cacheRoot, policy: policy)
        XCTAssertFalse(admitted.viaSiblingDrift)

        // A version-suffix sibling that WOULD drift under static/probed rules.
        let sibling = base.appendingPathComponent("abs-cache-2")
        try mkdir(sibling)
        assertRefused(sibling, policy: policy, guard: pathGuard,
                      message: "(.absolutePath gets no drift)")
    }

    // MARK: - Container vs deletion-root split

    func testContainerAdmissionIsSplitFromDeletionRootAdmission() throws {
        let documents = fixtureHome.appendingPathComponent("Documents")
        let downloads = fixtureHome.appendingPathComponent("Downloads")
        try mkdir(documents)
        try mkdir(downloads)
        let pathGuard = makeGuard(containers: [documents])

        // Admitted as a search root (a place to look, scan-time mode)…
        XCTAssertNoThrow(try pathGuard.admitSearchRoot(documents))
        // …and as a delete-time container under a session snapshot…
        XCTAssertNoThrow(try pathGuard.admitContainer(
            documents, snapshot: snapshot(of: [documents])
        ))
        // …while deletion-root admission refuses the same URL.
        assertRefused(documents, policy: emptyPolicy, guard: pathGuard)
        // Unconfigured roots are not containers, in EITHER mode.
        XCTAssertThrowsError(try pathGuard.admitSearchRoot(downloads)) { error in
            guard case .notAConfiguredContainer? = error as? PathGuardError else {
                return XCTFail("expected notAConfiguredContainer, got \(error)")
            }
        }
        XCTAssertThrowsError(try pathGuard.admitContainer(
            downloads, snapshot: snapshot(of: [downloads])
        )) { error in
            guard case .notAConfiguredContainer? = error as? PathGuardError else {
                return XCTFail("expected notAConfiguredContainer, got \(error)")
            }
        }
    }

    // MARK: - Symlink roots

    func testSymlinkRootJudgedByResolvedLocation() throws {
        let brew = fixtureHome.appendingPathComponent("Library/Caches/Homebrew")
        try mkdir(brew)
        let policy = driftPolicy(["Library/Caches/Homebrew"])
        let pathGuard = makeGuard()

        // Link INTO a declared root: admitted, and the token keeps the
        // unresolved spelling for deletion.
        let goodLink = base.appendingPathComponent("link-to-brew")
        try fm.createSymbolicLink(at: goodLink, withDestinationURL: brew)
        let admitted = try pathGuard.admitDeletionRoot(goodLink, policy: policy)
        XCTAssertEqual(admitted.requestedURL, goodLink,
                       "deletion must use the unresolved URL")

        // Link OUT to an undeclared location: refused by its real location.
        let elsewhere = base.appendingPathComponent("elsewhere")
        try mkdir(elsewhere)
        let escapeLink = fixtureHome
            .appendingPathComponent("Library/Caches/Homebrew-link")
        try fm.createSymbolicLink(at: escapeLink, withDestinationURL: elsewhere)
        assertRefused(escapeLink, policy: policy, guard: pathGuard,
                      message: "(symlink judged by real location)")
    }

    // MARK: - Registry smoke: every real category under its own policy

    func testRegistrySmokeEveryCategoryAdmittedUnderItsOwnPolicy() throws {
        let pathGuard = makeGuard()

        // Real registry (static + probed-fallback variants) plus one synthetic
        // absolute-path category so all three discovery kinds are exercised.
        let syntheticRoot = base.appendingPathComponent("synthetic-absolute-cache")
        let synthetic = CacheCategory(
            name: "synthetic", slug: "synthetic_absolute", description: "test",
            icon: "trash", discovery: [.absolutePath(syntheticRoot.path)],
            riskLevel: .safe, rebuildNote: "", defaultSelected: true
        )

        for category in CacheCategory.allCategories + [synthetic] {
            let policy = CategoryAdmissionPolicy(category: category, home: fixtureHome)
            XCTAssertFalse(policy.declaredRoots.isEmpty,
                           "\(category.slug): no declared roots")
            for declared in policy.declaredRoots {
                try mkdir(declared.url)
                XCTAssertNoThrow(
                    try pathGuard.admitDeletionRoot(declared.url, policy: policy),
                    "\(category.slug): own declared root refused: \(declared.url.path)"
                )
            }
        }
    }

    // MARK: - validateContainedChild

    func testValidateContainedChild() throws {
        let brew = fixtureHome.appendingPathComponent("Library/Caches/Homebrew")
        try mkdir(brew)
        let pathGuard = makeGuard()
        let root = try pathGuard.admitDeletionRoot(
            brew, policy: driftPolicy(["Library/Caches/Homebrew"])
        )

        // Real child accepted.
        let sub = brew.appendingPathComponent("downloads")
        try mkdir(sub)
        XCTAssertNoThrow(try pathGuard.validateContainedChild(sub, of: root))

        // Non-existent leaf still validates (already-gone = caller's skip case).
        let ghost = brew.appendingPathComponent("ghost.tar.gz")
        XCTAssertNoThrow(try pathGuard.validateContainedChild(ghost, of: root))

        // The root itself is not a child.
        XCTAssertThrowsError(try pathGuard.validateContainedChild(brew, of: root)) {
            guard case .isRootItself? = $0 as? PathGuardError else {
                return XCTFail("expected isRootItself, got \($0)")
            }
        }

        // Name-prefix sibling: /…/Homebrew-evil is NOT inside /…/Homebrew.
        let prefixSibling = URL(fileURLWithPath: brew.path + "-evil")
        XCTAssertThrowsError(
            try pathGuard.validateContainedChild(prefixSibling, of: root)
        ) {
            guard case .notADescendant? = $0 as? PathGuardError else {
                return XCTFail("expected notADescendant, got \($0)")
            }
        }

        // Symlink-ancestor escape: root/link/victim resolves outside the root.
        let outside = base.appendingPathComponent("outside")
        try mkdir(outside)
        let link = brew.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        let victim = link.appendingPathComponent("victim")
        XCTAssertThrowsError(
            try pathGuard.validateContainedChild(victim, of: root)
        ) {
            guard case .notADescendant? = $0 as? PathGuardError else {
                return XCTFail("expected notADescendant, got \($0)")
            }
        }

        // The escaping link ITSELF is a valid child — deleting it removes
        // only the link (leaf never resolved).
        XCTAssertNoThrow(try pathGuard.validateContainedChild(link, of: root))
    }

    // MARK: - validateRemovableItem

    func testValidateRemovableItem() throws {
        let documents = fixtureHome.appendingPathComponent("Documents")
        let library = fixtureHome.appendingPathComponent("Library")
        try mkdir(documents)
        try mkdir(library)
        // `fixtureHome` is deliberately still CONFIGURED here (fn-4.5): the
        // protected-child arm below pins that the R16 container-root policy
        // now refuses it at ADMISSION — one layer before the deny-list
        // re-check this test used to reach through it.
        let pathGuard = makeGuard(containers: [documents, fixtureHome])
        let sessionSnapshot = snapshot(of: [documents, fixtureHome])
        let docsContainer = try pathGuard.admitContainer(
            documents, snapshot: sessionSnapshot
        )

        // Item inside the container: accepted.
        let item = documents.appendingPathComponent("proj/node_modules")
        try mkdir(item)
        XCTAssertNoThrow(
            try pathGuard.validateRemovableItem(item, inside: docsContainer)
        )

        // The container itself: rejected.
        XCTAssertThrowsError(
            try pathGuard.validateRemovableItem(documents, inside: docsContainer)
        ) {
            guard case .isRootItself? = $0 as? PathGuardError else {
                return XCTFail("expected isRootItself, got \($0)")
            }
        }

        // Outside the container: rejected.
        XCTAssertThrowsError(
            try pathGuard.validateRemovableItem(
                URL(fileURLWithPath: documents.path + "X"), inside: docsContainer
            )
        ) {
            guard case .notADescendant? = $0 as? PathGuardError else {
                return XCTFail("expected notADescendant, got \($0)")
            }
        }

        // MIGRATED (fn-4.5, R16): this arm used to admit `$HOME` as a
        // container and then rely on the deny-list re-check to refuse
        // `~/Library` as a target. The container-root policy now refuses the
        // `$HOME` container OUTRIGHT, so the protected child below it is
        // unreachable a layer earlier — the same protection, one step
        // sooner. (`validateRemovableItem`'s deny-list re-check stays in
        // place as defense in depth; its volume-root/cross-device arms are
        // covered by the device tests below.)
        XCTAssertThrowsError(
            try pathGuard.admitContainer(fixtureHome, snapshot: sessionSnapshot)
        ) {
            guard case .deniedHomeDirectory? = $0 as? PathGuardError else {
                return XCTFail("expected deniedHomeDirectory, got \($0)")
            }
        }
        XCTAssertTrue(
            fm.fileExists(atPath: library.path),
            "nothing under the refused container was touched"
        )
    }

    // MARK: - Device rules (injected provider, R15)

    /// Provider that reports a fake device id for every path at/under a
    /// registered canonical prefix — hermetic stand-in for a mounted volume.
    private final class DeviceInjectingProvider: FileSystemIdentityProvider {
        var overrides: [(canonicalPrefix: String, device: UInt64)] = []

        override func identity(of url: URL) -> Identity? {
            let path = url.path
            for (prefix, device) in overrides {
                if path == prefix || path.hasPrefix(prefix + "/") {
                    let inode = super.identity(of: url)?.inode
                        ?? UInt64(bitPattern: Int64(path.hashValue))
                    return Identity(device: device, inode: inode)
                }
            }
            return super.identity(of: url)
        }
    }

    func testCrossDeviceItemRefused() throws {
        let documents = fixtureHome.appendingPathComponent("Documents")
        let mounted = documents.appendingPathComponent("mounted-proj")
        let item = mounted.appendingPathComponent("node_modules")
        try mkdir(item)

        let provider = DeviceInjectingProvider()
        // The foreign device covers the mount AND everything below it, so the
        // item is not itself a mount point — only on the wrong device.
        provider.overrides = [
            (provider.canonicalize(mounted).path, 0xBEEF)
        ]
        let pathGuard = makeGuard(containers: [documents], provider: provider)
        let container = try pathGuard.admitContainer(
            documents, snapshot: snapshot(of: [documents], provider: provider)
        )

        XCTAssertThrowsError(
            try pathGuard.validateRemovableItem(item, inside: container)
        ) {
            guard case .crossDevice? = $0 as? PathGuardError else {
                return XCTFail("expected crossDevice, got \($0)")
            }
        }
    }

    func testInjectedVolumeRootRefusedEvenWhenDeclared() throws {
        let caches = fixtureHome.appendingPathComponent("Library/Caches")
        let mountPoint = caches.appendingPathComponent("MountedCache")
        try mkdir(mountPoint)

        let provider = DeviceInjectingProvider()
        provider.overrides = [
            (provider.canonicalize(mountPoint).path, 0xF00D)
        ]
        let pathGuard = makeGuard(provider: provider)
        // Deny list beats policy: the mount point is literally declared.
        let policy = CategoryAdmissionPolicy(declaredRoots: [
            .init(url: mountPoint, allowsSiblingDrift: true)
        ])

        XCTAssertThrowsError(
            try pathGuard.admitDeletionRoot(mountPoint, policy: policy)
        ) {
            guard case .deniedVolumeRoot? = $0 as? PathGuardError else {
                return XCTFail("expected deniedVolumeRoot, got \($0)")
            }
        }
    }

    // MARK: - /var/folders ↔ /private/var canonicalization

    func testVarAndPrivateVarSpellingsAreInterchangeable() throws {
        let cacheRoot = base.appendingPathComponent("var-alias-cache")
        try mkdir(cacheRoot)
        try XCTSkipUnless(
            cacheRoot.path.hasPrefix("/var/"),
            "temporaryDirectory not under /var — alias probe not applicable"
        )
        let privateSpelling = URL(fileURLWithPath: "/private" + cacheRoot.path)
        let pathGuard = makeGuard()

        // Declared /var/…, candidate /private/var/… — and the reverse.
        let varPolicy = CategoryAdmissionPolicy(declaredRoots: [
            .init(url: cacheRoot, allowsSiblingDrift: false)
        ])
        XCTAssertNoThrow(
            try pathGuard.admitDeletionRoot(privateSpelling, policy: varPolicy)
        )
        let privatePolicy = CategoryAdmissionPolicy(declaredRoots: [
            .init(url: privateSpelling, allowsSiblingDrift: false)
        ])
        XCTAssertNoThrow(
            try pathGuard.admitDeletionRoot(cacheRoot, policy: privatePolicy)
        )

        // Non-existent leaf still admits across spellings (ancestors resolve;
        // the leaf is compared lexically).
        let ghost = base.appendingPathComponent("ghost-cache")
        let ghostPrivate = URL(fileURLWithPath: "/private" + ghost.path)
        let ghostPolicy = CategoryAdmissionPolicy(declaredRoots: [
            .init(url: ghost, allowsSiblingDrift: false)
        ])
        XCTAssertNoThrow(
            try pathGuard.admitDeletionRoot(ghostPrivate, policy: ghostPolicy)
        )
    }

    // MARK: - Unicode normalization (NFC/NFD)

    func testNFCAndNFDSpellingsShareOneIdentity() throws {
        let caches = fixtureHome.appendingPathComponent("Library/Caches")
        let nfdName = "cafe\u{0301}-cache" // e + combining acute (NFD)
        let nfcName = "café-cache"         // precomposed é (NFC)
        let nfdURL = caches.appendingPathComponent(nfdName)
        let nfcURL = caches.appendingPathComponent(nfcName)
        try mkdir(nfdURL)
        try XCTSkipUnless(
            fm.fileExists(atPath: nfcURL.path),
            "filesystem is normalization-sensitive — NFC spelling does not resolve"
        )

        // Declared in NFC, candidate spelled NFD: one inode, admitted.
        let policy = CategoryAdmissionPolicy(declaredRoots: [
            .init(url: nfcURL, allowsSiblingDrift: false)
        ])
        XCTAssertNoThrow(
            try makeGuard().admitDeletionRoot(nfdURL, policy: policy)
        )
    }

    // MARK: - Conditional real-firmlink integration (read-only)

    func testRealFirmlinkDataVolumeRefused() throws {
        let dataVolume = URL(fileURLWithPath: "/System/Volumes/Data")
        try XCTSkipUnless(
            fm.fileExists(atPath: dataVolume.path),
            "no /System/Volumes/Data on this system"
        )
        // Read-only: admission is pure lstat/realpath, and it must refuse the
        // Data volume root as a volume root regardless of policy.
        XCTAssertThrowsError(
            try makeGuard().admitDeletionRoot(dataVolume, policy: emptyPolicy)
        ) {
            guard case .deniedVolumeRoot? = $0 as? PathGuardError else {
                return XCTFail("expected deniedVolumeRoot, got \($0)")
            }
        }
    }

    // MARK: - Container-root admission policy (fn-4.1, R16)

    /// The shared policy component, tested DIRECTLY (its store call site is
    /// covered in DevRootsStoreTests; CLI and PathGuard-admission call
    /// sites arrive in fn-4.6 / fn-4.5). It is `denyCheck` MINUS the
    /// protected-children clause: `/`, volume roots, and `$HOME` are
    /// refused in canonical AND alias spellings; `~/Documents` is legal.

    func testContainerRootPolicyRejectsFilesystemRoot() {
        XCTAssertThrowsError(
            try PathGuard.validateContainerRoot(
                URL(fileURLWithPath: "/"), home: fixtureHome,
                provider: FileSystemIdentityProvider()
            )
        ) { error in
            XCTAssertEqual(error as? PathGuardError,
                           .deniedFilesystemRoot(path: "/"))
        }
    }

    func testContainerRootPolicyRejectsSymlinkAliasOfFilesystemRoot() throws {
        // Canonicalize-then-check, proven: the alias spelling is nowhere
        // near "/" lexically, yet resolves to it.
        let alias = base.appendingPathComponent("rootlink")
        try fm.createSymbolicLink(
            at: alias, withDestinationURL: URL(fileURLWithPath: "/")
        )
        XCTAssertThrowsError(
            try PathGuard.validateContainerRoot(
                alias, home: fixtureHome,
                provider: FileSystemIdentityProvider()
            )
        ) { error in
            XCTAssertEqual(error as? PathGuardError,
                           .deniedFilesystemRoot(path: "/"))
        }
    }

    func testContainerRootPolicyRejectsVolumeRootBothSignals() throws {
        // Signal (a): device-id change against the parent.
        let deviceVolume = base.appendingPathComponent("DeviceVol")
        try mkdir(deviceVolume)
        let deviceProvider = DeviceInjectingProvider()
        deviceProvider.overrides = [
            (deviceProvider.canonicalize(deviceVolume).path, 0xD15C)
        ]
        XCTAssertThrowsError(
            try PathGuard.validateContainerRoot(
                deviceVolume, home: fixtureHome, provider: deviceProvider
            ),
            "device-change signal must refuse a volume root"
        ) {
            guard case .deniedVolumeRoot? = $0 as? PathGuardError else {
                return XCTFail("expected deniedVolumeRoot, got \($0)")
            }
        }

        // Signal (b): statfs mount-root detection (injected mount probe) —
        // the firmlink case where st_dev never changes.
        let mountVolume = base.appendingPathComponent("MountVol")
        try mkdir(mountVolume)
        let mountProvider = MountPointInjectingProvider()
        mountProvider.mountPointPaths = [
            mountProvider.canonicalize(mountVolume).path
        ]
        XCTAssertThrowsError(
            try PathGuard.validateContainerRoot(
                mountVolume, home: fixtureHome, provider: mountProvider
            ),
            "mount-root signal must refuse even with an unchanged device id"
        ) {
            guard case .deniedVolumeRoot? = $0 as? PathGuardError else {
                return XCTFail("expected deniedVolumeRoot, got \($0)")
            }
        }
    }

    func testContainerRootPolicyRejectsInjectedHomeDirectAndAlias() throws {
        let provider = FileSystemIdentityProvider()
        // Direct spelling of the injected home.
        XCTAssertThrowsError(
            try PathGuard.validateContainerRoot(
                fixtureHome, home: fixtureHome, provider: provider
            )
        ) {
            guard case .deniedHomeDirectory? = $0 as? PathGuardError else {
                return XCTFail("expected deniedHomeDirectory, got \($0)")
            }
        }

        // Symlink alias — inode identity collapses the spellings.
        let alias = base.appendingPathComponent("homelink")
        try fm.createSymbolicLink(at: alias, withDestinationURL: fixtureHome)
        XCTAssertThrowsError(
            try PathGuard.validateContainerRoot(
                alias, home: fixtureHome, provider: provider
            )
        ) {
            guard case .deniedHomeDirectory? = $0 as? PathGuardError else {
                return XCTFail("expected deniedHomeDirectory, got \($0)")
            }
        }
    }

    func testContainerRootPolicyAcceptsProtectedChildren() throws {
        // The protected-children clause is deliberately EXCLUDED: intended
        // dev roots like ~/Documents and ~/Documents/dev must be legal
        // containers (the seed list depends on this) even though both stay
        // refused as DELETION targets.
        let documents = fixtureHome.appendingPathComponent("Documents")
        let dev = documents.appendingPathComponent("dev")
        try mkdir(dev)
        let provider = FileSystemIdentityProvider()

        XCTAssertNoThrow(try PathGuard.validateContainerRoot(
            documents, home: fixtureHome, provider: provider
        ))
        XCTAssertNoThrow(try PathGuard.validateContainerRoot(
            dev, home: fixtureHome, provider: provider
        ))

        // …and the SAME URL is still refused as a deletion target — the
        // split is the point.
        assertRefused(documents, policy: emptyPolicy, guard: makeGuard(),
                      message: "(deletion-target admission keeps the clause)")
    }

    // MARK: - Container-root policy INSIDE admission (fn-4.5, R16 layer c)
    //
    // The store (fn-4.1) and the CLI (fn-4.6) apply the same policy at
    // RESOLUTION, but resolution is configuration — this layer is the one
    // that holds when configuration is bypassed entirely. Every cell below
    // constructs a guard whose configured container root IS the dangerous
    // path (the shape a hand-edited plist, a future config path, or a
    // resolution bug produces) and asserts BOTH admission modes refuse it
    // with a CLASSIFIED error. The snapshot always contains the root, so a
    // refusal can never be the snapshot-missing fail-close by accident.

    /// One attack cell: (label, the configured root, the expected refusal
    /// predicate, the provider that makes the fixture behave like the
    /// dangerous thing).
    private func assertBothAdmissionModesRefuse(
        configuredRoot: URL,
        requestedAs requested: URL? = nil,
        provider: FileSystemIdentityProvider = FileSystemIdentityProvider(),
        label: String,
        expected: (PathGuardError) -> Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let pathGuard = makeGuard(containers: [configuredRoot], provider: provider)
        let sessionSnapshot = snapshot(of: [configuredRoot], provider: provider)
        let url = requested ?? configuredRoot

        for (mode, run) in [
            ("admitSearchRoot", { try pathGuard.admitSearchRoot(url) as Any }),
            ("admitContainer", {
                try pathGuard.admitContainer(url, snapshot: sessionSnapshot) as Any
            }),
        ] as [(String, () throws -> Any)] {
            XCTAssertThrowsError(
                try run(), "\(label): \(mode) must refuse",
                file: file, line: line
            ) { error in
                guard let guardError = error as? PathGuardError,
                      expected(guardError) else {
                    return XCTFail(
                        "\(label): \(mode) refused with the WRONG error: \(error)",
                        file: file, line: line
                    )
                }
            }
        }
    }

    func testAdmissionRefusesConfiguredFilesystemRootAndItsAlias() throws {
        assertBothAdmissionModesRefuse(
            configuredRoot: URL(fileURLWithPath: "/"),
            label: "configured filesystem root",
            expected: { if case .deniedFilesystemRoot = $0 { return true }; return false }
        )

        // The SYMLINK ALIAS of `/` — nowhere near "/" lexically. Both the
        // alias spelling and the canonical spelling must refuse, because the
        // policy runs on the CANONICALIZED matched root.
        let alias = base.appendingPathComponent("rootlink")
        try fm.createSymbolicLink(
            at: alias, withDestinationURL: URL(fileURLWithPath: "/")
        )
        assertBothAdmissionModesRefuse(
            configuredRoot: alias,
            label: "configured symlink alias of /",
            expected: { if case .deniedFilesystemRoot = $0 { return true }; return false }
        )
        assertBothAdmissionModesRefuse(
            configuredRoot: alias, requestedAs: URL(fileURLWithPath: "/"),
            label: "alias-configured root requested by its canonical spelling",
            expected: { if case .deniedFilesystemRoot = $0 { return true }; return false }
        )
    }

    func testAdmissionRefusesConfiguredHomeDirectlyAndViaAlias() throws {
        assertBothAdmissionModesRefuse(
            configuredRoot: fixtureHome,
            label: "configured $HOME",
            expected: { if case .deniedHomeDirectory = $0 { return true }; return false }
        )

        let alias = base.appendingPathComponent("homelink-admission")
        try fm.createSymbolicLink(at: alias, withDestinationURL: fixtureHome)
        assertBothAdmissionModesRefuse(
            configuredRoot: alias,
            label: "configured symlink alias of $HOME",
            expected: { if case .deniedHomeDirectory = $0 { return true }; return false }
        )
    }

    func testAdmissionRefusesConfiguredVolumeRootBothSignals() throws {
        // Signal (a): device-id change against the parent.
        let deviceVolume = base.appendingPathComponent("AdmitDeviceVol")
        try mkdir(deviceVolume)
        let deviceProvider = DeviceInjectingProvider()
        deviceProvider.overrides = [
            (deviceProvider.canonicalize(deviceVolume).path, 0xD15C)
        ]
        assertBothAdmissionModesRefuse(
            configuredRoot: deviceVolume, provider: deviceProvider,
            label: "configured volume root (device signal)",
            expected: { if case .deniedVolumeRoot = $0 { return true }; return false }
        )

        // Signal (b): statfs mount-root detection — the firmlink case where
        // st_dev never changes.
        let mountVolume = base.appendingPathComponent("AdmitMountVol")
        try mkdir(mountVolume)
        let mountProvider = MountPointInjectingProvider()
        mountProvider.mountPointPaths = [
            mountProvider.canonicalize(mountVolume).path
        ]
        assertBothAdmissionModesRefuse(
            configuredRoot: mountVolume, provider: mountProvider,
            label: "configured mount root (statfs signal)",
            expected: { if case .deniedVolumeRoot = $0 { return true }; return false }
        )
    }

    func testAdmissionAdmitsLegalProtectedChildContainerRoots() throws {
        // The LEGAL cell (the seeds depend on it): protected first-level
        // children and their descendants stay admissible as CONTAINERS in
        // both modes, and a symlinked-ANCESTOR spelling of such a root
        // canonicalizes to its legal target and admits too.
        let documents = fixtureHome.appendingPathComponent("Documents")
        let dev = documents.appendingPathComponent("dev")
        try mkdir(dev)
        let aliasParent = base.appendingPathComponent("docslink")
        try fm.createSymbolicLink(at: aliasParent, withDestinationURL: documents)
        let aliasDev = aliasParent.appendingPathComponent("dev")

        let roots = [documents, dev, aliasDev]
        let pathGuard = makeGuard(containers: roots)
        let sessionSnapshot = snapshot(of: roots)
        for root in roots {
            XCTAssertNoThrow(try pathGuard.admitSearchRoot(root),
                             "\(root.path) must admit as a search root")
            XCTAssertNoThrow(
                try pathGuard.admitContainer(root, snapshot: sessionSnapshot),
                "\(root.path) must admit as a delete-time container"
            )
        }

        // And a target inside the admitted protected-child container still
        // validates — the policy narrowed nothing legal.
        let target = dev.appendingPathComponent("proj/target")
        try mkdir(target)
        let container = try pathGuard.admitContainer(dev, snapshot: sessionSnapshot)
        XCTAssertNoThrow(try pathGuard.validateRemovableItem(target, inside: container))
    }

    func testEveryProductionRegisteredContainerRootStillAdmits() throws {
        // THE NO-REGRESSION CELL: the policy runs on every configured root
        // of every registered scanner, so the production union itself has to
        // pass it — seeded dev roots (several of them protected first-level
        // children) plus the orphaned-caches sweep root.
        let suiteName = "PathGuardTests-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        let provider = FileSystemIdentityProvider()
        let devRoots = DevRootsStore(defaults: suite, provider: provider)
            .effectiveRoots(home: fixtureHome)
        let runtime = SpaceScannerRuntime.production(
            home: fixtureHome, provider: provider, devRoots: devRoots
        )
        let roots = runtime.trustedContainerRoots
        // Non-vacuity: the union must actually carry the seeded roots AND a
        // protected first-level child (the case the policy must NOT reject).
        XCTAssertEqual(roots.count, DevRootsStore.seedRootNames.count + 1)
        XCTAssertTrue(
            roots.contains { $0.path == fixtureHome.appendingPathComponent("Documents").path },
            "~/Documents is a seeded dev root — the legal protected child"
        )

        let pathGuard = PathGuard(
            home: fixtureHome, containerRoots: roots, provider: provider
        )
        let sessionSnapshot = ContainerSnapshot.capture(
            roots: roots, provider: provider
        )
        for root in roots {
            XCTAssertNoThrow(try pathGuard.admitSearchRoot(root),
                             "registered root refused by the policy: \(root.path)")
            // Delete-time admission additionally needs the root to EXIST
            // (snapshot identity) — assert the policy verdict only for the
            // roots this fixture home actually has.
            if fm.fileExists(atPath: root.path) {
                XCTAssertNoThrow(
                    try pathGuard.admitContainer(root, snapshot: sessionSnapshot),
                    "registered root refused at delete time: \(root.path)"
                )
            }
        }
    }

    /// Injects statfs mount-root answers for canonical paths — hermetic
    /// stand-in for a firmlink/APFS-group mount (device id unchanged).
    private final class MountPointInjectingProvider:
        FileSystemIdentityProvider
    {
        var mountPointPaths: Set<String> = []
        override func isMountPoint(_ url: URL) -> Bool {
            if mountPointPaths.contains(url.path) { return true }
            return super.isMountPoint(url)
        }
    }

    // MARK: - Subprocess-traversal validation (fn-5.4, D13)

    /// An admitted container plus its guard, for the traversal cells.
    private func admittedContainer(
        provider: FileSystemIdentityProvider = FileSystemIdentityProvider()
    ) throws -> (guard: PathGuard, container: AdmittedContainer, root: URL) {
        let root = base.appendingPathComponent("dev")
        try mkdir(root)
        let pathGuard = makeGuard(containers: [root], provider: provider)
        let container = try pathGuard.admitContainer(
            root, snapshot: snapshot(of: [root], provider: provider)
        )
        return (pathGuard, container, root)
    }

    func testTraversalGuardRefusesASymlinkLeafEvenWhenItPointsInside() throws {
        // THE reason this operation exists: `validateRemovableItem` leaves the
        // leaf unresolved (correct for deletion — a symlink deletes as a
        // link), but a subprocess FOLLOWS what it is handed. A symlink leaf is
        // therefore refused OUTRIGHT here, even when its target is a perfectly
        // legal directory inside the same container.
        let (pathGuard, container, root) = try admittedContainer()
        let real = root.appendingPathComponent("real")
        try mkdir(real)
        let link = root.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)

        // The deletion-target validator accepts the link (by design).
        XCTAssertNoThrow(try pathGuard.validateRemovableItem(link, inside: container))
        // The traversal guard does not.
        XCTAssertThrowsError(
            try pathGuard.validateSubprocessTraversalDirectory(link, inside: container)
        ) { error in
            XCTAssertEqual(
                error as? PathGuardError,
                .notATraversableDirectory(path: link.path)
            )
        }
        XCTAssertNoThrow(
            try pathGuard.validateSubprocessTraversalDirectory(real, inside: container)
        )
    }

    func testTraversalGuardRefusesNonDirectoriesAndAbsentLeaves() throws {
        let (pathGuard, container, root) = try admittedContainer()
        let file = root.appendingPathComponent("file.txt")
        try Data("x".utf8).write(to: file)
        let absent = root.appendingPathComponent("nothing-here")

        for candidate in [file, absent] {
            XCTAssertThrowsError(
                try pathGuard.validateSubprocessTraversalDirectory(
                    candidate, inside: container
                ),
                candidate.lastPathComponent
            ) { error in
                XCTAssertEqual(
                    error as? PathGuardError,
                    .notATraversableDirectory(path: candidate.path)
                )
            }
        }
    }

    func testTraversalGuardCanonicalizesTheWholePathBeforeDecidingContainment()
        throws
    {
        // A symlinked ANCESTOR that escapes the container is caught because
        // the whole path canonicalizes first.
        let (pathGuard, container, root) = try admittedContainer()
        let outside = base.appendingPathComponent("outside")
        try mkdir(outside.appendingPathComponent("repo"))
        let escape = root.appendingPathComponent("escape")
        try fm.createSymbolicLink(at: escape, withDestinationURL: outside)

        XCTAssertThrowsError(
            try pathGuard.validateSubprocessTraversalDirectory(
                escape.appendingPathComponent("repo"), inside: container
            )
        ) { error in
            guard case .notADescendant = error as? PathGuardError else {
                return XCTFail("expected a containment refusal, got \(error)")
            }
        }
    }

    func testTraversalContainmentIsStrictByDefaultAndEqualOnlyWhenAsked()
        throws
    {
        // Round 4: `parentRepoWorkingDir` ALONE may equal the container (a
        // dev root that IS a repository); every mutated path stays strict.
        let (pathGuard, container, root) = try admittedContainer()
        XCTAssertThrowsError(
            try pathGuard.validateSubprocessTraversalDirectory(root, inside: container)
        ) { error in
            guard case .isRootItself = error as? PathGuardError else {
                return XCTFail("expected isRootItself, got \(error)")
            }
        }
        XCTAssertNoThrow(
            try pathGuard.validateSubprocessTraversalDirectory(
                root, inside: container, containment: .descendantOrEqual
            )
        )
        // Descendant-or-equal is not a licence to leave the container.
        let outside = base.appendingPathComponent("outside")
        try mkdir(outside)
        XCTAssertThrowsError(
            try pathGuard.validateSubprocessTraversalDirectory(
                outside, inside: container, containment: .descendantOrEqual
            )
        )
    }

    func testTraversalGuardFailsClosedOnDeviceMismatchAndOnUnreadableDevices()
        throws
    {
        // Cross-device parity with `validateRemovableItem` — and STRICTER by
        // design: a path whose device id cannot be read at all is refused
        // too, because a subprocess must never be pointed at a location this
        // guard could not prove sits on the container's volume.
        let injecting = DeviceInjectingProvider()
        let (pathGuard, container, root) = try admittedContainer(provider: injecting)
        let foreign = root.appendingPathComponent("foreign")
        try mkdir(foreign)
        injecting.overrides = [(pathGuard_canonicalPath(foreign), 4242)]

        XCTAssertThrowsError(
            try pathGuard.validateSubprocessTraversalDirectory(
                foreign, inside: container
            )
        ) { error in
            guard case .crossDevice = error as? PathGuardError else {
                return XCTFail("expected crossDevice, got \(error)")
            }
        }

        let unreadable = root.appendingPathComponent("unreadable")
        try mkdir(unreadable)
        let blind = UnreadableDeviceProvider()
        blind.blindPaths = [pathGuard_canonicalPath(unreadable)]
        let blindGuard = makeGuard(containers: [root], provider: blind)
        let blindContainer = try blindGuard.admitContainer(
            root, snapshot: snapshot(of: [root], provider: blind)
        )
        XCTAssertThrowsError(
            try blindGuard.validateSubprocessTraversalDirectory(
                unreadable, inside: blindContainer
            )
        ) { error in
            guard case .crossDevice = error as? PathGuardError else {
                return XCTFail("expected a fail-closed crossDevice, got \(error)")
            }
        }
    }

    /// Reports NO identity (and therefore no device id) for the named
    /// canonical paths — the "cannot prove it is on this volume" case.
    private final class UnreadableDeviceProvider: FileSystemIdentityProvider {
        var blindPaths: Set<String> = []
        override func identity(of url: URL) -> Identity? {
            blindPaths.contains(canonicalize(url).path)
                ? nil
                : super.identity(of: url)
        }
    }

    // MARK: - Small helper

    /// Canonical path of a fixture URL, for exact error-payload assertions.
    private func pathGuard_canonicalPath(_ url: URL) -> String {
        FileSystemIdentityProvider().canonicalize(url).path
    }
}
