import XCTest
@testable import Cacheout

/// fn-4.6 Settings dev-roots editor + per-root error display (R8/R12/R16).
///
/// SwiftUI bodies are assertion-dead, so the editor's semantics live as
/// view-model surfaces and pure presentation derivations, and THOSE are the
/// assertion surfaces:
///
/// - `CacheoutViewModel.addDevRoot/removeDevRoot/resetDevRootsToDefaults` —
///   every mutation round-trips through the injected `DevRootsStore` and
///   then rebuilds the runtime through fn-4.10's FACTORY seam (never a
///   direct `production(...)` call);
/// - add-time validation calls the SHARED container-root admission policy
///   (`PathGuard.validateContainerRoot`, reached through the store) — the
///   same component the store's own resolution runs, never a UI-local
///   duplicate: `/`, a volume root, `$HOME`, and symlink aliases of each are
///   REFUSED inline while `~/Documents` and `~/Documents/dev` are ACCEPTED;
/// - `CacheoutViewModel.devRootRows` — the declared list with the
///   `.containerRefused` detail of any policy-rejected persisted root;
/// - `ScanIssueRowPresentation` — the visible per-root error row: a denied
///   root with its grant-access affordance, a refused configured root, and
///   the PATH-LESS `.configInvalid` parse failure (no invented path).
///
/// Everything is hermetic: fixture homes, an ephemeral defaults suite, and
/// fixture runtime factories — zero reads of the real `$HOME`.
final class DevRootsSettingsTests: XCTestCase {

    private var base: URL!
    private var fixtureHome: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = fm.temporaryDirectory
            .appendingPathComponent("DevRootsSettingsTests-\(UUID().uuidString)")
        fixtureHome = base.appendingPathComponent("home")
        try fm.createDirectory(at: fixtureHome, withIntermediateDirectories: true)
        suiteName = "DevRootsSettingsTests-\(UUID().uuidString)"
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

    // MARK: - Fixtures

    private func makeStore(
        provider: FileSystemIdentityProvider = FileSystemIdentityProvider()
    ) -> DevRootsStore {
        DevRootsStore(defaults: defaults, provider: provider)
    }

    /// A view model wired to the fn-4.10 seam over a FIXTURE factory: the
    /// factory records every resolution it was handed and returns an empty
    /// fixture runtime, so "the Settings change went through the factory
    /// path" is one assertion.
    @MainActor
    private func makeViewModel(
        provider: FileSystemIdentityProvider = FileSystemIdentityProvider()
    ) throws -> (CacheoutViewModel, FactoryLog) {
        let log = FactoryLog()
        let home = fixtureHome!
        let runtime = try SpaceScannerRuntime(
            scanners: [], categories: [], home: home,
            provider: FileSystemIdentityProvider()
        )
        let seam = CacheoutViewModel.RuntimeReconstruction(
            devRootsStore: makeStore(provider: provider), home: home,
            makeRuntime: { resolution in
                log.record(resolution)
                return runtime
            }
        )
        return (
            CacheoutViewModel(runtime: runtime, reconstruction: seam), log
        )
    }

