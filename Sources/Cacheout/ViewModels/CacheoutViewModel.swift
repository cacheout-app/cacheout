/// # CacheoutViewModel — Main Application State
///
/// The central `@MainActor` view model that manages all application state and
/// coordinates between the scanning, cleaning, and UI layers.
///
/// ## Scanner registry (fn-2.4)
///
/// The twin stacks (`scanResults` + `nodeModulesItems` with duplicate
/// selection/total/clean helpers) are gone. The view model consumes the
/// `SpaceScannerRuntime`'s PROGRESSIVE VALIDATED EVENT STREAM and keeps ONE
/// selection/totals/clean model over `ReclaimableItem`:
///
/// - `outcomesByScannerID`: each scanner's latest VALIDATED outcome,
///   reconciled per-scanner as events arrive (progressive publishing — the
///   category scanner lands in ~2-5s, slower scanners later).
/// - `selectedItemKeys: Set<ItemKey>`: the one selection surface, keyed by
///   the composite cross-scanner identity. Selection SURVIVES rescans (this
///   fixes a live defect — node_modules items minted `UUID()` ids per scan,
///   so their selection reset on every rescan).
/// - The runtime owns orchestration and validation; this view model owns
///   presentation and reconciliation ONLY — no local TaskGroup, no direct
///   scanner calls, no `validatedOutcome` calls, no downcasts.
///
/// ## Reconciliation contract (epic rounds 5-10)
///
/// - A valid outcome reconciles ONLY its own scanner's entry — other
///   scanners' items and selections are never touched by it.
/// - Previously-emitted keys keep their user-set state, selected AND
///   deselected — an explicit deselection is user intent and a rescan must
///   never resurrect it. `defaultSelected` applies ONLY to a key's FIRST
///   emission in this session.
/// - Selections for VANISHED keys are pruned when the stream COMPLETES,
///   never mid-scan — a selection on scanner A must not vanish because
///   scanner B's event landed first.
/// - A `malformedOutcome` event is fail-closed: nothing published for that
///   scanner, the path-less issue surfaced, previous items and selections
///   RETAINED. Validation itself lives in the runtime, never here.
///
/// ## Selection policies (THREE, deliberately separate — epic contract)
///
/// (a) INITIAL selection = `defaultSelected`, first emission only.
/// (b) Quick Clean / `selectAllSafe` = `automaticCleanEligible && risk ==
///     .safe` on cleanly measured items — `defaultSelected` deliberately NOT
///     consulted (today's selectAllSafe ignores it).
/// (c) Smart-clean is EXCLUSIVELY the CLI's (fn-2.6). The GUI NEVER runs it
///     and never auto-selects review-risk; GUI code is PROHIBITED from
///     invoking the CLI's candidate-order helper.
///
/// `.denied`, `.empty`, and `.missing` items are UNSELECTABLE in every
/// surface — nothing to clean (round 9).
///
/// ## Runtime reconstruction (fn-4.10, R8)
///
/// A dev-roots change REBUILDS the composition. The rebuild goes through an
/// INJECTED `RuntimeReconstruction` seam (a `DevRootsStore` + a
/// `@Sendable (DevRootsResolution) -> SpaceScannerRuntime` factory), never a
/// bare `production(...)` call: this view model receives only a COMPLETED
/// runtime (home, provider, thresholds and categories are unrecoverable from
/// it), so rebuilding by re-deriving production defaults would silently swap
/// an injected composition — a fixture one, in every hermetic test — for the
/// production registry. There is deliberately NO production-only branch: the
/// production convenience initializer (fn-4.5) supplies a factory closing
/// over the production composition and travels the SAME path a fixture
/// factory does.
///
/// Three rules govern the swap:
///
/// - **Session capture.** `scan()` captures the runtime (and its generation)
///   ONCE, before its first suspension, and uses THAT for the whole session
///   — an in-flight scan never continues on a replacement runtime.
/// - **Deferred, latest-value-wins.** A replacement requested while a
///   session is in flight is held as a PENDING resolution (newest request
///   wins, collapsing many Settings edits into one rebuild) and applied at
///   session end, before the next session starts.
/// - **Destructive-freshness invalidation.** The adopted (items, snapshot)
///   tuple records the RUNTIME generation that produced it; every
///   destructive path stays gated (the fn-3.4 freshness gate) until a scan
///   from the NEW runtime completes and adopts — `clean()` can never pair a
///   new runtime's cleaner (and its revalidator registry) with an old
///   runtime's snapshot.
///
/// ## Persistence
///
/// User preferences are stored in `UserDefaults` via `didSet` observers:
/// `scanIntervalMinutes`, `lowDiskThresholdGB`, `launchAtLogin`,
/// `moveToTrash`. Untouched by unification, as are Docker prune, disk info,
/// and the memory subsystem.

import Foundation
import SwiftUI

// `ScanTrigger` lives in Scanner/SpaceScanner.swift (fn-2.1): the scanner
// layer consumes it via `ScanContext`, so the declaration must not live in
// this SwiftUI-importing file.

// MARK: - Presentation row models

/// One category aggregate presented through the UNCHANGED `CategoryRow`
/// inputs (fn-2.4): the row still consumes a `ScanResult`, rebuilt from the
/// aggregate `ReclaimableItem`'s carried category + state + components, with
/// `isSelected` projected from the one selection set. List identity is the
/// composite `key`, never `ScanResult.id` (a per-launch category UUID).
struct CategoryRowModel: Identifiable {
    let key: ItemKey
    let result: ScanResult
    var id: ItemKey { key }
}

/// One disclosed release artifact inside a confirmation row's item (fn-4.6,
/// R3): what the sheet SHOWS, derived from fn-4.4's structured
/// `DetectedValuable` — never re-probed, never re-sorted, never parsed out of
/// an evidence string.
///
/// The rendered date DERIVES from the `ValuableIdentity` integers (no `Date`
/// exists in the identity path); the wire-only identity fields
/// (`device`/`inode`) are deliberately NOT rendered — they are token and
/// wire material, not human evidence.
struct ConfirmationValuableRowModel: Identifiable, Equatable {
    /// Basename as discovered.
    let name: String
    let formattedSize: String
    /// Human modification date, derived from the identity integers.
    let formattedModified: String
    /// The UNRESOLVED display spelling — reveal-in-Finder's only input
    /// (`DetectedValuable.displayURL`). The canonical identity path is
    /// wire/token material and is never revealed or rendered.
    let revealURL: URL
    /// List identity: the canonical identity path — unique per valuable
    /// within an item by construction (it is the dedupe key of the
    /// disclosure's canonical order).
    let identityPath: String
    var id: String { identityPath }
}

/// One selected item in the clean-confirmation sheet's UNIFIED itemization
/// (fn-2.5): category aggregates and per-item scanner rows flow through ONE
/// row shape, and every row carries its item's `evidence` string — evidence
/// is first-class in the sheet (epic contract; the surface fn-3/fn-4/fn-5
/// deletion safety rests on). List identity is the composite `key`.
struct ConfirmationRowModel: Identifiable {
    let key: ItemKey
    /// SF Symbol — the registered category icon for aggregates, a generic
    /// container icon for per-item scanner rows.
    let icon: String
    /// Aggregates: the category name; per-item rows: "scanner: item"
    /// (preserves the pre-unification "node_modules: <project>" labelling).
    let label: String
    let formattedSize: String
    /// Rendered under the row verbatim. Aggregates carry description-grade
    /// evidence (the category description) — honest, never padded.
    let evidence: String
    /// The item's DISCLOSED release artifacts (fn-4.4), in their STORED
    /// canonical order — consumed as-is (R3: no re-derivation, no re-probe,
    /// no re-sort at sheet time). Empty for every item that discloses none,
    /// which renders exactly as it always did.
    let valuables: [ConfirmationValuableRowModel]
    /// Non-nil when the item's release-artifact inspection did NOT finish
    /// (R17's uniform incomplete rule). The row STAYS VISIBLE in this
    /// blocked/warning state with rescan guidance — selection is deliberately
    /// unchanged, because `confirmationRows` derives live from the selection
    /// and deselecting would hide the very warning the user must see — while
    /// the confirm ACTION filters this key out of BOTH the authorization
    /// context and the clean set.
    let blockedReason: String?
    var isBlocked: Bool { blockedReason != nil }
    var id: ItemKey { key }
}

/// One declared dev root in the Settings editor (fn-4.6, R8/R16). Pure
/// presentation over `DevRootsStore`'s declared list plus the resolution's
/// classified issues — SwiftUI renders this and nothing else.
struct DevRootRowModel: Identifiable, Equatable {
    /// Position in the declared list — LIST IDENTITY: declared strings are
    /// user input and can repeat, so the path is not a safe id.
    let index: Int
    /// The exact declared string persisted (what `remove` takes).
    let declaredPath: String
    /// Home-collapsed spelling for display only.
    let displayPath: String
    /// Non-nil when the shared container-root policy REFUSED this persisted
    /// root: it is never registered and never walked, and the row says so
    /// instead of pretending it is being scanned (R16).
    let issueDetail: String?
    var isRefused: Bool { issueDetail != nil }
    var id: Int { index }
}

/// A dev-root INPUT-FORM refusal (fn-4.6): the path the user typed is not a
/// supported spelling. Distinct from a POLICY refusal, which comes from the
/// shared container-root policy and carries its own reason.
struct DevRootInputRefusal: Error, Equatable {
    let message: String
}

/// One per-item scanner's section (every scanner except the aggregate
/// category adapter): header identity, its items in outcome order, its
/// root/scanner-level issues (including a synthesized `malformedOutcome`
/// issue when the last event was malformed), and its pending state.
struct ScannerSectionModel: Identifiable {
    let scannerID: String
    let displayName: String
    let items: [ReclaimableItem]
    let issues: [ScanIssue]
    let isScanning: Bool
    /// Whether this scanner has an entry in `outcomesByScannerID` — i.e.
    /// whether it has published a validated outcome at all this session. A
    /// scanner that RAN and found nothing publishes an EMPTY outcome, so
    /// this is false only for one that has never been inspected.
    let hasPublishedOutcome: Bool
    var id: String { scannerID }

