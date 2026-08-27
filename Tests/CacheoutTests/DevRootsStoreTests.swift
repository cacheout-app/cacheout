import XCTest
@testable import Cacheout

/// Hermetic tests for `DevRootsStore` (fn-4.1, R8/R16): seeds, guarded
/// persistence, the container-root admission policy at store resolution,
/// and exact-canonical-duplicate dedupe. House rules: injected UserDefaults
/// suite + injected fixture home ONLY — zero reads of the real `$HOME`,
/// zero standard-suite writes.
final class DevRootsStoreTests: XCTestCase {

    private var base: URL!
    private var fixtureHome: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = fm.temporaryDirectory
            .appendingPathComponent("DevRootsStoreTests-\(UUID().uuidString)")
        fixtureHome = base.appendingPathComponent("home")
        try fm.createDirectory(at: fixtureHome, withIntermediateDirectories: true)
        suiteName = "DevRootsStoreTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        if let suiteName {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        if let base {
            try? fm.removeItem(at: base)
        }
    }

    // MARK: - Helpers

    private func mkdir(_ url: URL) throws {
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func makeStore(
        provider: FileSystemIdentityProvider = FileSystemIdentityProvider()
    ) -> DevRootsStore {
        DevRootsStore(defaults: defaults, provider: provider)
    }

    private func persist(_ value: Any) {
        defaults.set(value, forKey: DevRootsStore.devRootsKey)
    }

    private var storedValue: Any? {
        defaults.object(forKey: DevRootsStore.devRootsKey)
    }

    /// The never-rewritten assertion — `as? NSObject` equality, never
    /// interpolated strings (`"\(NSNumber(true))"` prints "1"; the fn-3
    /// memory entry).
    private func assertStoredUnchanged(
        _ original: Any, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(
            storedValue as? NSObject, original as? NSObject,
            "resolution must NEVER rewrite the stored value",
            file: file, line: line
        )
    }

    /// The ten seed roots as an INDEPENDENT fixture list, resolved against
    /// the injected home. Until fn-4.7 this expectation was derived from
    /// `NodeModulesScanner.defaultSearchRoots(home:)`; the retired scanner's
    /// source is gone, and a hand-written list is the stronger fixture anyway
    /// (it cannot silently track a change to the code under test).
    private func expectedSeedRoots() -> [URL] {
        [
            "Documents", "Developer", "Projects", "Code", "Sites",
            "Desktop", "Dropbox", "repos", "src", "work",
        ].map { fixtureHome.appendingPathComponent($0) }
    }

    // MARK: - R8: seeds

    func testSeedsAreExactlyTheTenRetiredNodeModulesRootsAgainstInjectedHome() {
        // No persisted value → the seeds, resolved against the INJECTED
        // home, all kept (absent roots pass through verbatim — machines
        // differ; walk time maps absence to honest omission).
        let resolution = makeStore().effectiveRoots(home: fixtureHome)

        XCTAssertEqual(resolution.issues, [])
        XCTAssertEqual(
            resolution.keptRoots,
            expectedSeedRoots(),
            "seeds must be the retired node_modules scanner's ten VERBATIM"
        )
        // The literal list, frozen — and pinned against the source of truth.
        XCTAssertEqual(DevRootsStore.seedRootNames, [
            "Documents", "Developer", "Projects", "Code", "Sites",
            "Desktop", "Dropbox", "repos", "src", "work",
        ])
        // NO Documents/GitHub seed (D7: ~/Documents covers it to depth 8).
        XCTAssertFalse(resolution.keptRoots.contains {
            $0.path.hasSuffix("Documents/GitHub")
        })
    }

    func testHomeRelativeAndAbsoluteDeclaredStringsResolve() throws {
        let absolute = base.appendingPathComponent("elsewhere-root")
        try mkdir(absolute)
        persist(["Documents", absolute.path])

        let resolution = makeStore().effectiveRoots(home: fixtureHome)
        XCTAssertEqual(resolution.keptRoots.map(\.path), [
            fixtureHome.appendingPathComponent("Documents").path,
            absolute.path,
        ], "non-/-prefixed strings are home-relative (the seed convention); "
           + "/-prefixed are absolute")
        XCTAssertEqual(resolution.issues, [])
    }

    // MARK: - R16: store-layer attack fixtures

    func testPersistedFilesystemRootExcludedWithPolicyRefusedRoot() throws {
        let original: Any = ["/"]
        persist(original)

        let resolution = makeStore().effectiveRoots(home: fixtureHome)

        XCTAssertEqual(resolution.keptRoots, [],
                       "a persisted `/` must never be registered or walked")
        XCTAssertEqual(resolution.issues.count, 1)
        let issue = try XCTUnwrap(resolution.issues.first)
        XCTAssertEqual(issue.kind, .policyRefusedRoot,
                       "a policy-rejected root IS configured (fn-4.12): the "
                       + "kind-derived GUI label under `.containerRefused` "
                       + "said the opposite of the detail")
        XCTAssertEqual(issue.kind.wireString, "policy_refused_root")
        XCTAssertEqual(issue.url?.path, "/",
                       "a policy rejection carries its offending path honestly")
        assertStoredUnchanged(original)
    }

    func testPersistedSymlinkAliasOfFilesystemRootExcluded() throws {
        let alias = base.appendingPathComponent("rootlink")
        try fm.createSymbolicLink(
            at: alias, withDestinationURL: URL(fileURLWithPath: "/")
        )
        persist([alias.path])

        let resolution = makeStore().effectiveRoots(home: fixtureHome)

        XCTAssertEqual(resolution.keptRoots, [],
                       "an alias of / names / — read from the link's own "
                       + "content since fn-4.11, never by resolving it")
        XCTAssertEqual(resolution.issues.map(\.kind), [.policyRefusedRoot])
        XCTAssertEqual(resolution.issues.first?.url?.path, alias.path,
                       "the issue names the DECLARED offending spelling")
    }

    func testPersistedVolumeRootExcludedViaInjectedMountProbe() throws {
        let volume = base.appendingPathComponent("ExternalVol")
        try mkdir(volume)
        let provider = MountPointInjectingProvider()
        provider.mountPointPaths = [provider.canonicalize(volume).path]
        persist([volume.path])

        let resolution = makeStore(provider: provider)
            .effectiveRoots(home: fixtureHome)

        XCTAssertEqual(resolution.keptRoots, [])
        XCTAssertEqual(resolution.issues.map(\.kind), [.policyRefusedRoot])
    }

    func testPersistedHomeExcludedInDirectAndAliasSpellings() throws {
        let alias = base.appendingPathComponent("homelink")
        try fm.createSymbolicLink(at: alias, withDestinationURL: fixtureHome)
        persist([fixtureHome.path, alias.path])

        let resolution = makeStore().effectiveRoots(home: fixtureHome)

        XCTAssertEqual(resolution.keptRoots, [],
                       "$HOME must be excluded in EVERY spelling — by inode "
                       + "identity when spelled directly, by the link's own "
                       + "content when aliased (fn-4.11)")
        XCTAssertEqual(resolution.issues.map(\.kind),
                       [.policyRefusedRoot, .policyRefusedRoot])
        XCTAssertEqual(resolution.issues.map { $0.url?.path },
                       [fixtureHome.path, alias.path])
    }

    func testProtectedChildrenAreLegalDevRoots() throws {
        // The policy is denyCheck MINUS the protected-children clause —
        // the seeds depend on ~/Documents being a legal dev root.
        let documents = fixtureHome.appendingPathComponent("Documents")
        let dev = documents.appendingPathComponent("dev")
        try mkdir(dev)
        persist([documents.path, dev.path])

        let resolution = makeStore().effectiveRoots(home: fixtureHome)

        XCTAssertEqual(resolution.keptRoots.map(\.path),
                       [documents.path, dev.path])
        XCTAssertEqual(resolution.issues, [])
    }

    func testValidArrayElementsArePolicyCheckedIndividually() throws {
        let good = base.appendingPathComponent("good-root")
        try mkdir(good)
        persist(["/", good.path])

        let resolution = makeStore().effectiveRoots(home: fixtureHome)

        XCTAssertEqual(resolution.keptRoots.map(\.path), [good.path],
                       "a dangerous string in a VALID array is rejected "
                       + "individually; the rest of the list survives")
        XCTAssertEqual(resolution.issues.map(\.kind), [.policyRefusedRoot])
    }

    // MARK: - R8/R16: guarded parsing + mixed-corrupt semantics

    func testInvalidArrayShapesFallBackToSeedsWithoutRewriteAndSurfaceParseIssue() throws {
        let invalidValues: [Any] = [
            true,                    // CFBoolean — the fn-3 bridging trap
            42,                      // a number is not a string array
            "not-an-array",          // a lone string is not an array
            ["ok", 7],               // ANY non-string element corrupts the whole
            [true],                  // a boolean element likewise
        ]
        let seeds = expectedSeedRoots()

        for invalid in invalidValues {
            persist(invalid)
            let resolution = makeStore().effectiveRoots(home: fixtureHome)

            XCTAssertEqual(resolution.keptRoots, seeds,
                           "seeds in effect for \(invalid)")
            XCTAssertEqual(resolution.issues.count, 1,
                           "exactly one parse issue for \(invalid)")
            let issue = try XCTUnwrap(resolution.issues.first)
            XCTAssertEqual(issue.kind, .configInvalid)
            XCTAssertNil(issue.url,
                         "a config parse failure has NO honest filesystem "
                         + "path — none may be invented")
            XCTAssertTrue(issue.detail.contains(DevRootsStore.devRootsKey),
                          "the detail names the malformed key")
            assertStoredUnchanged(invalid)
        }
    }

    func testMixedCorruptCellTrueAndSlashIsWholeValueParseFailure() throws {
        // THE pinned attack cell: [true, "/"]. The array shape is invalid,
        // so the WHOLE value is a parse failure — seeds in effect, ONE
        // config_invalid issue, and the embedded "/" never reaches the kept
        // set (the visible parse issue covers it; no per-root refusal row
        // is fabricated for a value that was never accepted as config).
        let original: Any = [true, "/"]
        persist(original)

        let resolution = makeStore().effectiveRoots(home: fixtureHome)

        XCTAssertEqual(
            resolution.keptRoots,
            expectedSeedRoots()
        )
        XCTAssertEqual(resolution.issues.count, 1)
        let issue = try XCTUnwrap(resolution.issues.first)
        XCTAssertEqual(issue.kind, .configInvalid)
        XCTAssertEqual(issue.kind.wireString, "config_invalid")
        XCTAssertNil(issue.url)
        // The dangerous embedded string is never silently bypassed INTO the
        // kept set.
        XCTAssertFalse(resolution.keptRoots.contains {
            FileSystemIdentityProvider().canonicalize($0).path == "/"
        })
        assertStoredUnchanged(original)
    }

    func testConfigInvalidWireStringPinned() {
        XCTAssertEqual(ScanIssue.Kind.configInvalid.wireString,
                       "config_invalid")
    }

    // MARK: - R8/D7: exact-canonical-duplicate dedupe ONLY

    func testExactCanonicalDuplicateDedupeKeepsFirstDeclaredSpellingVerbatim() throws {
        // One real directory, two declared spellings: direct, and via a
        // symlinked ANCESTOR (legal — the /var → /private/var pattern).
        let parent = base.appendingPathComponent("real-parent")
        let root = parent.appendingPathComponent("dev-root")
        try mkdir(root)
        let aliasParent = base.appendingPathComponent("alias-parent")
        try fm.createSymbolicLink(at: aliasParent, withDestinationURL: parent)
        let aliasSpelling = aliasParent.appendingPathComponent("dev-root")

        persist([aliasSpelling.path, root.path])

        let resolution = makeStore().effectiveRoots(home: fixtureHome)

        // The FIRST declared spelling survives — VERBATIM, never the
        // canonical form (registration and walker originRoot need the
        // declared spelling).
        XCTAssertEqual(resolution.keptRoots.map(\.path), [aliasSpelling.path],
                       "kept root must be the DECLARED spelling, untouched")
        XCTAssertEqual(resolution.issues, [])
    }

    func testSymlinkLeafRootIsSetAsideAndPassesThroughVerbatim() throws {
        // A symlink-LEAF root whose target is NOT itself declared does not
        // participate in dedupe: it is set aside and passes through
        // verbatim (walk time refuses it with a classified issue).
        let real = base.appendingPathComponent("real-root")
        try mkdir(real)
        let link = base.appendingPathComponent("link-root")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)

        persist([link.path])

        let resolution = makeStore().effectiveRoots(home: fixtureHome)
        XCTAssertEqual(resolution.keptRoots.map(\.path), [link.path],
                       "symlink-leaf roots are SET ASIDE, not deduped away")
        XCTAssertEqual(resolution.issues, [])
    }

    // MARK: - R8/R16: alias suppression (a symlink alias never shadows the
    // real root it points at — `matchConfiguredRoot` is FIRST-match)

    /// Both declaration orders, end to end through the very admission the
    /// alias used to break: alias-first is the reviewer's scenario (the
    /// alias matched first and `admitContainer`'s no-follow gate then
    /// refused it without trying the real root), real-first is the control.
    func testSymlinkAliasNeverShadowsItsDeclaredTargetAtDeleteTime() throws {
        let real = base.appendingPathComponent("real-root")
        let project = real.appendingPathComponent("proj/build")
        try mkdir(project)
        let alias = base.appendingPathComponent("alias-root")
        try fm.createSymbolicLink(at: alias, withDestinationURL: real)

        for declared in [[alias.path, real.path], [real.path, alias.path]] {
            persist(declared)
            let provider = FileSystemIdentityProvider()
            let roots = makeStore(provider: provider)
                .effectiveRoots(home: fixtureHome).keptRoots
            let pathGuard = PathGuard(
                home: fixtureHome, containerRoots: roots, provider: provider
            )
            let sessionSnapshot = ContainerSnapshot.capture(
                roots: roots, provider: provider
            )

            // The real root is what the walker walks and stamps as every
            // item's `originRoot` — delete-time admission must accept it in
            // EITHER declaration order.
            let container = try pathGuard.admitContainer(
                real, snapshot: sessionSnapshot
            )
            XCTAssertNoThrow(
                try pathGuard.validateRemovableItem(project, inside: container),
                "items found under \(real.path) must stay cleanable "
                    + "(declared \(declared))"
            )
        }
    }

    func testSymlinkAliasOfADeclaredRealRootIsDroppedWithAClassifiedIssue()
        throws
    {
        let real = base.appendingPathComponent("real-root")
        try mkdir(real)
        let alias = base.appendingPathComponent("alias-root")
        try fm.createSymbolicLink(at: alias, withDestinationURL: real)

        persist([alias.path, real.path])

        let resolution = makeStore().effectiveRoots(home: fixtureHome)
        // The alias is dropped; the REAL root survives VERBATIM (its
        // declared spelling, never the canonical form) even though the
        // alias was declared first.
        XCTAssertEqual(resolution.keptRoots.map(\.path), [real.path],
                       "an unusable alias must never sit in the kept set "
                       + "ahead of the usable root it resolves to")
        // Never a silent drop: the user learns the declaration is redundant.
        let issue = try XCTUnwrap(resolution.issues.first)
        XCTAssertEqual(resolution.issues.count, 1)
        XCTAssertEqual(issue.kind, .symlinkRoot)
        XCTAssertEqual(issue.kind.wireString, "symlink_root")
        XCTAssertEqual(issue.url, alias)
        XCTAssertTrue(issue.detail.contains(real.path),
                      "the issue must name the root that already covers it")
    }

    /// The leaf-resolution doctrine survives the alias suppression: a
    /// symlink LEAF is never resolved INTO the kept set. Two aliases of the
    /// same real directory, that directory NOT declared — nothing is
    /// dropped, and no canonical (leaf-resolved) spelling appears.
    func testAliasSuppressionNeverResolvesLeavesIntoTheKeptSet() throws {
        let real = base.appendingPathComponent("real-root")
        try mkdir(real)
        let first = base.appendingPathComponent("alias-one")
        let second = base.appendingPathComponent("alias-two")
        try fm.createSymbolicLink(at: first, withDestinationURL: real)
        try fm.createSymbolicLink(at: second, withDestinationURL: real)

        persist([first.path, second.path])

        let resolution = makeStore().effectiveRoots(home: fixtureHome)
        XCTAssertEqual(resolution.keptRoots.map(\.path),
                       [first.path, second.path],
                       "no declared root covers these leaves — they pass "
                       + "through verbatim for the walk-time gate to class")
        XCTAssertEqual(resolution.issues, [])
    }

    func testAbsentAndNonDirectoryRootsPassThroughVerbatim() throws {
        let absent = base.appendingPathComponent("never-created")
        let file = base.appendingPathComponent("a-regular-file")
        try Data("x".utf8).write(to: file)

        persist([absent.path, file.path])

        let resolution = makeStore().effectiveRoots(home: fixtureHome)
        XCTAssertEqual(resolution.keptRoots.map(\.path),
                       [absent.path, file.path],
                       "absent → honest no-item omission at walk time; "
                       + "non-directory → refused at walk time with a "
                       + "classified issue — neither is the store's call")
        XCTAssertEqual(resolution.issues, [])
    }

    // MARK: - fn-4.11: resolution never names a symlink root's destination

    /// FAILS THE TEST on any call naming the forbidden DESTINATION or
    /// anything below it, and on any LEAF-FOLLOWING operation on a listed
    /// alias spelling (`canonicalize`/`realPath`/`isMountPoint` — `realpath(3)`
    /// resolves the link, `statfs(2)` follows it). `lstat`/`readlink`-class
    /// calls on the alias itself stay legal: they read the link's own entry
    /// and content, never the destination.
    private final class DestinationForbiddingProvider:
        FileSystemIdentityProvider, @unchecked Sendable
    {
        var forbiddenDestination = ""
        var aliasSpellings: Set<String> = []
        private let fail: (String) -> Void

        init(fail: @escaping (String) -> Void) {
            self.fail = fail
            super.init()
        }

        private func forbid(_ method: String, _ path: String) {
            guard !forbiddenDestination.isEmpty,
                  path == forbiddenDestination
                    || path.hasPrefix(forbiddenDestination + "/")
            else { return }
            fail("\(method) made first contact with the destination: \(path)")
        }
        private func forbidFollow(_ method: String, _ path: String) {
            forbid(method, path)
            if aliasSpellings.contains(path) {
                fail("\(method) is a leaf-following resolution of the alias "
                    + "spelling itself: \(path)")
            }
        }

        override func realPath(of path: String) -> String? {
            forbidFollow("realPath", path)
            let out = super.realPath(of: path)
            if let out { forbid("realPath output", out) }
            return out
        }
        override func canonicalize(_ url: URL) -> URL {
            forbidFollow("canonicalize", url.path)
            return super.canonicalize(url)
        }
        override func isMountPoint(_ url: URL) -> Bool {
            forbidFollow("isMountPoint", url.path)
            return super.isMountPoint(url)
        }
        override func probeKind(of url: URL) -> KindProbe {
            forbid("probeKind", url.path)
            return super.probeKind(of: url)
        }
        override func identity(of url: URL) -> Identity? {
            forbid("identity", url.path)
            return super.identity(of: url)
        }
        override func symlinkTarget(of url: URL) -> String? {
            forbid("symlinkTarget", url.path)
            return super.symlinkTarget(of: url)
        }
        override func canEnumerateDirectory(_ url: URL) -> Bool {
            forbidFollow("canEnumerateDirectory", url.path)
            return super.canEnumerateDirectory(url)
        }
        override func ownerProbe(of url: URL) -> OwnerProbe {
            forbid("ownerProbe", url.path)
            return super.ownerProbe(of: url)
        }
        override func leafMetadata(of url: URL) -> LeafMetadata? {
            forbid("leafMetadata", url.path)
            return super.leafMetadata(of: url)
        }
        override func linkCount(of url: URL) -> UInt64? {
            forbid("linkCount", url.path)
            return super.linkCount(of: url)
        }
    }

    /// fn-4.11: `effectiveRoots` runs synchronously inside runtime
    /// construction on the main thread, and a persisted dev root is a path
    /// the app does not control — a same-UID process can aim it at an
    /// unresponsive mounted volume. The old shape canonicalized every root
    /// (policy first, probe pair second), so a symlink root's DESTINATION
    /// was named — and could block launch — before any window existed. Both
    /// alias shapes are kept verbatim with ZERO destination contact.
    func testResolutionNeverContactsASymlinkDevRootsDestination() throws {
        let destination = base.appendingPathComponent("quarantined-dest")
        try mkdir(destination)
        let alias = base.appendingPathComponent("alias-to-dest")
        try fm.createSymbolicLink(at: alias, withDestinationURL: destination)
        let dangling = base.appendingPathComponent("dangling-alias")
        try fm.createSymbolicLink(
            at: dangling,
            withDestinationURL: destination.appendingPathComponent("gone")
        )
        persist([alias.path, dangling.path])

        let provider = DestinationForbiddingProvider(fail: { XCTFail($0) })
        provider.forbiddenDestination = destination.path
        provider.aliasSpellings = [alias.path, dangling.path]

        let resolution = makeStore(provider: provider)
            .effectiveRoots(home: fixtureHome)
        XCTAssertEqual(resolution.keptRoots.map(\.path),
                       [alias.path, dangling.path],
                       "nothing declared covers these leaves — they pass "
                       + "through verbatim for the walk-time gate to class")
        XCTAssertEqual(resolution.issues, [])
    }

    /// fn-4.11's recorded residual, pinned the way fn-6 pins its own
    /// (`testAliasWrittenThroughAThirdSpellingKeepsBothRootsRatherThanGuessing`):
    /// the drop decision compares the link's CONTENT against spellings the
    /// resolution already holds — it never resolves the destination, so a
    /// target written through a spelling nobody declared matches nothing and
    /// BOTH roots are kept rather than guessed about. The alias stays
    /// fail-closed in its own right: never walkable, never admissible.
    func testAliasNamingItsTargetThroughAThirdSpellingKeepsBothRoots() throws {
        let real = base.appendingPathComponent("real-root")
        try mkdir(real)
        let alias = base.appendingPathComponent("alias-root")
        // A case-variant spelling: on the default case-insensitive volume
        // the link RESOLVES onto the real root (the old full-resolution key
        // dropped it); lexically it matches nothing anyone declared.
        try fm.createSymbolicLink(
            at: alias,
            withDestinationURL: base.appendingPathComponent("REAL-ROOT")
        )
        persist([alias.path, real.path])

        let resolution = makeStore().effectiveRoots(home: fixtureHome)
        XCTAssertEqual(resolution.keptRoots.map(\.path),
                       [alias.path, real.path],
                       "a name compare must keep both rather than guess")
        XCTAssertEqual(resolution.issues, [])
    }

    func testNestedRealRootsBothKeptNoKeepAncestorDrop() throws {
        // D7: path ancestry is NEVER traversal equivalence — an ancestor's
        // depth-8 walk does not reach what a nested root's own depth-8
        // budget reaches.
        let documents = fixtureHome.appendingPathComponent("Documents")
        let deep = documents.appendingPathComponent("GitHub")
            .appendingPathComponent("deep")
        try mkdir(deep)

        persist([documents.path, deep.path])

        let resolution = makeStore().effectiveRoots(home: fixtureHome)
        XCTAssertEqual(resolution.keptRoots.map(\.path),
                       [documents.path, deep.path],
                       "nested real roots remain INDEPENDENT walks (D7)")
        XCTAssertEqual(resolution.issues, [])
    }

    func testEmptyPersistedArrayIsValidAndYieldsNoRoots() {
        persist([String]())
        let resolution = makeStore().effectiveRoots(home: fixtureHome)
        XCTAssertEqual(resolution.keptRoots, [],
                       "an explicitly empty list is valid config, not a "
                       + "parse failure — the user cleared every root")
        XCTAssertEqual(resolution.issues, [])
    }

    // MARK: - R8: mutations round-trip (injected suite only)

    func testAddRemoveResetRoundTrip() throws {
        let store = makeStore()
        let extra = base.appendingPathComponent("extra-root")
        try mkdir(extra)

        // Add on a fresh (seed) state: seeds + 1.
        store.add(extra.path)
        var resolution = store.effectiveRoots(home: fixtureHome)
        XCTAssertEqual(
            resolution.keptRoots.map(\.path),
            (expectedSeedRoots() + [extra]).map(\.path)
        )
        // Idempotent add — exact string already declared.
        store.add(extra.path)
        XCTAssertEqual(
            (storedValue as? [String])?.filter { $0 == extra.path }.count, 1
        )

        // Remove it again — seeds remain.
        store.remove(extra.path)
        resolution = store.effectiveRoots(home: fixtureHome)
        XCTAssertEqual(
            resolution.keptRoots,
            expectedSeedRoots()
        )

        // Remove a SEED name → nine effective roots.
        store.remove("Documents")
        resolution = store.effectiveRoots(home: fixtureHome)
        XCTAssertEqual(resolution.keptRoots.count, 9)
        XCTAssertFalse(resolution.keptRoots.contains(
            fixtureHome.appendingPathComponent("Documents")
        ))

        // Reset: the key is REMOVED (seeds are a fallback, never persisted).
        store.resetToDefaults()
        XCTAssertNil(storedValue)
        resolution = store.effectiveRoots(home: fixtureHome)
        XCTAssertEqual(
            resolution.keptRoots,
            expectedSeedRoots()
        )
    }

    // MARK: - R8/R16: non-persisted per-invocation replacement path

    func testReplacementPathAppliesPolicyAndPersistsNothing() throws {
        let good = base.appendingPathComponent("cli-root")
        try mkdir(good)

        let resolution = makeStore().effectiveRoots(
            replacing: [fixtureHome, good], home: fixtureHome
        )

        XCTAssertEqual(resolution.keptRoots.map(\.path), [good.path],
                       "the CLI replacement path runs the SAME policy")
        XCTAssertEqual(resolution.issues.map(\.kind), [.policyRefusedRoot])
        XCTAssertNil(storedValue,
                     "a per-invocation replacement is NEVER persisted")
    }

    // MARK: - Injected providers

    /// Marks injected canonical paths as mount roots — the statfs signal,
    /// hermetically (the DirectorySizer/OrphanedCaches test idiom).
    private final class MountPointInjectingProvider:
        FileSystemIdentityProvider
    {
        var mountPointPaths: Set<String> = []
        override func isMountPoint(_ url: URL) -> Bool {
            if mountPointPaths.contains(url.path) { return true }
            return super.isMountPoint(url)
        }
    }
}