    private func mkdir(_ url: URL) throws {
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    // MARK: - Add / remove / reset round-trip (R8)

    @MainActor
    func testAddRemoveResetRoundTripThroughTheStoreAndTheFactory() throws {
        let dev = fixtureHome.appendingPathComponent("dev")
        try mkdir(dev)
        let (viewModel, log) = try makeViewModel()

        // A fresh install shows the SEEDS it actually walks.
        XCTAssertEqual(viewModel.devRootRows.map(\.declaredPath),
                       DevRootsStore.seedRootNames)
        XCTAssertTrue(viewModel.isDevRootsEditorAvailable)

        // ADD — persisted through the store (seeds + 1, never a 1-element
        // list) and rebuilt through the injected factory.
        viewModel.addDevRoot(dev.path)
        XCTAssertNil(viewModel.devRootRejection)
        XCTAssertEqual(
            defaults.stringArray(forKey: DevRootsStore.devRootsKey),
            DevRootsStore.seedRootNames + [dev.path],
            "the store owns persistence — the editor never writes defaults"
        )
        XCTAssertEqual(viewModel.devRootRows.last?.declaredPath, dev.path)
        XCTAssertEqual(viewModel.devRootRows.last?.displayPath, "~/dev",
                       "display collapses the injected home")
        XCTAssertEqual(log.recorded.count, 1, "ONE factory rebuild")
        XCTAssertEqual(log.recorded.last?.keptRoots.last?.path, dev.path,
                       "the rebuild carried what the STORE resolved")

        // REMOVE — exact declared string, same funnel.
        viewModel.removeDevRoot(dev.path)
        XCTAssertEqual(
            defaults.stringArray(forKey: DevRootsStore.devRootsKey),
            DevRootsStore.seedRootNames
        )
        XCTAssertFalse(viewModel.devRootRows.contains { $0.declaredPath == dev.path })
        XCTAssertEqual(log.recorded.count, 2)

        // RESET — the key is removed entirely; the seeds are a fallback,
        // never persisted.
        viewModel.addDevRoot(dev.path)
        viewModel.resetDevRootsToDefaults()
        XCTAssertNil(defaults.object(forKey: DevRootsStore.devRootsKey))
        XCTAssertEqual(viewModel.devRootRows.map(\.declaredPath),
                       DevRootsStore.seedRootNames)
        XCTAssertEqual(log.recorded.count, 4)
    }

    /// A mutation that persists NOTHING must not rebuild: re-adding an
    /// already-declared root, removing one that was never there, and
    /// resetting when nothing is stored all leave the composition — and
    /// therefore DESTRUCTIVE FRESHNESS — exactly as they found it. A real
    /// change still gates (the non-vacuity half).
    @MainActor
    func testNoOpMutationsNeitherRebuildNorGateDestructivePaths() async throws {
        let container = base.appendingPathComponent("items")
        let junk = container.appendingPathComponent("junk")
        try mkdir(junk)

        let log = FactoryLog()
        let runtime = try SpaceScannerRuntime(
            scanners: [SelectableFixtureScanner(
                id: "fixture_settings", container: container
            )],
            categories: [], home: fixtureHome,
            provider: FileSystemIdentityProvider()
        )
        let viewModel = CacheoutViewModel(
            runtime: runtime,
            reconstruction: CacheoutViewModel.RuntimeReconstruction(
                devRootsStore: makeStore(), home: fixtureHome,
                makeRuntime: { resolution in
                    log.record(resolution)
                    return runtime
                }
            )
        )
        await viewModel.scan(trigger: .userInitiated)
        let item = try XCTUnwrap(
            viewModel.items(forScanner: "fixture_settings").first
        )
        viewModel.toggleSelection(for: item.key)
        XCTAssertTrue(viewModel.hasCleanableSelection)

        // (a) A duplicate add — `Documents` is already a declared seed.
        viewModel.addDevRoot("Documents")
        XCTAssertNil(viewModel.devRootRejection,
                     "an already-declared root is not an error")
        XCTAssertEqual(log.recorded.count, 0, "no rebuild for a no-op add")
        XCTAssertTrue(viewModel.hasCleanableSelection,
                      "destructive freshness survives a no-op")

        // (b) Removing something that was never declared — and it must not
        // materialize the seeds into the suite as a side effect.
        viewModel.removeDevRoot("/never/declared")
        XCTAssertEqual(log.recorded.count, 0)
        XCTAssertNil(defaults.object(forKey: DevRootsStore.devRootsKey))
        XCTAssertTrue(viewModel.hasCleanableSelection)

        // (c) Resetting when nothing is stored.
        viewModel.resetDevRootsToDefaults()
        XCTAssertEqual(log.recorded.count, 0)
        XCTAssertTrue(viewModel.hasCleanableSelection)

        // NON-VACUITY: a REAL change does rebuild — and gates the
        // destructive paths until a scan from the new composition adopts.
        let dev = fixtureHome.appendingPathComponent("dev")
        try mkdir(dev)
        viewModel.addDevRoot(dev.path)
        XCTAssertEqual(log.recorded.count, 1)
        XCTAssertFalse(viewModel.hasCleanableSelection,
                       "a real rebuild invalidates destructive freshness")
    }

    /// The declared string the editor persists ALWAYS resolves back to the
    /// URL it validated — one convention, so the editor can never validate
    /// one path while the scanner walks another.
    @MainActor
    func testTildeInputPersistsAsAPathTheStoreResolvesBack() throws {
        let dev = fixtureHome.appendingPathComponent("playground")
        try mkdir(dev)
        let (viewModel, log) = try makeViewModel()

        viewModel.addDevRoot("  ~/playground  ")   // whitespace trimmed
        XCTAssertNil(viewModel.devRootRejection)

        let declared = try XCTUnwrap(
            defaults.stringArray(forKey: DevRootsStore.devRootsKey)?.last
        )
        XCTAssertEqual(
            DevRootsStore.declaredURL(for: declared, home: fixtureHome).path,
            dev.path,
            "a persisted `~/…` spelling would resolve to a literal ~ folder"
        )
        XCTAssertEqual(log.recorded.last?.keptRoots.last?.path, dev.path)

        // A `~user`-style spelling is refused rather than silently persisted
        // as a literal folder name under home.
        viewModel.addDevRoot("~someone/dev")
        let rejection = try XCTUnwrap(viewModel.devRootRejection)
        XCTAssertTrue(rejection.contains("~someone/dev"), rejection)
        XCTAssertEqual(log.recorded.count, 1, "a refusal rebuilds nothing")
    }

    // MARK: - Add-time validation is the SHARED policy (R16)

    /// The attack matrix at the Settings surface: every dangerous pick is
    /// refused INLINE and changes nothing — no persistence, no rebuild —
    /// while the protected children the seeds depend on are accepted. The
    /// verdicts come from the SAME component the store's resolution runs
    /// (asserted below), never a UI-local copy.
    @MainActor
    func testAddTimeValidationRefusesDangerousRootsAndAcceptsProtectedChildren()
        throws
    {
        let volumeRoot = base.appendingPathComponent("ExternalVol")
        try mkdir(volumeRoot)
        let provider = MountPointInjectingProvider()
        provider.mountPointPaths = [provider.canonicalize(volumeRoot).path]
        let aliasOfRoot = base.appendingPathComponent("slash-alias")
        try fm.createSymbolicLink(
            at: aliasOfRoot, withDestinationURL: URL(fileURLWithPath: "/")
        )
        let aliasOfHome = base.appendingPathComponent("home-alias")
        try fm.createSymbolicLink(at: aliasOfHome, withDestinationURL: fixtureHome)

        let documents = fixtureHome.appendingPathComponent("Documents")
        let nested = documents.appendingPathComponent("dev")
        try mkdir(nested)

        let (viewModel, log) = try makeViewModel(provider: provider)
        let store = makeStore(provider: provider)

        let dangerous = ["/", fixtureHome.path, aliasOfRoot.path,
                         aliasOfHome.path, "~", volumeRoot.path]

        for pick in dangerous {
            viewModel.addDevRoot(pick)
            let rejection = try XCTUnwrap(
                viewModel.devRootRejection, "\(pick) must be refused"
            )
            XCTAssertTrue(rejection.contains("can't be used as a dev root"),
                          rejection)
            XCTAssertNil(defaults.object(forKey: DevRootsStore.devRootsKey),
                         "\(pick) must not be persisted")
            XCTAssertEqual(log.recorded.count, 0,
                           "\(pick) must not rebuild the runtime")

            // The SAME shared policy, reached through the store: the editor
            // is a call site, never a second implementation.
            XCTAssertThrowsError(try store.validateCandidateRoot(
                DevRootsStore.declaredURL(
                    for: CacheoutViewModel.devRootDeclaration(
                        for: pick, home: fixtureHome
                    ).get(),
                    home: fixtureHome
                ),
                home: fixtureHome
            ), "the store's own policy call must agree about \(pick)")
        }

        // The LEGAL protected children — `~/Documents` and a child of it.
        for legal in [documents.path, nested.path, "~/Documents", "Documents"] {
            viewModel.addDevRoot(legal)
            XCTAssertNil(viewModel.devRootRejection,
                         "\(legal) is a legal dev root")
        }
        XCTAssertEqual(
            viewModel.devRootRows.filter { $0.declaredPath.contains("Documents") }
                .isEmpty, false
        )
        XCTAssertGreaterThan(log.recorded.count, 0)
    }

    /// A SUCCESSFUL add clears a previous inline rejection — the error is
    /// about the last attempt, never a sticky banner.
    @MainActor
    func testSuccessfulAddClearsThePreviousRejection() throws {
        let dev = fixtureHome.appendingPathComponent("dev")
        try mkdir(dev)
        let (viewModel, _) = try makeViewModel()

        viewModel.addDevRoot("/")
        XCTAssertNotNil(viewModel.devRootRejection)
        viewModel.addDevRoot(dev.path)
        XCTAssertNil(viewModel.devRootRejection)

        viewModel.addDevRoot("   ")
        let empty = try XCTUnwrap(viewModel.devRootRejection)
        XCTAssertTrue(empty.contains("Enter a folder path"), empty)
    }

    /// An UNWIRED view model (no reconstruction seam) has no store to mutate
    /// and no factory to rebuild with — the editor reports itself
    /// unavailable and every mutation is an inert no-op, never a fallback to
    /// production defaults.
    @MainActor
    func testEditorIsInertWithoutTheReconstructionSeam() throws {
        let runtime = try SpaceScannerRuntime(
            scanners: [], categories: [], home: fixtureHome,
            provider: FileSystemIdentityProvider()
        )
        let viewModel = CacheoutViewModel(runtime: runtime)

        XCTAssertFalse(viewModel.isDevRootsEditorAvailable)
        XCTAssertTrue(viewModel.devRootRows.isEmpty)
        viewModel.addDevRoot(fixtureHome.appendingPathComponent("dev").path)
        viewModel.removeDevRoot("Documents")
        viewModel.resetDevRootsToDefaults()
        XCTAssertNil(viewModel.devRootRejection)
        XCTAssertNil(defaults.object(forKey: DevRootsStore.devRootsKey))
    }

    // MARK: - Editor rows carry the policy refusal (R16)

    /// A persisted root the policy rejects is never registered and never
    /// walked — and the editor SAYS so on that row instead of implying it is
    /// being scanned.
    @MainActor
    func testRefusedPersistedRootRendersItsRefusalInTheEditor() throws {
        let dev = fixtureHome.appendingPathComponent("dev")
        try mkdir(dev)
        defaults.set(["/", dev.path], forKey: DevRootsStore.devRootsKey)

        let (viewModel, _) = try makeViewModel()
        XCTAssertEqual(viewModel.devRootRows.map(\.declaredPath),
                       ["/", dev.path])

        let refused = try XCTUnwrap(viewModel.devRootRows.first)
        XCTAssertTrue(refused.isRefused)
        XCTAssertEqual(refused.displayPath, "/")
        XCTAssertTrue(
            try XCTUnwrap(refused.issueDetail).contains("refused"),
            "\(String(describing: refused.issueDetail))"
        )
        XCTAssertFalse(try XCTUnwrap(viewModel.devRootRows.last).isRefused)

        // Row identity is POSITIONAL: declared strings are user input and
        // may repeat, so a duplicated path must not collapse two rows.
        let rows = CacheoutViewModel.devRootRows(
            declaredPaths: ["Documents", "Documents"], issues: [],
            home: fixtureHome
        )
        XCTAssertEqual(rows.map(\.id), [0, 1])
    }

    // MARK: - Per-root error display (R12/R16)

    /// The three visible error shapes, through the ONE row derivation the
    /// section renders: a TCC-denied root (with its grant-access
    /// affordance), a policy-refused configured root NAMING the root, and a
    /// whole-value config parse failure with NO path invented.
    func testIssueRowPresentationCoversDeniedRefusedAndPathlessConfig() throws {
        let denied = fixtureHome.appendingPathComponent("Documents")
        let tcc = ScanIssueRowPresentation(
            issue: ScanIssue(
                url: denied, kind: .tccDenied,
                detail: "operation not permitted"
            ),
            home: fixtureHome
        )
        XCTAssertEqual(tcc.location, "~/Documents",
                       "home-collapsed, never a raw fixture path")
        XCTAssertEqual(tcc.label, "access denied by macOS privacy settings")
        XCTAssertTrue(tcc.showsSettingsLink,
                      "a TCC denial has a user-side remedy")
        XCTAssertEqual(tcc.text, "~/Documents — access denied by macOS "
                       + "privacy settings")

        let refused = ScanIssueRowPresentation(
            issue: ScanIssue(
                url: URL(fileURLWithPath: "/"), kind: .containerRefused,
                detail: "configured dev root refused: …"
            ),
            home: fixtureHome
        )
        XCTAssertEqual(refused.location, "/", "the row NAMES the root")
        XCTAssertEqual(refused.label, "not a configured search root")
        XCTAssertFalse(refused.showsSettingsLink,
                       "no settings link that cannot help")

        let parse = ScanIssueRowPresentation(
            issue: ScanIssue(
                url: nil, kind: .configInvalid,
                detail: "\(DevRootsStore.devRootsKey) is not an array of strings"
            ),
            home: fixtureHome
        )
        XCTAssertEqual(parse.location, "Scanner output",
                       "a path-less issue invents no filesystem path")
        XCTAssertEqual(parse.label,
                       "invalid saved configuration — defaults in effect")
        XCTAssertFalse(parse.showsSettingsLink)

        let permission = ScanIssueRowPresentation(
            issue: ScanIssue(
                url: denied, kind: .permissionDenied, detail: "EACCES"
            ),
            home: fixtureHome
        )
        XCTAssertFalse(permission.showsSettingsLink,
                       "a BSD-permission denial has no System Settings remedy")
    }

    /// AN OVER-MOUNTED ROOT SAYS SO, IN THE VISIBLE ROW (PR #459 codex r11,
    /// P2 DISCLOSURE).
    ///
    /// `ScanIssuesBlock` renders `row.text` and relegates `issue.detail` to
    /// a `.help` tooltip, so whatever the KIND maps to is the whole visible
    /// diagnosis. Under `.containerRefused` this row read "not a configured
    /// search root" — false for a root that is registered and admissible —
    /// and named no remedy at all, while the true condition and the fix sat
    /// in the hover text.
    ///
    /// The two kinds are asserted TOGETHER and must differ in both halves:
    /// the mounted row states the condition AND its remedy, and the refusal
    /// row is left exactly as it was, because `DevRootsStore` (a
    /// policy-rejected persisted root) and `ProjectTreeWalker` (a scan-time
    /// admission refusal) still render through it. `EphemeralTempScanner`'s
    /// own `admitSearchRoot` catch was the THIRD such producer until PR #459
    /// codex r13 moved it to `.policyRefusedRoot`; the cell below is that
    /// half.
    func testAMountedRootRowStatesTheConditionAndTheRemedyRefusalRowUnchanged() throws {
        let root = URL(fileURLWithPath: "/private/tmp")
        let mounted = ScanIssueRowPresentation(
            issue: ScanIssue(
                url: root, kind: .mountedVolumeRoot,
                detail: "Shared temp is a mounted volume — not scanned; its "
                    + "contents belong to that volume. "
                    + EphemeralTempScanner.mountRemedy
            ),
            home: fixtureHome
        )
        XCTAssertEqual(mounted.location, "/private/tmp",
                       "the row NAMES the over-mounted root")
        XCTAssertEqual(
            mounted.label, "mounted volume; eject or unmount it, then re-scan"
        )
        XCTAssertEqual(
            mounted.text,
            "/private/tmp — mounted volume; eject or unmount it, then re-scan",
            "the VISIBLE line carries both the condition and the remedy"
        )
        XCTAssertFalse(
            mounted.label.contains("not a configured search root"),
            "the root IS configured — that sentence was the defect"
        )
        XCTAssertFalse(mounted.showsSettingsLink,
                       "Full Disk Access cannot unmount a volume")

        // The OTHER producers of `.containerRefused` are untouched: same
        // kind, same fixed label as before this change.
        let refusal = ScanIssueRowPresentation(
            issue: ScanIssue(
                url: root, kind: .containerRefused, detail: "refused: …"
            ),
            home: fixtureHome
        )
        XCTAssertEqual(refusal.label, "not a configured search root")
        XCTAssertNotEqual(refusal.label, mounted.label,
                          "two conditions, two sentences")

        // ONE CONDITION, TWO REMEDIES (PR #459 codex r15). The mount can
        // also be standing when the app STARTS, in which case fn-6.1 refuses
        // the root before registering it — a verdict made once per runtime
        // and replayed from stored resolution issues, so the row above's
        // "then re-scan" would send the user round a loop that never clears
        // it. Same condition, different kind, and the labels must differ in
        // exactly that half.
        let atRegistration = ScanIssueRowPresentation(
            issue: ScanIssue(
                url: root, kind: .mountedVolumeRootAtRegistration,
                detail: "Shared temp is a mounted volume — the root was not "
                    + "registered, so nothing under it is scanned; its "
                    + "contents belong to that volume. "
                    + EphemeralTempRoots.registrationMountRemedy
            ),
            home: fixtureHome
        )
        XCTAssertEqual(
            atRegistration.label,
            "mounted volume at launch; unmount it, then relaunch"
        )
        XCTAssertEqual(
            atRegistration.text,
            "/private/tmp — mounted volume at launch; unmount it, "
                + "then relaunch"
        )
        XCTAssertFalse(
            atRegistration.label.contains("re-scan"),
            "a re-scan cannot clear a verdict made once per runtime"
        )
        XCTAssertNotEqual(atRegistration.label, mounted.label,
                          "one condition, two remedies, two sentences")
        XCTAssertFalse(atRegistration.showsSettingsLink,
                       "Full Disk Access cannot unmount a volume")
    }

    /// THE SIBLINGS OF THAT SAME DEFECT (PR #459 codex r13, P2 DISCLOSURE) —
    /// asserted on the SAME derivation, `ScanIssueRowPresentation`, which is
    /// the whole visible diagnosis because `ScanIssuesBlock` renders
    /// `row.text` and hangs `issue.detail` off `.help(…)`.
    ///
    /// Two kinds whose fixed label was untrue for a producer:
    ///
    /// - `.symlinkRoot` reads "symlinked — not searched", but
    ///   `EphemeralTempScanner`'s no-follow root gate emitted it for EVERY
    ///   non-directory — a regular file, FIFO, socket or device sent the
    ///   user hunting for a link that is not there. Now `.nonDirectoryRoot`.
    /// - `.containerRefused` reads "not a configured search root", but that
    ///   scanner constructs its `PathGuard` with
    ///   `containerRoots: roots.map(\.url)` and then iterates those same
    ///   roots, so the root reaching its `admitSearchRoot` catch is ALWAYS
    ///   configured. Now `.policyRefusedRoot`.
    ///
    /// Both halves are pinned in both directions: the new labels are exact,
    /// and the two OLD kinds still render exactly what they rendered before
    /// — `.symlinkRoot` is still produced by four other call sites
    /// (`EphemeralTempRoots`, `DevRootsStore`, `ProjectTreeWalker`,
    /// `OrphanedCachesScanner`) and `.containerRefused` by two
    /// (`DevRootsStore`, `ProjectTreeWalker`).
    func testNonDirectoryAndPolicyRefusedRootsGetTheirOwnVisibleSentences() throws {
        let root = URL(fileURLWithPath: "/private/tmp")

        let nonDirectory = ScanIssueRowPresentation(
            issue: ScanIssue(
                url: root, kind: .nonDirectoryRoot,
                detail: "Shared temp is not a real directory (special file) "
                    + "— never traversed"
            ),
            home: fixtureHome
        )
        XCTAssertEqual(nonDirectory.location, "/private/tmp",
                       "the row NAMES the root")
        XCTAssertEqual(nonDirectory.label, "not a directory — not searched")
        XCTAssertEqual(
            nonDirectory.text, "/private/tmp — not a directory — not searched"
        )
        XCTAssertFalse(
            nonDirectory.label.contains("symlink"),
            "a FIFO/socket/device/regular file is not a symlink — asserting "
                + "one was the defect"
        )
        XCTAssertFalse(nonDirectory.showsSettingsLink,
                       "Full Disk Access cannot turn a FIFO into a directory")

        let policyRefused = ScanIssueRowPresentation(
            issue: ScanIssue(
                url: root, kind: .policyRefusedRoot,
                detail: "Refusing to touch the home directory: /private/tmp"
            ),
            home: fixtureHome
        )
        XCTAssertEqual(policyRefused.location, "/private/tmp")
        XCTAssertEqual(policyRefused.label,
                       "refused by the search-root safety policy")
        XCTAssertEqual(
            policyRefused.text,
            "/private/tmp — refused by the search-root safety policy"
        )
        XCTAssertFalse(
            policyRefused.label.contains("not a configured search root"),
            "the root IS configured — that sentence was the defect"
        )
        XCTAssertFalse(policyRefused.showsSettingsLink,
                       "no settings link that cannot help")

        // THE OTHER PRODUCERS ARE UNCHANGED: same kind, same fixed label as
        // before this split, and each label distinct from its new sibling.
        let symlink = ScanIssueRowPresentation(
            issue: ScanIssue(
                url: root, kind: .symlinkRoot, detail: "is a symlink"
            ),
            home: fixtureHome
        )
        XCTAssertEqual(symlink.label, "symlinked — not searched")
        XCTAssertNotEqual(symlink.label, nonDirectory.label,
                          "two conditions, two sentences")

        let refused = ScanIssueRowPresentation(
            issue: ScanIssue(
                url: root, kind: .containerRefused, detail: "refused: …"
            ),
            home: fixtureHome
        )
        XCTAssertEqual(refused.label, "not a configured search root")
        XCTAssertNotEqual(refused.label, policyRefused.label,
                          "two conditions, two sentences")
    }

    /// END TO END through the REAL scanner: a policy-rejected persisted root
    /// and a corrupt stored value both reach the GUI section as VISIBLE
    /// issue rows — never a zero-byte item row, never an empty section.
    @MainActor
    func testRefusedAndCorruptConfigSurfaceAsSectionIssuesNotZeroByteRows()
        async throws
    {
        // A corrupt ARRAY SHAPE with a dangerous string hiding inside it:
        // the whole value fails to parse (seeds take effect, unrewritten)
        // and the `/` inside it never reaches the kept set.
        defaults.set([true, "/"], forKey: DevRootsStore.devRootsKey)
        let resolution = makeStore().effectiveRoots(home: fixtureHome)
        XCTAssertEqual(resolution.issues.map(\.kind), [.configInvalid])
        XCTAssertFalse(resolution.keptRoots.contains {
            $0.path == "/"
        }, "the dangerous string inside a corrupt array never survives")

        let scanner = BuildArtifactsScanner(
            home: fixtureHome,
            devRoots: DevRootsResolution(
                keptRoots: resolution.keptRoots,
                issues: resolution.issues + [ScanIssue(
                    url: URL(fileURLWithPath: "/"), kind: .containerRefused,
                    detail: "configured dev root refused: filesystem root"
                )]
            ),
            provider: FileSystemIdentityProvider()
        )
        let runtime = try SpaceScannerRuntime(
            scanners: [scanner], categories: [], home: fixtureHome,
            provider: FileSystemIdentityProvider()
        )
        let viewModel = CacheoutViewModel(runtime: runtime)
        await viewModel.scan(trigger: .userInitiated)

        let section = try XCTUnwrap(viewModel.perItemSections.first)
        XCTAssertEqual(section.scannerID, BuildArtifactsScanner.registeredID)
        XCTAssertTrue(section.items.isEmpty,
                      "no items — and therefore no zero-byte row to mistake "
                          + "for 'nothing there'")
        XCTAssertTrue(viewModel.hasDisplayableScanOutput,
                      "an issue-only outcome MUST render")

        let kinds = section.issues.map(\.kind)
        XCTAssertTrue(kinds.contains(.configInvalid), "\(kinds)")
        XCTAssertTrue(kinds.contains(.containerRefused), "\(kinds)")
        let rows = section.issues.map {
            ScanIssueRowPresentation(issue: $0, home: fixtureHome)
        }
        XCTAssertTrue(rows.contains { $0.location == "Scanner output" })
        XCTAssertTrue(rows.contains {
            $0.location == "/" && $0.label == "not a configured search root"
        })
    }
}

// MARK: - Fixture machinery

/// A tiny per-item scanner over one container: one SELECTABLE `.removeItem`
/// item per child, with the container declared as its trusted root — enough
/// to observe destructive-freshness gating (nothing is ever cleaned here).
private struct SelectableFixtureScanner: SpaceScanner {
    let id: String
    let container: URL
    var displayName: String { "Fixture \(id)" }
    var trustedContainerRoots: [URL] { [container] }

