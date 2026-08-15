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
/// - `ReclaimAction`: `remove_contents` | `remove_item` | `commands` |
///   `git_worktree_reclaim` — `.commands` and `.gitWorktreeReclaim`
///   serialize ONLY their kind; argv arrays and plan paths never reach any
///   wire.
/// - `ScanIssue.Kind`: `container_refused` | `symlink_root` | `tcc_denied` |
///   `permission_denied` | `unreadable` | `config_invalid` |
///   `tool_unavailable` | `malformed_outcome`.
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
    /// Admitted, but nothing DELETABLE was established: sizing was denied
    /// before any measurement, or a mount boundary anywhere in the tree
    /// voids the whole target (R15 — `removeGuardedItem` refuses it
    /// entirely, so partial sibling measurements are deliberately not
    /// published as deletable). NOT deletable.
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

// MARK: - Git worktree reclaim plan (fn-5.3, D1/D13/D14)

/// The PLAN the composite `ReclaimAction` carries: what git is to be pointed
/// at, expressed as structured paths and a mode — never as argv.
///
/// ARGV PROVENANCE (the whole reason this is a plan and not a
/// `.commands([[String]])` payload): command argv is trusted registry code,
/// never item input (fn-2.3). The cleaner assembles
/// `["git", "-C", <parentRepoWorkingDir>, "worktree", "remove", <path>]` /
/// `["git", "-C", <parentRepoWorkingDir>, "worktree", "prune", "--expire=now"]`
/// from these fields plus its own constants at execution time (fn-5.4), so a
/// forged item can only mis-POINT a fixed command — and every path it could
/// point at is bound to the item's own admitted container by
/// `GitWorktreeReclaimPlan.violation(...)`. `.commands` is not an option at
/// all here: validator checks (f)/(g) require every `.commands` item to carry
/// a REGISTERED `CacheCategory` whose `cleanCommands` equal the argv, and
/// fn-5 has no category — one such item would malform the whole outcome.
///
/// WHY THE MODE-SPECIFIC FIELDS ARE OPTIONAL rather than associated values on
/// `Mode`: the shapes this type must REFUSE (a stale plan carrying a
/// disclosed set, a prune plan carrying a worktree path) have to be
/// REPRESENTABLE for the two independent checkers — the cleaner's
/// `structuralRefusal` and the runtime validator — to refuse them. A
/// mode-parameterized enum would make the forgeries unrepresentable in Swift
/// and thereby unTESTABLE, which is the wrong trade for a payload whose
/// entire job is to survive a hostile item: the cleaner explicitly never
/// assumes the validator ran (fn-2.7's headless path reaches it directly).
struct GitWorktreeReclaimPlan: Equatable, Sendable {

    /// The two reclaim shapes. They are NOT interchangeable: stale removal
    /// deletes ONE worktree tree, prune removes EVERY prunable admin
    /// directory of the repository (a repo-wide side effect — D14).
    enum Mode: Equatable, Sendable {
        /// `git -C <parent> worktree remove <worktreePath>`, with fn-5.4's
        /// guarded rm + gated prune fallback.
        case removeStaleWorktree
        /// `git -C <parent> worktree prune --expire=now` — repository-level,
        /// one item per repo, disclosing the COMPLETE set it will remove.
        case pruneOrphanedAdmin
    }

    let mode: Mode

    /// STALE MODE ONLY (nil in prune mode): the linked worktree to remove,
    /// verbatim as the scan spelled it. Must equal the admission
    /// descriptor's `requestedTargetURL`.
    let worktreePath: URL?

    /// STALE MODE ONLY (nil in prune mode): that worktree's own admin
    /// directory, `<parentAdminContainer>/<id>`, as the fn-5.1 resolver
    /// derived it. fn-5.4's post-fallback prune gate compares the RECOMPUTED
    /// prunable set against exactly this entry and prunes only when they are
    /// the same one directory (epic round 8) — without the carried entry the
    /// gate could not name what it is allowed to sweep.
    let worktreeAdminEntry: URL?

    /// BOTH MODES: git's `-C` target — the porcelain FIRST record's path
    /// (`WorktreeMembership.parentRepoWorkingDir`), which is the main working
    /// tree or the bare repository directory. NEVER derived from the git
    /// directory's parent: under `--separate-git-dir` that is not the working
    /// tree (fn-5.1's authority split).
    let parentRepoWorkingDir: URL

    /// BOTH MODES: the RESOLVER-carried `<parentGitDir>/worktrees`
    /// (`WorktreeMembership.parentAdminContainer`) — the admin data every
    /// mode mutates. NEVER reconstructed as `<parentRepoWorkingDir>/.git/
    /// worktrees`: a bare parent's git directory does not live at
    /// `<wd>/.git`, and a linked worktree of a bare main is not itself
    /// `bare`, so no gate would catch the mis-pathing (D13 revised).
    let parentAdminContainer: URL

    /// PRUNE MODE ONLY (empty in stale mode): the PROVABLY-COMPLETE set of
    /// admin directories the repository-level prune will remove, as
    /// disclosed to the user at scan time. fn-5.4 recomputes the set at
    /// delete time and refuses fail-closed on anything outside this
    /// disclosure (D14).
    let disclosedAdminDirectories: [URL]

    /// Stale-removal plan. The disclosed set is empty BY CONSTRUCTION here —
    /// a stale item discloses no repo-wide prune set.
    static func removeStaleWorktree(
        worktreePath: URL,
        worktreeAdminEntry: URL,
        parentRepoWorkingDir: URL,
        adminContainer: URL
    ) -> GitWorktreeReclaimPlan {
        GitWorktreeReclaimPlan(
            mode: .removeStaleWorktree,
            worktreePath: worktreePath,
            worktreeAdminEntry: worktreeAdminEntry,
            parentRepoWorkingDir: parentRepoWorkingDir,
            parentAdminContainer: adminContainer,
            disclosedAdminDirectories: []
        )
    }

    /// Repository-level prune plan. No worktree path and no admin entry by
    /// construction — the operation is not about one worktree.
    static func pruneOrphanedAdmin(
        parentRepoWorkingDir: URL,
        adminContainer: URL,
        disclosedAdminDirectories: [URL]
    ) -> GitWorktreeReclaimPlan {
        GitWorktreeReclaimPlan(
            mode: .pruneOrphanedAdmin,
            worktreePath: nil,
            worktreeAdminEntry: nil,
            parentRepoWorkingDir: parentRepoWorkingDir,
            parentAdminContainer: adminContainer,
            disclosedAdminDirectories: disclosedAdminDirectories
        )
    }

    // MARK: Structural rules (ONE rule set, two enforcing sites)

    /// Every path the plan can point git at, each with the name the refusal
    /// wording uses. The `..` screen below walks THIS list, so a field added
    /// later is screened by construction rather than by remembering to.
    private var labelledPaths: [(label: String, url: URL)] {
        var paths: [(String, URL)] = [
            ("parentRepoWorkingDir", parentRepoWorkingDir),
            ("parentAdminContainer", parentAdminContainer),
        ]
        if let worktreePath { paths.append(("worktreePath", worktreePath)) }
        if let worktreeAdminEntry {
            paths.append(("worktreeAdminEntry", worktreeAdminEntry))
        }
        paths += disclosedAdminDirectories.map { ("disclosed admin directory", $0) }
        return paths
    }

