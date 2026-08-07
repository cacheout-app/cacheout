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

        // Admitted as a container (a place to look)…
        XCTAssertNoThrow(try pathGuard.admitContainer(documents))
        // …while deletion-root admission refuses the same URL.
        assertRefused(documents, policy: emptyPolicy, guard: pathGuard)
        // Unconfigured roots are not containers.
        XCTAssertThrowsError(try pathGuard.admitContainer(downloads)) { error in
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
        let pathGuard = makeGuard(containers: [documents, fixtureHome])
        let docsContainer = try pathGuard.admitContainer(documents)

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

        // Deny-list re-check: a protected first-level child is refused even
        // as a strict descendant of an admitted (home) container.
        let homeContainer = try pathGuard.admitContainer(fixtureHome)
        XCTAssertThrowsError(
            try pathGuard.validateRemovableItem(library, inside: homeContainer)
        ) {
            guard case .deniedProtectedChild? = $0 as? PathGuardError else {
                return XCTFail("expected deniedProtectedChild, got \($0)")
            }
        }
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
        let container = try pathGuard.admitContainer(documents)

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

    // MARK: - Small helper

    /// Canonical path of a fixture URL, for exact error-payload assertions.
    private func pathGuard_canonicalPath(_ url: URL) -> String {
        FileSystemIdentityProvider().canonicalize(url).path
    }
}
