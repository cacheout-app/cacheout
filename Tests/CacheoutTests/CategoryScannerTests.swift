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
        categories: [CacheCategory] = [],
        home: URL
    ) throws -> SpaceScannerRuntime {
        try SpaceScannerRuntime(
            scanners: scanners,
            categories: categories,
            home: home,
            provider: FileSystemIdentityProvider()
        )
    }

    /// The container root every `makeContainerItem` admission claims.
    private let fixtureContainer = URL(fileURLWithPath: "/tmp/fixture-container")

    /// A runtime with the two per-item fixture producer ids REGISTERED,
    /// each declaring `fixtureContainer` — origin-binding validation
    /// (round 6) checks a container-item origin against the PRODUCING
    /// scanner's registration-declared roots, so direct `validatedOutcome`
    /// exercises need the producer registered exactly as the stream has it.
    private func makeValidationRuntime(
        categories: [CacheCategory] = [], home: URL
    ) throws -> SpaceScannerRuntime {
        try makeRuntime(
            scanners: [
                FixtureScanner(
                    id: "fixture", trustedContainerRoots: [fixtureContainer]
                ),
                FixtureScanner(
                    id: "fixture_x", trustedContainerRoots: [fixtureContainer]
                ),
            ],
            categories: categories,
            home: home
        )
    }

    /// A structurally valid per-item fixture item (`.removeItem` +
    /// the frozen `.containerItem` descriptor + the measured record
    /// binding the deletion target). Defaults are STATE-COHERENT (round
    /// 5): zero-component states carry zeros, denied-family states carry a
    /// classified error, and the record multiset matches the frozen truth
    /// table — every default overridable to construct the exact malformed
    /// shapes the validator must refuse. `displayURL` (double-optional:
    /// `.some(nil)` forces a nil `url`) constructs display/deletion
    /// divergences; `scanError` likewise (`.some(nil)` forces nil on a
    /// denied-family state).
    private func makeContainerItem(
        id: String, scannerID: String,
        state: ScanState = .measured,
        rootRecords: [RootScanRecord]? = nil,
        displayURL: URL?? = nil,
        exactBytes: Int64? = nil,
        estimatedUpToBytes: Int64 = 0,
        logicalBytes: Int64? = nil,
        itemCount: Int? = nil,
        scanError: ScanError?? = nil,
        admission: AdmissionDescriptor? = nil
    ) -> ReclaimableItem {
        let container = fixtureContainer
        let target = container.appendingPathComponent(id)
        let zeroComponents =
            state == .missing || state == .empty || state == .denied
        let defaultRecords: [RootScanRecord]
        switch state {
        case .missing:
            defaultRecords = []
        case .denied:
            defaultRecords = [RootScanRecord(
                requestedURL: target, resolvedURL: target,
                status: .deniedUnmeasured
            )]
        case .empty, .measured, .partiallyDenied:
            defaultRecords = [RootScanRecord(
                requestedURL: target, resolvedURL: target, status: .measured
            )]
        }
        let defaultError: ScanError? =
            (state == .denied || state == .partiallyDenied)
            ? ScanError(kind: .permissionDenied, message: "fixture denial")
            : nil
        let defaultURL: URL? = state == .missing ? nil : target
        return ReclaimableItem(
            id: id, scannerID: scannerID, displayName: "item \(id)",
            exactBytes: exactBytes ?? (zeroComponents ? 0 : 1024),
            estimatedUpToBytes: estimatedUpToBytes,
            logicalBytes: logicalBytes,
            itemCount: itemCount ?? (zeroComponents ? 0 : 1),
            url: displayURL ?? defaultURL,
            declaredDisplayPath: "/tmp/fixture-container/\(id)",
            rootRecords: rootRecords ?? defaultRecords,
            state: state, scanError: scanError ?? defaultError,
            risk: .review, evidence: "fixture", rebuildNote: nil,
            action: .removeItem,
            admission: admission ?? .containerItem(
                originContainer: container,
                requestedTargetURL: target
            ),
            defaultSelected: false, automaticCleanEligible: false,
            isStale: nil
        )
    }

    /// A structurally valid aggregate fixture item for `category`
    /// (`.removeContents` or `.commands` + category provenance + root
    /// records): id defaults to the category slug and `scannerID` to the
    /// frozen adapter id. Defaults are STATE-COHERENT (round 5) exactly as
    /// `makeContainerItem`'s, and POLICY-COHERENT (round 6): `risk` and
    /// `defaultSelected` default to the adapter mapping's derivations from
    /// the category itself — everything overridable to construct the
    /// malformed shapes the validator must refuse.
    private func makeAggregateItem(
        category: CacheCategory,
        scannerID: String = CategoryScanner.registeredID,
        id: String? = nil,
        action: ReclaimAction = .removeContents,
        admission: AdmissionDescriptor? = nil,
        state: ScanState = .measured,
        rootRecords: [RootScanRecord]? = nil,
        exactBytes: Int64? = nil,
        estimatedUpToBytes: Int64 = 0,
        logicalBytes: Int64? = nil,
        itemCount: Int? = nil,
        scanError: ScanError?? = nil,
        risk: RiskLevel? = nil,
        defaultSelected: Bool? = nil,
        automaticCleanEligible: Bool = true,
        isStale: Bool? = nil
    ) -> ReclaimableItem {
        let root = URL(fileURLWithPath: "/tmp/fixture-root")
        let zeroComponents =
            state == .missing || state == .empty || state == .denied
        let defaultRecords: [RootScanRecord]
        switch state {
        case .missing:
            defaultRecords = []
        case .denied:
            defaultRecords = [RootScanRecord(
                requestedURL: root, resolvedURL: root,
                status: .deniedUnmeasured
            )]
        case .empty, .measured, .partiallyDenied:
            defaultRecords = [RootScanRecord(
                requestedURL: root, resolvedURL: root, status: .measured
            )]
        }
        let defaultError: ScanError? =
            (state == .denied || state == .partiallyDenied)
            ? ScanError(kind: .permissionDenied, message: "fixture denial")
            : nil
        let defaultURL: URL? = state == .missing ? nil : root
        return ReclaimableItem(
            id: id ?? category.slug, scannerID: scannerID,
            displayName: "aggregate \(category.slug)",
            exactBytes: exactBytes ?? (zeroComponents ? 0 : 2048),
            estimatedUpToBytes: estimatedUpToBytes,
            logicalBytes: logicalBytes,
            itemCount: itemCount ?? (zeroComponents ? 0 : 2),
            url: defaultURL, declaredDisplayPath: root.path,
            rootRecords: rootRecords ?? defaultRecords,
            state: state, scanError: scanError ?? defaultError,
            risk: risk ?? category.riskLevel,
            evidence: "fixture", rebuildNote: nil,
            action: action,
            admission: admission ?? .category(category),
            defaultSelected: defaultSelected ?? category.defaultSelected,
            automaticCleanEligible: automaticCleanEligible,
            isStale: isStale
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
        let item = makeAggregateItem(
            category: makeCategory(at: [], slug: "bytes_cache")
        )
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
        XCTAssertEqual(ScanIssue.Kind.configInvalid.wireString, "config_invalid")
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

    func testRegistrationRejectsMalformedCategorySlugs() throws {
        let home = try makeTempDir("home")
        // Category slugs share the address grammar with scanner slugs —
        // colon, whitespace, uppercase, and empty spellings must all be
        // refused at registration, not discovered as broken CLI addresses.
        for bad in ["bad:slug", "with space", "Uppercase", ""] {
            XCTAssertThrowsError(try makeRuntime(
                scanners: [],
                categories: [makeCategory(at: [], slug: bad)],
                home: home
            ), "category slug '\(bad)' must be rejected") { error in
                XCTAssertEqual(
                    error as? SpaceScannerRegistrationError,
                    .malformedCategorySlug(bad)
                )
            }
        }
    }

    func testRegistrationRejectsCategorySlugCollisions() throws {
        let home = try makeTempDir("home")
        // A category slug colliding with a registered scanner slug…
        XCTAssertThrowsError(try makeRuntime(
            scanners: [FixtureScanner(id: "node_modules")],
            categories: [makeCategory(at: [], slug: "node_modules")],
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
            categories: [makeCategory(at: [], slug: "categories")],
            home: home
        )) { error in
            XCTAssertEqual(
                error as? SpaceScannerRegistrationError,
                .namespaceCollision("categories")
            )
        }
    }

    /// MIGRATED for the fn-4.5 atomic swap: `node_modules` → `build_artifacts`
    /// in the SAME registration slot, with the same assertions (composition
    /// order + the union being exactly the per-item scanners' declared sets).
    /// The dev roots are INJECTED so the union is deterministic — the
    /// standard-suite read the nil default would do is a machine-dependent
    /// input, not a property of the composition.
    func testProductionFactoryRegistersCategoryScannerCollisionFree() throws {
        let home = try makeTempDir("home")
        let suiteName = "CategoryScannerTests-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        let devRoots = DevRootsStore(defaults: suite).effectiveRoots(home: home)
        let runtime = SpaceScannerRuntime.production(
            home: home, devRoots: devRoots
        )
        XCTAssertEqual(
            runtime.scanners.map(\.id),
            [
                CategoryScanner.registeredID,
                BuildArtifactsScanner.registeredID,
                OrphanedCachesScanner.registeredID,
                EphemeralTempScanner.registeredID,
            ]
        )
        XCTAssertFalse(
            runtime.scanners.contains { $0.id == "node_modules" },
            "the atomic swap unregistered node_modules in the same change — "
                + "the RETIRED slug is a bare string here because fn-4.7 "
                + "deleted the scanner that used to declare it"
        )
        // fn-6.4 appends the ephemeral temp scanner, whose roots are the
        // machine's REAL confstr-resolved temp containers — resolved here
        // through the same declaration the factory uses so the expectation
        // stays a property of the composition, not of this machine.
        let tempRoots = EphemeralTempRoots.resolve().roots.map(\.url.path)
        XCTAssertEqual(
            runtime.trustedContainerRoots.map(\.path),
            devRoots.keptRoots.map(\.path)
                + [home.appendingPathComponent("Library/Caches").path]
                + tempRoots,
            "the union is the per-item scanners' declared sets in "
                + "registration order (the kept dev roots, then the "
                + "orphaned-caches sweep root, then the ephemeral temp "
                + "roots) — CategoryScanner contributes no container roots"
        )
        // The factory reaching here at all asserts the production
        // category-slug/scanner-slug namespace is collision-free (a
        // collision would have trapped in the folded validation).
    }

    func testFixtureScannerRegistersAlongsideProductionWithZeroEdits() async throws {
        let home = try makeTempDir("home")
        let item = makeContainerItem(id: "abc123", scannerID: "fixture_x")
        let fixture = FixtureScanner(
            id: "fixture_x", trustedContainerRoots: [fixtureContainer],
            items: [item]
        )
        let runtime = try makeRuntime(
            scanners: [makeCategoryScanner(categories: [], home: home), fixture],
            categories: CacheCategory.allCategories,
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

    func testValidatedOutcomeRejectsForeignScannerID() throws {
        let home = try makeTempDir("home")
        let runtime = try makeValidationRuntime(home: home)
        let foreign = makeContainerItem(id: "abc", scannerID: "other_scanner")
        let verdict = runtime.validatedOutcome(
            ScanOutcome(items: [foreign], errors: []), from: "fixture"
        )
        let issue = malformedIssue(of: verdict)
        XCTAssertEqual(issue?.kind, .malformedOutcome)
        XCTAssertNil(issue?.url, "no filesystem location — never a fake path")
    }

    func testValidatedOutcomeRejectsDuplicateItemIDs() throws {
        let home = try makeTempDir("home")
        let runtime = try makeValidationRuntime(home: home)
        let a = makeContainerItem(id: "dup", scannerID: "fixture")
        let b = makeContainerItem(id: "dup", scannerID: "fixture")
        let verdict = runtime.validatedOutcome(
            ScanOutcome(items: [a, b], errors: []), from: "fixture"
        )
        let issue = malformedIssue(of: verdict)
        XCTAssertEqual(issue?.kind, .malformedOutcome)
        XCTAssertNil(issue?.url)
    }

    func testValidatedOutcomeRejectsNonCLISafeItemIDs() throws {
        // The documented `ReclaimableItem.id` invariant (nonempty, no
        // whitespace, no colon, no NUL) is enforced at validation: an empty
        // id publishes a `<scanner>:` address `parseCleanTargets` rejects —
        // an item `scan` prints but `clean` can never target — and a NUL id
        // (round 6) could never even be SPELLED as a `clean` argument:
        // POSIX argv strings are NUL-terminated, so the documented
        // `<scanner>:<item-id>` address is unpassable however the user
        // quotes it.
        let home = try makeTempDir("home")
        let runtime = try makeValidationRuntime(home: home)
        for bad in [
            "", " ", "with space", "with:colon", "tab\tid", "line\nid",
            "nul\u{0000}id", "\u{0000}",
        ] {
            let item = makeContainerItem(id: bad, scannerID: "fixture")
            let issue = malformedIssue(of: runtime.validatedOutcome(
                ScanOutcome(items: [item], errors: []), from: "fixture"
            ))
            XCTAssertEqual(
                issue?.kind, .malformedOutcome,
                "item id '\(bad)' must render the outcome malformed"
            )
            XCTAssertNil(issue?.url, "no filesystem location — never a fake path")
        }

        // The production id forms pass: the full 64-hex `stableID` (per-item
        // scanners) — NOT the slug grammar, which the item-id invariant is
        // deliberately looser than.
        let hex = ReclaimableItem.stableID(
            scannerID: "fixture", canonicalPath: "/tmp/fixture-container/x"
        )
        XCTAssertTrue(SpaceScannerRuntime.isCLISafeItemID(hex))

        // The round-trip boundary is EXACT (round 6): only U+0000 is
        // provably unpassable (argv cannot carry the byte). Other C0
        // controls are ugly but representable on BOTH legs — the JSON
        // envelope escapes them and argv bytes carry them — so rejecting
        // them would over-reject ids the opaque contract allows.
        XCTAssertTrue(SpaceScannerRuntime.isCLISafeItemID("ctl\u{01}id"))
        let good = makeContainerItem(id: hex, scannerID: "fixture")
        XCTAssertEqual(
            outcome(of: runtime.validatedOutcome(
                ScanOutcome(items: [good], errors: []), from: "fixture"
            ))?.items,
            [good]
        )
    }

    func testDeletableRemoveItemMustBindItsMeasuredCapture() throws {
        // Thread the deletion-target binding: in the states the cleaner
        // actually deletes (`.measured`/`.partiallyDenied`), a
        // `.removeItem` item's `requestedTargetURL` must be one of the
        // scan's own `.measured` captures — otherwise the GUI/CLI would
        // confirm the records' path while `removeGuardedItem` deletes a
        // DIFFERENT descendant of the admitted container.
        let home = try makeTempDir("home")
        let runtime = try makeValidationRuntime(home: home)
        let container = fixtureContainer
        let target = container.appendingPathComponent("bound1")
        let elsewhere = container.appendingPathComponent("elsewhere")

        // ZERO records on a measured `.removeItem` item: malformed.
        let noRecords = makeContainerItem(
            id: "bound1", scannerID: "fixture", rootRecords: []
        )
        XCTAssertNotNil(malformedIssue(of: runtime.validatedOutcome(
            ScanOutcome(items: [noRecords], errors: []), from: "fixture"
        )), "a deletable remove_item item with no records is unbound")

        // A measured record capturing a DIFFERENT path: malformed — the
        // mapping-error shape (confirm one path, delete another).
        let mismatched = makeContainerItem(
            id: "bound1", scannerID: "fixture",
            rootRecords: [RootScanRecord(
                requestedURL: elsewhere, resolvedURL: elsewhere,
                status: .measured
            )]
        )
        XCTAssertNotNil(malformedIssue(of: runtime.validatedOutcome(
            ScanOutcome(items: [mismatched], errors: []), from: "fixture"
        )), "a measured record for another path does not bind the target")

        // The right path but NOT `.measured`: malformed for a deletable
        // state — only measured captures are deletable (frozen truth table).
        let unmeasured = makeContainerItem(
            id: "bound1", scannerID: "fixture",
            rootRecords: [RootScanRecord(
                requestedURL: target, resolvedURL: target,
                status: .deniedUnmeasured
            )]
        )
        XCTAssertNotNil(malformedIssue(of: runtime.validatedOutcome(
            ScanOutcome(items: [unmeasured], errors: []), from: "fixture"
        )), "an unmeasured record does not bind a deletable target")

        // `.partiallyDenied` is deletable and demands the same binding.
        let partialUnbound = makeContainerItem(
            id: "bound1", scannerID: "fixture", state: .partiallyDenied,
            rootRecords: []
        )
        XCTAssertNotNil(malformedIssue(of: runtime.validatedOutcome(
            ScanOutcome(items: [partialUnbound], errors: []), from: "fixture"
        )))

        // DISPLAY-IDENTITY binding (review round 4): the record binding
        // the deletion target must also be the identity the item displays.
        // A record that captures the target's requested spelling but whose
        // `resolvedURL` names ANOTHER path than `url`: malformed — `scan`
        // would show one path while `removeGuardedItem` deletes another.
        let displayElsewhere = makeContainerItem(
            id: "bound1", scannerID: "fixture",
            rootRecords: [RootScanRecord(
                requestedURL: target, resolvedURL: target, status: .measured
            )],
            displayURL: .some(elsewhere)
        )
        XCTAssertNotNil(malformedIssue(of: runtime.validatedOutcome(
            ScanOutcome(items: [displayElsewhere], errors: []), from: "fixture"
        )), "a display url that is not the bound record's resolution is malformed")

        // A bound record whose resolution honestly FAILED (nil
        // `resolvedURL`) demands a nil display url (the declared spelling
        // is what renders) — a non-nil url alongside it is display forged
        // from somewhere other than the deletion capture: malformed.
        let unresolvedHonest = makeContainerItem(
            id: "bound1", scannerID: "fixture",
            rootRecords: [RootScanRecord(
                requestedURL: target, resolvedURL: nil, status: .measured
            )],
            displayURL: .some(nil)
        )
        XCTAssertNotNil(outcome(of: runtime.validatedOutcome(
            ScanOutcome(items: [unresolvedHonest], errors: []), from: "fixture"
        )), "nil resolution + nil display url is honest and must pass")
        let unresolvedForged = makeContainerItem(
            id: "bound1", scannerID: "fixture",
            rootRecords: [RootScanRecord(
                requestedURL: target, resolvedURL: nil, status: .measured
            )],
            displayURL: .some(elsewhere)
        )
        XCTAssertNotNil(malformedIssue(of: runtime.validatedOutcome(
            ScanOutcome(items: [unresolvedForged], errors: []), from: "fixture"
        )), "a display url with no resolved capture behind it is malformed")

        // The genuine shape passes — the fn-2.2 single-element-record
        // correspondence (requested spelling == descriptor target;
        // display url == that record's own resolution).
        let genuine = makeContainerItem(id: "bound1", scannerID: "fixture")
        XCTAssertEqual(
            outcome(of: runtime.validatedOutcome(
                ScanOutcome(items: [genuine], errors: []), from: "fixture"
            ))?.items,
            [genuine]
        )

        // The production truth table's NON-deletable emissions still pass:
        // `.denied` carries its honest `.deniedUnmeasured` record (the
        // cleaner refuses it; demanding a measured record would break
        // the retired node_modules scanner's denied emission), and
        // `.missing` carries zero records.
        let denied = makeContainerItem(
            id: "bound1", scannerID: "fixture", state: .denied,
            rootRecords: [RootScanRecord(
                requestedURL: target, resolvedURL: target,
                status: .deniedUnmeasured
            )]
        )
        XCTAssertNotNil(outcome(of: runtime.validatedOutcome(
            ScanOutcome(items: [denied], errors: []), from: "fixture"
        )), "an honest denied emission must not be rejected")
        let missing = makeContainerItem(
            id: "bound1", scannerID: "fixture", state: .missing,
            rootRecords: []
        )
        XCTAssertNotNil(outcome(of: runtime.validatedOutcome(
            ScanOutcome(items: [missing], errors: []), from: "fixture"
        )), "a missing item carries no records and must pass")
        let empty = makeContainerItem(
            id: "bound1", scannerID: "fixture", state: .empty
        )
        XCTAssertNotNil(outcome(of: runtime.validatedOutcome(
            ScanOutcome(items: [empty], errors: []), from: "fixture"
        )), "a clean-empty walk (measured record, empty state) must pass")
    }

    // MARK: - Origin-container binding (round 6)

    func testContainerItemOriginMustBeAProducingScannersDeclaredRoot() throws {
        // Delete-time admission checks the runtime-wide UNION by FROZEN R4
        // design (registration alone extends admission — the zero-edit
        // fixture proof), so the union cannot tell WHICH scanner declared
        // a root. Scan-time publication therefore binds every container-
        // item origin to the PRODUCING scanner's own declared roots: a
        // mapping bug in scanner A can no longer pair its target with
        // scanner B's registered container and ride B's registration
        // through union admission. (Production: the retired node_modules
        // scanner's `originContainer` was always the exact search root the walk
        // started from — an exact member of its declared set.)
        let home = try makeTempDir("home")
        let rootA = fixtureContainer
        let rootB = URL(fileURLWithPath: "/tmp/other-container")
        let runtime = try makeRuntime(
            scanners: [
                FixtureScanner(id: "alpha", trustedContainerRoots: [rootA]),
                FixtureScanner(id: "beta", trustedContainerRoots: [rootB]),
            ],
            home: home
        )
        // BOTH roots are in the delete-time union — which is exactly why
        // the scan-time check must be per-scanner, not union-wide.
        XCTAssertEqual(
            runtime.trustedContainerRoots.map(\.path),
            [rootA.path, rootB.path]
        )

        // The genuine shape: origin is the producing scanner's own root.
        let own = makeContainerItem(id: "own1", scannerID: "alpha")
        XCTAssertEqual(
            outcome(of: runtime.validatedOutcome(
                ScanOutcome(items: [own], errors: []), from: "alpha"
            ))?.items,
            [own]
        )

        // ANOTHER registered scanner's root as origin: malformed — even
        // though the union would admit that root at delete time (the
        // review scenario). The deletion-target binding itself is intact
        // (the measured record captures the target), so origin alone
        // decides.
        let ridesBeta = makeContainerItem(
            id: "cross1", scannerID: "alpha",
            admission: .containerItem(
                originContainer: rootB,
                requestedTargetURL: rootA.appendingPathComponent("cross1")
            )
        )
        XCTAssertNotNil(malformedIssue(of: runtime.validatedOutcome(
            ScanOutcome(items: [ridesBeta], errors: []), from: "alpha"
        )), "an origin declared by ANOTHER scanner must not publish")

        // A wholly undeclared origin: malformed.
        let undeclared = makeContainerItem(
            id: "und1", scannerID: "alpha",
            admission: .containerItem(
                originContainer: URL(fileURLWithPath: "/tmp/undeclared"),
                requestedTargetURL: rootA.appendingPathComponent("und1")
            )
        )
        XCTAssertNotNil(malformedIssue(of: runtime.validatedOutcome(
            ScanOutcome(items: [undeclared], errors: []), from: "alpha"
        )))

        // The origin claim is registration-derived data in EVERY state —
        // a non-deletable `.denied` item with a foreign origin is still
        // malformed (production always emits the walked search root).
        let deniedForeign = makeContainerItem(
            id: "den1", scannerID: "alpha", state: .denied,
            admission: .containerItem(
                originContainer: rootB,
                requestedTargetURL: rootA.appendingPathComponent("den1")
            )
        )
        XCTAssertNotNil(malformedIssue(of: runtime.validatedOutcome(
            ScanOutcome(items: [deniedForeign], errors: []), from: "alpha"
        )))

        // An UNREGISTERED producer id has declared nothing — no origin can
        // bind (the stream can never produce this shape; the direct API
        // must not be looser).
        let ghost = makeContainerItem(id: "g1", scannerID: "ghost")
        XCTAssertNotNil(malformedIssue(of: runtime.validatedOutcome(
            ScanOutcome(items: [ghost], errors: []), from: "ghost"
        )))
    }

    func testStructuralInvariantsAreStateAware() throws {
        let home = try makeTempDir("home")
        let category = makeCategory(at: [], slug: "agg_cache")
        let runtime = try makeRuntime(
            scanners: [], categories: [category], home: home
        )
        let adapterID = CategoryScanner.registeredID

        // A NON-missing `.commands` item with ZERO root records: malformed —
        // zero roots would vacuously pass `.commands` re-admission and then
        // execute argv.
        let commandsNoRoots = makeAggregateItem(
            category: category, action: .commands([["true"]]),
            state: .measured, rootRecords: []
        )
        XCTAssertNotNil(malformedIssue(of: runtime.validatedOutcome(
            ScanOutcome(items: [commandsNoRoots], errors: []), from: adapterID
        )))

        // A NON-missing `.removeContents` item with ZERO root records:
        // malformed.
        let contentsNoRoots = makeAggregateItem(
            category: category, action: .removeContents,
            state: .measured, rootRecords: []
        )
        XCTAssertNotNil(malformedIssue(of: runtime.validatedOutcome(
            ScanOutcome(items: [contentsNoRoots], errors: []), from: adapterID
        )))

        // A `.removeItem` item WITHOUT the frozen `.containerItem`
        // descriptor: malformed — from a PER-ITEM scanner, so the
        // descriptor check itself is exercised (an adapter-owned
        // `.removeItem` is refused EARLIER, for converse ownership).
        let noDescriptor = makeAggregateItem(
            category: category, scannerID: "fixture_x", action: .removeItem
        )
        XCTAssertNotNil(malformedIssue(of: runtime.validatedOutcome(
            ScanOutcome(items: [noDescriptor], errors: []), from: "fixture_x"
        )))

        // The zero-record rule covers `.removeItem` in EVERY non-missing
        // state (round 4): `.empty`/`.denied` never reach deletion, but a
        // recordless item has NO capture supporting its state, bytes, or
        // display identity — construction bug, never vacuously admissible.
        for state: ScanState in [.empty, .denied] {
            let recordless = makeContainerItem(
                id: "recordless", scannerID: "fixture_x",
                state: state, rootRecords: []
            )
            XCTAssertNotNil(
                malformedIssue(of: runtime.validatedOutcome(
                    ScanOutcome(items: [recordless], errors: []),
                    from: "fixture_x"
                )),
                "a non-missing \(state) remove_item item with zero records is malformed"
            )
        }

        // `.removeContents`/`.commands` items WITHOUT category provenance:
        // malformed.
        let container = URL(fileURLWithPath: "/tmp/c")
        for action: ReclaimAction in [.removeContents, .commands([["true"]])] {
            let wrongProvenance = makeAggregateItem(
                category: category, action: action,
                admission: .containerItem(
                    originContainer: container,
                    requestedTargetURL: container.appendingPathComponent("x")
                )
            )
            XCTAssertNotNil(
                malformedIssue(of: runtime.validatedOutcome(
                    ScanOutcome(items: [wrongProvenance], errors: []),
                    from: adapterID
                )),
                "\(action.wireString) without category provenance is malformed"
            )
        }

        // A `.missing` item with EMPTY records PASSES — a scan containing a
        // missing category must not render the whole outcome malformed.
        let missing = makeAggregateItem(
            category: category, action: .removeContents,
            state: .missing, rootRecords: []
        )
        let verdict = runtime.validatedOutcome(
            ScanOutcome(items: [missing], errors: []), from: adapterID
        )
        XCTAssertEqual(outcome(of: verdict)?.items, [missing])
    }

    // MARK: - Value-domain validation (round 5)

    func testValueDomainMatrixOverEveryNumericField() throws {
        // The COMPLETE numeric-field domain, one table (`ReclaimableItem`
        // carries exactly four numeric fields; `RootScanRecord` carries
        // none): components nonnegative, their sum representable,
        // `logicalBytes`/`itemCount` nonnegative. The overflow cells are
        // the review shape — `allocatedBytes` is computed on first access,
        // so an accepted overflowing pair would trap `scanEnvelope`, GUI
        // totals, sorting, and clean plans instead of producing
        // `malformed_outcome`.
        let home = try makeTempDir("home")
        let category = makeCategory(at: [], slug: "value_cache")
        let runtime = try makeValidationRuntime(
            categories: [category], home: home
        )
        let adapterID = CategoryScanner.registeredID

        let cells: [(label: String, item: ReclaimableItem, producer: String, valid: Bool)] = [
            ("Int64.max + 1 component sum (the review shape)",
             makeContainerItem(id: "v1", scannerID: "fixture",
                               exactBytes: .max, estimatedUpToBytes: 1),
             "fixture", false),
            ("both components Int64.max",
             makeContainerItem(id: "v1", scannerID: "fixture",
                               exactBytes: .max, estimatedUpToBytes: .max),
             "fixture", false),
            ("negative exactBytes",
             makeContainerItem(id: "v1", scannerID: "fixture", exactBytes: -1),
             "fixture", false),
            ("negative estimatedUpToBytes",
             makeContainerItem(id: "v1", scannerID: "fixture",
                               estimatedUpToBytes: -1),
             "fixture", false),
            ("negative logicalBytes",
             makeContainerItem(id: "v1", scannerID: "fixture",
                               logicalBytes: -5),
             "fixture", false),
            ("negative itemCount",
             makeContainerItem(id: "v1", scannerID: "fixture", itemCount: -1),
             "fixture", false),
            // Boundary: Int64.max ALONE is representable — the domain rule
            // is about the SUM, never a cap on either component.
            ("Int64.max exactBytes alone",
             makeContainerItem(id: "v1", scannerID: "fixture",
                               exactBytes: .max),
             "fixture", true),
            // A positive logical-divergence figure is a valid shape.
            ("positive logicalBytes",
             makeContainerItem(id: "v1", scannerID: "fixture",
                               logicalBytes: 4096),
             "fixture", true),
            // The identical domain rules cover the aggregate kind.
            ("negative exactBytes on an aggregate",
             makeAggregateItem(category: category, exactBytes: -1),
             adapterID, false),
            ("overflowing component sum on an aggregate",
             makeAggregateItem(category: category,
                               exactBytes: .max, estimatedUpToBytes: 1),
             adapterID, false),
        ]
        for cell in cells {
            let verdict = runtime.validatedOutcome(
                ScanOutcome(items: [cell.item], errors: []),
                from: cell.producer
            )
            if cell.valid {
                XCTAssertNotNil(
                    outcome(of: verdict), "\(cell.label) must validate"
                )
                XCTAssertNil(malformedIssue(of: verdict), cell.label)
            } else {
                let issue = malformedIssue(of: verdict)
                XCTAssertNotNil(issue, "\(cell.label) must be refused")
                XCTAssertEqual(issue?.kind, .malformedOutcome, cell.label)
                XCTAssertNil(
                    issue?.url,
                    "\(cell.label): no filesystem location — never a fake path"
                )
            }
        }
    }

    // MARK: - Value domain, outcome-wide half (round 8)

    func testOutcomeWideComponentSumOverflowIsMalformedAndBoundaryPasses() throws {
        // Per-item validation bounds each PAIR, but the cross-item
        // `allocatedBytes` sum is what every single-scanner consumer total
        // computes — two individually valid items claiming Int64.max + 1
        // bytes together describe a physically impossible scan (> 9.2 EB)
        // and would trap the first consumer instead of producing
        // `malformed_outcome`.
        let home = try makeTempDir("home")
        let runtime = try makeValidationRuntime(home: home)

        let overflowCells: [(label: String, items: [ReclaimableItem])] = [
            ("Int64.max + 1 across two exact components (the review shape)",
             [makeContainerItem(id: "big", scannerID: "fixture",
                                exactBytes: .max),
              makeContainerItem(id: "one", scannerID: "fixture",
                                exactBytes: 1)]),
            ("overflow reached through an estimated component",
             [makeContainerItem(id: "big", scannerID: "fixture",
                                exactBytes: .max),
              makeContainerItem(id: "est", scannerID: "fixture",
                                exactBytes: 0, estimatedUpToBytes: 1)]),
        ]
        for cell in overflowCells {
            let issue = malformedIssue(of: runtime.validatedOutcome(
                ScanOutcome(items: cell.items, errors: []), from: "fixture"
            ))
            XCTAssertNotNil(issue, "\(cell.label) must be refused")
            XCTAssertEqual(issue?.kind, .malformedOutcome, cell.label)
            XCTAssertNil(
                issue?.url,
                "\(cell.label): no filesystem location — never a fake path"
            )
        }

        // Boundary: an outcome summing EXACTLY to Int64.max is
        // representable — the rule is overflow, never an invented cap
        // below it (round 5's objection, preserved).
        let boundary = ScanOutcome(
            items: [
                makeContainerItem(id: "almost", scannerID: "fixture",
                                  exactBytes: .max - 1),
                makeContainerItem(id: "last", scannerID: "fixture",
                                  exactBytes: 0, estimatedUpToBytes: 1),
            ],
            errors: []
        )
        let verdict = runtime.validatedOutcome(boundary, from: "fixture")
        XCTAssertNil(malformedIssue(of: verdict),
                     "an outcome summing exactly to Int64.max must publish")
        XCTAssertEqual(outcome(of: verdict)?.items.count, 2)
    }

    // MARK: - State ↔ record-status coherence (round 5)

    func testStateCoherenceMatrixOverRecordStatusesAndComponents() throws {
        // The COMPLETE state x record-status/component table, one matrix
        // (round-4 idiom), derived from the frozen truth table and the two
        // production mappings. Valid cells pin every shape production
        // actually emits (including the boundaries the validator must NOT
        // over-enforce); invalid cells pin every incoherence it must
        // refuse — headlined by the review shape: a `.measured` item whose
        // nonempty records are all refused/denied, which would let the CLI
        // plan a clean that `cleanContents` (measured-records-only) turns
        // into a zero-byte "success".
        let home = try makeTempDir("home")
        let category = makeCategory(at: [], slug: "coherent_cache")
        let runtime = try makeValidationRuntime(
            categories: [category], home: home
        )
        let adapterID = CategoryScanner.registeredID
        let root = URL(fileURLWithPath: "/tmp/fixture-root")
        let record = { (status: RootScanStatus) in
            RootScanRecord(requestedURL: root, resolvedURL: root, status: status)
        }
        let target = URL(fileURLWithPath: "/tmp/fixture-container/c1")
        let targetRecord = { (status: RootScanStatus) in
            RootScanRecord(
                requestedURL: target, resolvedURL: target, status: status
            )
        }
        let fixtureError = ScanError(
            kind: .permissionDenied, message: "fixture denial"
        )

        let cells: [(label: String, item: ReclaimableItem, producer: String, valid: Bool)] = [
            // ---- Valid: every shape production emits.
            ("measured aggregate over a measured record",
             makeAggregateItem(category: category), adapterID, true),
            ("measured zero-byte item with counted files",
             makeContainerItem(id: "c1", scannerID: "fixture",
                               exactBytes: 0, itemCount: 1),
             "fixture", true),
            ("clean-empty aggregate (measured record, zero components)",
             makeAggregateItem(category: category, state: .empty),
             adapterID, true),
            // Single-root partial walk: denials live INSIDE the tree — the
            // only record is honestly `.measured` (both mappings emit
            // this; demanding a denied record here would reject them).
            ("partially-denied aggregate with ONLY a measured record",
             makeAggregateItem(category: category, state: .partiallyDenied),
             adapterID, true),
            ("partially-denied aggregate with measured + denied records",
             makeAggregateItem(category: category, state: .partiallyDenied,
                               rootRecords: [record(.measured),
                                             record(.deniedUnmeasured)]),
             adapterID, true),
            ("denied aggregate with a denied-unmeasured record",
             makeAggregateItem(category: category, state: .denied),
             adapterID, true),
            ("denied aggregate with a refused record",
             makeAggregateItem(category: category, state: .denied,
                               rootRecords: [record(.refusedAdmission)]),
             adapterID, true),
            // CacheScanner's boundary mix: a clean-empty root walks
            // honestly (`.measured`) beside a refused sibling while the
            // aggregate measured nothing — `.denied` must not forbid the
            // measured record.
            ("denied aggregate with clean-empty measured + refused records",
             makeAggregateItem(category: category, state: .denied,
                               rootRecords: [record(.measured),
                                             record(.refusedAdmission)]),
             adapterID, true),
            ("missing aggregate (no records, zero components)",
             makeAggregateItem(category: category, state: .missing),
             adapterID, true),
            ("denied per-item (the retired node_modules denied emission)",
             makeContainerItem(id: "c1", scannerID: "fixture",
                               state: .denied),
             "fixture", true),

            // ---- Invalid: the review shape, both scanner kinds.
            ("measured aggregate whose records are all refused/denied",
             makeAggregateItem(category: category,
                               rootRecords: [record(.refusedAdmission),
                                             record(.deniedUnmeasured)]),
             adapterID, false),
            ("measured per-item whose record is denied-unmeasured",
             makeContainerItem(id: "c1", scannerID: "fixture",
                               rootRecords: [targetRecord(.deniedUnmeasured)]),
             "fixture", false),

            // ---- Invalid: the rest of the coherence table.
            ("measured aggregate with a refused record mixed in",
             makeAggregateItem(category: category,
                               rootRecords: [record(.measured),
                                             record(.refusedAdmission)]),
             adapterID, false),
            ("measured aggregate that measured nothing",
             makeAggregateItem(category: category,
                               exactBytes: 0, itemCount: 0),
             adapterID, false),
            ("measured aggregate carrying a scan error",
             makeAggregateItem(category: category,
                               scanError: .some(fixtureError)),
             adapterID, false),
            ("empty aggregate with nonzero bytes",
             makeAggregateItem(category: category, state: .empty,
                               exactBytes: 4096),
             adapterID, false),
            ("empty aggregate with a counted item",
             makeAggregateItem(category: category, state: .empty,
                               itemCount: 1),
             adapterID, false),
            ("empty aggregate over a denied record",
             makeAggregateItem(category: category, state: .empty,
                               rootRecords: [record(.deniedUnmeasured)]),
             adapterID, false),
            ("empty aggregate carrying a logical-bytes figure",
             makeAggregateItem(category: category, state: .empty,
                               logicalBytes: 4096),
             adapterID, false),
            ("partially-denied aggregate with no measured record",
             makeAggregateItem(category: category, state: .partiallyDenied,
                               rootRecords: [record(.deniedUnmeasured)]),
             adapterID, false),
            ("partially-denied aggregate with nil scanError",
             makeAggregateItem(category: category, state: .partiallyDenied,
                               scanError: .some(nil)),
             adapterID, false),
            ("partially-denied aggregate that measured nothing",
             makeAggregateItem(category: category, state: .partiallyDenied,
                               exactBytes: 0, itemCount: 0),
             adapterID, false),
            ("denied aggregate with only measured records",
             makeAggregateItem(category: category, state: .denied,
                               rootRecords: [record(.measured)]),
             adapterID, false),
            ("denied aggregate with nonzero bytes",
             makeAggregateItem(category: category, state: .denied,
                               exactBytes: 4096),
             adapterID, false),
            ("denied aggregate with nil scanError",
             makeAggregateItem(category: category, state: .denied,
                               scanError: .some(nil)),
             adapterID, false),
            ("denied aggregate carrying a logical-bytes figure",
             makeAggregateItem(category: category, state: .denied,
                               logicalBytes: 4096),
             adapterID, false),
            ("missing aggregate carrying a record",
             makeAggregateItem(category: category, state: .missing,
                               rootRecords: [record(.measured)]),
             adapterID, false),
            ("missing aggregate with nonzero bytes",
             makeAggregateItem(category: category, state: .missing,
                               exactBytes: 4096),
             adapterID, false),
            ("missing per-item displaying a url",
             makeContainerItem(id: "c1", scannerID: "fixture",
                               state: .missing, displayURL: .some(target)),
             "fixture", false),
        ]
        for cell in cells {
            let verdict = runtime.validatedOutcome(
                ScanOutcome(items: [cell.item], errors: []),
                from: cell.producer
            )
            if cell.valid {
                XCTAssertNotNil(
                    outcome(of: verdict), "\(cell.label) must validate"
                )
                XCTAssertNil(malformedIssue(of: verdict), cell.label)
            } else {
                let issue = malformedIssue(of: verdict)
                XCTAssertNotNil(issue, "\(cell.label) must be refused")
                XCTAssertEqual(issue?.kind, .malformedOutcome, cell.label)
                XCTAssertNil(
                    issue?.url,
                    "\(cell.label): no filesystem location — never a fake path"
                )
            }
        }
    }

    func testProductionStateEmissionsPassCoherenceValidation() async throws {
        // Every state the REAL category pipeline can emit, through the
        // validated stream: the coherence rules must be exactly as strong
        // as the production mappings — no emission may render its outcome
        // malformed. Covers the two boundary shapes the validator
        // deliberately permits: a partially-denied aggregate carrying all
        // three record statuses, and a denied aggregate carrying an honest
        // clean-empty `.measured` record beside its refused root.
        let home = try makeTempDir("home")
        // Refused root: a protected first-level $HOME child (deny list).
        let documents = home.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(
            at: documents, withIntermediateDirectories: true
        )
        // Denied-unmeasured root: admitted, denied before any measurement.
        let deniedDir = try makeTempDir("denied")
        try writeFile(deniedDir.appendingPathComponent("f.bin"))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: deniedDir.path
        )
        addTeardownBlock {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: deniedDir.path
            )
        }
        let measuredDir = try makeTempDir("measured")
        try writeFile(measuredDir.appendingPathComponent("f.bin"))
        let emptyDir = try makeTempDir("empty")
        let emptyBesideRefused = try makeTempDir("empty-beside-refused")
        let nowhere = FileManager.default.temporaryDirectory
            .appendingPathComponent("CategoryScannerTests-nowhere-\(UUID().uuidString)")

        func category(_ slug: String, _ discovery: [PathDiscovery]) -> CacheCategory {
            CacheCategory(
                name: slug, slug: slug, description: "fixture", icon: "trash",
                discovery: discovery, riskLevel: .safe, rebuildNote: "",
                defaultSelected: true
            )
        }
        let categories = [
            // All three record statuses on one aggregate → .partiallyDenied.
            category("partial_cache", [
                .staticPath("Documents"),
                .absolutePath(deniedDir.path),
                .absolutePath(measuredDir.path),
                .absolutePath(emptyDir.path),
            ]),
            // Clean-empty measured record beside a refused root → .denied
            // with a `.measured` record present.
            category("denied_mixed", [
                .staticPath("Documents"),
                .absolutePath(emptyBesideRefused.path),
            ]),
            category("measured_cache", [.absolutePath(measuredDir.path)]),
            category("empty_cache", [.absolutePath(emptyDir.path)]),
            category("denied_cache", [.absolutePath(deniedDir.path)]),
            category("missing_cache", [.absolutePath(nowhere.path)]),
        ]
        let runtime = try makeRuntime(
            scanners: [makeCategoryScanner(categories: categories, home: home)],
            categories: categories,
            home: home
        )

        let events = await collect(runtime.scanValidated(
            context: ScanContext(trigger: .userInitiated)
        ))

        XCTAssertEqual(events.count, 1)
        XCTAssertNil(
            malformedIssue(of: events[0]),
            "no production emission may fail the coherence validator"
        )
        let items = try XCTUnwrap(outcome(of: events[0])?.items)
        let bySlug = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        XCTAssertEqual(bySlug["partial_cache"]?.state, .partiallyDenied)
        XCTAssertEqual(
            Set(bySlug["partial_cache"]?.rootRecords.map(\.status) ?? []),
            [.refusedAdmission, .deniedUnmeasured, .measured],
            "all three statuses ride one validated partially-denied aggregate"
        )
        XCTAssertEqual(bySlug["denied_mixed"]?.state, .denied)
        XCTAssertEqual(
            Set(bySlug["denied_mixed"]?.rootRecords.map(\.status) ?? []),
            [.refusedAdmission, .measured],
            "the honest clean-empty measured record validates beside the refusal"
        )
        XCTAssertEqual(bySlug["measured_cache"]?.state, .measured)
        XCTAssertEqual(bySlug["empty_cache"]?.state, .empty)
        XCTAssertEqual(bySlug["denied_cache"]?.state, .denied)
        XCTAssertEqual(bySlug["missing_cache"]?.state, .missing)
    }

    func testAggregateAdapterMayEmitOnlyCategoryBackedActions() throws {
        // CONVERSE ownership (review round 4): downstream treats every
        // `categories` item as an aggregate — the CLI plan skips zero-byte
        // aggregates while the cleaner deliberately deletes zero-byte
        // `.removeItem` targets — so an adapter-owned `.removeItem` could
        // delete on a confirmed run what its preview said it would skip.
        // The validator refuses it even in the OTHERWISE-VALID shape
        // (container descriptor + bound measured record + matching display)
        // that a per-item scanner passes with.
        let home = try makeTempDir("home")
        let runtime = try makeValidationRuntime(home: home)
        let adapterOwned = makeContainerItem(
            id: "sneaky", scannerID: CategoryScanner.registeredID
        )
        XCTAssertNotNil(malformedIssue(of: runtime.validatedOutcome(
            ScanOutcome(items: [adapterOwned], errors: []),
            from: CategoryScanner.registeredID
        )), "the adapter may emit only category-backed actions")

        // The IDENTICAL shape from a per-item scanner still passes — the
        // refusal is ownership-directional, not shape-based.
        let perItem = makeContainerItem(id: "sneaky", scannerID: "fixture")
        XCTAssertEqual(
            outcome(of: runtime.validatedOutcome(
                ScanOutcome(items: [perItem], errors: []), from: "fixture"
            ))?.items,
            [perItem]
        )
    }

    func testOwnershipDirectionMatrixOverActionAndScannerKind() throws {
        // The COMPLETE ownership-direction matrix, one table (review
        // round 4): category-backed actions (`.removeContents`/`.commands`
        // with `.category` provenance) are valid ONLY from the aggregate
        // adapter; container-backed `.removeItem` is valid ONLY from
        // per-item scanners. Every action x scanner-kind cell, each item
        // otherwise fully valid, so ownership direction alone decides.
        let home = try makeTempDir("home")
        let category = makeCategory(at: [], slug: "agg_cache")
        let commandBacked = makeCategory(
            at: [], slug: "cmd_cache", cleanCommands: [["true"]]
        )
        let runtime = try makeValidationRuntime(
            categories: [category, commandBacked], home: home
        )
        let adapterID = CategoryScanner.registeredID

        let cells: [(label: String, item: ReclaimableItem, producer: String, valid: Bool)] = [
            ("remove_contents from the adapter",
             makeAggregateItem(category: category), adapterID, true),
            ("commands from the adapter",
             makeAggregateItem(category: commandBacked,
                               action: .commands([["true"]])), adapterID, true),
            ("remove_item from the adapter",
             makeContainerItem(id: "x1", scannerID: adapterID), adapterID, false),
            ("remove_contents from a per-item scanner",
             makeAggregateItem(category: category, scannerID: "fixture"),
             "fixture", false),
            ("commands from a per-item scanner",
             makeAggregateItem(category: commandBacked, scannerID: "fixture",
                               action: .commands([["true"]])), "fixture", false),
            ("remove_item from a per-item scanner",
             makeContainerItem(id: "x1", scannerID: "fixture"), "fixture", true),
        ]
        for cell in cells {
            let verdict = runtime.validatedOutcome(
                ScanOutcome(items: [cell.item], errors: []), from: cell.producer
            )
            if cell.valid {
                XCTAssertNotNil(
                    outcome(of: verdict), "\(cell.label) must validate"
                )
                XCTAssertNil(malformedIssue(of: verdict), cell.label)
            } else {
                XCTAssertNotNil(
                    malformedIssue(of: verdict), "\(cell.label) must be refused"
                )
            }
        }
    }

    func testCommandsArgvMustEqualTheCategoryDeclaration() throws {
        // Action/argv coherence (fn-2.3, mirrored by the cleaner): command
        // argv is registry code — the payload must BE the registered
        // category's `cleanCommands`, and a command-backed category can
        // never carry `.removeContents`.
        let home = try makeTempDir("home")
        let commandBacked = makeCategory(
            at: [], slug: "cmd_cache", cleanCommands: [["true"]]
        )
        let runtime = try makeRuntime(
            scanners: [], categories: [commandBacked], home: home
        )
        let adapterID = CategoryScanner.registeredID

        // Forged argv payload on a genuine registered category: malformed.
        let forgedArgv = makeAggregateItem(
            category: commandBacked,
            action: .commands([["rm", "-rf", "/tmp/evil"]])
        )
        XCTAssertNotNil(malformedIssue(of: runtime.validatedOutcome(
            ScanOutcome(items: [forgedArgv], errors: []), from: adapterID
        )))

        // A command-backed category routed through file deletion: malformed.
        let contentsRouted = makeAggregateItem(
            category: commandBacked, action: .removeContents
        )
        XCTAssertNotNil(malformedIssue(of: runtime.validatedOutcome(
            ScanOutcome(items: [contentsRouted], errors: []), from: adapterID
        )))

        // The genuine declaration passes.
        let genuine = makeAggregateItem(
            category: commandBacked, action: .commands([["true"]])
        )
        XCTAssertEqual(
            outcome(of: runtime.validatedOutcome(
                ScanOutcome(items: [genuine], errors: []), from: adapterID
            ))?.items,
            [genuine]
        )
    }

    func testCategoryProvenanceIsBoundToTheRegisteredRegistry() throws {
        let home = try makeTempDir("home")
        let registered = makeCategory(at: [], slug: "real_cache")
        let runtime = try makeRuntime(
            scanners: [], categories: [registered], home: home
        )
        let adapterID = CategoryScanner.registeredID

        // A non-adapter scanner cannot emit category-backed actions AT ALL —
        // even carrying the genuinely registered category.
        let fromFixture = makeAggregateItem(
            category: registered, scannerID: "fixture_x"
        )
        XCTAssertNotNil(malformedIssue(of: runtime.validatedOutcome(
            ScanOutcome(items: [fromFixture], errors: []), from: "fixture_x"
        )))

        // An invented category (unregistered slug) is refused: its declared
        // roots sit outside every registration-derived policy.
        let invented = makeCategory(
            at: [URL(fileURLWithPath: "/tmp/evil")], slug: "invented_cache"
        )
        XCTAssertNotNil(malformedIssue(of: runtime.validatedOutcome(
            ScanOutcome(items: [makeAggregateItem(category: invented)], errors: []),
            from: adapterID
        )))

        // An invented category REUSING a registered slug is still refused —
        // the registered INSTANCE is what is trusted, not the slug spelling.
        let forged = makeCategory(
            at: [URL(fileURLWithPath: "/tmp/evil")], slug: "real_cache"
        )
        XCTAssertNotNil(malformedIssue(of: runtime.validatedOutcome(
            ScanOutcome(items: [makeAggregateItem(category: forged)], errors: []),
            from: adapterID
        )))

        // The aggregate item id must equal the carried category's slug.
        let wrongID = makeAggregateItem(category: registered, id: "other_id")
        XCTAssertNotNil(malformedIssue(of: runtime.validatedOutcome(
            ScanOutcome(items: [wrongID], errors: []), from: adapterID
        )))

        // The genuine registered instance from the adapter passes.
        let genuine = makeAggregateItem(category: registered)
        XCTAssertEqual(
            outcome(of: runtime.validatedOutcome(
                ScanOutcome(items: [genuine], errors: []), from: adapterID
            ))?.items,
            [genuine]
        )
    }

    // MARK: - Aggregate risk/selection-policy binding (round 6)

    func testAggregatePolicyMustMatchTheRegisteredCategory() throws {
        // The adapter mapping derives risk (`category.riskLevel`),
        // `defaultSelected` (`category.defaultSelected`),
        // `automaticCleanEligible` (always true), and `isStale` (always
        // nil) FROM the registered category — but downstream trusts the
        // CARRIED copies: Quick Clean/selectAllSafe selects
        // `automaticCleanEligible && risk == .safe`, initial selection
        // reads `defaultSelected`, Select Stale reads `isStale`. The
        // matrix pins every field: a mapping regression fails closed
        // instead of e.g. auto-cleaning a `.caution` Docker aggregate
        // without its caution warning (the review shape).
        let home = try makeTempDir("home")
        let cautionCat = makeCategory(
            at: [], slug: "docker_like", riskLevel: .caution,
            defaultSelected: false
        )
        let safeCat = makeCategory(at: [], slug: "safe_cache")
        let runtime = try makeValidationRuntime(
            categories: [cautionCat, safeCat], home: home
        )
        let adapterID = CategoryScanner.registeredID

        let cells: [(label: String, item: ReclaimableItem, valid: Bool)] = [
            // ---- The review shape: a caution category carried as safe
            // would ride Quick Clean without the caution warning.
            ("caution category carried as safe risk",
             makeAggregateItem(category: cautionCat, risk: .safe), false),
            ("safe category carried as caution risk",
             makeAggregateItem(category: safeCat, risk: .caution), false),
            ("defaultSelected diverging from the declaration",
             makeAggregateItem(category: safeCat, defaultSelected: false),
             false),
            ("defaultSelected forged on an unselected declaration",
             makeAggregateItem(category: cautionCat, defaultSelected: true),
             false),
            ("automaticCleanEligible false on an aggregate",
             makeAggregateItem(category: safeCat,
                               automaticCleanEligible: false), false),
            ("a staleness flag on an aggregate",
             makeAggregateItem(category: safeCat, isStale: true), false),
            // ---- The genuine adapter derivations pass, both risk tiers.
            ("the genuine safe mapping",
             makeAggregateItem(category: safeCat), true),
            ("the genuine caution mapping",
             makeAggregateItem(category: cautionCat), true),
        ]
        for cell in cells {
            let verdict = runtime.validatedOutcome(
                ScanOutcome(items: [cell.item], errors: []), from: adapterID
            )
            if cell.valid {
                XCTAssertNotNil(
                    outcome(of: verdict), "\(cell.label) must validate"
                )
                XCTAssertNil(malformedIssue(of: verdict), cell.label)
            } else {
                let issue = malformedIssue(of: verdict)
                XCTAssertNotNil(issue, "\(cell.label) must be refused")
                XCTAssertEqual(issue?.kind, .malformedOutcome, cell.label)
                XCTAssertNil(issue?.url, cell.label)
            }
        }
    }

    // MARK: - Reserved malformed_outcome issue kind (round 6)

    func testScannerAuthoredMalformedOutcomeIssuesAreRejected() throws {
        // `malformed_outcome` means the scanner's ENTIRE outcome was
        // rejected and its items excluded (wire contract). A scanner
        // authoring the kind into its ordinary `errors` would make the CLI
        // print its items BESIDE a malformed_outcome row — so the forgery
        // itself malforms the outcome, and the runtime's genuinely
        // synthesized replacement is the correct fail-closed response.
        let home = try makeTempDir("home")
        let runtime = try makeValidationRuntime(home: home)
        let item = makeContainerItem(id: "ok1", scannerID: "fixture")
        let forged = ScanIssue(
            url: nil, kind: .malformedOutcome, detail: "scanner-authored"
        )

        // Beside a valid item: the WHOLE outcome is replaced.
        let besideItem = runtime.validatedOutcome(
            ScanOutcome(items: [item], errors: [forged]), from: "fixture"
        )
        let issue = malformedIssue(of: besideItem)
        XCTAssertEqual(issue?.kind, .malformedOutcome)
        XCTAssertNil(issue?.url, "no filesystem location — never a fake path")
        XCTAssertNotEqual(
            issue, forged,
            "the published issue is the runtime's synthesis, not the forgery"
        )

        // With no items at all: still rejected — the kind is reserved,
        // not merely incompatible with published items.
        XCTAssertNotNil(malformedIssue(of: runtime.validatedOutcome(
            ScanOutcome(items: [], errors: [forged]), from: "fixture"
        )))

        // Ordinary scanner-authored kinds pass through VERBATIM beside
        // valid items — the reservation covers exactly one kind.
        let benign = ScanIssue(
            url: URL(fileURLWithPath: "/tmp/denied-root"),
            kind: .tccDenied, detail: "fixture denial"
        )
        let passed = runtime.validatedOutcome(
            ScanOutcome(items: [item], errors: [benign]), from: "fixture"
        )
        XCTAssertEqual(outcome(of: passed)?.items, [item])
        XCTAssertEqual(outcome(of: passed)?.errors, [benign])
    }

    func testStreamRejectsFixtureScannerForgingCategoryItems() async throws {
        let home = try makeTempDir("home")
        let registered = makeCategory(at: [], slug: "real_cache")
        // The fixture scanner claims category provenance for a `.commands`
        // item with a forged category — correct ownership, matching item
        // id, plausible records; everything but the trust binding.
        let forged = makeCategory(
            at: [URL(fileURLWithPath: "/tmp/evil")], slug: "real_cache",
            cleanCommands: [["rm", "-rf", "/tmp/evil"]]
        )
        let forgedItem = makeAggregateItem(
            category: forged, scannerID: "fixture_x",
            action: .commands([["rm", "-rf", "/tmp/evil"]])
        )
        let fixture = FixtureScanner(id: "fixture_x", items: [forgedItem])
        let runtime = try makeRuntime(
            scanners: [fixture], categories: [registered], home: home
        )

        let events = await collect(runtime.scanValidated(
            context: ScanContext(trigger: .automatic)
        ))

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(
            malformedIssue(of: events[0])?.kind, .malformedOutcome,
            "a fixture scanner must not be able to publish a category-backed "
                + "action through the validated stream"
        )
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
            id: "good", trustedContainerRoots: [fixtureContainer],
            items: [makeContainerItem(id: "ok", scannerID: "good")]
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
        let fixture = FixtureScanner(
            id: "fixture_x", trustedContainerRoots: [fixtureContainer],
            items: [fixtureItem]
        )
        let runtime = try makeRuntime(
            scanners: [
                makeCategoryScanner(categories: [categoryA, categoryB], home: home),
                fixture,
            ],
            categories: [categoryA, categoryB],
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
