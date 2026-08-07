/// # SpaceScanner — Unified Scanner Protocol & Reclaimable-Item Model (fn-2.1)
///
/// The one abstraction both scanning stacks converge on: the 23-entry
/// `CacheCategory` aggregate registry (via `CategoryScanner`) and every
/// per-item scanner (node_modules today; build artifacts, git worktrees,
/// temp dirs to follow) implement `SpaceScanner` and emit `ReclaimableItem`s
/// — the ONE currency GUI, CLI, and cleaner all consume.
///
/// ## Layering
///
/// - `SpaceScanner` + `ScanContext`: the protocol boundary. The registry
///   stays `[any SpaceScanner]` with NO downcasting — scanner-specific knobs
///   (TCC trigger gating, category filtering) cross the boundary via the
///   context or not at all.
/// - `ReclaimableItem` / `ItemKey` / `ScanOutcome` / `ScanIssue` /
///   `ReclaimAction`: the unified item model. Identity, ownership, byte
///   components, per-root scan records, selection policy, and admission
///   provenance all RIDE ON the item — `clean(items:)` receives bare items,
///   so nothing may need to be looked up (and race a rescan) at clean time.
/// - `SpaceScannerRuntime`: the single trusted composition source. The
///   production registry, the cleaner configuration DERIVED from it (the
///   union of scanner-declared trusted container roots), registration-time
///   validation, and the one validated-scan entry point all live here.
///
/// ## Frozen wire values (epic contract — fn-2.6 asserts, fn-3..fn-6 inherit)
///
/// - CategoryScanner's scanner id: `categories`.
/// - `ReclaimAction`: `remove_contents` | `remove_item` | `commands` —
///   `.commands` serializes ONLY its kind; argv arrays never reach any wire.
/// - `ScanIssue.Kind`: `container_refused` | `symlink_root` | `tcc_denied` |
///   `permission_denied` | `unreadable` | `malformed_outcome`.
/// - Item ids: full 64-char lowercase-hex SHA-256 over the UTF-8 bytes of
///   `scannerID + "\0" + canonicalPath` (`ReclaimableItem.stableID`).

import CryptoKit
import Foundation

// MARK: - Scan trigger & context

/// What set a scan in motion (fn-1.4, R9). TCC-protected search roots
/// (Documents, Desktop, …) are enumerated ONLY for `.userInitiated` scans —
/// a background refresh must never be the thing that fires a macOS privacy
/// prompt.
enum ScanTrigger: Equatable, Sendable {
    /// The user explicitly asked (Scan button, Quick Clean, confirmed
    /// cleanup). Protected roots are included; macOS may prompt once.
    case userInitiated
    /// Popover/tab auto-rescan or any other background refresh. Protected
    /// roots are skipped entirely.
    case automatic
}

/// The generic per-scan parameter every `SpaceScanner` receives. Deliberately
/// minimal — trigger + derivations + the category filter, no config bag:
/// scanner-specific knobs cross the protocol boundary here or not at all
/// (the registry stays `[any SpaceScanner]` with no downcasting).
struct ScanContext: Equatable, Sendable {
    /// What set the scan in motion. CategoryScanner ignores it; per-item
    /// scanners consume the derived `includeProtectedRoots` flag.
    let trigger: ScanTrigger

    /// Category slugs to scan (CategoryScanner ONLY honors this — with a
    /// filter, unrequested categories' resolvers/probes are never invoked);
    /// nil = all. Every other scanner ignores it.
    let categoryFilter: Set<String>?

    init(trigger: ScanTrigger, categoryFilter: Set<String>? = nil) {
        self.trigger = trigger
        self.categoryFilter = categoryFilter
    }

    /// DERIVED TCC gate — exactly the mapping the ViewModel performed at its
    /// node_modules call site before unification: protected search roots are
    /// walked only when the user explicitly asked.
    var includeProtectedRoots: Bool { trigger == .userInitiated }
}

// MARK: - Per-root scan records

