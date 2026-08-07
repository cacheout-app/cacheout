import XCTest
@testable import Cacheout

/// fn-2.1 coverage: the `SpaceScanner` protocol surfaces, the
/// `ReclaimableItem` model invariants (stable ids, byte components, frozen
/// wire strings), the per-root `RootScanRecord` truth table captured by
/// `CacheScanner`, the `CategoryScanner` adapter's byte-for-byte behavior
/// preservation, and the `SpaceScannerRuntime` (folded registration
/// validation, shared outcome validation, the progressive validated event
/// stream, subset + category-filter scoping, and the trusted-container-root
/// union).
///
/// All filesystem fixtures live under temp dirs via `.absolutePath`
/// categories (CacheCleanerTests style); nothing touches the real `$HOME`.
final class CategoryScannerTests: XCTestCase {

    // MARK: - Fixture helpers

    private func makeTempDir(_ label: String = #function) throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("CategoryScannerTests-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func writeFile(_ url: URL, bytes: Int = 4096) throws {
        try Data(repeating: 0xAB, count: bytes).write(to: url)
    }

    private func makeCategory(
        at urls: [URL], slug: String = "test_cache", name: String? = nil,
        riskLevel: RiskLevel = .safe, defaultSelected: Bool = true,
        cleanCommands: [[String]]? = nil
    ) -> CacheCategory {
        CacheCategory(
            name: name ?? slug,
            slug: slug,
            description: "fixture category \(slug)",
            icon: "trash",
            discovery: urls.map { .absolutePath($0.path) },
            riskLevel: riskLevel,
            rebuildNote: "rebuilds",
            defaultSelected: defaultSelected,
            cleanCommands: cleanCommands
        )
    }

    /// A category whose probe leaves one observable mark per resolver
    /// evaluation — the fixture seam proving when resolvers/probes run
    /// (and, critically, when they do NOT).
    private func makeProbeCountingCategory(
        slug: String, dir: URL, home: URL
    ) -> CacheCategory {
        CacheCategory(
            name: slug,
            slug: slug,
            description: "probe-counting fixture \(slug)",
            icon: "trash",
            discovery: [.probed(
                command: "printf x >> \"$HOME/probe-\(slug)-count\"; echo \(dir.path)",
                requiresTool: nil,
                fallbacks: [dir.path]
            )],
            riskLevel: .safe,
            rebuildNote: "",
            defaultSelected: true
        )
    }

    private func probeCount(slug: String, home: URL) -> Int {
        let url = home.appendingPathComponent("probe-\(slug)-count")
        guard let data = try? Data(contentsOf: url) else { return 0 }
        return data.count
    }

    private func makeCategoryScanner(
        categories: [CacheCategory], home: URL
    ) -> CategoryScanner {
        CategoryScanner(
            categories: categories,
            scanner: CacheScanner(home: home)
        )
    }

    private func scanItems(
        categories: [CacheCategory], home: URL,
        trigger: ScanTrigger = .userInitiated,
        categoryFilter: Set<String>? = nil
    ) async -> ScanOutcome {
        await makeCategoryScanner(categories: categories, home: home).scan(
            context: ScanContext(trigger: trigger, categoryFilter: categoryFilter)
        )
    }

    private func makeRuntime(
        scanners: [any SpaceScanner],
        categorySlugs: [String] = [],
        home: URL
    ) throws -> SpaceScannerRuntime {
        try SpaceScannerRuntime(
            scanners: scanners,
            categorySlugs: categorySlugs,
            home: home,
            provider: FileSystemIdentityProvider()
        )
    }

    /// A structurally valid per-item fixture item (`.removeItem` +
    /// the frozen `.containerItem` descriptor).
    private func makeContainerItem(
        id: String, scannerID: String,
        state: ScanState = .measured
    ) -> ReclaimableItem {
        let container = URL(fileURLWithPath: "/tmp/fixture-container")
        return ReclaimableItem(
            id: id, scannerID: scannerID, displayName: "item \(id)",
            exactBytes: 1024, estimatedUpToBytes: 0, logicalBytes: nil,
            itemCount: 1,
            url: container.appendingPathComponent(id),
            declaredDisplayPath: "/tmp/fixture-container/\(id)",
            rootRecords: [RootScanRecord(
                requestedURL: container.appendingPathComponent(id),
                resolvedURL: container.appendingPathComponent(id),
                status: .measured
            )],
            state: state, scanError: nil,
            risk: .review, evidence: "fixture", rebuildNote: nil,
            action: .removeItem,
            admission: .containerItem(
                originContainer: container,
                requestedTargetURL: container.appendingPathComponent(id)
            ),
            defaultSelected: false, automaticCleanEligible: false,
            isStale: nil
        )
    }