    /// The ONE structural rule set for a composite item — shared VERBATIM by
    /// `CacheCleaner.structuralRefusal` and
    /// `SpaceScannerRuntime.structuralViolation` (the
    /// `missingRevalidatorRefusal` precedent: one helper, two call sites, so
    /// the two enforcers can never diverge in wording OR in condition).
    /// Returns the bare reason; the cleaner prefixes it with `refused: `.
    ///
    /// What it defends: this plan is a CLAIM riding an item, and the item is
    /// the only thing `clean(items:)` receives. Every field is therefore
    /// bound to the item's OWN admitted container so a forged or regressed
    /// plan cannot point `git -C` at another repository on disk (D13).
    ///
    /// NOT its job: filesystem truth. Every check here is lexical, on the
    /// VERBATIM spellings — the root-capture doctrine forbids a second
    /// resolution at validation time (it would race the filesystem), and the
    /// delete-time subprocess-traversal guard (fn-5.4, D13) is what proves a
    /// leaf is a real directory canonically inside the container.
    static func violation(
        for item: ReclaimableItem, plan: GitWorktreeReclaimPlan
    ) -> String? {
        // The composite mutates ONE container's worth of git data, so it
        // needs the per-item container admission — a category descriptor
        // would admit by policy roots that have nothing to do with it.
        guard case .containerItem(let originContainer, let requestedTargetURL)
                = item.admission else {
            return "a git_worktree_reclaim item must carry the "
                + "container-item admission descriptor"
        }

        // (1) `..` SCREEN — FIRST, before any standardization (epic round
        // 9). Standardization ERASES `..` (`/a/../b` becomes `/b`), so a
        // containment check run on standardized spellings would accept a
        // traversal spelling as if it had been written plainly — and the
        // path that reaches git at execution time is the VERBATIM one.
        // Order here is the whole defense: screen raw components, then
        // standardize only for the containment comparison below.
        for (label, url) in plan.labelledPaths
        where url.pathComponents.contains("..") {
            return "the plan's \(label) '\(url.path)' contains a '..' "
                + "component — a traversal spelling is malformed, never "
                + "standardized away"
        }

        // (2) MODE SHAPE. Each mode's fields are exactly the ones its git
        // invocation consumes; carrying the OTHER mode's fields is a forged
        // or regressed plan, never a harmless extra.
        switch plan.mode {
        case .removeStaleWorktree:
            guard let worktreePath = plan.worktreePath else {
                return "a stale-removal plan must carry the worktree path it "
                    + "removes"
            }
            guard let adminEntry = plan.worktreeAdminEntry else {
                return "a stale-removal plan must carry the worktree's admin "
                    + "entry — the post-fallback prune gate identifies the "
                    + "one entry it may sweep by that path"
            }
            if !plan.disclosedAdminDirectories.isEmpty {
                return "a stale-removal plan must disclose no prune set — a "
                    + "repository-wide prune set belongs to the prune-only "
                    + "mode, and undisclosed sweeping is what D14 forbids"
            }
            // The deletion target is the descriptor's, never the plan's: if
            // they disagree, the item was admitted for one path and would
            // execute against another.
            if worktreePath.path != requestedTargetURL.path {
                return "the plan's worktree path '\(worktreePath.path)' is "
                    + "not the admitted requestedTargetURL "
                    + "'\(requestedTargetURL.path)' — the path admitted and "
                    + "the path removed must be the same one"
            }
            if !isStrictDescendant(adminEntry, of: plan.parentAdminContainer) {
                return "the worktree's admin entry '\(adminEntry.path)' is "
                    + "not inside the carried admin container "
                    + "'\(plan.parentAdminContainer.path)'"
            }
        case .pruneOrphanedAdmin:
            if let worktreePath = plan.worktreePath {
                return "a prune-only plan must carry no worktree path "
                    + "(carried '\(worktreePath.path)') — the operation is "
                    + "repository-level and removes no checkout"
            }
            if let adminEntry = plan.worktreeAdminEntry {
                return "a prune-only plan must carry no worktree admin entry "
                    + "(carried '\(adminEntry.path)') — its removal set is "
                    + "the disclosed set, not one worktree's entry"
            }
            if plan.disclosedAdminDirectories.isEmpty {
                return "a prune-only plan must disclose the non-empty set of "
                    + "admin directories the repository-level prune removes"
            }
            // The item's admitted target IS the container being mutated —
            // compared against the CARRIED field, never against a
            // `<wd>/.git/worktrees` reconstruction (D13: a bare parent's git
            // directory does not live there).
            if requestedTargetURL.path != plan.parentAdminContainer.path {
                return "the prune-only plan's admitted requestedTargetURL "
                    + "'\(requestedTargetURL.path)' is not the carried admin "
                    + "container '\(plan.parentAdminContainer.path)'"
            }
            for directory in plan.disclosedAdminDirectories
            where !isStrictDescendant(directory, of: plan.parentAdminContainer) {
                return "disclosed admin directory '\(directory.path)' is not "
                    + "inside the carried admin container "
                    + "'\(plan.parentAdminContainer.path)'"
            }
        }

        // (3) MUTATION SCOPE, both modes (D13). The admin container holds
        // the data git rewrites, so it must sit STRICTLY inside the item's
        // own admitted container — a plan whose admin container IS the
        // container would put every sibling of the repository in scope.
        if !isStrictDescendant(plan.parentAdminContainer, of: originContainer) {
            return "the plan's admin container "
                + "'\(plan.parentAdminContainer.path)' is not strictly "
                + "inside the admitted originContainer "
                + "'\(originContainer.path)' — a plan may only mutate git "
                + "data inside its own admitted container"
        }
        // The `-C` target may EQUAL the container: a dev root that IS a
        // repository is a legal, common shape (epic round 4) — only its
        // strictly-contained admin data is mutated. Anything OUTSIDE is a
        // forged mutation scope.
        if !isDescendantOrEqual(plan.parentRepoWorkingDir, of: originContainer) {
            return "the plan's parent repository "
                + "'\(plan.parentRepoWorkingDir.path)' is outside the "
                + "admitted originContainer '\(originContainer.path)' — git "
                + "would be pointed at a repository this item never admitted"
        }

        // (4) MEASURED-RECORD / DISPLAY BINDING, mirrored from the
        // `.removeItem` arm. In the states the cleaner dispatches, the
        // admitted target must be one of the scan's OWN `.measured`
        // captures, and the item's display identity must be that same
        // record's resolution — otherwise a forged item could measure and
        // show one capture while executing against another admitted path.
        // Exhaustive over `ScanState` so a future state decides at compile
        // time; the non-deletable states never reach execution.
        switch item.state {
        case .measured, .partiallyDenied:
            let bound = item.rootRecords.filter { record in
                record.status == .measured
                    && record.requestedURL.path == requestedTargetURL.path
            }
            if bound.isEmpty {
                return "a deletable git_worktree_reclaim item must carry a "
                    + "measured root record capturing its "
                    + "requestedTargetURL — the measured path and the "
                    + "reclaim target must be the same capture"
            }
            let displayBound = bound.contains { record in
                record.resolvedURL?.path == item.url?.path
            }
            if !displayBound {
                return "a deletable git_worktree_reclaim item's display url "
                    + "must be the resolved identity of the record binding "
                    + "its target — the path shown and the path reclaimed "
                    + "must be the same capture"
            }
        case .missing, .empty, .denied:
            break
        }

        return nil
    }

    /// STRICT lexical containment on STANDARDIZED spellings, compared as
    /// `pathComponents` arrays — never `hasPrefix` (`/a/bc` is not inside
    /// `/a/b`), the PathGuard doctrine (PathGuard.swift:45). Standardization
    /// runs only AFTER the `..` screen above; it collapses `.`, `//` and
    /// trailing slashes so two spellings of one path compare equal, and it
    /// resolves NO symlinks (that is delete-time's job).
    private static func isStrictDescendant(_ candidate: URL, of ancestor: URL) -> Bool {
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        let ancestorComponents = ancestor.standardizedFileURL.pathComponents
        guard candidateComponents.count > ancestorComponents.count else {
            return false
        }
        return Array(candidateComponents.prefix(ancestorComponents.count))
            == ancestorComponents
    }

    /// Descendant OR EQUAL — used for `parentRepoWorkingDir` alone.
    private static func isDescendantOrEqual(_ candidate: URL, of ancestor: URL) -> Bool {
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        let ancestorComponents = ancestor.standardizedFileURL.pathComponents
        guard candidateComponents.count >= ancestorComponents.count else {
            return false
        }
        return Array(candidateComponents.prefix(ancestorComponents.count))
            == ancestorComponents
    }
}

// MARK: - Reclaim action