/// What the scan established about one resolved root (FROZEN truth table —
/// this IS the deletability boundary, epic round 5).
enum RootScanStatus: Equatable, Sendable {
    /// PathGuard refused the root at scan-time admission. NEVER deletable.
    case refusedAdmission
    /// Admitted, but sizing was denied before ANY measurement. NOT deletable.
    case deniedUnmeasured
    /// Admitted and walked — INCLUDING clean-empty walks and partial walks
    /// that yielded any measurable content. Deletable.
    case measured
}

/// One resolved root captured AT SCAN TIME (fn-1's dual-canonicalization
/// doctrine): `requestedURL` is the UNRESOLVED spelling deletion uses;
/// `resolvedURL` the canonical spelling containment compares against (nil
/// when resolution failed). Downstream (fn-2.3): `.removeContents` deletes
/// only `.measured` records; `.commands` re-admits every record's
/// `requestedURL` at delete time. `CategoryScanner` consumes these records
/// verbatim and NEVER re-evaluates `CacheCategory.resolvedPaths` — a second
/// evaluation could resolve differently and break the invariant.
struct RootScanRecord: Equatable, Sendable {
    let requestedURL: URL
    let resolvedURL: URL?
    let status: RootScanStatus
}

// MARK: - Item identity

/// The composite cross-scanner identity: selection sets, progressive-publish
/// reconciliation, `CleanupReport` error keying, and SwiftUI list identity
/// all use it. A bare item id is meaningful only in scanner scope (CLI rows
/// with a `scanner_id` sibling; the `<scanner-slug>:<item-id>` address form).
struct ItemKey: Hashable, Sendable {
    let scannerID: String
    let itemID: String

    init(scannerID: String, itemID: String) {
        self.scannerID = scannerID
        self.itemID = itemID
    }
}

// MARK: - Reclaim action

/// How an item's bytes are reclaimed. Dispatch with EXHAUSTIVE switches (no
/// `default:`) — fn-5 adds a composite case (git worktree remove → fallback
/// removeItem + prune) and that addition must be a compile-time-visible
/// change. Do not encode "there are exactly three actions" anywhere.
enum ReclaimAction: Equatable, Sendable {
    /// Delete the children of every `.measured` root record, keeping the
    /// root directory itself (today's category clean).
    case removeContents
    /// Delete the item's own tree (today's node_modules clean).
    case removeItem
    /// Run these argv arrays via `/usr/bin/env` instead of deleting files.
    /// At delete time EVERY root record's `requestedURL` is re-admitted and
    /// ANY refusal blocks the ENTIRE command set (fn-1.3 R17 parity).
    case commands([[String]])

    /// FROZEN wire strings (epic contract; `ScanError.Kind.wireString`
    /// precedent). `.commands` serializes ONLY its kind — the argv arrays
    /// are NEVER exposed on any wire surface (deliberate non-exposure: the
    /// CLI JSON is a reporting surface, not an execution contract).
    var wireString: String {
        switch self {
        case .removeContents: return "remove_contents"
        case .removeItem: return "remove_item"
        case .commands: return "commands"
        }
    }
}

// MARK: - Admission provenance

/// Which PathGuard admission mode applies to an item at the cleaner's
/// chokepoint (fn-2.3). Provenance is a CLAIM the cleaner validates — items
/// can never widen admission (container roots come from the runtime's
/// scanner-declared union, never from items).
enum AdmissionDescriptor: Equatable, Sendable {
    /// Category-policy admission for aggregate items: build
    /// `CategoryAdmissionPolicy(category:home:)` + `validateContainedChild`,
    /// then admit over the item's root records.
    case category(CacheCategory)
    /// FROZEN arm (epic round 6) for per-item scanners: `admitContainer` on
    /// `originContainer` + `validateRemovableItem`. `requestedTargetURL` is
    /// the UNRESOLVED deletion target — leaf never resolved (fn-1
    /// dual-canonicalization doctrine). `ReclaimableItem.url` is display
    /// state and NEVER an admission or deletion input.
    case containerItem(originContainer: URL, requestedTargetURL: URL)
}