    /// A structurally valid aggregate fixture item (`.removeContents` or
    /// `.commands` + category provenance + root records).
    private func makeAggregateItem(
        id: String, scannerID: String,
        action: ReclaimAction = .removeContents,
        admission: AdmissionDescriptor? = nil,
        state: ScanState = .measured,
        rootRecords: [RootScanRecord]? = nil
    ) -> ReclaimableItem {
        let root = URL(fileURLWithPath: "/tmp/fixture-root")
        let defaultRecords = [RootScanRecord(
            requestedURL: root, resolvedURL: root, status: .measured
        )]
        return ReclaimableItem(
            id: id, scannerID: scannerID, displayName: "aggregate \(id)",
            exactBytes: 2048, estimatedUpToBytes: 0, logicalBytes: nil,
            itemCount: 2,
            url: root, declaredDisplayPath: root.path,
            rootRecords: rootRecords ?? defaultRecords,
            state: state, scanError: nil,
            risk: .safe, evidence: "fixture", rebuildNote: nil,
            action: action,
            admission: admission ?? .category(makeCategory(at: [root], slug: id)),
            defaultSelected: true, automaticCleanEligible: true,
            isStale: nil
        )
    }

    private func scannerID(of event: ValidatedScannerEvent) -> String {
        switch event {
        case .outcome(let id, _): return id
        case .malformed(let id, _): return id
        }
    }

    private func outcome(of event: ValidatedScannerEvent) -> ScanOutcome? {
        if case .outcome(_, let outcome) = event { return outcome }
        return nil
    }

    private func malformedIssue(of event: ValidatedScannerEvent) -> ScanIssue? {
        if case .malformed(_, let issue) = event { return issue }
        return nil
    }