/// How an item's bytes are reclaimed. Dispatch with EXHAUSTIVE switches (no
/// `default:`) — fn-5 adds a composite case (git worktree remove → fallback
/// removeItem + prune) and that addition must be a compile-time-visible
/// change. Do not encode "there are exactly four actions" anywhere.
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
    /// The fn-5 COMPOSITE reclaim: a git-mediated worktree removal, or a
    /// repository-level prune of orphaned worktree admin directories. The
    /// payload is a PLAN of structured paths — never argv. The cleaner
    /// builds the argv from the plan's fields plus registry-controlled
    /// constants, so command argv stays trusted registry code exactly as it
    /// is for `.commands` (fn-2.3's argv-provenance rule).
    case gitWorktreeReclaim(GitWorktreeReclaimPlan)

    /// FROZEN wire strings (epic contract; `ScanError.Kind.wireString`
    /// precedent). `.commands` and `.gitWorktreeReclaim` serialize ONLY
    /// their kind — argv arrays and plan paths are NEVER exposed on any wire
    /// surface (deliberate non-exposure: the CLI JSON is a reporting
    /// surface, not an execution contract).
    var wireString: String {
        switch self {
        case .removeContents: return "remove_contents"
        case .removeItem: return "remove_item"
        case .commands: return "commands"
        // SITE 5 of 8 (fn-5.3): FROZEN at merge, snake_case like its three
        // siblings and the PROTOCOL.md action rows.
        case .gitWorktreeReclaim: return "git_worktree_reclaim"
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
    /// opaque string (no whitespace, no colon, no NUL — it must fit the
    /// `<scanner-slug>:<item-id>` grammar slot AND survive a POSIX argv
    /// round trip). A category aggregate's id is the category SLUG;
    /// per-item scanners derive ids via `stableID`.
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

    /// ADDITIVE (fn-4.4, R3/R17) — the structural record of what the
    /// scan-time valuables probe SAW inside this item: the disclosed valuable
    /// identity set (already in the ONE canonical order) plus the probe's
    /// COMPLETENESS. `nil` for every scanner that runs no such probe (every
    /// scanner but `build_artifacts` today) — absent, never a fake "clean and
    /// complete".
    ///
    /// **DISCLOSURE IS NEVER CONSENT.** This field records what was shown; it
    /// is NEVER read as acknowledgement. Both a GUI clean and an
    /// unacknowledged CLI clean hand the revalidator this same scanned item —
    /// only the per-clean `[ItemKey: acknowledgement]` authorization context
    /// distinguishes them (fn-4.6/fn-4.8/fn-4.9).
    let valuablesDisclosure: ValuablesDisclosure?

    /// ADDITIVE (fn-4.4, R17, D8) — the SCANNER-AGNOSTIC structural signal
    /// that this item MUST be re-inspected immediately before deletion.
    /// Default `false`: every existing scanner's items are unaffected until
    /// fn-4.8's orphaned-caches migration. fn-4.8's generalized cleaner fails
    /// CLOSED whenever the marker is set but no revalidator is registered for
    /// the item's scanner — so a direct `CacheCleaner` construction without
    /// the registry refuses marked items of ANY scanner.
    let requiresPreDeleteRevalidation: Bool

    /// EXPLICIT memberwise initializer (fn-4.4): the two additive fields
    /// above default, so no existing construction site changes — the
    /// `logicalBytes` additive precedent, one field-set later. Every stored
    /// property stays `let` (a synthesized memberwise init cannot default a
    /// `let`, which is the only reason this is written out).
    init(
        id: String,
        scannerID: String,
        displayName: String,
        exactBytes: Int64,
        estimatedUpToBytes: Int64,
        logicalBytes: Int64?,
        itemCount: Int,
        url: URL?,
        declaredDisplayPath: String,
        rootRecords: [RootScanRecord],
        state: ScanState,
        scanError: ScanError?,
        risk: RiskLevel,
        evidence: String,
        rebuildNote: String?,
        action: ReclaimAction,
        admission: AdmissionDescriptor,
        defaultSelected: Bool,
        automaticCleanEligible: Bool,
        isStale: Bool?,
        valuablesDisclosure: ValuablesDisclosure? = nil,
        requiresPreDeleteRevalidation: Bool = false
    ) {
        self.id = id
        self.scannerID = scannerID
        self.displayName = displayName
        self.exactBytes = exactBytes
        self.estimatedUpToBytes = estimatedUpToBytes
        self.logicalBytes = logicalBytes
        self.itemCount = itemCount
        self.url = url
        self.declaredDisplayPath = declaredDisplayPath
        self.rootRecords = rootRecords
        self.state = state
        self.scanError = scanError
        self.risk = risk
        self.evidence = evidence
        self.rebuildNote = rebuildNote
        self.action = action
        self.admission = admission
        self.defaultSelected = defaultSelected
        self.automaticCleanEligible = automaticCleanEligible
        self.isStale = isStale
        self.valuablesDisclosure = valuablesDisclosure
        self.requiresPreDeleteRevalidation = requiresPreDeleteRevalidation
    }

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

    /// The ONE 30-day staleness threshold behind every item's `isStale`
    /// field and the GUI's "Select Stale (30d+)" section action — inherited
    /// VERBATIM from the retired `NodeModulesItem` (fn-4.7), which was its
    /// only home while node_modules was the only per-item scanner. It lives
    /// on the item model now because the field it decides does: a scanner
    /// that dates its content maps days-since to this predicate, and one
    /// threshold means the badge and the selection policy can never drift.
    /// `nil` days (nothing dated) is NEVER stale — an unknown age must not
    /// read as an old one.
    static func isStale(daysSinceModified days: Int?) -> Bool {
        guard let days else { return false }
        return days > 30
    }
}

// MARK: - Scan outcome & issues

/// A classified, non-fatal root/scanner-level problem that produced NO item.
/// Two-surface rule (epic contract): impediments attributable to an emitted
/// item ride the item's `state`/`scanError`; only root/scanner-level
/// problems with no recognized candidate land here.
struct ScanIssue: Equatable, Sendable {
    /// EXTENSIBLE taxonomy (proven by `malformedOutcome`) — never write
    /// consumers that assume the case list is closed. Generalizes the
    /// retired `NodeModulesScanIssue.Kind` scanner-agnostically.
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
        /// A PERSISTED configuration value this build cannot parse (fn-4,
        /// R8/R16 — e.g. a `devRoots` array whose shape is invalid). The
        /// scanner fell back to its defaults WITHOUT rewriting the stored
        /// value; the fallback is never silent — this issue rides every
        /// scan outcome while the corrupt value persists. A NON-filesystem
        /// kind: a config parse failure has no honest filesystem path, so
        /// `url` is nil and a fake path is never invented. (Policy-REJECTED
        /// configured roots are NOT this kind — they carry their offending
        /// path honestly under the frozen `.containerRefused`.)
        case configInvalid
        /// An EXTERNAL TOOL a scanner depends on is unavailable (fn-5, D12
        /// revised — e.g. `git` missing from the runner's fixed PATH, or its
        /// availability probe failing). The affected scan produced no
        /// results BECAUSE the tool could not run, and that must be VISIBLE:
        /// a tool-less scan reporting zero findings is indistinguishable
        /// from a clean machine. Another NON-filesystem kind: the problem is
        /// the toolchain, not a path, so `url` is nil and a fake path is
        /// never invented (the round-3 rejection of reusing `.unreadable`
        /// with a nil url — `url` is required BY CONTRACT for the
        /// filesystem kinds). `detail` names the tool and the context.
        case toolUnavailable
        /// Synthesized ONLY by `SpaceScannerRuntime.validatedOutcome` when a
        /// scanner's outcome fails ownership/structural validation — never
        /// produced by scanners themselves. RESERVED and enforced (check
        /// (h)): a scanner-authored instance in `ScanOutcome.errors` is
        /// itself a validation violation that malforms the whole outcome —
        /// the wire contract says this kind means the outcome was rejected
        /// and its items excluded, so a scanner must not be able to publish
        /// items BESIDE a `malformed_outcome` row.
        case malformedOutcome

        /// FROZEN wire strings, case-by-case (epic contract).
        var wireString: String {
            switch self {
            case .containerRefused: return "container_refused"
            case .symlinkRoot: return "symlink_root"
            case .tccDenied: return "tcc_denied"
            case .permissionDenied: return "permission_denied"
            case .unreadable: return "unreadable"
            case .configInvalid: return "config_invalid"
            case .toolUnavailable: return "tool_unavailable"
            case .malformedOutcome: return "malformed_outcome"
            }
        }
    }

    /// Required BY CONVENTION for the filesystem kinds; nil for the
    /// NON-filesystem kinds (`.malformedOutcome`, `.configInvalid`,
    /// `.toolUnavailable`) — no filesystem location exists, and a fake path
    /// must never be invented.
    /// The wire `path` key is conditional on the same rule.
    let url: URL?
    let kind: Kind
    let detail: String
}

/// What one scanner's scan produced: items plus root/scanner-level issues.
struct ScanOutcome: Sendable {
    var items: [ReclaimableItem]
    var errors: [ScanIssue]
}

// MARK: - Pre-delete revalidator seam (fn-4.8, R17/D8)

/// One revalidator's answer for ONE item, immediately before its deletion.
///
/// A revalidation can only ever REFUSE — it NEVER widens admission (the
/// as-built chokepoint doctrine, preserved verbatim through the
/// generalization). Everything a refusal needs downstream is TYPED: fn-4.9's
/// wire rows serialize from this payload, never by parsing the prose reason.
enum PreDeleteVerdict: Equatable, Sendable {
    /// Nothing the delete-time inspection saw stands in the way. The
    /// deletion still faces every other gate (admission, snapshot identity,
    /// containment, mount boundaries).
    case allow
    /// FAIL-CLOSED refusal. `reason` is the item-keyed human detail (the
    /// error surface + the REFUSED log line); `valuables` is the CURRENT
    /// probe's set in the ONE canonical order (empty for revalidators with
    /// no valuables model, e.g. orphaned caches); `acknowledgementToken` is
    /// present ONLY for a COMPLETE probe with a NON-EMPTY current set —
    /// the uniform R17 rule (an incomplete probe is unauthorizable and
    /// tokenless; a vanished set has nothing to acknowledge).
    case refuse(
        reason: String,
        valuables: [DetectedValuable],
        acknowledgementToken: String?
    )
}

/// The per-clean `[ItemKey: acknowledgement]` AUTHORIZATION CONTEXT.
///
/// Built ONCE per clean invocation by the surface that obtained the user's
/// acknowledgement (fn-4.6's confirmation sheet, fn-4.9's
/// `--acknowledge-valuables` flags) and handed down the deletion path so
/// each item's revalidator receives ITS OWN entry (nil when absent). The
/// item's structural `valuablesDisclosure` is DISCLOSURE ONLY and is NEVER
/// read as acknowledgement — otherwise an unacknowledged CLI clean of the
/// same scanned item would count as acknowledged.
typealias PreDeleteAuthorizationContext = [ItemKey: String]

/// The GENERALIZED per-scanner revalidator (the seam the as-built cleaner
/// comment promised fn-4/fn-5). A `Sendable` VALUE with exactly two members,
/// declared by the scanner that owns the probe and captured by the runtime
/// at registration — the cleaner owns the chokepoint, the scanner owns what
/// "still safe to delete" means for its own items.
///
/// Runs SYNCHRONOUSLY on the cleaner's execution context (off the main
/// actor), bounded by its scanner's shared probe caps.
struct PreDeleteRevalidator: Sendable {
    /// PURE, DETERMINISTIC item-SHAPE predicate — no filesystem access, no
    /// state, no I/O of any kind. It is called during SCAN-TIME validation
    /// (the applicable-but-unmarked structural invariant below) as well as
    /// at the chokepoint, so it must answer identically in both places from
    /// the item alone. ALL probing belongs in `revalidate`.
    private let applicability: @Sendable (ReclaimableItem) -> Bool

    /// The delete-time inspection. `authorization` is the item's OWN entry
    /// from the per-clean authorization context (nil when absent).
    private let inspection:
        @Sendable (ReclaimableItem, String?) -> PreDeleteVerdict

    init(
        requiresRevalidation: @escaping @Sendable (ReclaimableItem) -> Bool,
        revalidate:
            @escaping @Sendable (ReclaimableItem, String?) -> PreDeleteVerdict
    ) {
        self.applicability = requiresRevalidation
        self.inspection = revalidate
    }

    /// The registry's OWN applicability opinion — the BELT half of the
    /// belt-and-braces dispatch (the `requiresPreDeleteRevalidation` marker
    /// is the braces): an item this returns true for is re-probed at the
    /// chokepoint even if a mapping regression forgot to mark it.
    func requiresRevalidation(item: ReclaimableItem) -> Bool {
        applicability(item)
    }

    /// The delete-time verdict for ONE item, with ITS authorization entry.
    func revalidate(
        item: ReclaimableItem, authorization: String?
    ) -> PreDeleteVerdict {
        inspection(item, authorization)
    }
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
    /// This scanner's DELETE-TIME revalidator (fn-4.8, R17/D8) — DEFAULT
    /// NIL, so a scanner that needs none changes zero lines. Captured by
    /// the runtime AT REGISTRATION into a scanner-ID-keyed registry and
    /// injected into the cleaner's constructor; never read off items, never
    /// global state.
    var preDeleteRevalidator: PreDeleteRevalidator? { get }
    func scan(context: ScanContext) async -> ScanOutcome
}