    /// "Select Stale" renders only where staleness applies to at least one
    /// item (`isStale == nil` = control hidden/inapplicable).
    var supportsStaleness: Bool { items.contains { $0.isStale != nil } }

    /// NEVER INSPECTED, as distinct from INSPECTED AND FOUND NOTHING
    /// (PR #459 codex r11, DISCLOSURE). `items` and `issues` both fall back
    /// to `[]` when no outcome exists (`CacheoutViewModel.items(forScanner:)`
    /// / `issues(forScanner:)`), so an empty section on its own cannot tell
    /// the two apart — and the ephemeral temp scanner sits in exactly that
    /// state from launch until the user presses Scan, because
    /// `EphemeralTempScanner.participates(in:)` returns
    /// `context.includeProtectedRoots` and a non-participating scanner
    /// publishes NO outcome (deliberately — that is what keeps an automatic
    /// refresh from erasing prior findings and ticks).
    ///
    /// Three clauses, each load-bearing:
    /// - `!hasPublishedOutcome` — an outcome ever published means the
    ///   answer is known, and "nothing" is then a real finding.
    /// - `!isScanning` — a first scan IN FLIGHT has its own spinner; this
    ///   state is about the absence of a scan, not its progress.
    /// - `issues.isEmpty` — a scanner whose only event was
    ///   `malformedOutcome` has no outcome but DOES have a visible issue
    ///   (`malformedIssuesByScannerID`), and that is not silence.
    ///
    /// `items.isEmpty` is IMPLIED by `!hasPublishedOutcome` and is
    /// deliberately not restated: a clause no mutation can falsify is not a
    /// guard.
    var isAwaitingFirstScan: Bool {
        !hasPublishedOutcome && !isScanning && issues.isEmpty
    }

    /// Whether `ContentView` renders this section at all — HOISTED out of
    /// the view body (PR #459 codex r11) so the visibility rule is
    /// assertable: SwiftUI bodies are assertion-dead, and this predicate is
    /// what decides whether the not-yet-scanned disclosure reaches the user
    /// at all.
    ///
    /// The first three clauses are the as-built gate, verbatim; the fourth
    /// is the fix. A section that HAS been scanned and holds nothing stays
    /// hidden exactly as before — silence still means "looked, found
    /// nothing", and it no longer also means "never looked".
    var isDisplayed: Bool {
        !items.isEmpty || isScanning || !issues.isEmpty || isAwaitingFirstScan
    }

    /// The header's parenthetical. "0 found" is an AFFIRMATIVE claim about a
    /// completed inspection, so a never-inspected section must not make it.
    var headerCountLabel: String {
        isAwaitingFirstScan ? "not scanned yet" : "\(items.count) found"
    }
}

@MainActor
class CacheoutViewModel: ObservableObject {

    // MARK: - Unified scan state (fn-2.4)

    /// Each scanner's latest VALIDATED outcome. A malformed event never
    /// lands here — the previous outcome is retained (fail-closed).
    @Published private(set) var outcomesByScannerID: [String: ScanOutcome] = [:]

    /// THE selection surface — composite `ItemKey`s only (a bare item id is
    /// unique only within one scanner and is never a key here).
    @Published private(set) var selectedItemKeys: Set<ItemKey> = []

    /// Scanners whose event has not arrived in the current scan. Replaces
    /// the split `isScanning`/`isNodeModulesScanning` with per-scanner
    /// state. Internal-settable so tests can pin mid-scan windows.
    ///
    /// DISPLAY state only (PR #456 P2): the set empties the moment the
    /// LAST event is handled, while `scan()` is still suspending toward
    /// snapshot adoption — the re-entrancy guard is `activeScanGeneration`,
    /// which covers that tail. Derivations must read `isAnyScanInProgress`,
    /// never this set's emptiness.
    @Published var scanningScannerIDs: Set<String> = []

    /// The synthesized path-less issue for a scanner whose LAST event was
    /// `malformedOutcome` — surfaced beside the retained previous items,
    /// cleared when a valid outcome arrives (fail-closed disposition).
    @Published private(set) var malformedIssuesByScannerID: [String: ScanIssue] = [:]

    /// Each scanner's ever-emitted key set for THIS session. `defaultSelected`
    /// applies only to keys absent from here (first emission ever);
    /// previously-emitted keys keep their user-set state across rescans.
    /// Deliberately never pruned: a vanished-then-reappearing key was still
    /// emitted this session, so it does not re-enroll in initial selection.
    private var emittedKeysByScannerID: [String: Set<ItemKey>] = [:]

    @Published var isCleaning = false
    @Published var diskInfo: DiskInfo?
    @Published var showCleanConfirmation = false
    @Published var showCleanupReport = false
    @Published var lastReport: CleanupReport?
    @Published var moveToTrash = true

    /// Increments on every completed scan — views can use .task(id:) to react
    @Published var scanGeneration: Int = 0

    /// Whether at least one scan has completed. Unlike `hasResults`, this
    /// stays `true` even if the scan found zero items, preventing redundant
    /// re-scans when switching tabs.
    @Published var hasScanned = false

    /// When the last scan completed
    @Published var lastScanDate: Date?

    /// User-configurable scan interval in minutes (persisted in UserDefaults)
    @Published var scanIntervalMinutes: Double {
        didSet { UserDefaults.standard.set(scanIntervalMinutes, forKey: "cacheout.scanIntervalMinutes") }
    }

    /// Low-disk notification threshold in GB (persisted in UserDefaults)
    @Published var lowDiskThresholdGB: Double {
        didSet { UserDefaults.standard.set(lowDiskThresholdGB, forKey: "cacheout.lowDiskThresholdGB") }
    }

    /// Whether to launch at login (persisted in UserDefaults)
    @Published var launchAtLogin: Bool {
        didSet { UserDefaults.standard.set(launchAtLogin, forKey: "cacheout.launchAtLogin") }
    }

    /// True while a scan SESSION is in flight (R11): from `scan()`'s
    /// invocation until its snapshot adoption (or cancelled wind-down) —
    /// NOT merely while scanner events are pending. The last event empties
    /// `scanningScannerIDs` while `scan()` is still suspending toward
    /// adoption; releasing the guard there let a second scan interleave,
    /// mutate the shared session counter, and mis-pair items with a
    /// snapshot their session did not capture (PR #456 P2). Scan/clean
    /// controls and model guards must cover the WHOLE window — the category
    /// scanner finishes in seconds while node_modules can run 10-30s longer,
    /// and a clean must never act on a half-built result set.
    /// (`scanningScannerIDs` is OR-ed in so tests can still pin mid-scan
    /// windows by seeding per-scanner pending state directly.)
    var isAnyScanInProgress: Bool {
        activeScanGeneration != nil || !scanningScannerIDs.isEmpty
    }

    /// Whether the menubar should trigger an auto-rescan (no results or stale data)
    var shouldAutoRescan: Bool {
        if isAnyScanInProgress || isCleaning { return false }
        if !hasResults { return true }
        guard let last = lastScanDate else { return true }
        return Date().timeIntervalSince(last) > scanIntervalMinutes * 60
    }

    /// The ONE composition source (fn-2.1): scanner instances + the cleaner
    /// configuration derived from them. Because `clean()` uses the
    /// runtime-constructed cleaner, a registered scanner's
    /// `trustedContainerRoots` reach delete-time admission with ZERO view
    /// model edits (R4).
    ///
    /// A `var` since fn-4.10: a dev-roots change REBUILDS it through the
    /// injected factory (below). Every reader that must not straddle a
    /// rebuild captures it first — `scan()` takes ONE session capture before
    /// its first suspension; the display derivations (`orderedScannerIDs`,
    /// `perItemSections`) read the composition IN FORCE on purpose, and the
    /// destructive paths are gated by the runtime generation until a scan
    /// from the new composition adopts.
    private var runtime: SpaceScannerRuntime

    // MARK: Session provenance & snapshot pairing (fn-3.4, R9)

    /// The container-identity snapshot of the last COMPLETED scan session —
    /// adopted atomically WITH that session's freshness set (below), so a
    /// mid-scan snapshot can never pair old retained items with a new
    /// container identity. `clean()` builds its cleaner from THIS; nil (no
    /// completed session yet) fail-closes every `.removeItem` deletion.
    private var adoptedSnapshot: ContainerSnapshot?

    /// Monotonic scan-session counter: bumped when `scan()` starts. Each
    /// invocation immediately captures its OWN value as an immutable local
    /// generation and threads THAT through event handling and adoption
    /// (PR #456 P2) — the shared counter is never read again mid-session,
    /// so a later session's start cannot re-stamp an in-flight session's
    /// events or pair its generation with another session's snapshot.
    private var sessionGeneration = 0
    /// The in-flight session's generation — the RE-ENTRANCY guard `scan()`
    /// checks (via `isAnyScanInProgress`). Held from invocation through
    /// snapshot adoption (or the cancelled path's producer wind-down),
    /// deliberately NOT derived from `scanningScannerIDs` emptiness: the
    /// last event empties that set while the session is still suspending
    /// toward adoption. Keyed by generation so only the OWNING session's
    /// epilogue can clear it — one session's completion can never release
    /// another's guard. Every transition co-publishes via a
    /// `scanningScannerIDs` assignment in the same MainActor step, so
    /// SwiftUI readers of `isAnyScanInProgress` stay notified.
    private var activeScanGeneration: Int?
    /// The generation whose snapshot `adoptedSnapshot` is — set at scan
    /// COMPLETION, never mid-scan.
    private var adoptedGeneration = 0
    /// Per-scanner session provenance: the generation in which each scanner
    /// last delivered a VALID outcome (a malformed event deliberately
    /// clears it). An item is CLEANABLE only when its scanner's provenance
    /// equals the adopted generation — fn-2's retention rules keep items
    /// the latest session did NOT produce (malformed retention, an
    /// undelivered scanner after early termination), and those retained
    /// rows stay VISIBLE but must never pair with a snapshot their session
    /// did not capture (fail-closed; cleanability returns when the scanner
    /// succeeds in a completed session).
    private var outcomeGenerationByScannerID: [String: Int] = [:]