    func scan(context: ScanContext) async -> ScanOutcome {
        let children = ((try? FileManager.default.contentsOfDirectory(
            at: container, includingPropertiesForKeys: nil
        )) ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
        return ScanOutcome(
            items: children.map { child in
                ReclaimableItem(
                    id: child.lastPathComponent,
                    scannerID: id,
                    displayName: child.lastPathComponent,
                    exactBytes: 4096,
                    estimatedUpToBytes: 0,
                    logicalBytes: nil,
                    itemCount: 1,
                    url: child,
                    declaredDisplayPath: child.path,
                    rootRecords: [RootScanRecord(
                        requestedURL: child, resolvedURL: child,
                        status: .measured
                    )],
                    state: .measured,
                    scanError: nil,
                    risk: .review,
                    evidence: "fixture item \(child.lastPathComponent)",
                    rebuildNote: nil,
                    action: .removeItem,
                    admission: .containerItem(
                        originContainer: container, requestedTargetURL: child
                    ),
                    defaultSelected: false,
                    automaticCleanEligible: false,
                    isStale: nil
                )
            },
            errors: []
        )
    }
}

/// Marks injected canonical paths as mount roots — the statfs signal,
/// hermetically (the `DevRootsStoreTests` idiom: a real volume root cannot
/// be created inside a fixture directory).
private final class MountPointInjectingProvider: FileSystemIdentityProvider {
    var mountPointPaths: Set<String> = []
    override func isMountPoint(_ url: URL) -> Bool {
        if mountPointPaths.contains(url.path) { return true }
        return super.isMountPoint(url)
    }
}

/// What the injected runtime factory was handed, and how often. Lock-guarded
/// because the factory type is `@Sendable`; every call here is on the
/// MainActor.
private final class FactoryLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [DevRootsResolution] = []

    func record(_ resolution: DevRootsResolution) {
        lock.lock()
        defer { lock.unlock() }
        values.append(resolution)
    }

    var recorded: [DevRootsResolution] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