extension SpaceScanner {
    /// The default: no delete-time revalidation. Every scanner that existed
    /// before fn-4.8 inherits this unchanged.
    var preDeleteRevalidator: PreDeleteRevalidator? { nil }
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

/// One RUNNING validated scan (review P2): the progressive event stream
/// plus the unstructured producer task that drives the scan `TaskGroup`.
/// The producer is private — a consumer can WAIT for it, never steer it
/// (stream termination remains the one cancellation path).
struct ValidatedScanSession {
    /// The session's container-identity snapshot (fn-3.4, R9): every
    /// REGISTERED container root's no-follow (device, inode), captured
    /// BEFORE any scanner task launched — so anything swapped DURING the
    /// scan already mismatches at delete time. Cleaning this session's
    /// items must go through `makeCleaner(snapshot:)` with THIS snapshot;
    /// capture is part of the session on purpose (a consumer cannot
    /// misorder it), and absent roots are omitted (fail-closed downstream).
    let snapshot: ContainerSnapshot
    /// Progressive validated events — the identical frozen contract
    /// `scanValidated` returns (that API is now a thin wrapper over this).
    let events: AsyncStream<ValidatedScannerEvent>
    fileprivate let producer: Task<Void, Never>

    /// Suspends until the producer task has ACTUALLY returned — scanners
    /// finished or wound down, the group drained. Deliberately
    /// NON-cancellable: `Task<_, Never>.value` cannot throw, so awaiting it
    /// from an already-cancelled task still waits out the wind-down — the
    /// entire point is to hold a "scan in progress" guard honestly PAST the
    /// consumer's own cancellation. In the normal completion path the
    /// producer has already finished by the time `events` ends, so the
    /// await returns immediately.
    func untilProducerFinishes() async {
        await producer.value
    }
}

/// Registration-time refusals from the runtime's folded validation.
enum SpaceScannerRegistrationError: Error, Equatable {
    /// Scanner id does not match `[a-z0-9_]+`.
    case malformedScannerID(String)
    case duplicateScannerID(String)
    /// Category slug does not match `[a-z0-9_]+` — the address grammar
    /// covers category slugs exactly as it covers scanner slugs (a colon
    /// or whitespace in an aggregate item id would break CLI addressing).
    case malformedCategorySlug(String)
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

    /// PER-SCANNER declared container roots, captured at registration
    /// (round 6). Delete-time admission deliberately checks the UNION
    /// above (frozen R4 design: registration alone extends admission), so
    /// the union cannot tell WHICH scanner declared a root — scan-time
    /// validation therefore binds each container-item origin claim to the
    /// PRODUCING scanner's own declaration through this map, never the
    /// union.
    private let declaredContainerRoots: [String: [URL]]

    /// The AUTHORITATIVE category registry, keyed by slug — registered at
    /// composition time alongside the scanners. Category-backed items are
    /// validated against THIS map (identity included), so an item carrying
    /// an invented `CacheCategory` can never widen admission past the
    /// registration-derived policy.
    private let registeredCategories: [String: CacheCategory]

    /// PER-SCANNER delete-time revalidators (fn-4.8, R17/D8), captured AT
    /// CONSTRUCTION from each scanner's default-nil declaration. Two
    /// consumers, one source: `makeCleaner(snapshot:)` injects this map into
    /// the cleaner's constructor (never global state), and scan-time
    /// validation reads the PRODUCING scanner's entry to enforce the
    /// applicable-but-unmarked structural invariant. A scanner without a
    /// declaration is absent here — its items behave exactly as before.
    private let preDeleteRevalidators: [String: PreDeleteRevalidator]

    private let home: URL
    private let provider: FileSystemIdentityProvider

    /// The SHARED git runner (fn-5.1), held at the composition layer and
    /// handed to every cleaner this runtime builds (fn-5.4). ONE instance per
    /// runtime by design: fn-5.1 made the `git --version` availability cache
    /// INSTANCE-scoped, so a second runner built elsewhere would probe (and
    /// cache) independently — and detection and execution must agree about
    /// whether git exists at all. `nil` stays the fail-closed default for
    /// runtimes composed without one (every test runtime today), which makes
    /// their cleaners refuse composite items per item.
    ///
    /// fn-5.5's `GitWorktreeScanner` must be constructed with THIS SAME
    /// instance when fn-5.6 registers it — never with a fresh one.
    let gitRunner: (any GitCommandRunning)?

    /// Registration + FOLDED validation as one check (epic rounds 6-7):
    /// scanner-id slug syntax, scanner-id uniqueness, and the combined
    /// category-slug/scanner-slug namespace collision check. Injectable for
    /// tests — registering a fixture scanner requires zero production edits
    /// (R4).
    ///
    /// - Parameter categories: the category registry the `CategoryScanner`
    ///   adapter scans — registered HERE so scan-time validation has an
    ///   authoritative source to check category provenance against.
    /// - Parameter gitRunner: the SHARED fn-5.1 runner (see the stored
    ///   property). TRAILING and DEFAULTED so every existing composition
    ///   compiles unchanged; the default `nil` keeps those runtimes'
    ///   cleaners fail-closed for composite items.
    init(
        scanners: [any SpaceScanner],
        categories: [CacheCategory],
        home: URL,
        provider: FileSystemIdentityProvider,
        gitRunner: (any GitCommandRunning)? = nil
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
            // Category slugs live in the SAME address grammar as scanner
            // slugs (aggregate item ids ARE the slugs) — validate them with
            // the same rule, or a `bad:slug` category would ship an
            // unaddressable aggregate through the `try!` factory.
            guard Self.isValidSlug(category.slug) else {
                throw SpaceScannerRegistrationError.malformedCategorySlug(category.slug)
            }
            guard namespace.insert(category.slug).inserted else {
                throw SpaceScannerRegistrationError.namespaceCollision(category.slug)
            }
            registered[category.slug] = category
        }

        var union: [URL] = []
        var seenRoots = Set<String>()
        var declared: [String: [URL]] = [:]
        var revalidators: [String: PreDeleteRevalidator] = [:]
        for scanner in scanners {
            declared[scanner.id] = scanner.trustedContainerRoots
            // Captured ONCE, here — the same registration act that extends
            // delete-time admission also declares how this scanner's items
            // are re-inspected before deletion (fn-4.8).
            revalidators[scanner.id] = scanner.preDeleteRevalidator
            for root in scanner.trustedContainerRoots
            where seenRoots.insert(root.path).inserted {
                union.append(root)
            }
        }

        self.scanners = scanners
        self.registeredCategories = registered
        self.trustedContainerRoots = union
        self.declaredContainerRoots = declared
        self.preDeleteRevalidators = revalidators
        self.home = home
        self.provider = provider
        self.gitRunner = gitRunner
    }

    /// The production registry — the single place scanners are registered.
    /// The ViewModel (fn-2.4) and CLI (fn-2.6) both consume this factory.
    /// A per-item scanner's registration is what puts its roots in the
    /// runtime's container-root union — delete-time admission derives from
    /// HERE, never from items.
    ///
    /// **THE ATOMIC SWAP (fn-4.5, R6/D4).** `BuildArtifactsScanner` REPLACES
    /// `NodeModulesScanner` in ONE composition change, with no interval in
    /// which both are registered: two registered scanners would double-list
    /// the same directories (no cross-scanner dedupe exists — D4) AND leave
    /// the legacy slug emitting UNMARKED, non-revalidated items for trees
    /// that can contain `.app`/`.dmg` release artifacts (an R17 bypass).
    /// Unregistration retires the `node_modules` slug's ADDRESSABILITY
    /// immediately — slug addressing derives from the registered scanners —
    /// while the class, its direct tests, and its dead source survive until
    /// fn-4.7's migration + deletion. `node_modules/` trees are still found:
    /// they are one row of fn-4.1's rule table, listed under
    /// `build_artifacts` with the same `.review` risk the as-built scanner
    /// declared.
    ///
    /// `try!` is deliberate: the registry is static configuration, so a
    /// registration-validation failure is a programmer error (a malformed or
    /// colliding slug in source) that unit tests catch before it can ship —
    /// there is no runtime input to recover from.
    /// - Parameter orphanedCachesThresholds: the sweep scanner's
    ///   classification thresholds (R8). `nil` — the GUI's composition —
    ///   resolves defaults → UserDefaults; the CLI passes an
    ///   invocation-scoped layering that additionally folds in its flags
    ///   (never persisted). Thresholds are scanner-construction state by
    ///   frozen contract: they do not ride `ScanContext`.
    /// - Parameter devRoots: the build-artifacts scanner's resolved dev
    ///   roots (fn-4.1's `{keptRoots, issues}`) — CONSTRUCTION state, not
    ///   `ScanContext` (D1: `trustedContainerRoots` freeze at registration,
    ///   so changing roots REBUILDS the runtime). `nil` — the GUI's
    ///   composition — resolves the persisted `DevRootsStore` here, exactly
    ///   as `orphanedCachesThresholds` does; the CLI passes an
    ///   invocation-scoped replacement (`--dev-root`, fn-4.6) that is never
    ///   persisted. `keptRoots` become the scanner's declared container
    ///   roots (and the walker's roots); `issues` ride EVERY scan outcome,
    ///   so a policy-rejected persisted root stays visible while never
    ///   registering or walking (R16).
    static func production(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        provider: FileSystemIdentityProvider = FileSystemIdentityProvider(),
        orphanedCachesThresholds: OrphanedCacheClassifier.Thresholds? = nil,
        devRoots: DevRootsResolution? = nil
    ) -> SpaceScannerRuntime {
        let categories = CacheCategory.allCategories
        let categoryScanner = CategoryScanner(
            categories: categories,
            scanner: CacheScanner(home: home, provider: provider)
        )
        let buildArtifactsScanner = BuildArtifactsScanner(
            home: home,
            devRoots: devRoots
                ?? DevRootsStore(provider: provider)
                    .effectiveRoots(home: home),
            provider: provider
        )
        // fn-3.3's production resolver, wired in as the classifier's
        // tri-state predicate; one instance per runtime so its lazy census
        // is built at most once per process.
        let installedAppResolver = InstalledAppResolver(home: home)
        let orphanedCachesScanner = OrphanedCachesScanner(
            home: home,
            provider: provider,
            thresholds: orphanedCachesThresholds
                ?? OrphanedCachesSweepConfig.resolvedThresholds(),
            installedAppStatus: { installedAppResolver.status(ofBundleID: $0) }
        )
        return try! SpaceScannerRuntime(
            scanners: [
                categoryScanner, buildArtifactsScanner, orphanedCachesScanner,
            ],
            categories: categories,
            home: home,
            provider: provider,
            // The SHARED git runner (fn-5.1/fn-5.4): built ONCE here so the
            // cleaner this runtime makes can execute `git_worktree_reclaim`
            // instead of refusing it fail-closed. Inert until an item exists
            // — nothing constructs a subprocess and nothing probes for git
            // until a composite item is actually cleaned, and no registered
            // scanner emits one until fn-5.5.
            //
            // fn-5.6 registers `GitWorktreeScanner` with THIS instance (hold
            // it in a local above and pass it to both) — a second runner
            // would fork fn-5.1's deliberately instance-scoped availability
            // cache, letting the scan and the clean disagree about whether
            // git exists.
            gitRunner: GitCommandRunner(home: home)
        )
    }