// MARK: - Reclaimable item

/// The ONE currency for GUI + CLI + cleaner. Every destructive path consumes
/// a `RootScanRecord.requestedURL` or the admission descriptor's
/// `requestedTargetURL` — `url` is DISPLAY ONLY (destructive-target rule).
struct ReclaimableItem: Equatable, Sendable {
    /// Scanner-DEFINED under three invariants: (1) stable across rescans for
    /// the same logical item, (2) unique within its scanner, (3) CLI-safe
    /// opaque string (no whitespace, no colon — it must fit the
    /// `<scanner-slug>:<item-id>` grammar slot). A category aggregate's id
    /// is the category SLUG; per-item scanners derive ids via `stableID`.
    let id: String
    /// Ownership rides ON the item (epic round 4): `clean(items:)` receives
    /// bare items — ownership must travel with them, never be looked up.
    let scannerID: String
    /// Presentation identity (aggregates: `category.name`; node_modules:
    /// the project name).
    let displayName: String

    /// Bytes on unique inodes — deletion verifiably frees these (fn-1.2's
    /// split survives unification at the model layer).
    let exactBytes: Int64
    /// Hardlinked/command bytes that MAY be freed.
    let estimatedUpToBytes: Int64
    /// Logical (apparent) bytes; nil unless materially diverging from
    /// allocated (sparse-file field case: 57.1G logical vs 31G allocated).
    let logicalBytes: Int64?
    let itemCount: Int

    /// DISPLAY ONLY — the first root record with a non-nil `resolvedURL`
    /// regardless of status (a denied root's resolved location is still
    /// honest display data). Nil only for `.missing` items or when no root
    /// resolved — never a fake resolution. NEVER an admission or deletion
    /// input (destructive-target rule).
    let url: URL?
    /// The declared spelling for presenting unresolved/missing items
    /// honestly, without inventing a resolution.
    let declaredDisplayPath: String

    /// The scan's per-root capture, carried VERBATIM (root-capture
    /// invariant). Empty for `.missing`; single-element for per-item
    /// scanners.
    let rootRecords: [RootScanRecord]

    /// Item-level error surface (decision: on the item, not alongside it) —
    /// fn-1.2's types verbatim. The cleaner refuses `.denied` items; the GUI
    /// renders denied rows; never flatten `denied` to `empty` (D6).
    let state: ScanState
    let scanError: ScanError?

    let risk: RiskLevel
    /// Renders in the confirmation sheet per item (aggregates: the category
    /// description; per-item scanners provide real content in fn-3+).
    let evidence: String
    let rebuildNote: String?
    let action: ReclaimAction
    /// Which PathGuard mode applies at the cleaner chokepoint (fn-2.3).
    let admission: AdmissionDescriptor

    /// Selection policy — structured fields, not inferred from risk. THREE
    /// separate consumers (epic contract): initial selection reads
    /// `defaultSelected` (first emission only); Quick Clean/selectAllSafe
    /// reads `automaticCleanEligible && risk == .safe` (defaultSelected
    /// deliberately NOT consulted); CLI smart-clean keeps its safe-then-
    /// review logic minus `automaticCleanEligible == false` items.
    let defaultSelected: Bool
    let automaticCleanEligible: Bool
    /// Nil = staleness not applicable to this item (aggregates: nil).
    let isStale: Bool?

    /// The composite cross-scanner identity.
    var key: ItemKey { ItemKey(scannerID: scannerID, itemID: id) }

    /// COMPUTED display convenience — always the component sum, never
    /// stored independently (nothing downstream may re-derive the split
    /// from it).
    var allocatedBytes: Int64 { exactBytes + estimatedUpToBytes }