    // MARK: Runtime reconstruction (fn-4.10, R8)

    /// The INJECTED runtime-reconstruction seam: everything a dev-roots
    /// change needs to rebuild the composition it was given, and nothing
    /// else. Bundled as ONE value so the seam can never be half-wired (a
    /// store without a factory would silently ignore Settings edits).
    ///
    /// Both members are injected by the composing initializer: fn-4.5's
    /// production convenience initializer closes the factory over the
    /// production composition; hermetic tests close it over fixture
    /// runtimes. The ViewModel calls it the same way for both.
    struct RuntimeReconstruction {
        /// The persisted dev-roots config (fn-4.1). Re-RESOLVED on every
        /// change request, so the Settings surface owns mutation and this
        /// view model owns only reconstruction.
        let devRootsStore: DevRootsStore
        /// The home the store resolves declared roots against (the store
        /// takes it per call — the injectable-home house rule).
        let home: URL
        /// THE factory: one dev-roots resolution in, one complete runtime
        /// out. `@Sendable` because the composition it closes over must be
        /// safe to hold beyond the initializer that built it.
        let makeRuntime: @Sendable (DevRootsResolution) -> SpaceScannerRuntime

        init(
            devRootsStore: DevRootsStore,
            home: URL,
            makeRuntime:
                @escaping @Sendable (DevRootsResolution) -> SpaceScannerRuntime
        ) {
            self.devRootsStore = devRootsStore
            self.home = home
            self.makeRuntime = makeRuntime
        }
    }

    /// nil = the seam is UNWIRED: the injected runtime is the whole story
    /// and `devRootsDidChange()` is a no-op (every pre-fn-4.5 call site,
    /// including the hermetic suites that inject a finished fixture
    /// runtime). Nothing here ever falls back to production defaults.
    private let reconstruction: RuntimeReconstruction?

    /// Monotonic RUNTIME-COMPOSITION counter — a SECOND AXIS beside the
    /// session machinery above, deliberately NOT a parallel session counter:
    /// it counts runtime replacements, is incremented at the ONE factory
    /// call site (`installRuntime`), is captured beside `sessionGeneration`
    /// as an immutable local by `scan()`, is adopted in the SAME atomic step
    /// as the snapshot, and is compared inside the ONE existing freshness
    /// gate (`isBlockedFromDestructivePaths`). Session pairing still rides
    /// `sessionGeneration`/`adoptedGeneration` exactly as before.
    private var runtimeGeneration = 0

    /// The RUNTIME generation that produced the adopted (items, snapshot)
    /// tuple — recorded at COMPLETION in the same MainActor step as
    /// `adoptedSnapshot`/`adoptedGeneration`, from the SESSION's captured
    /// value (never the live counter, which a session-end replacement may
    /// already have advanced). While it differs from `runtimeGeneration`,
    /// no adopted result belongs to the composition `clean()` would build
    /// its cleaner from, so every destructive path is fail-closed.
    private var adoptedRuntimeGeneration = 0

    /// The DEFERRED replacement: the newest dev-roots resolution requested
    /// while a session was in flight. LATEST-VALUE-WINS — many Settings
    /// edits during one scan collapse to ONE rebuild, applied at session end
    /// (before the next session starts), so an in-flight scan is never
    /// disturbed and no intermediate composition is ever built.
    private var pendingDevRoots: DevRootsResolution?

    /// - Parameter runtime: injectable for hermetic tests (fixture scanners
    ///   and homes — zero real-`$HOME` reads); production uses the one
    ///   production registry. This injection seam is what fn-2.7's zero-edit
    ///   extensibility proof exercises.
    /// - Parameter reconstruction: the fn-4.10 runtime-reconstruction seam
    ///   (nil = unwired, see above). When wired, `runtime` should be the
    ///   composition its OWN factory produced for the current resolution —
    ///   the initial runtime and every rebuilt one then come from the same
    ///   source.
    init(
        runtime: SpaceScannerRuntime = .production(),
        reconstruction: RuntimeReconstruction? = nil
    ) {
        self.runtime = runtime
        self.reconstruction = reconstruction

        let storedInterval = UserDefaults.standard.double(forKey: "cacheout.scanIntervalMinutes")
        self.scanIntervalMinutes = storedInterval > 0 ? storedInterval : 30

        let storedThreshold = UserDefaults.standard.double(forKey: "cacheout.lowDiskThresholdGB")
        self.lowDiskThresholdGB = storedThreshold > 0 ? storedThreshold : 10

        self.launchAtLogin = UserDefaults.standard.bool(forKey: "cacheout.launchAtLogin")

        // The Settings dev-roots editor renders from persisted state, so its
        // rows exist from construction (fn-4.6). Empty — and untouched —
        // while the reconstruction seam is unwired: there is no store to
        // read and nothing the editor could mutate.
        refreshDevRootRows()
    }

    /// THE PRODUCTION COMPOSITION (fn-4.5) — the app's one construction site
    /// (`CacheoutApp`), and the piece fn-4.10's seam was built to receive.
    ///
    /// One factory closes over the production composition inputs
    /// (home/provider → `SpaceScannerRuntime.production(devRoots:)`, which
    /// owns the categories, thresholds, and scanner list). It builds BOTH
    /// the INITIAL runtime and every rebuilt one, so the composition can
    /// never drift across a Settings-triggered rebuild — and the rebuild
    /// path is the SAME one hermetic tests drive with fixture factories (no
    /// production-only branch anywhere).
    ///
    /// Dev roots are read from the persisted store HERE, at construction
    /// (D1): `trustedContainerRoots` freeze at registration, so a roots
    /// change means a new runtime, never a mutation of this one.
    ///
    /// - Parameters:
    ///   - home: the home the whole composition anchors to (injectable —
    ///     the house rule; production takes the account home).
    ///   - provider: identity provider shared by every composed piece.
    ///   - devRootsStore: the persisted dev-roots config the factory
    ///     re-resolves on every change request (injectable suite in tests).
    static func production(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        provider: FileSystemIdentityProvider = FileSystemIdentityProvider(),
        devRootsStore: DevRootsStore? = nil
    ) -> CacheoutViewModel {
        let store = devRootsStore ?? DevRootsStore(provider: provider)
        let makeRuntime: @Sendable (DevRootsResolution) -> SpaceScannerRuntime = {
            devRoots in
            .production(home: home, provider: provider, devRoots: devRoots)
        }
        return CacheoutViewModel(
            // The initial runtime comes from the SAME factory the rebuild
            // path uses — one source, so the first composition and every
            // later one are identical apart from their dev roots.
            runtime: makeRuntime(store.effectiveRoots(home: home)),
            reconstruction: RuntimeReconstruction(
                devRootsStore: store, home: home, makeRuntime: makeRuntime
            )
        )
    }

    // MARK: - Item access

    /// Registry order — the stable presentation order for sections and for
    /// the items handed to `clean()`.
    private var orderedScannerIDs: [String] { runtime.scanners.map(\.id) }

    func items(forScanner id: String) -> [ReclaimableItem] {
        outcomesByScannerID[id]?.items ?? []
    }

    func issues(forScanner id: String) -> [ScanIssue] {
        outcomesByScannerID[id]?.errors ?? []
    }

    func item(for key: ItemKey) -> ReclaimableItem? {
        outcomesByScannerID[key.scannerID]?.items.first { $0.id == key.itemID }
    }

    /// True while `scannerID`'s LATEST rescan was rejected as malformed OR
    /// while its displayed outcome was not produced by the session whose
    /// snapshot the cleaner would hold (the fn-3.4 freshness gate, R9) OR
    /// while the RUNTIME has been rebuilt since that adoption (fn-4.10, R8).
    /// The fail-closed disposition retains the previous items and selections
    /// for DISPLAY (epic contract — nothing user-set is lost), but those
    /// retained records must not reach any DESTRUCTIVE path until the
    /// scanner delivers a valid outcome in a COMPLETED session again
    /// (`reconcile` + session adoption lift the block together).
    ///
    /// The runtime clause is scanner-INDEPENDENT on purpose: after a rebuild
    /// NOTHING adopted belongs to the composition `clean()` would build its
    /// cleaner from, so the whole model is gated until a scan from the new
    /// runtime completes and adopts (`clean()` would otherwise pair the new
    /// runtime's cleaner and revalidator registry with the old runtime's
    /// snapshot).
    private func isBlockedFromDestructivePaths(_ scannerID: String) -> Bool {
        malformedIssuesByScannerID[scannerID] != nil
            || outcomeGenerationByScannerID[scannerID] != adoptedGeneration
            || adoptedRuntimeGeneration != runtimeGeneration
    }

    /// The selected items in presentation order (registry order, then each
    /// outcome's own order) — exactly what `clean()` hands the unified entry
    /// and what the confirmation sheet lists. Scanners whose latest rescan
    /// was rejected as malformed are EXCLUDED: their retained selections
    /// stay visible in the results list but never reach a destructive path.
    var selectedItems: [ReclaimableItem] {
        orderedScannerIDs
            .filter { !isBlockedFromDestructivePaths($0) }
            .flatMap { id in
                items(forScanner: id).filter { selectedItemKeys.contains($0.key) }
            }
    }