    /// The cleaner configuration derived from registration (R4 groundwork):
    /// delete-time container admission covers exactly the runtime union —
    /// never anything an item claims.
    ///
    /// - Parameter snapshot: the container-identity snapshot of the scan
    ///   session that produced the items this cleaner will consume
    ///   (`ValidatedScanSession.snapshot`). `nil` is FAIL-CLOSED: every
    ///   `.removeItem` deletion is refused (`container-unavailable`) —
    ///   there is deliberately no fail-open path.
    ///
    /// The REGISTRATION-captured revalidator registry rides along beside the
    /// snapshot (fn-4.8): a cleaner built THROUGH the runtime can always
    /// honour a `requiresPreDeleteRevalidation` marker, and a cleaner built
    /// without one fails closed on marked items.
    ///
    /// The runtime's SHARED git runner rides along the same way (fn-5.4): a
    /// cleaner built THROUGH a runtime that holds one can EXECUTE
    /// `git_worktree_reclaim`, and a cleaner built through a runtime without
    /// one (or constructed directly) refuses those items per item —
    /// fail-closed, never a silent no-op. `production(...)` always supplies
    /// it, so the GUI and CLI paths are wired end to end.
    func makeCleaner(
        snapshot: ContainerSnapshot? = nil,
        trashHandler: CacheCleaner.TrashHandler? = nil
    ) -> CacheCleaner {
        CacheCleaner(
            home: home,
            containerRoots: trustedContainerRoots,
            containerSnapshot: snapshot,
            preDeleteRevalidators: preDeleteRevalidators,
            provider: provider,
            trashHandler: trashHandler,
            gitRunner: gitRunner
        )
    }

    // MARK: Scan-time validation