    /// Shared per-item id derivation (R7) with the EXACT frozen preimage:
    /// the FULL lowercase-hex SHA-256 (64 chars) over the UTF-8 bytes of
    /// `scannerID + "\0" + canonicalPath`. The NUL separator prevents
    /// ambiguous concatenations (`"a"+"bc"` vs `"ab"+"c"` — two distinct
    /// (scanner, path) pairs must never share an id). No truncation, ever —
    /// stability is unconditional and no collision machinery exists. Every
    /// per-item scanner (fn-2.2, fn-3..fn-6) calls this instead of
    /// re-implementing; PROTOCOL.md documents the derivation (fn-2.6).
    static func stableID(scannerID: String, canonicalPath: String) -> String {
        let preimage = Data((scannerID + "\0" + canonicalPath).utf8)
        return SHA256.hash(data: preimage)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

// MARK: - Scan outcome & issues

/// A classified, non-fatal root/scanner-level problem that produced NO item.
/// Two-surface rule (epic contract): impediments attributable to an emitted
/// item ride the item's `state`/`scanError`; only root/scanner-level
/// problems with no recognized candidate land here.
struct ScanIssue: Equatable, Sendable {
    /// EXTENSIBLE taxonomy (proven by `malformedOutcome`) — never write
    /// consumers that assume the case list is closed. Generalizes
    /// `NodeModulesScanIssue.Kind` scanner-agnostically.
    enum Kind: Equatable, Sendable {
        /// `PathGuard.admitContainer` refused the search root.
        case containerRefused
        /// The search root is a symlink (or not a real directory).
        case symlinkRoot
        /// macOS TCC (privacy) denial — EPERM under the Cocoa error.
        case tccDenied
        /// BSD permission denial — EACCES.
        case permissionDenied
        /// Enumeration or metadata failure that is not a permission problem.
        case unreadable
        /// Synthesized ONLY by `SpaceScannerRuntime.validatedOutcome` when a
        /// scanner's outcome fails ownership/structural validation — never
        /// produced by scanners themselves.
        case malformedOutcome

        /// FROZEN wire strings, case-by-case (epic contract).
        var wireString: String {
            switch self {
            case .containerRefused: return "container_refused"
            case .symlinkRoot: return "symlink_root"
            case .tccDenied: return "tcc_denied"
            case .permissionDenied: return "permission_denied"
            case .unreadable: return "unreadable"
            case .malformedOutcome: return "malformed_outcome"
            }
        }
    }

    /// Required BY CONVENTION for the filesystem kinds; nil for
    /// `.malformedOutcome` — no filesystem location exists, and a fake path
    /// must never be invented.
    let url: URL?
    let kind: Kind
    let detail: String
}

/// What one scanner's scan produced: items plus root/scanner-level issues.
struct ScanOutcome: Sendable {
    var items: [ReclaimableItem]
    var errors: [ScanIssue]
}

// MARK: - SpaceScanner protocol

/// One space scanner. Conformers are actors or value types (`Sendable`).
/// Adding a scanner = implement this + register with the runtime — nothing
/// else (R4): the runtime derives delete-time admission from registration.
protocol SpaceScanner: Sendable {
    /// Stable slug, CLI-addressable — part of every item's address. Must
    /// match `[a-z0-9_]+` (no colon; the first `:` in an address splits
    /// scanner slug from item id). Validated at registration.
    var id: String { get }
    var displayName: String { get }
    /// Container roots this scanner needs admitted for its `.removeItem`
    /// deletions — declared at REGISTRATION, consumed only through the
    /// runtime union, never read off items at clean time. Empty for
    /// scanners with none (CategoryScanner: its admission is
    /// category-policy).
    var trustedContainerRoots: [URL] { get }
    func scan(context: ScanContext) async -> ScanOutcome
}

// MARK: - Runtime

/// One scanner's VALIDATED result on the runtime's event stream: either its
/// outcome (every item ownership- and structure-checked) or the synthesized
/// path-less `malformedOutcome` issue that replaced it. Address resolution
/// never sees unvalidated outcomes — a malformed scanner's items cannot be
/// listed, selected, addressed, or deleted through any path.
enum ValidatedScannerEvent: Sendable {
    case outcome(scannerID: String, ScanOutcome)
    case malformed(scannerID: String, ScanIssue)
}

/// Registration-time refusals from the runtime's folded validation.
enum SpaceScannerRegistrationError: Error, Equatable {
    /// Scanner id does not match `[a-z0-9_]+`.
    case malformedScannerID(String)
    case duplicateScannerID(String)
    /// The combined category-slug/scanner-slug namespace has a collision
    /// (covers the frozen `categories` id: no category slug may spell it).
    case namespaceCollision(String)
}

/// The ONE trusted composition source (epic contract): scanner instances +
/// the cleaner configuration DERIVED from them. The production `CacheCleaner`
/// is constructed FROM the runtime (fn-2.3: `trustedContainerRoots` becomes
/// PathGuard's constructor-injected container roots), so "implement protocol
/// + register" automatically extends delete-time admission — and NOTHING
/// else does: items cannot widen admission.
struct SpaceScannerRuntime {

    let scanners: [any SpaceScanner]
    /// UNION of every scanner's declared `trustedContainerRoots`, in
    /// registration order, deduplicated by path.
    let trustedContainerRoots: [URL]

    /// The AUTHORITATIVE category registry, keyed by slug — registered at
    /// composition time alongside the scanners. Category-backed items are
    /// validated against THIS map (identity included), so an item carrying
    /// an invented `CacheCategory` can never widen admission past the
    /// registration-derived policy.
    private let registeredCategories: [String: CacheCategory]

    private let home: URL
    private let provider: FileSystemIdentityProvider

    /// Registration + FOLDED validation as one check (epic rounds 6-7):
    /// scanner-id slug syntax, scanner-id uniqueness, and the combined
    /// category-slug/scanner-slug namespace collision check. Injectable for
    /// tests — registering a fixture scanner requires zero production edits
    /// (R4).
    ///
    /// - Parameter categories: the category registry the `CategoryScanner`
    ///   adapter scans — registered HERE so scan-time validation has an
    ///   authoritative source to check category provenance against.
    init(
        scanners: [any SpaceScanner],
        categories: [CacheCategory],
        home: URL,
        provider: FileSystemIdentityProvider
    ) throws {
        var namespace = Set<String>()
        for scanner in scanners {
            let id = scanner.id
            guard Self.isValidSlug(id) else {
                throw SpaceScannerRegistrationError.malformedScannerID(id)
            }
            guard namespace.insert(id).inserted else {
                throw SpaceScannerRegistrationError.duplicateScannerID(id)
            }
        }
        var registered: [String: CacheCategory] = [:]
        for category in categories {
            guard namespace.insert(category.slug).inserted else {
                throw SpaceScannerRegistrationError.namespaceCollision(category.slug)
            }
            registered[category.slug] = category
        }

        var union: [URL] = []
        var seenRoots = Set<String>()
        for scanner in scanners {
            for root in scanner.trustedContainerRoots
            where seenRoots.insert(root.path).inserted {
                union.append(root)
            }
        }

        self.scanners = scanners
        self.registeredCategories = registered
        self.trustedContainerRoots = union
        self.home = home
        self.provider = provider
    }

    /// The production registry — the single place scanners are registered.
    /// fn-2.2 adds NodeModulesScanner here; the ViewModel (fn-2.4) and CLI
    /// (fn-2.6) both consume this factory.
    ///
    /// `try!` is deliberate: the registry is static configuration, so a
    /// registration-validation failure is a programmer error (a malformed or
    /// colliding slug in source) that unit tests catch before it can ship —
    /// there is no runtime input to recover from.
    static func production(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        provider: FileSystemIdentityProvider = FileSystemIdentityProvider()
    ) -> SpaceScannerRuntime {
        let categories = CacheCategory.allCategories
        let categoryScanner = CategoryScanner(
            categories: categories,
            scanner: CacheScanner(home: home, provider: provider)
        )
        return try! SpaceScannerRuntime(
            scanners: [categoryScanner],
            categories: categories,
            home: home,
            provider: provider
        )
    }

    /// The cleaner configuration derived from registration (R4 groundwork):
    /// delete-time container admission covers exactly the runtime union —
    /// never anything an item claims.
    func makeCleaner(
        trashHandler: CacheCleaner.TrashHandler? = nil
    ) -> CacheCleaner {
        CacheCleaner(
            home: home,
            containerRoots: trustedContainerRoots,
            provider: provider,
            trashHandler: trashHandler
        )
    }

    // MARK: Scan-time validation

    /// The SHARED fail-closed outcome validation (epic rounds 7-12) —
    /// applied INSIDE `scanValidated`; consumers never call it directly and
    /// never own validation. Checks, in order:
    ///
    /// (a) OWNERSHIP — every item's `scannerID` equals the producing
    ///     scanner's id;
    /// (b) UNIQUENESS — item ids are unique within the outcome;
    /// (c) STRUCTURE, STATE-AWARE — a `.removeItem` item MUST carry the
    ///     frozen `.containerItem` descriptor; `.removeContents`/`.commands`
    ///     items MUST ALWAYS carry category provenance; EMPTY root records
    ///     are valid exactly for `.missing` items (pre-dispatch-skipped) —
    ///     every NON-`.missing` `.removeContents`/`.commands` item requires
    ///     AT LEAST ONE root record (zero records on a non-missing item is
    ///     malformed, never vacuously admissible);
    /// (d) CATEGORY-PROVENANCE TRUST — category-backed actions are accepted
    ///     ONLY from the registered category adapter (the frozen
    ///     `categories` id), the item id must equal the carried category's
    ///     slug, and the carried category must BE the registered instance
    ///     for that slug. A category descriptor is a CLAIM: without this
    ///     binding, any scanner could invent a `CacheCategory` whose
    ///     declared roots or clean commands sit outside every
    ///     registration-derived policy — exactly the admission-widening the
    ///     runtime exists to prevent.
    ///
    /// Any violation replaces the WHOLE outcome with a synthesized path-less
    /// `.malformedOutcome` issue — nothing from a malformed outcome is
    /// published or reachable downstream. (`CacheCleaner` independently
    /// refuses the same shapes at dispatch, fn-2.3 — defense in depth.)
    func validatedOutcome(
        _ outcome: ScanOutcome, from scannerID: String
    ) -> ValidatedScannerEvent {
        Self.validatedOutcome(
            outcome, from: scannerID,
            registeredCategories: registeredCategories
        )
    }

    /// Static core so the stream's task-group children capture only the
    /// Sendable category map, never the runtime.
    private static func validatedOutcome(
        _ outcome: ScanOutcome,
        from scannerID: String,
        registeredCategories: [String: CacheCategory]
    ) -> ValidatedScannerEvent {
        var seenIDs = Set<String>()
        for item in outcome.items {
            guard item.scannerID == scannerID else {
                return .malformed(scannerID: scannerID, ScanIssue(
                    url: nil, kind: .malformedOutcome,
                    detail: "scanner '\(scannerID)' emitted an item owned by "
                        + "'\(item.scannerID)' (id '\(item.id)')"
                ))
            }
            guard seenIDs.insert(item.id).inserted else {
                return .malformed(scannerID: scannerID, ScanIssue(
                    url: nil, kind: .malformedOutcome,
                    detail: "scanner '\(scannerID)' emitted duplicate item id "
                        + "'\(item.id)'"
                ))
            }
            if let violation = structuralViolation(
                of: item, from: scannerID,
                registeredCategories: registeredCategories
            ) {
                return .malformed(scannerID: scannerID, ScanIssue(
                    url: nil, kind: .malformedOutcome,
                    detail: "scanner '\(scannerID)' item '\(item.id)': "
                        + violation
                ))
            }
        }
        return .outcome(scannerID: scannerID, outcome)
    }

    /// The state-aware structural invariants ((c)/(d) above). Exhaustive
    /// over `ReclaimAction` — a future action case must make this a
    /// compile-time decision, never a silent pass through `default:`.
    private static func structuralViolation(
        of item: ReclaimableItem,
        from scannerID: String,
        registeredCategories: [String: CacheCategory]
    ) -> String? {
        switch item.action {
        case .removeItem:
            switch item.admission {
            case .containerItem:
                return nil
            case .category:
                return "a .removeItem item must carry the .containerItem "
                    + "admission descriptor"
            }
        case .removeContents, .commands:
            switch item.admission {
            case .category(let carried):
                // (d) Category provenance is trusted only from the
                // registered adapter, and only for the registered category
                // INSTANCE. `CacheCategory` ids are per-launch UUIDs on
                // fully-immutable values, so identity equality pins the
                // exact registered declaration — a freshly-invented
                // category (even one reusing a registered slug) can never
                // match.
                if scannerID != CategoryScanner.registeredID {
                    return "category-backed \(item.action.wireString) items "
                        + "are accepted only from the registered category "
                        + "adapter ('\(CategoryScanner.registeredID)')"
                }
                if item.id != carried.slug {
                    return "aggregate item id '\(item.id)' must equal its "
                        + "category slug '\(carried.slug)'"
                }
                guard registeredCategories[carried.slug] == carried else {
                    return "category '\(carried.slug)' is not the registered "
                        + "category for that slug — provenance is a claim, "
                        + "and only registered categories are trusted"
                }
            case .containerItem:
                return "a \(item.action.wireString) item must carry category "
                    + "admission provenance"
            }
            // Empty root records are valid exactly for `.missing` items
            // (pre-dispatch-skipped); zero records on a non-missing item can
            // only be a construction bug — and would vacuously pass
            // `.commands` re-admission before executing argv.
            if item.state != .missing && item.rootRecords.isEmpty {
                return "a non-missing \(item.action.wireString) item requires "
                    + "at least one root record"
            }
            return nil
        }
    }

    // MARK: Validated-scan entry point

    /// The ONE scan-and-validate API (epic rounds 8-10, FROZEN shape): a
    /// progressive validated EVENT STREAM — each event is one scanner's
    /// validated outcome or its synthesized `malformedOutcome` issue. The
    /// scan `TaskGroup` and ALL validation live HERE; consumers pick scope
    /// and consumption style, never validation: the ViewModel (fn-2.4)
    /// consumes events as they arrive (no ViewModel-local TaskGroup, no
    /// direct `validatedOutcome` calls); the CLI handlers (fn-2.6) collect
    /// the same stream to completion.
    ///
    /// - Parameters:
    ///   - scannerIDs: SCANNER SUBSET to scan — only the named scanners run
    ///     (a scanner outside the subset is never invoked); nil = all
    ///     registered. Every subset flows through the same validator.
    ///   - context: passed to every scanner; its `categoryFilter` gives
    ///     category-granular scoping inside CategoryScanner.
    func scanValidated(
        scannerIDs: Set<String>? = nil,
        context: ScanContext
    ) -> AsyncStream<ValidatedScannerEvent> {
        let selected = scanners.filter { scanner in
            scannerIDs?.contains(scanner.id) ?? true
        }
        let registeredCategories = self.registeredCategories
        return AsyncStream { continuation in
            let task = Task {
                // Parallelism must not regress: scanners run concurrently
                // across the group (and internally parallel as today);
                // events yield in COMPLETION order — that is the
                // progressive-publishing contract.
                await withTaskGroup(of: ValidatedScannerEvent.self) { group in
                    for scanner in selected {
                        group.addTask {
                            let outcome = await scanner.scan(context: context)
                            return Self.validatedOutcome(
                                outcome, from: scanner.id,
                                registeredCategories: registeredCategories
                            )
                        }
                    }
                    for await event in group {
                        continuation.yield(event)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Slug syntax

    /// `[a-z0-9_]+` — the address grammar's slug alphabet (no colon, so the
    /// first `:` in a target token splits scanner slug from item id
    /// unambiguously).
    static func isValidSlug(_ slug: String) -> Bool {
        !slug.isEmpty && slug.utf8.allSatisfy { byte in
            (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
                || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                || byte == UInt8(ascii: "_")
        }
    }
}