    /// The destructive-selection gate for the Clean button and the
    /// confirmation sheet's item count — derived from the gated
    /// `selectedItems`, NOT from `selectedItemKeys`, so retained
    /// selections under a malformed rescan cannot enable or inflate the
    /// clean controls. (`hasSelection`/`selectedCount` stay key-based for
    /// display surfaces that mirror the visible checkmarks.)
    var hasCleanableSelection: Bool { !selectedItems.isEmpty }

    var cleanableSelectedCount: Int { selectedItems.count }

    var selectedCount: Int { selectedItemKeys.count }

    var hasResults: Bool {
        outcomesByScannerID.values.contains { !$0.items.isEmpty }
    }

    /// What the results list gates on: items OR classified issues OR a
    /// malformed-outcome surface. An issue-only scan (every root denied,
    /// zero items) and a first-event malformed scanner both MUST render —
    /// a denied search root is information, never an empty state (R14/D6),
    /// and a fail-closed refusal is only fail-closed if it is visible.
    var hasDisplayableScanOutput: Bool {
        hasResults
            || outcomesByScannerID.values.contains { !$0.errors.isEmpty }
            || !malformedIssuesByScannerID.isEmpty
    }

    var hasSelection: Bool { !selectedItemKeys.isEmpty }

    // MARK: - Derived rows (views render these, logic stays testable here)

    /// Category aggregates through the UNCHANGED `CategoryRow` shape. The
    /// aggregate item's admission descriptor carries the registered
    /// `CacheCategory`, so the row model rebuilds fn-1.4's exact inputs;
    /// selection projects from `selectedItemKeys`.
    var categoryRows: [CategoryRowModel] {
        items(forScanner: CategoryScanner.registeredID).compactMap { item in
            guard case .category(let category) = item.admission else {
                // Category-scanner items always carry category provenance
                // (runtime-validated); anything else is unrenderable here.
                return nil
            }
            var result = ScanResult(
                category: category,
                state: item.state,
                exactBytes: item.exactBytes,
                estimatedUpToBytes: item.estimatedUpToBytes,
                itemCount: item.itemCount,
                scanError: item.scanError,
                rootRecords: item.rootRecords
            )
            result.isSelected = selectedItemKeys.contains(item.key)
            return CategoryRowModel(key: item.key, result: result)
        }
    }

    /// The confirmation sheet's unified itemization (fn-2.5): ONE row shape
    /// over `selectedItems` in presentation order — aggregates and per-item
    /// scanner rows through the same derivation, each carrying its evidence
    /// string.
    var confirmationRows: [ConfirmationRowModel] {
        Self.confirmationRows(for: selectedItems)
    }

    /// Pure derivation behind `confirmationRows` — static so XCTest asserts
    /// on it without a runtime (SwiftUI bodies are assertion-dead).
    nonisolated static func confirmationRows(
        for selectedItems: [ReclaimableItem]
    ) -> [ConfirmationRowModel] {
        selectedItems.map { item in
            let icon: String
            let label: String
            switch item.admission {
            case .category(let category):
                // Aggregate rows keep their registered category icon and
                // name (the admission descriptor carries the category —
                // runtime-validated provenance, same source `categoryRows`
                // trusts).
                icon = category.icon
                label = category.name
            case .containerItem:
                icon = "shippingbox.fill"
                label = "\(item.scannerID): \(item.displayName)"
            }
            return ConfirmationRowModel(
                key: item.key,
                icon: icon,
                label: label,
                formattedSize: ByteCountFormatter.sharedFile
                    .string(fromByteCount: item.allocatedBytes),
                evidence: item.evidence,
                valuables: valuableRows(for: item),
                blockedReason: blockedReason(for: item)
            )
        }
    }

    // MARK: Valuables in the sheet (fn-4.6, R3/R17)

    /// The rescan guidance an INCOMPLETE-probed row carries. Absence of
    /// valuables is meaningful only when the inspection actually finished,
    /// so the item is unauthorizable — the row says why and what to do, and
    /// the confirm action skips it.
    nonisolated static let incompleteProbeSheetGuidance =
        "Couldn't fully inspect this folder for release artifacts (.dmg, "
        + ".pkg, .app, …), so it can't be cleaned yet — scan again and "
        + "retry. It will be SKIPPED by this cleanup."

    /// The same row, blocked because the inspection ran out of its ENTRY
    /// BUDGET rather than because something obstructed it. The budget starts
    /// at the folder's own count and DOUBLES until the inspection finishes
    /// (`ValuablesProbeBudget`), so surviving all of it means the folder is
    /// CHANGING while it is read — which a retry genuinely can clear, and a
    /// permissions fix cannot. Two causes, two remedies: telling a user to
    /// "scan again" for an impediment no scan can move is what the retired
    /// fixed budget did, and telling one to wait for a build that is not
    /// running is what a bound derived from a truncated count did (review r8).
    nonisolated static let growingFolderSheetGuidance =
        "This folder is changing faster than it can be inspected for release "
        + "artifacts (.dmg, .pkg, .app, …), so it can't be cleaned yet — let "
        + "the build finish, then scan again. It will be SKIPPED by this "
        + "cleanup."

    /// The item's DISCLOSED valuables as sheet rows — read DIRECTLY off
    /// fn-4.4's structured field in its STORED canonical order (R3): no
    /// re-probe, no filesystem read, no evidence-string parsing, no re-sort.
    /// The reveal click is the sheet's only filesystem touch.
    nonisolated static func valuableRows(
        for item: ReclaimableItem
    ) -> [ConfirmationValuableRowModel] {
        (item.valuablesDisclosure?.valuables ?? []).map { valuable in
            ConfirmationValuableRowModel(
                name: valuable.name,
                formattedSize: ByteCountFormatter.sharedFile
                    .string(fromByteCount: valuable.identity.allocatedBytes),
                formattedModified: formattedModified(valuable.identity),
                revealURL: valuable.displayURL,
                identityPath: valuable.canonicalIdentityPath
            )
        }
    }

    /// The human modification date, DERIVED from the `ValuableIdentity`
    /// integers (fn-4.4: no `Date` exists in the identity path). Out-of-
    /// domain integers — unreachable for anything the validator admitted —
    /// render as unknown rather than as an invented instant.
    nonisolated static func formattedModified(
        _ identity: ValuableIdentity
    ) -> String {
        guard let nanoseconds = identity.modifiedAtNanoseconds else {
            return "modified date unavailable"
        }
        let seconds = Double(nanoseconds)
            / Double(ValuableIdentity.nanosecondsPerSecond)
        return valuableDateFormatter
            .string(from: Date(timeIntervalSince1970: seconds))
    }

    private nonisolated static let valuableDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// Why this row is blocked, or nil. The ONE rule (R17): a probe that
    /// could not finish is unauthorizable and tokenless everywhere. Items
    /// with no valuables model at all (`nil` disclosure — every scanner but
    /// `build_artifacts`) are never blocked.
    nonisolated static func blockedReason(
        for item: ReclaimableItem
    ) -> String? {
        guard let disclosure = item.valuablesDisclosure,
              !disclosure.probeComplete else { return nil }
        return disclosure.incompleteness == .entryBudget
            ? growingFolderSheetGuidance
            : incompleteProbeSheetGuidance
    }

    /// The keys the confirm action must filter out of BOTH the authorization
    /// context and the clean set — exactly the rows rendered blocked above.
    nonisolated static func blockedConfirmationKeys(
        for selectedItems: [ReclaimableItem]
    ) -> Set<ItemKey> {
        Set(selectedItems.filter { blockedReason(for: $0) != nil }.map(\.key))
    }

    /// THE per-clean `[ItemKey: acknowledgement]` AUTHORIZATION CONTEXT the
    /// confirmation sheet's confirm action produces (R17): ONE entry per
    /// DISPLAYED, COMPLETE-probed, valuable-BEARING item, its token computed
    /// from exactly the displayed set — acknowledgement covers precisely what
    /// the user saw and nothing more.
    ///
    /// Items without valuables get NO entry (there is no empty-set token
    /// anywhere), and an INCOMPLETE-probed item gets none either — its token
    /// derivation returns nil by its own precondition, and the caller has
    /// already filtered it out of the clean set.
    nonisolated static func confirmationAuthorization(
        for displayedItems: [ReclaimableItem]
    ) -> PreDeleteAuthorizationContext {
        var context: PreDeleteAuthorizationContext = [:]
        for item in displayedItems {
            guard let disclosure = item.valuablesDisclosure,
                  let token = disclosure.acknowledgementToken(for: item.key)
            else { continue }
            context[item.key] = token
        }
        return context
    }

    /// The authorization context for the CURRENT sheet contents — the
    /// view-model-level assertion surface for R17's "one entry per displayed
    /// complete-probed valuable-bearing item".
    var confirmationAuthorization: PreDeleteAuthorizationContext {
        Self.confirmationAuthorization(for: confirmableSelectedItems)
    }

    /// The sheet's blocked rows (visible, warned, unauthorizable).
    var blockedConfirmationKeys: Set<ItemKey> {
        Self.blockedConfirmationKeys(for: selectedItems)
    }

    /// What the confirm action will ACTUALLY clean: the displayed selection
    /// minus the blocked rows. Selection itself is untouched — only the
    /// action filters.
    var confirmableSelectedItems: [ReclaimableItem] {
        let blocked = blockedConfirmationKeys
        return selectedItems.filter { !blocked.contains($0.key) }
    }

    var confirmableSelectedCount: Int { confirmableSelectedItems.count }

    /// The bytes the confirm action will act on — blocked rows excluded, so
    /// the sheet never quotes a total it will not clean (the same honesty
    /// rule `totalCleanableSelectedSize` encodes for malformed-blocked
    /// scanners).
    var confirmableSelectedSize: Int64 {
        confirmableSelectedItems.reduce(Int64(0)) {
            $0.saturatingAdding($1.allocatedBytes)
        }
    }

    var formattedConfirmableSelectedSize: String {
        ByteCountFormatter.sharedFile
            .string(fromByteCount: confirmableSelectedSize)
    }