    private func collect(
        _ stream: AsyncStream<ValidatedScannerEvent>
    ) async -> [ValidatedScannerEvent] {
        var events: [ValidatedScannerEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    // MARK: - Fixture scanners

    private actor ScanRecorder {
        private(set) var calls = 0
        func record() { calls += 1 }
        func count() -> Int { calls }
    }

    private actor AsyncGate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func open() {
            opened = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }
        func wait() async {
            guard !opened else { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    /// Registers with zero production edits (R4); records its scan calls;
    /// emits a fixed outcome. Deliberately IGNORES `categoryFilter` — the
    /// filter is CategoryScanner's alone.
    private struct FixtureScanner: SpaceScanner {
        let id: String
        var displayName: String { "Fixture \(id)" }
        let trustedContainerRoots: [URL]
        let recorder: ScanRecorder?
        let items: [ReclaimableItem]

        init(
            id: String, trustedContainerRoots: [URL] = [],
            recorder: ScanRecorder? = nil, items: [ReclaimableItem] = []
        ) {
            self.id = id
            self.trustedContainerRoots = trustedContainerRoots
            self.recorder = recorder
            self.items = items
        }

        func scan(context: ScanContext) async -> ScanOutcome {
            await recorder?.record()
            return ScanOutcome(items: items, errors: [])
        }
    }

    /// Blocks in `scan` until its gate opens — the staggered-completion
    /// fixture for the progressive-stream assertion.
    private struct GatedScanner: SpaceScanner {
        let id: String
        var displayName: String { "Gated \(id)" }
        var trustedContainerRoots: [URL] { [] }
        let gate: AsyncGate
        let finished: ScanRecorder

        func scan(context: ScanContext) async -> ScanOutcome {
            await gate.wait()
            await finished.record()
            return ScanOutcome(items: [], errors: [])
        }
    }

    // MARK: - Stable id helper (R7)

    func testStableItemIDMatchesPinnedVector() {
        // Pinned externally:
        //   printf 'node_modules\0/Users/dev/project/node_modules' | shasum -a 256
        let id = ReclaimableItem.stableID(
            scannerID: "node_modules",
            canonicalPath: "/Users/dev/project/node_modules"
        )
        XCTAssertEqual(
            id,
            "0d3a9ab9a662fb335a6803cccf0e8a73dd5f1f2a36965334d7f3f5742caeec0e"
        )
        XCTAssertEqual(id.count, 64, "full digest — no truncation code path")
        XCTAssertFalse(id.contains(":"))
        XCTAssertNil(id.rangeOfCharacter(from: .whitespacesAndNewlines))
        XCTAssertEqual(id, id.lowercased())
    }

    func testStableItemIDNulSeparatorDisambiguates() {
        // Without the NUL separator both pairs would hash "abc".
        // Pinned externally: printf 'a\0bc' / printf 'ab\0c' | shasum -a 256
        let first = ReclaimableItem.stableID(scannerID: "a", canonicalPath: "bc")
        let second = ReclaimableItem.stableID(scannerID: "ab", canonicalPath: "c")
        XCTAssertEqual(
            first,
            "40bb547d936bbd31318ee37ac8799e7ecbb22eda2651f65e3214bffb8ce97bb4"
        )
        XCTAssertEqual(
            second,
            "6c032e631d39a14d85aff7e319546af701e26c97b57ca95fbfe9c6ba855f67bf"
        )
        XCTAssertNotEqual(first, second)
    }

    // MARK: - Byte model (R1)

    func testAllocatedBytesIsTheComputedComponentSum() {
        let item = makeAggregateItem(id: "bytes", scannerID: "fixture")
        XCTAssertEqual(item.allocatedBytes, item.exactBytes + item.estimatedUpToBytes)

        let split = ReclaimableItem(
            id: "split", scannerID: "fixture", displayName: "split",
            exactBytes: 100, estimatedUpToBytes: 50, logicalBytes: nil,
            itemCount: 1, url: nil, declaredDisplayPath: "/x",
            rootRecords: [RootScanRecord(
                requestedURL: URL(fileURLWithPath: "/x"),
                resolvedURL: URL(fileURLWithPath: "/x"),
                status: .measured
            )],
            state: .measured, scanError: nil, risk: .safe, evidence: "",
            rebuildNote: nil, action: .removeContents,
            admission: .category(makeCategory(at: [], slug: "split")),
            defaultSelected: true, automaticCleanEligible: true, isStale: nil
        )
        XCTAssertEqual(split.allocatedBytes, 150)
    }

    // MARK: - Aggregate identity (R1, R7)

    func testAggregateIDIsTheCategorySlugAndStableAcrossRescans() async throws {
        let home = try makeTempDir("home")
        let root = try makeTempDir("root")
        try writeFile(root.appendingPathComponent("f.bin"))
        let category = makeCategory(at: [root], slug: "fixture_cache")

        let first = await scanItems(categories: [category], home: home)
        let second = await scanItems(categories: [category], home: home)

        XCTAssertEqual(first.items.count, 1)
        XCTAssertEqual(first.items[0].id, "fixture_cache")
        XCTAssertEqual(
            first.items.map(\.id), second.items.map(\.id),
            "ids must be identical across two scans of the same fixture"
        )
        XCTAssertEqual(
            first.items[0].key,
            ItemKey(scannerID: "categories", itemID: "fixture_cache")
        )
    }

    func testCategoryScannerNeverReevaluatesResolvedPaths() async throws {
        let home = try makeTempDir("home")
        let dir = try makeTempDir("probed-dir")
        try writeFile(dir.appendingPathComponent("f.bin"))
        let category = makeProbeCountingCategory(slug: "a", dir: dir, home: home)

        let outcome = await scanItems(categories: [category], home: home)

        XCTAssertEqual(outcome.items.count, 1)
        XCTAssertEqual(
            probeCount(slug: "a", home: home), 1,
            "resolvedPaths must be evaluated exactly ONCE (by CacheScanner at "
                + "scan time) — a second evaluation could resolve differently "
                + "and break the root-capture invariant"
        )
        // The records the item carries are the scan-time capture, not a
        // re-resolution.
        XCTAssertEqual(outcome.items[0].rootRecords.count, 1)
        XCTAssertEqual(outcome.items[0].rootRecords[0].status, .measured)
        XCTAssertEqual(outcome.items[0].rootRecords[0].requestedURL.path, dir.path)
    }

    // MARK: - RootScanRecord truth table (R1)

    func testRootScanRecordTruthTableCoversAllThreeStatuses() async throws {
        let home = try makeTempDir("home")
        // Refused root: a protected first-level $HOME child (deny list).
        let documents = home.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        // Denied-unmeasured root: admitted, but the walk is denied before
        // any measurement.
        let denied = try makeTempDir("denied")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: denied.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: denied.path)
        }
        // Measured root, reached via a symlink so the requested (unresolved)
        // and resolved (canonical) spellings deterministically differ.
        let measuredTarget = try makeTempDir("measured-target")
        try writeFile(measuredTarget.appendingPathComponent("f.bin"))
        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent("CategoryScannerTests-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: measuredTarget)
        addTeardownBlock { try? FileManager.default.removeItem(at: link) }
        // Clean-empty root: walked cleanly, nothing there — still deletable.
        let empty = try makeTempDir("empty")

        let category = CacheCategory(
            name: "truth-table", slug: "truth_table", description: "fixture",
            icon: "trash",
            discovery: [
                .staticPath("Documents"),
                .absolutePath(denied.path),
                .absolutePath(link.path),
                .absolutePath(empty.path),
            ],
            riskLevel: .safe, rebuildNote: "", defaultSelected: true
        )

        let result = await CacheScanner(home: home).scanCategory(category)

        XCTAssertEqual(result.rootRecords.count, 4)
        let provider = FileSystemIdentityProvider()

        // Refused at admission — never walked, never deletable; the record
        // still carries the honest canonical spelling.
        XCTAssertEqual(result.rootRecords[0].status, .refusedAdmission)
        XCTAssertEqual(result.rootRecords[0].requestedURL.path, documents.path)
        XCTAssertEqual(
            result.rootRecords[0].resolvedURL?.path,
            provider.canonicalize(documents).path
        )

        // Admitted but denied before ANY measurement — not deletable.
        XCTAssertEqual(result.rootRecords[1].status, .deniedUnmeasured)
        XCTAssertEqual(result.rootRecords[1].requestedURL.path, denied.path)

        // Measured: requested keeps the UNRESOLVED symlink spelling (what
        // deletion uses), resolved is the canonical target (what containment
        // compares against).
        XCTAssertEqual(result.rootRecords[2].status, .measured)
        XCTAssertEqual(result.rootRecords[2].requestedURL.path, link.path)
        XCTAssertEqual(
            result.rootRecords[2].resolvedURL?.path,
            provider.canonicalize(measuredTarget).path
        )
        XCTAssertNotEqual(
            result.rootRecords[2].requestedURL.path,
            result.rootRecords[2].resolvedURL?.path
        )

        // A CLEAN-EMPTY walked root is `.measured` (deletable), NOT denied.
        XCTAssertEqual(result.rootRecords[3].status, .measured)
        XCTAssertEqual(result.rootRecords[3].requestedURL.path, empty.path)
    }

    func testMissingCategoryHasEmptyCaptureAndDeclaredDisplayPath() async throws {
        let home = try makeTempDir("home")
        let nowhere = FileManager.default.temporaryDirectory
            .appendingPathComponent("CategoryScannerTests-nowhere-\(UUID().uuidString)")
        let category = makeCategory(at: [nowhere], slug: "missing_cache")

        let outcome = await scanItems(categories: [category], home: home)

        XCTAssertEqual(outcome.items.count, 1)
        let item = outcome.items[0]
        XCTAssertEqual(item.state, .missing)
        XCTAssertNil(item.url, "never a fake resolution for a missing category")
        XCTAssertTrue(item.rootRecords.isEmpty, "`.missing` → empty capture")
        XCTAssertEqual(
            item.declaredDisplayPath, nowhere.path,
            "the declared spelling presents the missing category honestly"
        )
    }

    // MARK: - Adapter parity (R1)

    func testCategoryScannerMatchesCacheScannerAndIgnoresTrigger() async throws {
        let home = try makeTempDir("home")
        let bigRoot = try makeTempDir("big")
        try writeFile(bigRoot.appendingPathComponent("big.bin"), bytes: 32768)
        let smallRoot = try makeTempDir("small")
        try writeFile(smallRoot.appendingPathComponent("small.bin"), bytes: 4096)
        let emptyRoot = try makeTempDir("empty")
        let categories = [
            makeCategory(at: [bigRoot], slug: "big_cache"),
            makeCategory(at: [smallRoot], slug: "small_cache"),
            makeCategory(at: [emptyRoot], slug: "empty_cache"),
        ]

        let direct = await CacheScanner(home: home).scanAll(categories)
        let user = await scanItems(
            categories: categories, home: home, trigger: .userInitiated
        )
        let automatic = await scanItems(
            categories: categories, home: home, trigger: .automatic
        )

        XCTAssertEqual(user.items.count, direct.count)
        for (item, result) in zip(user.items, direct) {
            XCTAssertEqual(item.id, result.category.slug)
            XCTAssertEqual(item.exactBytes, result.exactBytes)
            XCTAssertEqual(item.estimatedUpToBytes, result.estimatedUpToBytes)
            XCTAssertEqual(item.itemCount, result.itemCount)
            XCTAssertEqual(item.state, result.state)
            XCTAssertEqual(item.scanError, result.scanError)
            XCTAssertEqual(
                item.rootRecords, result.rootRecords,
                "per-root records ride the item VERBATIM"
            )
        }
        XCTAssertEqual(
            user.items, automatic.items,
            "CategoryScanner must ignore the trigger — identical outcomes"
        )
        XCTAssertTrue(user.errors.isEmpty)
        XCTAssertTrue(automatic.errors.isEmpty)
    }

    func testDeniedRootIsAnItemStateNeverAnOutcomeError() async throws {
        let home = try makeTempDir("home")
        let denied = try makeTempDir("denied")
        try writeFile(denied.appendingPathComponent("f.bin"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: denied.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: denied.path)
        }
        let category = makeCategory(at: [denied], slug: "denied_cache")

        let outcome = await scanItems(categories: [category], home: home)

        XCTAssertEqual(outcome.items.count, 1)
        let item = outcome.items[0]
        XCTAssertEqual(item.state, .denied, "never flattened to .empty (D6)")
        XCTAssertEqual(item.scanError?.kind, .permissionDenied)
        XCTAssertTrue(
            outcome.errors.isEmpty,
            "aggregate impediments are item states, not outcome issues"
        )
        // Round-14 advisory: a fully-denied-but-resolved root still yields
        // honest display data.
        XCTAssertNotNil(item.url)
        XCTAssertEqual(item.rootRecords.count, 1)
        XCTAssertEqual(item.rootRecords[0].status, .deniedUnmeasured)
    }

    // MARK: - Policy + presentation fields (R1)

    func testPolicyFieldsMirrorTheCategory() async throws {
        let home = try makeTempDir("home")
        let rootA = try makeTempDir("a")
        try writeFile(rootA.appendingPathComponent("a.bin"), bytes: 8192)
        let rootB = try makeTempDir("b")
        try writeFile(rootB.appendingPathComponent("b.bin"), bytes: 4096)
        let categories = [
            makeCategory(at: [rootA], slug: "selected_cache", defaultSelected: true),
            makeCategory(at: [rootB], slug: "unselected_cache", defaultSelected: false),
        ]

        let outcome = await scanItems(categories: categories, home: home)

        let bySlug = Dictionary(uniqueKeysWithValues: outcome.items.map { ($0.id, $0) })
        XCTAssertEqual(bySlug["selected_cache"]?.defaultSelected, true)
        XCTAssertEqual(bySlug["unselected_cache"]?.defaultSelected, false)
        for item in outcome.items {
            XCTAssertTrue(item.automaticCleanEligible, "aggregates are eligible")
            XCTAssertNil(item.isStale, "staleness is not applicable to aggregates")
        }
    }

    func testOwnershipAndPresentationMappings() async throws {
        let home = try makeTempDir("home")
        let root = try makeTempDir("root")
        try writeFile(root.appendingPathComponent("f.bin"))
        let category = makeCategory(
            at: [root], slug: "owned_cache", name: "Owned Cache",
            riskLevel: .review
        )

        let outcome = await scanItems(categories: [category], home: home)

        let item = outcome.items[0]
        XCTAssertEqual(item.scannerID, "categories", "the frozen aggregate id")
        XCTAssertEqual(item.scannerID, CategoryScanner.registeredID)
        XCTAssertEqual(item.displayName, "Owned Cache")
        XCTAssertEqual(item.key, ItemKey(scannerID: "categories", itemID: "owned_cache"))
        XCTAssertEqual(item.risk, .review)
        XCTAssertEqual(item.evidence, category.description)
        XCTAssertEqual(item.rebuildNote, category.rebuildNote)
        if case .category(let carried) = item.admission {
            XCTAssertEqual(carried, category)
        } else {
            XCTFail("aggregate items carry category admission provenance")
        }
    }

    func testCleanCommandsCategoryMapsToCommandsActionVerbatim() async throws {
        let home = try makeTempDir("home")
        let root = try makeTempDir("root")
        try writeFile(root.appendingPathComponent("f.bin"))
        let argv = [["xcrun", "simctl", "shutdown", "all"], ["true"]]
        let category = makeCategory(
            at: [root], slug: "command_cache", cleanCommands: argv
        )

        let outcome = await scanItems(categories: [category], home: home)

        XCTAssertEqual(
            outcome.items[0].action, .commands(argv),
            "argv arrays pass through unmodified"
        )
    }

    // MARK: - ReclaimAction dispatch + frozen wire strings (R4, R7, R8)

    func testReclaimActionDispatchIsExhaustive() {
        // COMPILE-LEVEL assertion (R4 groundwork): this switch has no
        // `default:` — as does every switch over ReclaimAction in this
        // task's production code — so fn-5's composite case will be a
        // compile-time-visible change everywhere, never a silent fallthrough.
        let actions: [ReclaimAction] = [
            .removeContents, .removeItem, .commands([["true"]]),
        ]
        for action in actions {
            switch action {
            case .removeContents:
                XCTAssertEqual(action.wireString, "remove_contents")
            case .removeItem:
                XCTAssertEqual(action.wireString, "remove_item")
            case .commands:
                XCTAssertEqual(action.wireString, "commands")
            }
        }
    }

    func testFrozenWireStringsArePinned() {
        XCTAssertEqual(ReclaimAction.removeContents.wireString, "remove_contents")
        XCTAssertEqual(ReclaimAction.removeItem.wireString, "remove_item")
        // `.commands` serializes ONLY its kind — the argv arrays never
        // appear on any wire surface (`wireString` is the single
        // serialization the action exposes).
        XCTAssertEqual(
            ReclaimAction.commands([["rm", "-rf", "secret"]]).wireString,
            "commands"
        )

        XCTAssertEqual(ScanIssue.Kind.containerRefused.wireString, "container_refused")
        XCTAssertEqual(ScanIssue.Kind.symlinkRoot.wireString, "symlink_root")
        XCTAssertEqual(ScanIssue.Kind.tccDenied.wireString, "tcc_denied")
        XCTAssertEqual(ScanIssue.Kind.permissionDenied.wireString, "permission_denied")
        XCTAssertEqual(ScanIssue.Kind.unreadable.wireString, "unreadable")
        XCTAssertEqual(ScanIssue.Kind.malformedOutcome.wireString, "malformed_outcome")
    }

    // MARK: - Registration-time validation (R4, R7)

    func testRegistrationRejectsDuplicateScannerIDs() throws {
        let home = try makeTempDir("home")
        XCTAssertThrowsError(try makeRuntime(
            scanners: [FixtureScanner(id: "twin"), FixtureScanner(id: "twin")],
            home: home
        )) { error in
            XCTAssertEqual(
                error as? SpaceScannerRegistrationError,
                .duplicateScannerID("twin")
            )
        }
    }

    func testRegistrationRejectsMalformedSlugs() throws {
        let home = try makeTempDir("home")
        for bad in ["Bad", "with-dash", "with:colon", "with space", ""] {
            XCTAssertThrowsError(try makeRuntime(
                scanners: [FixtureScanner(id: bad)], home: home
            ), "slug '\(bad)' must be rejected") { error in
                XCTAssertEqual(
                    error as? SpaceScannerRegistrationError,
                    .malformedScannerID(bad)
                )
            }
        }
    }

    func testRegistrationRejectsCategorySlugCollisions() throws {
        let home = try makeTempDir("home")
        // A category slug colliding with a registered scanner slug…
        XCTAssertThrowsError(try makeRuntime(
            scanners: [FixtureScanner(id: "node_modules")],
            categorySlugs: ["node_modules"],
            home: home
        )) { error in
            XCTAssertEqual(
                error as? SpaceScannerRegistrationError,
                .namespaceCollision("node_modules")
            )
        }
        // …including a category slug spelled `categories` against the frozen
        // aggregate scanner id.
        let scanner = makeCategoryScanner(categories: [], home: home)
        XCTAssertThrowsError(try makeRuntime(
            scanners: [scanner],
            categorySlugs: ["categories"],
            home: home
        )) { error in
            XCTAssertEqual(
                error as? SpaceScannerRegistrationError,
                .namespaceCollision("categories")
            )
        }
    }

    func testProductionFactoryRegistersCategoryScannerCollisionFree() throws {
        let home = try makeTempDir("home")
        let runtime = SpaceScannerRuntime.production(home: home)
        XCTAssertEqual(runtime.scanners.map(\.id), ["categories"])
        XCTAssertTrue(
            runtime.trustedContainerRoots.isEmpty,
            "CategoryScanner contributes no container roots"
        )
        // The factory reaching here at all asserts the production
        // category-slug/scanner-slug namespace is collision-free (a
        // collision would have trapped in the folded validation).
    }

    func testFixtureScannerRegistersAlongsideProductionWithZeroEdits() async throws {
        let home = try makeTempDir("home")
        let item = makeContainerItem(id: "abc123", scannerID: "fixture_x")
        let fixture = FixtureScanner(id: "fixture_x", items: [item])
        let runtime = try makeRuntime(
            scanners: [makeCategoryScanner(categories: [], home: home), fixture],
            categorySlugs: CacheCategory.allCategories.map(\.slug),
            home: home
        )

        let events = await collect(runtime.scanValidated(
            scannerIDs: ["fixture_x"],
            context: ScanContext(trigger: .automatic)
        ))

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(outcome(of: events[0])?.items, [item])
    }

    // MARK: - Shared outcome validation (R1, R8)

    func testValidatedOutcomeRejectsForeignScannerID() {
        let foreign = makeContainerItem(id: "abc", scannerID: "other_scanner")
        let verdict = SpaceScannerRuntime.validatedOutcome(
            ScanOutcome(items: [foreign], errors: []), from: "fixture"
        )
        let issue = malformedIssue(of: verdict)
        XCTAssertEqual(issue?.kind, .malformedOutcome)
        XCTAssertNil(issue?.url, "no filesystem location — never a fake path")
    }

    func testValidatedOutcomeRejectsDuplicateItemIDs() {
        let a = makeContainerItem(id: "dup", scannerID: "fixture")
        let b = makeContainerItem(id: "dup", scannerID: "fixture")
        let verdict = SpaceScannerRuntime.validatedOutcome(
            ScanOutcome(items: [a, b], errors: []), from: "fixture"
        )
        let issue = malformedIssue(of: verdict)
        XCTAssertEqual(issue?.kind, .malformedOutcome)
        XCTAssertNil(issue?.url)
    }

    func testStructuralInvariantsAreStateAware() {
        // A NON-missing `.commands` item with ZERO root records: malformed —
        // zero roots would vacuously pass `.commands` re-admission and then
        // execute argv.
        let commandsNoRoots = makeAggregateItem(
            id: "cmd", scannerID: "fixture", action: .commands([["true"]]),
            state: .measured, rootRecords: []
        )
        XCTAssertNotNil(malformedIssue(of: SpaceScannerRuntime.validatedOutcome(
            ScanOutcome(items: [commandsNoRoots], errors: []), from: "fixture"
        )))

        // A NON-missing `.removeContents` item with ZERO root records:
        // malformed.
        let contentsNoRoots = makeAggregateItem(
            id: "contents", scannerID: "fixture", action: .removeContents,
            state: .measured, rootRecords: []
        )
        XCTAssertNotNil(malformedIssue(of: SpaceScannerRuntime.validatedOutcome(
            ScanOutcome(items: [contentsNoRoots], errors: []), from: "fixture"
        )))

        // A `.removeItem` item WITHOUT the frozen `.containerItem`
        // descriptor: malformed.
        var noDescriptor = makeContainerItem(id: "no_desc", scannerID: "fixture")
        noDescriptor = ReclaimableItem(
            id: noDescriptor.id, scannerID: noDescriptor.scannerID,
            displayName: noDescriptor.displayName,
            exactBytes: noDescriptor.exactBytes,
            estimatedUpToBytes: noDescriptor.estimatedUpToBytes,
            logicalBytes: nil, itemCount: noDescriptor.itemCount,
            url: noDescriptor.url,
            declaredDisplayPath: noDescriptor.declaredDisplayPath,
            rootRecords: noDescriptor.rootRecords,
            state: noDescriptor.state, scanError: nil,
            risk: noDescriptor.risk, evidence: noDescriptor.evidence,
            rebuildNote: nil, action: .removeItem,
            admission: .category(makeCategory(at: [], slug: "wrong")),
            defaultSelected: false, automaticCleanEligible: false, isStale: nil
        )
        XCTAssertNotNil(malformedIssue(of: SpaceScannerRuntime.validatedOutcome(
            ScanOutcome(items: [noDescriptor], errors: []), from: "fixture"
        )))

        // `.removeContents`/`.commands` items WITHOUT category provenance:
        // malformed.
        let container = URL(fileURLWithPath: "/tmp/c")
        for action: ReclaimAction in [.removeContents, .commands([["true"]])] {
            let wrongProvenance = makeAggregateItem(
                id: "wrong_prov", scannerID: "fixture", action: action,
                admission: .containerItem(
                    originContainer: container,
                    requestedTargetURL: container.appendingPathComponent("x")
                )
            )
            XCTAssertNotNil(
                malformedIssue(of: SpaceScannerRuntime.validatedOutcome(
                    ScanOutcome(items: [wrongProvenance], errors: []),
                    from: "fixture"
                )),
                "\(action.wireString) without category provenance is malformed"
            )
        }

        // A `.missing` item with EMPTY records PASSES — a scan containing a
        // missing category must not render the whole outcome malformed.
        let missing = makeAggregateItem(
            id: "missing_ok", scannerID: "fixture", action: .removeContents,
            state: .missing, rootRecords: []
        )
        let verdict = SpaceScannerRuntime.validatedOutcome(
            ScanOutcome(items: [missing], errors: []), from: "fixture"
        )
        XCTAssertEqual(outcome(of: verdict)?.items, [missing])
    }

    // MARK: - Validated event stream (R4, R8)

    func testStreamEventsArriveProgressively() async throws {
        let home = try makeTempDir("home")
        let gate = AsyncGate()
        let finished = ScanRecorder()
        let fast = FixtureScanner(id: "fast")
        let gated = GatedScanner(id: "gated", gate: gate, finished: finished)
        let runtime = try makeRuntime(scanners: [fast, gated], home: home)

        var events: [ValidatedScannerEvent] = []
        for await event in runtime.scanValidated(
            context: ScanContext(trigger: .automatic)
        ) {
            events.append(event)
            if events.count == 1 {
                // The fast scanner's VALIDATED event arrives while the gated
                // scanner is still running — the progressive contract.
                XCTAssertEqual(scannerID(of: event), "fast")
                let gatedDone = await finished.count()
                XCTAssertEqual(gatedDone, 0, "gated scanner must still be running")
                await gate.open()
            }
        }

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(scannerID(of: events[1]), "gated")
    }

    func testStreamSubsetScansOnlyTheNamedScanners() async throws {
        let home = try makeTempDir("home")
        let alphaCalls = ScanRecorder()
        let betaCalls = ScanRecorder()
        let alpha = FixtureScanner(id: "alpha", recorder: alphaCalls)
        let beta = FixtureScanner(id: "beta", recorder: betaCalls)
        let runtime = try makeRuntime(scanners: [alpha, beta], home: home)

        let subsetEvents = await collect(runtime.scanValidated(
            scannerIDs: ["alpha"],
            context: ScanContext(trigger: .automatic)
        ))
        let alphaAfterSubset = await alphaCalls.count()
        let betaAfterSubset = await betaCalls.count()
        XCTAssertEqual(subsetEvents.map { scannerID(of: $0) }, ["alpha"])
        XCTAssertEqual(alphaAfterSubset, 1)
        XCTAssertEqual(
            betaAfterSubset, 0,
            "a scanner outside the subset records ZERO scan calls"
        )

        // nil = all registered.
        let allEvents = await collect(runtime.scanValidated(
            context: ScanContext(trigger: .automatic)
        ))
        let alphaAfterAll = await alphaCalls.count()
        let betaAfterAll = await betaCalls.count()
        XCTAssertEqual(Set(allEvents.map { scannerID(of: $0) }), ["alpha", "beta"])
        XCTAssertEqual(alphaAfterAll, 2)
        XCTAssertEqual(betaAfterAll, 1)
    }

    func testStreamReplacesMalformedOutcomeWithIssueEvent() async throws {
        let home = try makeTempDir("home")
        let foreign = makeContainerItem(id: "abc", scannerID: "someone_else")
        let bad = FixtureScanner(id: "bad", items: [foreign])
        let good = FixtureScanner(
            id: "good", items: [makeContainerItem(id: "ok", scannerID: "good")]
        )
        let runtime = try makeRuntime(scanners: [bad, good], home: home)

        let events = await collect(runtime.scanValidated(
            scannerIDs: ["bad", "good"],
            context: ScanContext(trigger: .automatic)
        ))

        XCTAssertEqual(events.count, 2)
        let badEvents = events.filter { scannerID(of: $0) == "bad" }
        XCTAssertEqual(badEvents.count, 1)
        let issue = malformedIssue(of: badEvents[0])
        XCTAssertEqual(
            issue?.kind, .malformedOutcome,
            "a malformed outcome yields its synthesized issue and NO item event"
        )
        XCTAssertNil(issue?.url)
        // The valid scanner in the same subset still publishes.
        let goodEvents = events.filter { scannerID(of: $0) == "good" }
        XCTAssertEqual(outcome(of: goodEvents[0])?.items.count, 1)
    }

    // MARK: - Category filter (R1, R8)

    func testCategoryFilterNeverInvokesUnrequestedResolvers() async throws {
        let home = try makeTempDir("home")
        let dirA = try makeTempDir("dir-a")
        try writeFile(dirA.appendingPathComponent("a.bin"))
        let dirB = try makeTempDir("dir-b")
        try writeFile(dirB.appendingPathComponent("b.bin"))
        let categoryA = makeProbeCountingCategory(slug: "a", dir: dirA, home: home)
        let categoryB = makeProbeCountingCategory(slug: "b", dir: dirB, home: home)
        let fixtureItem = makeContainerItem(id: "fx", scannerID: "fixture_x")
        let fixture = FixtureScanner(id: "fixture_x", items: [fixtureItem])
        let runtime = try makeRuntime(
            scanners: [
                makeCategoryScanner(categories: [categoryA, categoryB], home: home),
                fixture,
            ],
            categorySlugs: ["a", "b"],
            home: home
        )

        let events = await collect(runtime.scanValidated(
            context: ScanContext(trigger: .automatic, categoryFilter: ["a"])
        ))

        let categoryEvents = events.first { scannerID(of: $0) == "categories" }
        XCTAssertEqual(outcome(of: categoryEvents!)?.items.map(\.id), ["a"])
        XCTAssertEqual(probeCount(slug: "a", home: home), 1)
        XCTAssertEqual(
            probeCount(slug: "b", home: home), 0,
            "the unrequested category's resolver/probe is NEVER invoked"
        )
        // A per-item scanner ignores the filter entirely.
        let fixtureEvents = events.first { scannerID(of: $0) == "fixture_x" }
        XCTAssertEqual(outcome(of: fixtureEvents!)?.items, [fixtureItem])

        // nil filter scans all.
        let allEvents = await collect(runtime.scanValidated(
            scannerIDs: ["categories"],
            context: ScanContext(trigger: .automatic)
        ))
        let allItems = outcome(of: allEvents[0])?.items
        XCTAssertEqual(Set(allItems?.map(\.id) ?? []), ["a", "b"])
        XCTAssertEqual(probeCount(slug: "b", home: home), 1)
    }

    // MARK: - Trusted container-root union (R4)

    func testRuntimeDerivesContainerRootUnionFromScanners() async throws {
        let home = try makeTempDir("home")
        let rootOne = try makeTempDir("union-one")
        let rootTwo = try makeTempDir("union-two")
        let one = FixtureScanner(id: "one", trustedContainerRoots: [rootOne])
        let two = FixtureScanner(id: "two", trustedContainerRoots: [rootTwo])
        let categoryScanner = makeCategoryScanner(categories: [], home: home)
        let runtime = try makeRuntime(
            scanners: [categoryScanner, one, two], home: home
        )

        XCTAssertEqual(
            runtime.trustedContainerRoots.map(\.path),
            [rootOne.path, rootTwo.path],
            "the union covers both disjoint declarations; CategoryScanner "
                + "contributes none"
        )
        // The cleaner configuration is DERIVED from registration — the one
        // reviewed composition point (fn-2.3 wires it into PathGuard).
        _ = runtime.makeCleaner()
    }

    // MARK: - ScanContext derivation

    func testScanContextDerivesProtectedRootInclusionFromTrigger() {
        XCTAssertTrue(
            ScanContext(trigger: .userInitiated).includeProtectedRoots
        )
        XCTAssertFalse(
            ScanContext(trigger: .automatic).includeProtectedRoots
        )
    }
}