    /// The SHARED fail-closed outcome validation (epic rounds 7-12; the
    /// value-domain and state-coherence checks close round 13) — applied
    /// INSIDE `scanValidated`; consumers never call it directly and never
    /// own validation. Checks, in order:
    ///
    /// (a) OWNERSHIP — every item's `scannerID` equals the producing
    ///     scanner's id;
    /// (b) ID FORM — every item id is a NONEMPTY, CLI-safe opaque string
    ///     (no whitespace, no colon, no U+0000 — the documented
    ///     `ReclaimableItem.id` invariant): an empty or unaddressable id
    ///     would publish an item `scan` prints but whose
    ///     `<scanner>:<item-id>` address `parseCleanTargets` can never
    ///     accept — and a NUL id could never even be SPELLED as an argv
    ///     token (`isCLISafeItemID` documents the exact boundary);
    /// (c) UNIQUENESS — item ids are unique within the outcome;
    /// (d) VALUE DOMAIN — every numeric field is a sane physical quantity:
    ///     byte components and `itemCount` nonnegative, `logicalBytes`
    ///     (when carried) nonnegative, and `exactBytes +
    ///     estimatedUpToBytes` representable in Int64. `allocatedBytes` is
    ///     a COMPUTED sum touched by `scanEnvelope` rows, GUI totals, size
    ///     sorting, and clean plans — an overflowing pair would trap the
    ///     first consumer instead of producing `malformed_outcome`
    ///     (`valueDomainViolation`). The OUTCOME-WIDE half (round 8): the
    ///     sum of `allocatedBytes` ACROSS the outcome's items must also be
    ///     representable — two individually valid items can still claim
    ///     more than Int64.max bytes together, which no real scan can
    ///     (> 9.2 EB), and the cross-item sum is exactly what every
    ///     single-scanner consumer total computes. fn-4.4 extends this SAME
    ///     family (no new family) to every numeric of the additive
    ///     `valuablesDisclosure`: each valuable's `allocatedBytes`
    ///     nonnegative, `modifiedNanoseconds` in `[0, 1e9)`, and
    ///     `modifiedSeconds` inside the range where the derived
    ///     `modified_at_ns` still fits Int64 — checked-REJECT, never
    ///     saturated. Cross-SCANNER totals
    ///     remain consumer arithmetic, saturating by construction
    ///     (`Int64.saturatingAdding`);
    /// (e) STATE↔RECORD COHERENCE — the item's `state` must be SUPPORTED
    ///     by its captured record statuses, byte components, and error
    ///     surface, per the frozen truth table: e.g. a `.measured` item
    ///     whose nonempty records are all refused/denied would let the CLI
    ///     plan a clean that `cleanContents` (which deletes only
    ///     `.measured` records) turns into a zero-byte "success"
    ///     (`stateCoherenceViolation` documents the full per-state table
    ///     and the deliberately unenforced boundaries). This subsumes the
    ///     record-presence rule: EMPTY root records are valid exactly for
    ///     `.missing` items (pre-dispatch-skipped) — every non-`.missing`
    ///     item of EVERY action requires AT LEAST ONE root record (the
    ///     records are the only capture supporting the item's state,
    ///     bytes, and display identity, and for `.commands` an empty set
    ///     would even vacuously pass re-admission before executing argv);
    /// (f) STRUCTURE, STATE-AWARE — a `.removeItem` item
    ///     is accepted ONLY from per-item scanners — NEVER the aggregate
    ///     adapter (converse ownership: downstream treats every
    ///     `categories` item as an aggregate, e.g. the CLI plan's zero-byte
    ///     "skip", while the cleaner deliberately deletes zero-byte
    ///     `.removeItem` targets — an adapter-owned `.removeItem` would let
    ///     a confirmed run delete what its preview skipped). It MUST carry
    ///     the frozen `.containerItem` descriptor, whose `originContainer`
    ///     must be one of the PRODUCING scanner's own registration-declared
    ///     `trustedContainerRoots` (round 6): delete-time admission checks
    ///     the runtime-wide UNION by frozen R4 design, so without this
    ///     per-scanner binding a mapping bug in scanner A could pair its
    ///     target with scanner B's registered container and ride B's
    ///     registration through union admission. In the states the
    ///     cleaner actually deletes (`.measured`/`.partiallyDenied` —
    ///     `.missing`/`.empty` skip pre-dispatch, `.denied` is refused) its
    ///     `requestedTargetURL` must be BOUND to the scan's own capture:
    ///     at least one `.measured` root record whose `requestedURL` is
    ///     that exact spelling AND whose `resolvedURL` is the identity the
    ///     item DISPLAYS (`url`, nil matching nil — internal consistency
    ///     among already-captured fields, never a second resolution), so
    ///     the path the scan measured, the path the GUI/CLI show, and the
    ///     path the cleaner deletes are all the SAME capture;
    ///     `.removeContents`/`.commands` items MUST ALWAYS carry category
    ///     provenance;
    /// (g) CATEGORY-PROVENANCE TRUST — category-backed actions are accepted
    ///     ONLY from the registered category adapter (the frozen
    ///     `categories` id), the item id must equal the carried category's
    ///     slug, and the carried category must BE the registered instance
    ///     for that slug. A category descriptor is a CLAIM: without this
    ///     binding, any scanner could invent a `CacheCategory` whose
    ///     declared roots or clean commands sit outside every
    ///     registration-derived policy — exactly the admission-widening the
    ///     runtime exists to prevent. RISK/SELECTION-POLICY BINDING rides
    ///     the same trust boundary (round 6): the item's `risk`,
    ///     `defaultSelected`, `automaticCleanEligible`, and `isStale` must
    ///     equal exactly what the adapter mapping derives from the
    ///     registered category (`riskLevel`, `defaultSelected`, `true`,
    ///     `nil`) — Quick Clean selects `automaticCleanEligible && risk ==
    ///     .safe` off the CARRIED copies, so a mapping regression could
    ///     otherwise auto-clean a `.caution` category without its warning.
    ///     Action/argv COHERENCE rides the same
    ///     check (fn-2.3): a `.commands` payload must equal the category's
    ///     declared `cleanCommands` (argv is registry code, never item
    ///     input) and a command-backed category can never carry
    ///     `.removeContents`;
    /// (h) RESERVED ISSUE KIND — `ScanIssue.Kind.malformedOutcome` is the
    ///     runtime's own synthesis, never scanner-authored data: a scanner
    ///     placing it in `ScanOutcome.errors` would publish its items
    ///     BESIDE a `malformed_outcome` row, contradicting the wire
    ///     contract that the kind means the whole outcome was rejected.
    ///     The violation itself malforms the outcome (the genuinely
    ///     synthesized replacement is the correct fail-closed response).
    /// (i) REVALIDATION MARKER (fn-4.8, R17/D8) — when the PRODUCING
    ///     scanner declared a `preDeleteRevalidator`, every item that
    ///     revalidator's pure `requiresRevalidation(item:)` predicate deems
    ///     applicable must carry `requiresPreDeleteRevalidation`. A mapping
    ///     regression that emits an applicable item WITHOUT the marker is a
    ///     structural violation here — the invariant whose landing is what
    ///     allowed the old hard-coded orphaned-caches cleaner gate to be
    ///     removed in the same change (`revalidationMarkerViolation`).
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
            // Registration-time declaration: an unregistered producer id
            // has declared nothing, so no container-item origin can bind.
            declaredContainerRoots: declaredContainerRoots[scannerID] ?? [],
            registeredCategories: registeredCategories,
            preDeleteRevalidator: preDeleteRevalidators[scannerID]
        )
    }

    /// Static core so the stream's task-group children capture only the
    /// Sendable declared-roots and category maps, never the runtime.
    private static func validatedOutcome(
        _ outcome: ScanOutcome,
        from scannerID: String,
        declaredContainerRoots: [URL],
        registeredCategories: [String: CacheCategory],
        preDeleteRevalidator: PreDeleteRevalidator?
    ) -> ValidatedScannerEvent {
        var seenIDs = Set<String>()
        // Check (d), outcome-wide half: running `allocatedBytes` sum.
        var outcomeAllocatedTotal: Int64 = 0
        for item in outcome.items {
            guard item.scannerID == scannerID else {
                return .malformed(scannerID: scannerID, ScanIssue(
                    url: nil, kind: .malformedOutcome,
                    detail: "scanner '\(scannerID)' emitted an item owned by "
                        + "'\(item.scannerID)' (id '\(item.id)')"
                ))
            }
            guard isCLISafeItemID(item.id) else {
                return .malformed(scannerID: scannerID, ScanIssue(
                    url: nil, kind: .malformedOutcome,
                    detail: "scanner '\(scannerID)' emitted item id "
                        + "'\(item.id)' that cannot round-trip the "
                        + "<scanner>:<item-id> address grammar (ids must be "
                        + "nonempty with no whitespace and no colon)"
                ))
            }
            guard seenIDs.insert(item.id).inserted else {
                return .malformed(scannerID: scannerID, ScanIssue(
                    url: nil, kind: .malformedOutcome,
                    detail: "scanner '\(scannerID)' emitted duplicate item id "
                        + "'\(item.id)'"
                ))
            }
            // `??` is lazy left-to-right, so the ORDER is load-bearing:
            // value-domain first (state coherence reads `allocatedBytes`,
            // which is only safe once the components are proven
            // nonnegative and non-overflowing), then coherence (structure
            // may assume a non-missing item carries >=1 record).
            if let violation = valueDomainViolation(of: item)
                ?? stateCoherenceViolation(of: item)
                ?? structuralViolation(
                    of: item, from: scannerID,
                    declaredContainerRoots: declaredContainerRoots,
                    registeredCategories: registeredCategories
                )
                ?? revalidationMarkerViolation(
                    of: item, revalidator: preDeleteRevalidator
                ) {
                return .malformed(scannerID: scannerID, ScanIssue(
                    url: nil, kind: .malformedOutcome,
                    detail: "scanner '\(scannerID)' item '\(item.id)': "
                        + violation
                ))
            }
            // Check (d), outcome-wide half (round 8): `allocatedBytes` is
            // safe to touch only AFTER the per-item value-domain check
            // above proved this item's pair representable. Two
            // individually valid items can still sum past Int64.max —
            // an outcome claiming more than 9.2 EB from one scan is
            // physically impossible, and the cross-item sum is exactly
            // what every single-scanner consumer total computes.
            let (runningTotal, overflow) = outcomeAllocatedTotal
                .addingReportingOverflow(item.allocatedBytes)
            if overflow {
                return .malformed(scannerID: scannerID, ScanIssue(
                    url: nil, kind: .malformedOutcome,
                    detail: "scanner '\(scannerID)' outcome-wide "
                        + "allocatedBytes sum overflows Int64 at item "
                        + "'\(item.id)' — a single scan claiming more than "
                        + "Int64.max bytes is physically impossible, and "
                        + "the sum would trap the first consumer total"
                ))
            }
            outcomeAllocatedTotal = runningTotal
        }
        // Check (h): the reserved issue kind. Runs over the ISSUE list —
        // a scanner-authored `.malformedOutcome` would let the CLI print
        // this scanner's items beside a `malformed_outcome` row, though
        // the wire contract says that kind means the whole outcome was
        // rejected. The synthesized replacement IS the contract's shape.
        for issue in outcome.errors where issue.kind == .malformedOutcome {
            return .malformed(scannerID: scannerID, ScanIssue(
                url: nil, kind: .malformedOutcome,
                detail: "scanner '\(scannerID)' authored a reserved "
                    + "malformed_outcome issue (detail: '\(issue.detail)') "
                    + "— the kind is synthesized only by the runtime when "
                    + "it rejects an entire outcome"
            ))
        }
        return .outcome(scannerID: scannerID, outcome)
    }

    /// Check (i), STRUCTURE — the REVALIDATION-MARKER invariant (fn-4.8,
    /// R17/D8). For an outcome whose PRODUCING scanner declared a
    /// `preDeleteRevalidator`, any item that revalidator's own
    /// `requiresRevalidation(item:)` predicate deems APPLICABLE must ALSO
    /// carry the structural `requiresPreDeleteRevalidation` marker: a
    /// scanner's output has to match its declared applicability.
    ///
    /// This is the check the orphaned-caches migration is ORDERED against:
    /// the old hard-coded cleaner gate could only be removed in the SAME
    /// change that landed this invariant, so at no commit does a
    /// marker-forgotten mapping regression escape both. The chokepoint's
    /// belt-and-braces dispatch (marker OR predicate) still re-probes such
    /// an item if one ever reached the cleaner directly — this check makes
    /// sure it never reaches ANY consumer through a validated scan.
    ///
    /// The converse is deliberately NOT enforced: an item MARKED while the
    /// predicate says inapplicable is safe (the marker only ever adds a
    /// re-inspection), and the marker is also the fail-closed signal for
    /// cleaners built without the registry, so nothing may discourage it.
    /// Scanners with NO declared revalidator are untouched here — their
    /// items were never in this contract.
    private static func revalidationMarkerViolation(
        of item: ReclaimableItem, revalidator: PreDeleteRevalidator?
    ) -> String? {
        guard let revalidator,
              !item.requiresPreDeleteRevalidation,
              revalidator.requiresRevalidation(item: item)
        else { return nil }
        return "the scanner's registered pre-delete revalidator deems this "
            + "item applicable, but it does not carry "
            + "requiresPreDeleteRevalidation — a scanner's items must match "
            + "its declared delete-time applicability (R17)"
    }

    /// Check (d): the value-domain invariants over EVERY numeric field on
    /// `ReclaimableItem` (`exactBytes`, `estimatedUpToBytes`,
    /// `logicalBytes`, `itemCount` — `RootScanRecord` carries no numeric
    /// fields, only URLs and a status). Producers measure real trees (the
    /// shared sizer emits only nonnegative components), so a negative or
    /// overflowing figure can only be a scanner mapping bug — and
    /// `allocatedBytes` is computed on EVERY access (`scanEnvelope` rows,
    /// GUI totals, size sorting, clean plans), so an overflowing pair
    /// would trap the process at first touch instead of producing
    /// `malformed_outcome`. Fail closed here.
    ///
    /// PER-ITEM half only — the outcome-wide `allocatedBytes` sum (the
    /// same honesty rule one level up, round 8) accumulates in
    /// `validatedOutcome`'s item loop, where the running total lives.
    /// Round 5 declined cross-item bounds as "consumer-side arithmetic";
    /// that held for any per-item CAP below `Int64.max` (an invented
    /// constraint the model does not document) but NOT for outcome-wide
    /// overflow: an outcome whose items sum past Int64.max claims more
    /// than 9.2 EB from one scan — physically impossible, so rejecting it
    /// invents nothing. Cross-SCANNER totals stay deliberately unenforced
    /// here (each outcome is bounded individually; their sum is unbounded
    /// in principle) — every consumer aggregation saturates instead
    /// (`Int64.saturatingAdding`).
    private static func valueDomainViolation(
        of item: ReclaimableItem
    ) -> String? {
        if item.exactBytes < 0 {
            return "exactBytes \(item.exactBytes) is negative — byte "
                + "components are physical quantities"
        }
        if item.estimatedUpToBytes < 0 {
            return "estimatedUpToBytes \(item.estimatedUpToBytes) is "
                + "negative — byte components are physical quantities"
        }
        if item.exactBytes
            .addingReportingOverflow(item.estimatedUpToBytes).overflow {
            return "exactBytes (\(item.exactBytes)) + estimatedUpToBytes "
                + "(\(item.estimatedUpToBytes)) overflows Int64 — "
                + "allocatedBytes would trap its first consumer"
        }
        if let logical = item.logicalBytes, logical < 0 {
            return "logicalBytes \(logical) is negative — byte components "
                + "are physical quantities"
        }
        if item.itemCount < 0 {
            return "itemCount \(item.itemCount) is negative"
        }
        // fn-4.4 (R13/R17): the SAME value-domain family, extended to every
        // numeric of the additive valuables field. No new check family, no
        // state-coherence coupling — items WITHOUT the field are untouched.
        // Every violation is REJECTED, never saturated: `modified_at_ns` is
        // derived as `modifiedSeconds * 1e9 + modifiedNanoseconds`, so an
        // out-of-domain pair would either publish a lie or trap its first
        // consumer. Computed here with overflow-REPORTING arithmetic (the
        // outcome-wide `addingReportingOverflow` precedent above) BEFORE any
        // `modified_at_ns` access downstream.
        for valuable in item.valuablesDisclosure?.valuables ?? [] {
            let identity = valuable.identity
            if identity.allocatedBytes < 0 {
                return "valuable '\(valuable.name)' allocatedBytes "
                    + "\(identity.allocatedBytes) is negative — byte "
                    + "components are physical quantities"
            }
            if identity.modifiedNanoseconds < 0
                || identity.modifiedNanoseconds
                    >= ValuableIdentity.nanosecondsPerSecond {
                return "valuable '\(valuable.name)' modifiedNanoseconds "
                    + "\(identity.modifiedNanoseconds) is outside "
                    + "[0, 1000000000) — a nanosecond field cannot name a "
                    + "whole second"
            }
            let (scaled, scaleOverflow) = identity.modifiedSeconds
                .multipliedReportingOverflow(
                    by: ValuableIdentity.nanosecondsPerSecond
                )
            if scaleOverflow
                || scaled.addingReportingOverflow(
                    identity.modifiedNanoseconds
                ).overflow {
                return "valuable '\(valuable.name)' modifiedSeconds "
                    + "\(identity.modifiedSeconds) is outside the range where "
                    + "modifiedSeconds * 1000000000 + modifiedNanoseconds "
                    + "fits Int64 — modified_at_ns would overflow, and a "
                    + "saturated timestamp is a lie"
            }
        }
        return nil
    }

    /// Check (e): state ↔ record-status/component coherence, derived from
    /// the FROZEN `RootScanStatus` truth table (fn-2.1) and verified
    /// against BOTH production mappings (`CacheScanner.scanCategory`'s
    /// state derivation and `NodeModulesScanner`'s complete candidate
    /// truth table). The consumers make this load-bearing: `cleanContents`
    /// deletes only `.measured` records while the CLI/GUI plan from
    /// `state`, so a `.measured` item whose records are all
    /// refused/denied plans a clean that deletes nothing and reports a
    /// zero-byte "success" for a scan that never established a deletable
    /// root. Enforced, per state (every rule holds on every production
    /// emission path):
    ///
    /// - `.missing` — no resolved path exists: NO records, zero
    ///   components, nil `url` (never a fake resolution), nil `scanError`,
    ///   nil `logicalBytes`.
    /// - `.empty` — clean walk to emptiness: >=1 record, ALL `.measured`
    ///   (clean-empty = measured, frozen truth table), zero components,
    ///   nil `scanError`, nil `logicalBytes`.
    /// - `.measured` — fully walked: >=1 record, ALL `.measured` (any
    ///   refusal or denial forces a denied-family state), measured
    ///   SOMETHING (items or bytes — zero-byte trees with counted files
    ///   are honestly measured), nil `scanError`.
    /// - `.partiallyDenied` — measured bytes exist beside denials: >=1
    ///   `.measured` record (the measured content came from a walked
    ///   root), measured something, non-nil `scanError`.
    /// - `.denied` — nothing deletable was established: >=1 record, >=1
    ///   refused-or-denied record (something must actually have been
    ///   refused or denied), zero components, non-nil `scanError`, nil
    ///   `logicalBytes`. Boundary-voided candidates (a mount boundary
    ///   anywhere in a `.removeItem` tree — R15 refuses the WHOLE target)
    ///   land here too: their mapping publishes zero components even when
    ///   the walk measured readable siblings, because the components mean
    ///   "deletion frees these" and deletion is categorically refused —
    ///   the measured floor rides the scanError message instead.
    ///
    /// Deliberately NOT enforced — production emits these shapes:
    /// - `.partiallyDenied` does NOT require a refused/denied RECORD: a
    ///   single-root partial walk carries its denials INSIDE the tree, so
    ///   the root record itself is honestly `.measured` (both mappings).
    /// - `.denied` does NOT forbid `.measured` records: a clean-empty root
    ///   beside a refused sibling walked honestly yet measured nothing —
    ///   `CacheScanner` emits exactly that mix.
    /// - `logicalBytes > allocated` when present is NodeModulesScanner's
    ///   sparse-divergence display policy, not a model invariant — only
    ///   sign (check (d)) and absence on unmeasured states are validated.
    private static func stateCoherenceViolation(
        of item: ReclaimableItem
    ) -> String? {
        // Safe only AFTER check (d): the components are nonnegative and
        // their sum representable.
        let measuredAnything = item.itemCount > 0 || item.allocatedBytes > 0
        let statuses = item.rootRecords.map(\.status)
        let recordless = "a non-missing \(item.action.wireString) item "
            + "requires at least one root record"

        switch item.state {
        case .missing:
            if !item.rootRecords.isEmpty {
                return "a missing item carries root records — no resolved "
                    + "path exists, so there is nothing to have captured"
            }
            if measuredAnything {
                return "a missing item carries measured components — "
                    + "nothing resolved, so nothing can have been measured"
            }
            if item.url != nil {
                return "a missing item displays a resolved url — never a "
                    + "fake resolution"
            }
            if item.scanError != nil {
                return "a missing item carries a scan error — absence is "
                    + "not an impediment (clean states carry nil)"
            }
            if item.logicalBytes != nil {
                return "a missing item carries a logical-bytes figure with "
                    + "no measurement behind it"
            }
        case .empty:
            if item.rootRecords.isEmpty { return recordless }
            if statuses.contains(where: { $0 != .measured }) {
                return "an empty item may carry only measured root records "
                    + "— a refusal or denial forces a denied-family state"
            }
            if measuredAnything {
                return "an empty item carries measured components — "
                    + "emptiness means a clean walk measured nothing"
            }
            if item.scanError != nil {
                return "an empty item carries a scan error — clean states "
                    + "carry nil"
            }
            if item.logicalBytes != nil {
                return "an empty item carries a logical-bytes figure with "
                    + "no measurement behind it"
            }
        case .measured:
            if item.rootRecords.isEmpty { return recordless }
            if statuses.contains(where: { $0 != .measured }) {
                return "a measured item may carry only measured root "
                    + "records — a refusal or denial forces a denied-family "
                    + "state, and the cleaner deletes only measured records"
            }
            if !measuredAnything {
                return "a measured item measured nothing — no items and no "
                    + "bytes is the empty state"
            }
            if item.scanError != nil {
                return "a measured item carries a scan error — clean "
                    + "states carry nil"
            }
        case .partiallyDenied:
            if item.rootRecords.isEmpty { return recordless }
            if !statuses.contains(.measured) {
                return "a partially-denied item requires at least one "
                    + "measured root record — its measured content must "
                    + "come from a walked root"
            }
            if !measuredAnything {
                return "a partially-denied item measured nothing — that is "
                    + "the denied state"
            }
            if item.scanError == nil {
                return "a denied-family item requires its classified "
                    + "scanError"
            }
        case .denied:
            if item.rootRecords.isEmpty { return recordless }
            if !statuses.contains(where: {
                $0 == .refusedAdmission || $0 == .deniedUnmeasured
            }) {
                return "a denied item requires at least one refused or "
                    + "denied root record — something must actually have "
                    + "been refused or denied"
            }
            if measuredAnything {
                return "a denied item carries measured components — denied "
                    + "means nothing was measurable"
            }
            if item.scanError == nil {
                return "a denied-family item requires its classified "
                    + "scanError"
            }
            if item.logicalBytes != nil {
                return "a denied item carries a logical-bytes figure with "
                    + "no measurement behind it"
            }
        }
        return nil
    }

    /// The state-aware structural invariants ((f)/(g) above). Runs AFTER
    /// checks (d)/(e), so a non-missing item is guaranteed >=1 root record
    /// here. Exhaustive over `ReclaimAction` — a future action case must
    /// make this a compile-time decision, never a silent pass through
    /// `default:`.
    private static func structuralViolation(
        of item: ReclaimableItem,
        from scannerID: String,
        declaredContainerRoots: [URL],
        registeredCategories: [String: CacheCategory]
    ) -> String? {
        switch item.action {
        case .removeItem:
            // CONVERSE ownership: the aggregate adapter may emit ONLY
            // category-backed actions. Downstream treats every `categories`
            // item as an aggregate (the CLI plan skips zero-byte aggregates
            // while the cleaner deliberately deletes zero-byte `.removeItem`
            // targets), so an adapter-owned `.removeItem` — a mapping
            // regression, since the adapter constructs only category-backed
            // items — could delete on a confirmed run what its preview said
            // it would skip. The forward direction (category-backed actions
            // only FROM the adapter) is check (g) below.
            if scannerID == CategoryScanner.registeredID {
                return "the aggregate category adapter may emit only "
                    + "category-backed actions — remove_item is reserved "
                    + "for per-item scanners"
            }
            switch item.admission {
            case .containerItem(let originContainer, let requestedTargetURL):
                // ORIGIN BINDING (round 6): the origin-container claim must
                // be one of the PRODUCING scanner's own registration-
                // declared roots — in EVERY state (production always sets
                // it to the search root the walk started from). Delete-time
                // admission checks the runtime-wide UNION by frozen R4
                // design (registration alone extends admission), so the
                // union cannot tell WHICH scanner declared a root: without
                // this scan-time narrowing, a mapping bug in scanner A
                // could pair its target with scanner B's registered
                // container and ride B's registration through union
                // admission. Path equality against the declaration — never
                // a second resolution.
                if !declaredContainerRoots.contains(where: {
                    $0.path == originContainer.path
                }) {
                    return "originContainer '\(originContainer.path)' is "
                        + "not one of the producing scanner's declared "
                        + "trustedContainerRoots — delete-time admission "
                        + "checks the runtime-wide union, so an undeclared "
                        + "origin could ride another scanner's registration"
                }
                // Deletion-target binding: in the states the cleaner
                // dispatches (`removeGuardedItem` deletes the descriptor's
                // `requestedTargetURL`, never anything read off records),
                // the target must be one of the scan's own `.measured`
                // captures — same requested (unresolved) spelling, the
                // fn-2.2 single-element-record correspondence. Without it,
                // a scanner mapping bug could measure and display one path
                // while deleting a DIFFERENT descendant of the admitted
                // container. Exhaustive over `ScanState` so a future state
                // decides its deletability at compile time; `.denied`
                // (honest `.deniedUnmeasured` record) and `.empty`/
                // `.missing` never reach deletion, so no binding is
                // demanded of them.
                switch item.state {
                case .measured, .partiallyDenied:
                    let bound = item.rootRecords.filter { record in
                        record.status == .measured
                            && record.requestedURL.path
                                == requestedTargetURL.path
                    }
                    if bound.isEmpty {
                        return "a deletable remove_item item must carry a "
                            + "measured root record capturing its "
                            + "requestedTargetURL — the measured path and "
                            + "the deletion target must be the same capture"
                    }
                    // Display-identity binding: the record that binds the
                    // deletion target must ALSO be the identity the item
                    // displays — `url` (documented: the first root record
                    // with a non-nil `resolvedURL`) must be that record's
                    // own `resolvedURL`, nil matching nil (a target whose
                    // resolution honestly failed displays the declared
                    // spelling, never another record's resolution). This is
                    // internal consistency among already-captured fields —
                    // NEVER a second resolution (root-capture doctrine: a
                    // re-canonicalization here could race the filesystem).
                    // Without it, a mapping bug could publish path B as
                    // `url` while the descriptor deletes path A.
                    let displayBound = bound.contains { record in
                        record.resolvedURL?.path == item.url?.path
                    }
                    if !displayBound {
                        return "a deletable remove_item item's display url "
                            + "must be the resolved identity of the record "
                            + "binding its deletion target — the path shown "
                            + "and the path deleted must be the same capture"
                    }
                case .missing, .empty, .denied:
                    break
                }
                return nil
            case .category:
                return "a .removeItem item must carry the .containerItem "
                    + "admission descriptor"
            }
        // SITE 6 of 8 (fn-5.3). The composite gets its OWN top-level arm:
        // a forged plan/admission divergence must malform the outcome at
        // VALIDATION time, not only at the cleaner — the two enforcers are
        // deliberately independent, and only this one holds the registration
        // facts (declared roots, the producing scanner id).
        case .gitWorktreeReclaim(let plan):
            // CONVERSE ownership, mirrored from `.removeItem`: the aggregate
            // adapter constructs only category-backed items, so a composite
            // item bearing its id is a mapping regression, and downstream
            // treats every `categories` item as an aggregate.
            if scannerID == CategoryScanner.registeredID {
                return "the aggregate category adapter may emit only "
                    + "category-backed actions — git_worktree_reclaim is "
                    + "reserved for per-item scanners"
            }
            switch item.admission {
            case .containerItem(let originContainer, _):
                // ORIGIN BINDING (round 6 doctrine, same reason as
                // `.removeItem`): delete-time admission checks the
                // runtime-wide UNION, so an undeclared origin could ride
                // another scanner's registration. Path equality against the
                // declaration — never a second resolution.
                if !declaredContainerRoots.contains(where: {
                    $0.path == originContainer.path
                }) {
                    return "originContainer '\(originContainer.path)' is "
                        + "not one of the producing scanner's declared "
                        + "trustedContainerRoots — delete-time admission "
                        + "checks the runtime-wide union, so an undeclared "
                        + "origin could ride another scanner's registration"
                }
            case .category:
                // Refused by the shared rule set below, in its ONE wording.
                break
            }
            // The plan/admission rules themselves: ONE implementation, also
            // called by `CacheCleaner.structuralRefusal`, so validation and
            // the chokepoint can never disagree about what a well-formed
            // composite item is.
            return GitWorktreeReclaimPlan.violation(for: item, plan: plan)
        case .removeContents, .commands:
            switch item.admission {
            case .category(let carried):
                // (g) Category provenance is trusted only from the
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
                // RISK/SELECTION-POLICY BINDING (round 6): these four
                // fields are the adapter mapping's DERIVATIONS from the
                // registered category (`CategoryScanner.item(from:)`:
                // `riskLevel`, `defaultSelected`, `true`, `nil`) — yet
                // downstream trusts the CARRIED copies: Quick Clean /
                // selectAllSafe selects `automaticCleanEligible && risk ==
                // .safe`, initial selection reads `defaultSelected`, and
                // Select Stale reads `isStale`. A mapping regression (a
                // `.caution` Docker aggregate carried as `.safe`) would
                // otherwise ride Quick Clean without its caution warning.
                // Equality is against the PROVEN-registered instance —
                // `carried` is identity-checked above.
                if item.risk != carried.riskLevel {
                    return "aggregate risk '\(item.risk.rawValue)' does not "
                        + "match the registered category's declared "
                        + "riskLevel '\(carried.riskLevel.rawValue)' — "
                        + "risk policy derives from registration"
                }
                if item.defaultSelected != carried.defaultSelected {
                    return "aggregate defaultSelected "
                        + "\(item.defaultSelected) does not match the "
                        + "registered category's declaration "
                        + "(\(carried.defaultSelected)) — selection policy "
                        + "derives from registration"
                }
                if !item.automaticCleanEligible {
                    return "aggregate automaticCleanEligible must be true — "
                        + "the adapter mapping enrolls every aggregate; a "
                        + "divergence is a mapping regression"
                }
                if item.isStale != nil {
                    return "an aggregate carries a staleness flag — "
                        + "staleness is not applicable to category "
                        + "aggregates (the adapter maps nil)"
                }
                // Action/argv coherence (fn-2.3 defense-in-depth, mirrored
                // by the cleaner): command argv is TRUSTED REGISTRY CODE —
                // a `.commands` payload must BE the carried category's
                // declaration, and a command-backed category can never
                // route through `.removeContents` file deletion.
                switch item.action {
                case .commands(let payload):
                    if carried.cleanCommands != payload {
                        return "a commands item's argv must equal its "
                            + "category's declared cleanCommands — argv is "
                            + "registry code, never item input"
                    }
                case .removeContents:
                    if carried.cleanCommands != nil {
                        return "a command-backed category must carry the "
                            + "commands action, never remove_contents"
                    }
                case .removeItem:
                    break // unreachable — the outer switch splits it out
                // SITE 7 of 8 (fn-5.3). This nested switch is exhaustive
                // over `ReclaimAction` in its OWN right, so the composite
                // case must decide here even though the outer switch splits
                // it out too — the `.removeItem` precedent immediately
                // above. Nothing to check: the composite carries no argv and
                // no category, and its coherence rules live in its own
                // outer-switch arm.
                case .gitWorktreeReclaim:
                    break // unreachable — the outer switch splits it out
                }
            case .containerItem:
                return "a \(item.action.wireString) item must carry category "
                    + "admission provenance"
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
        scanValidatedSession(scannerIDs: scannerIDs, context: context).events
    }

    /// `scanValidated` plus the producer's REAL completion (additive over
    /// the frozen stream shape — review P2). Cancelling the task consuming
    /// `events` terminates the stream immediately and cancels the producer,
    /// but the scanners' filesystem walks wind down COOPERATIVELY, not
    /// instantly — `untilProducerFinishes()` is how a stateful consumer
    /// keeps its "scanning" guard honest until the walk has actually
    /// stopped, instead of releasing it while an orphaned traversal is
    /// still reading the same trees.
    func scanValidatedSession(
        scannerIDs: Set<String>? = nil,
        context: ScanContext
    ) -> ValidatedScanSession {
        // Container-identity capture is PART OF the session (fn-3.4, R9 —
        // a consumer cannot misorder it): every REGISTERED root, before
        // any scanner task launches, so a container swapped mid-scan
        // mismatches at delete time. ALL registered roots on purpose, even
        // under a scanner subset — capture is cheap (one lstat per root)
        // and a subset-blind snapshot can never pair a root with the wrong
        // session.
        let snapshot = ContainerSnapshot.capture(
            roots: trustedContainerRoots, provider: provider
        )
        let selected = scanners.filter { scanner in
            scannerIDs?.contains(scanner.id) ?? true
        }
        let registeredCategories = self.registeredCategories
        let declaredContainerRoots = self.declaredContainerRoots
        let preDeleteRevalidators = self.preDeleteRevalidators
        let (events, continuation) =
            AsyncStream<ValidatedScannerEvent>.makeStream()
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
                            // The REGISTRATION-time declaration (init
                            // capture), matching the cleaner union's
                            // provenance — never re-read mid-scan.
                            declaredContainerRoots:
                                declaredContainerRoots[scanner.id] ?? [],
                            registeredCategories: registeredCategories,
                            // The same registration capture the cleaner's
                            // injected registry reads (fn-4.8) — scan-time
                            // applicability and delete-time dispatch can
                            // never disagree about who has a revalidator.
                            preDeleteRevalidator:
                                preDeleteRevalidators[scanner.id]
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
        return ValidatedScanSession(
            snapshot: snapshot, events: events, producer: task
        )
    }

    // MARK: Slug & item-id syntax

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

    /// The documented `ReclaimableItem.id` invariant, enforced at scan-time
    /// validation: a NONEMPTY opaque string with no whitespace, no colon,
    /// and no U+0000 — anything else cannot round-trip the
    /// `<scanner-slug>:<item-id>` address (an empty id publishes a
    /// `<scanner>:` address `parseCleanTargets` rejects, so the item could
    /// never be cleaned individually even by echoing `scan` output
    /// verbatim; a NUL id is PROVABLY unspellable as a `clean` argument —
    /// POSIX argv strings are NUL-terminated, so no invocation can carry
    /// the byte, even though the JSON envelope escapes it as a \\u0000 sequence
    /// happily). The boundary is deliberately EXACT (round 6): other C0
    /// controls are ugly but representable on BOTH legs — JSON escapes
    /// them and argv bytes carry them — so rejecting them would over-
    /// reject ids the opaque contract allows. Deliberately LOOSER than
    /// the slug grammar: item ids are opaque (64-hex `stableID`s and
    /// category slugs today), not slugs — the validator must never reject
    /// an id the documented contract allows.
    static func isCLISafeItemID(_ id: String) -> Bool {
        !id.isEmpty
            && !id.contains { $0 == ":" || $0.isWhitespace }
            && !id.unicodeScalars.contains { $0.value == 0 }
    }
}