    /// The category scanner emits no outcome-level errors by design; this
    /// surfaces only a synthesized `malformedOutcome` (fail-closed, visible).
    var categoryScanIssues: [ScanIssue] {
        var all = issues(forScanner: CategoryScanner.registeredID)
        if let malformed = malformedIssuesByScannerID[CategoryScanner.registeredID] {
            all.append(malformed)
        }
        return all
    }

    /// One generic section per NON-category scanner, in registry order —
    /// the node_modules section generalized (fn-2.4).
    var perItemSections: [ScannerSectionModel] {
        runtime.scanners
            .filter { $0.id != CategoryScanner.registeredID }
            .map { scanner in
                var issues = issues(forScanner: scanner.id)
                if let malformed = malformedIssuesByScannerID[scanner.id] {
                    issues.append(malformed)
                }
                return ScannerSectionModel(
                    scannerID: scanner.id,
                    displayName: scanner.displayName,
                    items: items(forScanner: scanner.id),
                    issues: issues,
                    isScanning: scanningScannerIDs.contains(scanner.id),
                    // THE never-inspected signal (PR #459 codex r11): an
                    // entry exists iff `reconcile` ever ran for this
                    // scanner, and it runs for an EMPTY outcome too — so
                    // absence means "no scan has ever reported", never
                    // "reported nothing".
                    hasPublishedOutcome: outcomesByScannerID[scanner.id] != nil
                )
            }
    }

    // MARK: - Totals (three FROZEN scopes, one shared helper — epic round 6)

    /// THE aggregation helper: every byte total flows through here with
    /// EXPLICIT predicates — scope (which scanners) and inclusion (which
    /// items) as arguments, never copy-pasted loops. SATURATING (round 8):
    /// the validator bounds each outcome's sum individually, but this
    /// helper adds ACROSS scanners, where no per-outcome bound applies —
    /// clamp at Int64.max instead of trapping (byte-identical for every
    /// physically possible total).
    private func aggregateBytes(
        scannerScope: (String) -> Bool,
        include: (ReclaimableItem) -> Bool
    ) -> Int64 {
        var total: Int64 = 0
        for (scannerID, outcome) in outcomesByScannerID where scannerScope(scannerID) {
            for item in outcome.items where include(item) {
                total = total.saturatingAdding(item.allocatedBytes)
            }
        }
        return total
    }

    /// Scope 1 (FROZEN pre-refactor parity): AGGREGATE-CATEGORY items only —
    /// per-item scanners excluded, exactly like the old `scanResults`-only
    /// property. `.denied` contributes nothing by construction; the explicit
    /// filter keeps that true even if a future state carries bytes it cannot
    /// promise (R18). The old `!isEmpty` filter is spelled out as
    /// not-missing + measurable-bytes.
    var totalRecoverable: Int64 {
        aggregateBytes(
            scannerScope: { $0 == CategoryScanner.registeredID },
            include: { $0.state != .missing && $0.state != .denied && $0.allocatedBytes > 0 }
        )
    }

    /// Scope 2: a per-scanner SECTION total stays section-local (the old
    /// `selectedNodeModulesSize`, generalized per scanner id).
    func selectedSize(forScanner id: String) -> Int64 {
        aggregateBytes(
            scannerScope: { $0 == id },
            include: { selectedItemKeys.contains($0.key) }
        )
    }

    func formattedSelectedSize(forScanner id: String) -> String {
        ByteCountFormatter.sharedFile.string(fromByteCount: selectedSize(forScanner: id))
    }

    /// Scope 3: selected bytes across EVERY scanner (the old
    /// `selectedSize + selectedNodeModulesSize`).
    var totalSelectedSize: Int64 {
        aggregateBytes(
            scannerScope: { _ in true },
            include: { selectedItemKeys.contains($0.key) }
        )
    }

    var formattedTotalSelectedSize: String {
        ByteCountFormatter.sharedFile.string(fromByteCount: totalSelectedSize)
    }

    /// NOT a fourth display scope — the DESTRUCTIVE variant of scope 3 the
    /// confirmation sheet quotes: selected bytes excluding scanners blocked
    /// by a malformed rescan, i.e. exactly the bytes `clean()` will act on.
    /// The three frozen scopes above stay key-based (display parity — they
    /// mirror the visible checkmarks, retained rows included).
    var totalCleanableSelectedSize: Int64 {
        aggregateBytes(
            scannerScope: { !isBlockedFromDestructivePaths($0) },
            include: { selectedItemKeys.contains($0.key) }
        )
    }

    var formattedTotalCleanableSelectedSize: String {
        ByteCountFormatter.sharedFile
            .string(fromByteCount: totalCleanableSelectedSize)
    }

    /// Section-header display total (all of one scanner's items — the old
    /// `nodeModulesTotal`); same helper, unfiltered inclusion.
    func totalSize(forScanner id: String) -> Int64 {
        aggregateBytes(scannerScope: { $0 == id }, include: { _ in true })
    }

    func formattedTotalSize(forScanner id: String) -> String {
        ByteCountFormatter.sharedFile.string(fromByteCount: totalSize(forScanner: id))
    }

    /// D8 disclosure shown beside every recoverable/removable total (R8):
    /// APFS clones and cross-category hardlinks make scan totals a ceiling,
    /// not a promise.
    nonisolated var overcountCaveat: String { DiskSpaceCaveat.overcount }

    /// True when the current selection includes a `.partiallyDenied` item —
    /// the confirmation sheet must warn that its size covers measured bytes
    /// only (R18).
    var hasPartiallyDeniedSelection: Bool {
        selectedItems.contains { $0.state == .partiallyDenied }
    }

    /// True when the current selection includes a command-backed item — its
    /// clean commands execute regardless of the Move-to-Trash toggle and
    /// erase permanently, so the confirmation sheet must say so whenever
    /// Trash mode is on (P2).
    var hasCommandBackedSelection: Bool {
        selectedItems.contains { if case .commands = $0.action { return true } else { return false } }
    }

    /// The `.commands` Move-to-Trash disclosure the confirmation sheet
    /// renders when non-nil (fn-2.5, epic contract): `nil` when NO selected
    /// item cleans via commands; otherwise a string naming ONLY the
    /// command-backed items by display name — their argv runs regardless of
    /// the Trash toggle and places nothing in the Trash (P2), so the sheet
    /// must say exactly which items the toggle does not cover. Items cleaned
    /// by deletion are never named.
    var commandsTrashDisclosure: String? {
        Self.commandsTrashDisclosure(selectedItems: selectedItems)
    }

    /// Pure derivation behind `commandsTrashDisclosure` — static so XCTest
    /// asserts on it without a runtime.
    nonisolated static func commandsTrashDisclosure(
        selectedItems: [ReclaimableItem]
    ) -> String? {
        let names = selectedItems
            .filter { if case .commands = $0.action { return true } else { return false } }
            .map(\.displayName)
        guard !names.isEmpty else { return nil }
        if names.count == 1 {
            return "\(names[0]) runs its own cleanup command — "
                + "Move to Trash does not apply to it"
        }
        return "\(names.joined(separator: ", ")) run their own cleanup "
            + "commands — Move to Trash does not apply to them"
    }

    /// True when the current selection includes a caution-risk item (the
    /// confirmation sheet's warning banner).
    var hasCautionSelection: Bool {
        selectedItems.contains { $0.risk == .caution }
    }

    /// Bytes Quick Clean would actually act on — the SAME policy (b)
    /// predicate `selectAllSafe` applies, across every scanner, through the
    /// one shared helper. The menubar's Quick Clean gate reads THIS, not
    /// `totalRecoverable`: that total is category-scoped by frozen contract,
    /// while the auto path is registry-wide — a safe eligible item on a
    /// future per-item scanner must keep Quick Clean live even when category
    /// bytes are zero (and bytes that policy (b) will not touch must not
    /// light the button).
    var automaticCleanableSize: Int64 {
        // Malformed-blocked scanners are excluded from the SCOPE, keeping
        // this gate equal to what `selectAllSafe` (and therefore Quick
        // Clean) will actually act on.
        aggregateBytes(
            scannerScope: { !isBlockedFromDestructivePaths($0) },
            include: Self.safeAutoSelectable
        )
    }

    var hasAutomaticCleanableItems: Bool { automaticCleanableSize > 0 }

    // MARK: - Runtime reconstruction (fn-4.10, R8)

    /// The dev-roots configuration changed — re-resolve it and rebuild the
    /// runtime through the INJECTED factory. The Settings surface (fn-4.6)
    /// mutates `DevRootsStore` and then calls THIS; resolution happens here
    /// so the view model always rebuilds from what is actually persisted.
    ///
    /// A no-op while the seam is unwired (`reconstruction == nil`): a view
    /// model handed a finished runtime has no configurable composition, and
    /// inventing production defaults for it is exactly what this seam
    /// exists to prevent.
    func devRootsDidChange() {
        guard let reconstruction else { return }
        requestRuntimeReplacement(
            devRoots: reconstruction.devRootsStore
                .effectiveRoots(home: reconstruction.home)
        )
        // The Settings editor's rows describe the SAME persisted state the
        // rebuild was requested for — refreshed here, in the one funnel every
        // mutation goes through, never inside a SwiftUI body (fn-4.6).
        refreshDevRootRows()
    }

    /// Apply now, or DEFER to the end of the in-flight session
    /// (latest-value-wins). Deliberately keyed on `isAnyScanInProgress` and
    /// not on `isCleaning`: an in-flight clean already holds the cleaner and
    /// the item list it captured before its first await, so a replacement
    /// cannot re-pair them — and `isBlockedFromDestructivePaths`' runtime
    /// clause gates the NEXT destructive action until a scan from the new
    /// runtime adopts.
    private func requestRuntimeReplacement(devRoots: DevRootsResolution) {
        // No seam, no bookkeeping: an unwired view model must not even
        // record a pending replacement it could never install.
        guard reconstruction != nil else { return }
        guard !isAnyScanInProgress else {
            // LATEST-VALUE-WINS: the newest request simply replaces the
            // pending one — N Settings edits during one scan cost exactly
            // ONE rebuild, and no intermediate composition is ever built.
            pendingDevRoots = devRoots
            return
        }
        installRuntime(devRoots: devRoots)
    }

    /// THE factory call site — the only place `runtime` is replaced and the
    /// only place `runtimeGeneration` moves. A rebuild is UNCONDITIONAL,
    /// even for a resolution equal to the one in force: dev-roots equality
    /// does not prove COMPOSITION equality (the factory closes over state
    /// this view model cannot see), and over-gating is the fail-closed
    /// direction — one rescan restores every destructive path.
    ///
    /// Both replaced fields are PRIVATE, so this is the one transition that
    /// changes published derivations (`perItemSections`, `selectedItems`,
    /// `hasCleanableSelection`, the clean totals) without any `@Published`
    /// write to carry it — the same co-publishing obligation the session
    /// guard has, met explicitly here. Sent BEFORE the mutation
    /// (`objectWillChange` semantics) and on the same MainActor step, so no
    /// SwiftUI reader can render a stale section list or a live Clean
    /// control over a composition that no longer exists.
    private func installRuntime(devRoots: DevRootsResolution) {
        guard let reconstruction else { return }
        objectWillChange.send()
        runtime = reconstruction.makeRuntime(devRoots)
        runtimeGeneration += 1
    }

    // MARK: - Dev-roots Settings editor (fn-4.6, R8/R16)

    /// The declared dev roots the Settings editor renders — refreshed
    /// through the ONE mutation funnel below (and at construction), never
    /// re-derived inside a SwiftUI body.
    @Published private(set) var devRootRows: [DevRootRowModel] = []

    /// The INLINE add-time rejection the editor shows, or nil. Set only by
    /// `addDevRoot` — a rejected pick is never persisted and never rebuilds
    /// anything.
    @Published private(set) var devRootRejection: String?

    /// Whether the editor can function at all: without the reconstruction
    /// seam there is no store to mutate and no factory to rebuild with, so
    /// the Settings surface says so instead of pretending to persist.
    var isDevRootsEditorAvailable: Bool { reconstruction != nil }

    /// ADD (R8/R16): normalize the input to a declared string that resolves
    /// back to the URL being validated, run the SHARED container-root
    /// admission policy through the store (never a UI-local duplicate), and
    /// only then persist + rebuild. A refusal sets `devRootRejection` and
    /// changes NOTHING.
    func addDevRoot(_ input: String) {
        guard let reconstruction else { return }
        let home = reconstruction.home
        switch Self.devRootDeclaration(for: input, home: home) {
        case .failure(let refusal):
            devRootRejection = refusal.message
        case .success(let declared):
            let url = DevRootsStore.declaredURL(for: declared, home: home)
            do {
                try reconstruction.devRootsStore
                    .validateCandidateRoot(url, home: home)
            } catch {
                devRootRejection = Self.devRootRefusal(path: url.path, error: error)
                return
            }
            devRootRejection = nil
            // A duplicate declaration is a store no-op — and therefore a
            // REBUILD no-op (see `applyDevRootMutation`).
            applyDevRootMutation(reconstruction.devRootsStore.add(declared))
        }
    }

    /// REMOVE (R8): every exact-string occurrence, through the store.
    func removeDevRoot(_ declaredPath: String) {
        guard let reconstruction else { return }
        devRootRejection = nil
        applyDevRootMutation(reconstruction.devRootsStore.remove(declaredPath))
    }

    /// RESET (R8): back to the seeds — the persisted key is removed
    /// entirely (seeds are a fallback, never persisted).
    func resetDevRootsToDefaults() {
        guard let reconstruction else { return }
        devRootRejection = nil
        applyDevRootMutation(reconstruction.devRootsStore.resetToDefaults())
    }

    /// Rebuild ONLY when the store actually changed. A rebuild is
    /// deliberately unconditional for a REAL dev-roots change (dev-roots
    /// equality does not prove COMPOSITION equality — `installRuntime`), but
    /// a mutation that persisted NOTHING — re-adding an already-declared
    /// root, removing one that was never there, resetting when nothing is
    /// stored — must not gate every destructive path until the next scan
    /// over a configuration nobody changed. The rows refresh either way, so
    /// the editor and the persisted state never diverge.
    private func applyDevRootMutation(_ changed: Bool) {
        guard changed else {
            refreshDevRootRows()
            return
        }
        devRootsDidChange()
    }

    /// Re-derives the editor rows from what is actually persisted. Called
    /// at construction and after every mutation (inside `devRootsDidChange`),
    /// so the rows and the composition in force always describe one state.
    func refreshDevRootRows() {
        guard let reconstruction else {
            devRootRows = []
            return
        }
        let store = reconstruction.devRootsStore
        devRootRows = Self.devRootRows(
            declaredPaths: store.declaredPaths(),
            issues: store.effectiveRoots(home: reconstruction.home).issues,
            home: reconstruction.home
        )
    }

    /// Pure row derivation (XCTest asserts on this directly): one row per
    /// DECLARED path, carrying the refusal detail of the `.containerRefused`
    /// issue that names it — a policy-rejected persisted root is visible in
    /// the editor exactly as it is visible in the scan results (R16).
    nonisolated static func devRootRows(
        declaredPaths: [String], issues: [ScanIssue], home: URL
    ) -> [DevRootRowModel] {
        let refusalsByPath = Dictionary(
            issues
                .filter { $0.kind == .containerRefused }
                .compactMap { issue -> (String, String)? in
                    guard let url = issue.url else { return nil }
                    return (url.standardizedFileURL.path, issue.detail)
                },
            uniquingKeysWith: { first, _ in first }
        )
        return declaredPaths.enumerated().map { index, declared in
            let url = DevRootsStore.declaredURL(for: declared, home: home)
            return DevRootRowModel(
                index: index,
                declaredPath: declared,
                displayPath: homeCollapsed(url.path, home: home),
                issueDetail: refusalsByPath[url.standardizedFileURL.path]
            )
        }
    }

    /// The editor's input rule (pure, testable): ABSOLUTE paths and
    /// `~`-EXPANDED paths are accepted; a bare name stays HOME-RELATIVE
    /// exactly like the seeds (`Documents`), which is what the store's
    /// declared-string convention means. A `~user`-style spelling is
    /// REFUSED rather than silently persisted as a literal `~user`
    /// directory name under home.
    ///
    /// Returns the string to PERSIST — always one that
    /// `DevRootsStore.declaredURL` maps back to the validated URL, so the
    /// editor can never validate one path and the scanner walk another.
    nonisolated static func devRootDeclaration(
        for input: String, home: URL
    ) -> Result<String, DevRootInputRefusal> {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(DevRootInputRefusal(
                message: "Enter a folder path, or choose one with Choose…"
            ))
        }
        if trimmed == "~" {
            return .success(home.path)
        }
        if trimmed.hasPrefix("~/") {
            return .success(
                home.appendingPathComponent(String(trimmed.dropFirst(2))).path
            )
        }
        guard !trimmed.hasPrefix("~") else {
            return .failure(DevRootInputRefusal(message:
                "'\(trimmed)' isn't a supported path — use an absolute path "
                + "(/Users/you/dev), a ~/ path (~/dev), or a folder name "
                + "inside your home folder (Documents)."
            ))
        }
        return .success(trimmed)
    }

    /// The INLINE refusal copy: the offending path plus the shared policy's
    /// own reason (never a re-worded UI-side guess at why).
    nonisolated static func devRootRefusal(path: String, error: Error) -> String {
        let reason = (error as? LocalizedError)?.errorDescription
            ?? String(describing: error)
        return "\(path) can't be used as a dev root: \(reason)"
    }

    /// Display-only home collapsing (`/Users/you/dev` → `~/dev`).
    nonisolated static func homeCollapsed(_ path: String, home: URL) -> String {
        let homePath = home.standardizedFileURL.path
        if path == homePath { return "~" }
        guard path.hasPrefix(homePath + "/") else { return path }
        return "~" + path.dropFirst(homePath.count)
    }

    /// Applies the deferred replacement at session end. Re-checks the guard:
    /// the pending resolution outlives any window it cannot be applied in,
    /// so a request that arrives during a session the caller does not own
    /// still lands exactly once, at the end of the session that does.
    private func applyPendingRuntimeReplacement() {
        guard let pending = pendingDevRoots, !isAnyScanInProgress else {
            return
        }
        pendingDevRoots = nil
        installRuntime(devRoots: pending)
    }

    // MARK: - Scanning

    /// No default trigger — every caller must classify itself (R9). A
    /// defaulted `.userInitiated` let timer-driven refreshes inherit TCC
    /// consent silently; making the argument mandatory turns a
    /// misclassified new call site into a compile error.
    ///
    /// Consumes fn-2.1's progressive validated event stream — nil
    /// `categoryFilter`. The trigger rides `ScanContext` (its derived
    /// `includeProtectedRoots` is the exact TCC mapping this view model used
    /// to special-case at the node_modules call site); orchestration,
    /// parallelism, and validation all live inside the runtime.
    ///
    /// - Parameter scannerIDs: SCANNER SUBSET to run (nil — every existing
    ///   caller — scans all registered scanners that PARTICIPATE in this
    ///   context; see `SpaceScanner.participates(in:)`, whose default is
    ///   true, so this is byte-identical for every scanner that always runs).
    ///   A subset session adopts its snapshot atomically exactly like a
    ///   full one, so scanners OUTSIDE the subset keep their PRIOR session
    ///   provenance: fn-2's retention rules leave their items displayed,
    ///   but the R9 freshness gate makes those retained rows
    ///   visible-but-NON-cleanable — they never pair with a snapshot their
    ///   session did not capture — until their scanner succeeds in a later
    ///   completed session (fail-closed; a full rescan restores them). The
    ///   frozen display scopes (totals, sections, checkmarks) are
    ///   deliberately untouched by the gate.
    func scan(trigger: ScanTrigger, scannerIDs: Set<String>? = nil) async {
        // Re-entrancy guard (R11): correctness must not depend on button
        // state — an overlapping scan would race two writers over the same
        // published state while slower scanners are still running, and
        // scanning DURING a cleanup would publish results mid-deletion.
        // (clean()'s own post-cleanup rescan runs after isCleaning clears.)
        guard !isAnyScanInProgress && !isCleaning else { return }
        // Registered AFTER the re-entrancy guard on purpose: a BLOCKED
        // attempt owns no session, so it must never install another
        // session's deferred replacement. Every exit of a session that DID
        // start — completed or cancelled — applies the pending replacement
        // in the same synchronous MainActor step as its epilogue, so the
        // next session starts on the new composition (fn-4.10, R8).
        defer { applyPendingRuntimeReplacement() }
        // The SESSION runtime, captured ONCE — before the first suspension,
        // beside the session generation (fn-4.10, R8). Everything this
        // session touches (its pending-scanner set, its event stream, its
        // snapshot, its adoption) comes from THIS capture: reading the
        // stored `runtime` again after the awaits below would let a
        // replacement installed mid-session launch a different composition
        // than the one whose scanners this session announced.
        let sessionRuntime = runtime
        let sessionRuntimeGeneration = runtimeGeneration
        // THE SESSION CONTEXT, HOISTED, and the participating set derived
        // from it ONCE (PR #459 review r1). The pending state and the session
        // consume the SAME set, so they cannot disagree — a runtime-side
        // filter alone would leave `scanningScannerIDs` claiming a scanner is
        // running that never runs, which `perItemSections` renders as a
        // permanently spinning section.
        //
        // A scanner that declines this trigger (`participates(in:)` false) is
        // simply NOT IN THE SESSION, so `reconcile` never sees an entry for it
        // and its prior outcome, its prior issues and the user's ticks all
        // survive. An empty outcome would instead have asserted "there is
        // nothing there" and wiped all three.
        let context = ScanContext(trigger: trigger)
        // Pending state covers exactly the scanners this session RUNS —
        // a subset must not hold the guard hostage to scanners that will
        // never report (the runtime invokes only the named subset).
        let participating = Set(
            sessionRuntime.scanners
                .filter {
                    (scannerIDs?.contains($0.id) ?? true)
                        && $0.participates(in: context)
                }
                .map(\.id)
        )
        scanningScannerIDs = participating
        // New session: outcomes reconciled from here on carry THIS
        // generation's provenance — they pair only with THIS session's
        // snapshot, adopted below at completion (fn-3.4, R9). The
        // generation is captured as an IMMUTABLE local (PR #456 P2):
        // events and adoption use the capture, never the shared counter,
        // so this session's pairing survives any later mutation. The
        // guard rises here and holds through adoption — every await
        // below is covered.
        sessionGeneration += 1
        let generation = sessionGeneration
        activeScanGeneration = generation
        diskInfo = await Task.detached { DiskInfo.current() }.value

        let session = sessionRuntime.scanValidatedSession(
            scannerIDs: participating,
            context: context
        )
        for await event in session.events {
            handle(event, generation: generation)
        }

        // If the consuming task was cancelled the stream may have ended
        // early — some scanners never delivered. Pruning then would drop
        // selections for items whose scanner simply never reported.
        let completed = !Task.isCancelled

        // Early termination only CANCELS the producer; its filesystem walks
        // wind down cooperatively rather than instantly (review P2).
        // `activeScanGeneration` is the re-entrancy guard every scan-start,
        // `clean()`, and `shouldAutoRescan` read — releasing it while the
        // orphaned walk is still traversing would let a new scan or a
        // cleanup overlap the same trees. Hold it until the producer has
        // ACTUALLY finished (the await is deliberately non-cancellable; in
        // the normal completion path it returns immediately).
        await session.untilProducerFinishes()
        // Session-keyed release (PR #456 P2): only the session that RAISED
        // the guard may clear it. The guard serializes sessions, so the key
        // always matches today — the check is defense-in-depth ensuring a
        // future suspension point in this epilogue could still never let
        // one session's completion release another's in-flight guard.
        // Everything from here to the end of the function is ONE
        // synchronous MainActor step: release and adoption are atomic with
        // respect to any other scan or clean.
        if activeScanGeneration == generation {
            scanningScannerIDs = []
            activeScanGeneration = nil
        }
        guard completed else { return }

        // Atomic (items, snapshot) adoption (R9): the snapshot and the
        // generation it vouches for land in ONE MainActor step, only at
        // COMPLETION. THIS session's captured generation pairs with THIS
        // session's snapshot — never the shared counter, which a later
        // session may have advanced. A cancelled scan adopts nothing —
        // outcomes it reconciled carry the new generation while the adopted
        // one stays old, so their items are non-cleanable (fail-closed)
        // until a completed session pairs them with its own capture. A
        // SUBSET session adopts exactly the same way: scanners outside the
        // subset never delivered in this generation, so their retained rows
        // are REVOKED from every destructive path by the same comparison —
        // visible-but-stale beats deletable-under-a-swapped-container.
        adoptedSnapshot = session.snapshot
        adoptedGeneration = generation
        // The RUNTIME half of the same atomic adoption (fn-4.10, R8): the
        // tuple records the composition that PRODUCED it, from this
        // session's CAPTURE — a replacement deferred to this session's end
        // (the `defer` above, which runs after this step) must leave the
        // destructive paths gated, not silently vouch for a snapshot the
        // new composition never captured.
        adoptedRuntimeGeneration = sessionRuntimeGeneration

        pruneVanishedSelections()

        // Track scan completion for reactive UI updates
        lastScanDate = Date()
        scanGeneration += 1
        hasScanned = true
    }

    /// Serial-context convenience over `handle(_:generation:)` — stamps the
    /// CURRENT session counter. Internal (not private) so tests seed
    /// view-model state through the SAME path production uses, never a
    /// parallel back door; safe there because seeding is synchronous.
    /// `scan()` never calls this form: it threads its own captured
    /// invocation generation so a later session's start cannot re-stamp an
    /// in-flight session's events (PR #456 P2).
    func handle(_ event: ValidatedScannerEvent) {
        handle(event, generation: sessionGeneration)
    }

    /// Applies ONE stream event — the reconciliation entry point `scan()`
    /// drives, stamping provenance with the INVOKING session's captured
    /// `generation` (never the shared mutable counter).
    func handle(_ event: ValidatedScannerEvent, generation: Int) {
        switch event {
        case .outcome(let scannerID, let outcome):
            reconcile(outcome, from: scannerID)
            // Session provenance (R9): this scanner's displayed outcome now
            // belongs to the DELIVERING session's generation. Mid-scan that
            // generation is not yet adopted, so the items are non-cleanable
            // until the session completes and its snapshot is adopted
            // (cleaning is blocked mid-scan anyway — this keeps the pairing
            // honest even if the scan is cancelled before adoption).
            outcomeGenerationByScannerID[scannerID] = generation
            scanningScannerIDs.remove(scannerID)
        case .malformed(let scannerID, let issue):
            // Fail-closed disposition (epic contract): NOTHING published for
            // this scanner — previous items and selections RETAINED, the
            // path-less issue surfaced. The failure is visible, nothing is
            // corrupted, nothing user-set is lost. Validation itself
            // happened in the runtime; this is only the disposition. While
            // this entry is set the retained records are DISPLAY-ONLY:
            // every destructive derivation excludes the scanner (see
            // `isBlockedFromDestructivePaths`) until a valid outcome
            // replaces it.
            malformedIssuesByScannerID[scannerID] = issue
            // The retained items' provenance is REVOKED (R9): whatever
            // session they came from, they no longer represent a validated
            // view — non-cleanable until a valid outcome in a completed
            // session replaces them.
            outcomeGenerationByScannerID[scannerID] = nil
            scanningScannerIDs.remove(scannerID)
        }
    }

    /// Per-scanner reconciliation against the PRIOR outcome (epic round 5):
    /// touches ONLY this scanner's entry and selections.
    private func reconcile(_ outcome: ScanOutcome, from scannerID: String) {
        let previouslyEmitted = emittedKeysByScannerID[scannerID] ?? []
        for item in outcome.items {
            let key = item.key
            if !Self.isSelectableState(item.state) {
                // `.denied`/`.empty`/`.missing` are unselectable in EVERY
                // surface (round 9): a retained selection on a now-denied
                // item would show a selected row every path refuses. (fn-1.4
                // parity: a rescan never leaves these selected.)
                selectedItemKeys.remove(key)
            } else if !previouslyEmitted.contains(key), Self.initiallySelected(item) {
                // Policy (a): `defaultSelected` on the key's FIRST emission
                // ever this session. Previously-emitted keys keep their
                // user-set state — selected AND deselected — verbatim.
                selectedItemKeys.insert(key)
            }
        }
        emittedKeysByScannerID[scannerID] =
            previouslyEmitted.union(outcome.items.map(\.key))
        outcomesByScannerID[scannerID] = outcome
        malformedIssuesByScannerID[scannerID] = nil
    }

    /// Vanished-key pruning, run EXACTLY at scan completion (never mid-scan
    /// — a selection on scanner A must not vanish because scanner B's event
    /// landed first, and must not flicker while A is still pending). A
    /// malformed scanner's retained items stay live, so their selections
    /// survive.
    private func pruneVanishedSelections() {
        var liveKeys = Set<ItemKey>()
        for outcome in outcomesByScannerID.values {
            for item in outcome.items { liveKeys.insert(item.key) }
        }
        selectedItemKeys.formIntersection(liveKeys)
    }

    // MARK: - Selection rules (fn-1.4 semantics preserved bit-for-bit)

    /// `.denied`/`.empty`/`.missing` cannot be selected anywhere — nothing
    /// to clean (round 9). `.partiallyDenied` stays manually toggleable; the
    /// confirmation sheet carries the warning.
    private static func isSelectableState(_ state: ScanState) -> Bool {
        switch state {
        case .measured, .partiallyDenied: return true
        case .denied, .empty, .missing: return false
        }
    }

    /// Policy (a) — the EXACT fn-1.4 initial-selection derivation
    /// (`ScanResult.init`): defaultSelected, cleanly measured, measurable
    /// bytes. `.partiallyDenied` is never auto-selected (its size is a
    /// floor, not a promise).
    private static func initiallySelected(_ item: ReclaimableItem) -> Bool {
        item.defaultSelected && item.state == .measured && item.allocatedBytes > 0
    }

    /// Policy (b) — Quick Clean / selectAllSafe eligibility: structured
    /// fields, not risk inference. `defaultSelected` is deliberately NOT
    /// consulted — today's selectAllSafe ignores it, and adding it would be
    /// a silent behavior change dressed as parity. The clean-state rules are
    /// as-built: only cleanly `.measured` items with measurable bytes
    /// (`.partiallyDenied` never rides an auto path — R18).
    private static func safeAutoSelectable(_ item: ReclaimableItem) -> Bool {
        item.automaticCleanEligible
            && item.risk == .safe
            && item.state == .measured
            && item.allocatedBytes > 0
    }

    func toggleSelection(for key: ItemKey) {
        guard let item = item(for: key) else { return }
        // Unselectable states are no-ops for aggregate AND per-item rows
        // alike — the checkbox must not pretend otherwise (R18/round 9).
        guard Self.isSelectableState(item.state) else { return }
        if selectedItemKeys.contains(key) {
            selectedItemKeys.remove(key)
        } else {
            selectedItemKeys.insert(key)
        }
    }

    /// Policy (b) across every scanner. Today only category aggregates are
    /// `automaticCleanEligible`; node_modules ships ineligible, so behavior
    /// is unchanged — and a future eligible safe scanner enrolls by
    /// declaration, not by an edit here.
    func selectAllSafe() {
        for (scannerID, outcome) in outcomesByScannerID
        where !isBlockedFromDestructivePaths(scannerID) {
            // A malformed-blocked scanner's retained items are display-only:
            // the auto path must not (re)stage them for cleaning.
            for item in outcome.items where Self.safeAutoSelectable(item) {
                selectedItemKeys.insert(item.key)
            }
        }
    }

    func deselectAll() {
        selectedItemKeys = []
    }

    // MARK: - Per-section selection (the old node_modules quick actions,
    // generalized per scanner id)

    /// "Select Stale" operates on `isStale == true` ONLY — `isStale == nil`
    /// means staleness is inapplicable and contributes nothing. No-op while
    /// the scanner is malformed-blocked: bulk actions stage items for
    /// cleaning, and a blocked scanner's retained items are display-only.
    /// (The individual checkbox stays live — retained selection state is
    /// the user's to curate, it just cannot reach a destructive path.)
    func selectStale(inScanner id: String) {
        guard !isBlockedFromDestructivePaths(id) else { return }
        for item in items(forScanner: id)
        where item.isStale == true && Self.isSelectableState(item.state) {
            selectedItemKeys.insert(item.key)
        }
    }

    func selectAll(inScanner id: String) {
        guard !isBlockedFromDestructivePaths(id) else { return }
        for item in items(forScanner: id)
        where Self.isSelectableState(item.state) {
            selectedItemKeys.insert(item.key)
        }
    }

    func deselectAll(inScanner id: String) {
        for item in items(forScanner: id) {
            selectedItemKeys.remove(item.key)
        }
    }

    /// Menu bar label: show free GB in the tray
    var menuBarTitle: String {
        guard let disk = diskInfo else { return "💾" }
        let freeGB = Double(disk.freeSpace) / (1024 * 1024 * 1024)
        return String(format: "%.0fGB", freeGB)
    }

    /// Quick clean: a PURE auto path (R18) and strictly policy (b). Any
    /// manual selections — including a deliberately toggled
    /// `.partiallyDenied` category or per-item rows — are cleared first, so
    /// Quick Clean acts on exactly the auto-selected safe set and nothing
    /// rides along. Policy (c) — smart-clean's safe-then-review ordering —
    /// is EXCLUSIVELY the CLI's (fn-2.6): the GUI never invokes its
    /// candidate-order helper and never selects review-risk.
    func smartClean() async {
        deselectAll()
        selectAllSafe()
        await clean()
        // Re-scan updates are handled inside clean()
    }

    // MARK: - Docker Management

    @Published var isDockerPruning = false
    @Published var lastDockerPruneResult: String?

    func dockerPrune() async {
        isDockerPruning = true
        defer { isDockerPruning = false }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["docker", "system", "prune", "-f"]
        process.standardOutput = pipe
        process.standardError = pipe
        // Real home is correct here: the view model has no injected-home
        // seam — docker prune is a production-only action on the real
        // account (unlike CacheCleaner/CacheCategory subprocesses, which
        // pin HOME to their injected home).
        process.environment = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin",
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path
        ]

        do {
            let result = try await Task.detached { () -> (Int32, String) in
                try process.run()
                let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
                process.waitUntilExit()
                let output = String(data: data, encoding: .utf8) ?? ""
                return (process.terminationStatus, output)
            }.value

            if result.0 == 0 {
                // Extract "Total reclaimed space:" line
                if let line = result.1.components(separatedBy: "\n")
                    .first(where: { $0.contains("reclaimed") }) {
                    lastDockerPruneResult = line.trimmingCharacters(in: .whitespaces)
                } else {
                    lastDockerPruneResult = "Docker pruned successfully"
                }
            } else {
                let lowerOutput = result.1.lowercased()
                if lowerOutput.contains("cannot connect") ||
                   lowerOutput.contains("is the docker daemon running") ||
                   lowerOutput.contains("connection refused") ||
                   lowerOutput.contains("no such file or directory") {
                    lastDockerPruneResult = "Docker must be running to prune"
                } else {
                    lastDockerPruneResult = "Docker prune failed — is Docker running?"
                }
            }
        } catch {
            lastDockerPruneResult = "Docker not found"
        }

        // Refresh disk info after prune
        diskInfo = await Task.detached { DiskInfo.current() }.value
    }

    // MARK: - Cleaning

    /// Builds `[ReclaimableItem]` from `selectedItemKeys` and drives
    /// fn-2.3's unified entry on the RUNTIME-constructed cleaner — one
    /// composition source, so delete-time admission covers exactly the
    /// registered scanners' declared container roots.
    ///
    /// UNACKNOWLEDGED by construction: this is the bare path (Quick Clean /
    /// smart clean), and an empty authorization context is exactly what it
    /// means — a valuable-bearing item reaching it is REFUSED by its
    /// revalidator. The confirmation sheet's authorized path is
    /// `confirmClean()` below.
    func clean() async {
        await clean(items: selectedItems, authorization: [:])
    }

    /// THE confirmation sheet's confirm action (fn-4.6, R17). Three things,
    /// in one MainActor step over ONE capture of the displayed selection:
    ///
    /// 1. blocked (INCOMPLETE-probed) rows are filtered out of the CLEAN SET
    ///    — their rows stay visible and their selection stays untouched, but
    ///    the cleaner provably never sees them;
    /// 2. the per-clean `[ItemKey: acknowledgement]` AUTHORIZATION CONTEXT is
    ///    built from exactly the remaining DISPLAYED items — one entry per
    ///    complete-probed valuable-bearing item, tokens over exactly the
    ///    disclosed sets the sheet rendered;
    /// 3. the context is PASSED DOWN the clean path into the cleaner, where
    ///    each item's revalidator receives its own entry. Producing the map
    ///    is not enough — the plumbing is what authorizes a deletion.
    func confirmClean() async {
        let displayed = selectedItems
        let blocked = Self.blockedConfirmationKeys(for: displayed)
        let authorizedItems = displayed.filter { !blocked.contains($0.key) }
        await clean(
            items: authorizedItems,
            authorization: Self.confirmationAuthorization(for: authorizedItems)
        )
    }

    /// The ONE clean core both paths share — the only place the cleaner is
    /// built and driven.
    private func clean(
        items: [ReclaimableItem],
        authorization: PreDeleteAuthorizationContext
    ) async {
        // Guard at the model, not just the buttons (R11 + fn-3.4 session
        // integrity): cleaning while any scanner is still reporting would
        // act on a half-built result set — and on items not yet paired
        // with an adopted session snapshot.
        guard !isCleaning && !isAnyScanInProgress else { return }
        isCleaning = true
        // The cleaner is built PER CLEAN from the adopted session's
        // snapshot (R9): every caller derives `items` from `selectedItems`,
        // which already excludes every scanner whose outcome that session
        // did not produce, so items and snapshot are the atomic pair the
        // session adoption established.
        // No completed session (nil snapshot) fail-closes `.removeItem`.
        // After a runtime rebuild the SAME gate empties `selectedItems`
        // wholesale (fn-4.10, R8), so this current-runtime cleaner can
        // never act on a snapshot the previous composition captured.
        let cleaner = runtime.makeCleaner(snapshot: adoptedSnapshot)
        let report = await cleaner.clean(
            items: items, moveToTrash: moveToTrash,
            authorization: authorization
        )
        lastReport = report
        isCleaning = false
        showCleanupReport = true

        // Rescan to update sizes. `.userInitiated`: a confirmed cleanup is
        // explicit user action (see ScanTrigger), and the refresh must see
        // the same roots the results being updated came from.
        await scan(trigger: .userInitiated)
    }
}
