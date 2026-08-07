/// # CacheCleaner — Guarded Cache Deletion + Honest Freed-Bytes Accounting
///
/// An `actor` that deletes cache trees — permanently or to the Trash — with
/// every deletion target passing through `PathGuard` (D4) and every freed
/// byte measured at delete time, never assumed from pre-scan totals (D1).
///
/// ## Safety model (fn-1.3)
///
/// 1. **Scan-state refusal (R18)**: a `.denied` scan result is refused even
///    when force-selected — `isSelected` is mutable UI state and never
///    overrides the scanner's verdict. `.partiallyDenied` reaches the cleaner
///    only through explicit selection (fn-1.4 owns never-auto-selecting it)
///    and reports measured deletions only.
/// 2. **Mode-aware guard**: category roots are re-admitted at delete time via
///    `admitDeletionRoot` against the category's OWN `CategoryAdmissionPolicy`;
///    each child is then `validateContainedChild`-checked (strict descendant).
///    node_modules items go through `admitContainer` (configured search roots
///    only) + `validateRemovableItem` (strict descendant + deny-list re-check
///    + cross-device refusal, R15) against their origin-container provenance.
/// 3. **Unresolved spelling deletes; resolved spelling contains**: children
///    are enumerated under `AdmittedRoot.requestedURL` and deleted by their
///    unresolved URLs — a symlink child is removed AS a link, its target
///    untouched (R4). Containment always compares against
///    `AdmittedRoot.resolvedURL`, and the chain is re-validated immediately
///    before each destructive call (TOCTOU narrowing).
/// 4. **cleanCommands (R17)**: every resolved root is admitted BEFORE any
///    argv runs; one refusal skips the whole command set. Paths that appear
///    INSIDE a command's argv are trusted registry code (`Categories.swift`),
///    not runtime input — admission covers the roots the category operates on.
///
/// ## Freed-bytes accounting (D1/R8)
///
/// Each deletion target is measured with `DirectorySizer` in `.deletionTarget`
/// mode immediately before deletion and settled through the claim-based
/// two-phase `InodeAccountingRegistry`: claims are REGISTERED before deletion,
/// canonical bytes TRANSFER once after success. Unique-inode bytes are exact;
/// hardlinked bytes are estimates (`estimatedUpToBytes`). Failed deletions
/// accept nothing — their registered claims remain transferable by siblings.
/// Command categories free bytes nothing measures: exact 0, estimated =
/// pre-scan size (R16).
///
/// ## Deletion modes
///
/// - **Permanent delete** (`moveToTrash: false`): `FileManager.removeItem()`
///   offloaded to a background queue. Contents of category roots are removed
///   individually (the root itself survives so tools/apps can recreate it).
/// - **Move to Trash** (`moveToTrash: true`): the injectable `@MainActor`
///   trash seam (production: `FileManager.trashItem`, which talks to Finder).
///   A trash failure is a per-child error — it never falls through to a
///   permanent delete.
///
/// The per-target pipeline is sequential — measure → register → re-validate →
/// delete → accept — with per-child error isolation (R10): one undeletable
/// child never poisons its siblings. The measurement latency is accepted
/// (epic: at most one metadata walk per deleted tree, no separate pre-walk).
///
/// ## Custom Clean Commands
///
/// Categories with `cleanCommands` (e.g., Simulator Devices) bypass file
/// deletion entirely. Each command runs directly via `/usr/bin/env` with an
/// argv array (never a shell), a 30-second timeout, and a restricted `PATH`
/// environment. If a command times out, the process is terminated and an
/// error is reported.
///
/// ## Cleanup Logging
///
/// Every cleanup action AND every refusal is appended to
/// `<home>/.cacheout/cleanup.log` with ISO 8601 timestamps. Refusal lines are
/// classified off the typed `PathGuardError` cases — never message strings.
/// The home directory is injectable, so tests log inside their fixture home.
///
/// ## Error Handling
///
/// Errors are collected per category / per child rather than aborting the
/// cleanup. The returned `CleanupReport` carries split-component entries and
/// errors so the UI can render partial results honestly (R11/R16).

import Foundation
import Darwin

// MARK: - Claim-based two-phase accounting (R8)

/// Opaque token binding one deletion target ("child") to the inode claims it
/// registered. Returned by `registerObservations(_:)`; handed back to
/// `acceptSuccessful(_:)` after — and only after — the deletion succeeded.
/// The memberwise initializer is fileprivate so tokens cannot be forged.
struct RegisteredChild {
    fileprivate let claimedIdentities: [FileSystemIdentityProvider.Identity]
}

/// The byte components a successful deletion actually transferred out of the
/// registry — exactly what the report may add for that child, nothing more.
struct AcceptedByteComponents {
    var exactBytes: Int64 = 0
    var estimatedUpToBytes: Int64 = 0
}

/// Per-category-operation inode accounting registry (R8, D8 mitigation).
///
/// Deleting one hardlink DECREMENTS the survivors' `st_nlink`, so later
/// observations of the same inode cannot be trusted for classification or
/// size. The registry therefore retains the CANONICAL byte value and a STICKY
/// classification from registration time, and transfers each inode's bytes at
/// most once per operation:
///
/// - **Phase 1 — `registerObservations`** (after measurement, BEFORE
///   deletion, atomic): merges the child's claims into the registry. Once ANY
///   observer saw an inode hardlinked it stays ESTIMATED for the whole
///   operation, regardless of registration order. Registration accepts no
///   bytes.
/// - **Phase 2 — `acceptSuccessful`** (after successful deletion only,
///   atomic): every inode the token claimed that has not yet been transferred
///   is marked transferred and its canonical bytes returned under the sticky
///   classification. Failed deletions never accept — their registrations
///   remain for siblings to transfer later (a successful child can accept
///   bytes first observed by a failed sibling).
actor InodeAccountingRegistry {

    private struct Registration {
        /// Byte value from the FIRST observation — later observations of a
        /// partially-deleted inode are not trusted.
        let canonicalByteSize: Int64
        /// Sticky: ratchets to `true` and never back — a survivor whose
        /// `st_nlink` already decayed to 1 must not reclassify as exact.
        var stickyHardlinked: Bool
        var transferred: Bool
    }

    private var registrations: [FileSystemIdentityProvider.Identity: Registration] = [:]

    /// Identities the registry has seen — handed to `DirectorySizer.measure`
    /// as `knownInodes` so an already-registered inode contributes zero local
    /// bytes while still emitting a claim.
    var knownIdentities: Set<FileSystemIdentityProvider.Identity> {
        Set(registrations.keys)
    }

    func registerObservations(_ claims: [InodeClaim]) -> RegisteredChild {
        for claim in claims {
            if var existing = registrations[claim.identity] {
                existing.stickyHardlinked =
                    existing.stickyHardlinked || claim.observedHardlinked
                registrations[claim.identity] = existing
            } else {
                registrations[claim.identity] = Registration(
                    canonicalByteSize: claim.canonicalByteSize,
                    stickyHardlinked: claim.observedHardlinked,
                    transferred: false
                )
            }
        }
        return RegisteredChild(claimedIdentities: claims.map(\.identity))
    }

    func acceptSuccessful(_ token: RegisteredChild) -> AcceptedByteComponents {
        var accepted = AcceptedByteComponents()
        for identity in token.claimedIdentities {
            guard var registration = registrations[identity],
                  !registration.transferred else { continue }
            registration.transferred = true
            registrations[identity] = registration
            if registration.stickyHardlinked {
                accepted.estimatedUpToBytes += registration.canonicalByteSize
            } else {
                accepted.exactBytes += registration.canonicalByteSize
            }
        }
        return accepted
    }
}

// MARK: - CacheCleaner

actor CacheCleaner {

    /// Injectable Trash seam. Production moves the URL to the Trash via
    /// Finder; tests record or redirect so nothing outside a fixture root is
    /// ever trashed. `@MainActor` because `trashItem` talks to Finder.
    typealias TrashHandler = @Sendable @MainActor (URL) throws -> Void

    private let fileManager = FileManager.default
    private let home: URL
    private let provider: FileSystemIdentityProvider
    private let sizer: DirectorySizer
    private let pathGuard: PathGuard
    private nonisolated let trashHandler: TrashHandler

    /// - Parameters:
    ///   - home: home directory admission policies and the deny list anchor
    ///     to, and where `.cacheout/cleanup.log` lives (injectable — tests
    ///     pass a fixture home; production the real one).
    ///   - containerRoots: configured node_modules search roots for
    ///     `admitContainer`. `nil` uses the scanner's default list for
    ///     `home`, keeping delete-time admission in lockstep with discovery.
    ///   - provider: identity provider shared with `PathGuard` and the sizer
    ///     (tests may subclass to inject devices/kinds).
    ///   - trashHandler: Trash seam; `nil` uses `FileManager.trashItem`.
    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        containerRoots: [URL]? = nil,
        provider: FileSystemIdentityProvider = FileSystemIdentityProvider(),
        trashHandler: TrashHandler? = nil
    ) {
        self.home = home
        self.provider = provider
        self.sizer = DirectorySizer(provider: provider)
        self.pathGuard = PathGuard(
            home: home,
            containerRoots: containerRoots
                ?? NodeModulesScanner.defaultSearchRoots(home: home),
            provider: provider
        )
        self.trashHandler = trashHandler ?? { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }

    // MARK: Clean

    func clean(
        results: [ScanResult],
        nodeModules: [NodeModulesItem] = [],
        moveToTrash: Bool
    ) async -> CleanupReport {
        var entries: [CleanupReport.Entry] = []
        var errors: [(category: String, error: String)] = []

        for result in results where result.isSelected {
            let name = result.category.name

            // Nothing resolved on this machine — nothing to do.
            if result.state == .missing { continue }

            // R18: the scanner's verdict beats mutable selection state — a
            // `.denied` category is refused even force-selected (the CLI
            // force-selects), and the refusal SURFACES as an error rather
            // than silently skipping.
            if result.state == .denied {
                let reason = Self.deniedRefusalReason(for: result)
                errors.append((name, reason))
                logRefusal(category: name, tag: "scan-denied", detail: reason)
                continue
            }

            // `.partiallyDenied` proceeds only via explicit selection
            // (fn-1.4 never auto-selects it). Its freed bytes are measured
            // deletions only — which is all this pipeline ever reports.

            // Empty/zero-measured categories: nothing measurable to free.
            if result.isEmpty { continue }

            if let commands = result.category.cleanCommands {
                let outcome = cleanViaCommands(commands, for: result)
                if let entry = outcome.entry { entries.append(entry) }
                errors.append(contentsOf: outcome.errors)
            } else {
                let outcome = await cleanCategoryPaths(
                    for: result, moveToTrash: moveToTrash
                )
                if let entry = outcome.entry { entries.append(entry) }
                errors.append(contentsOf: outcome.errors)
            }
        }

        let nodeModulesOutcome = await cleanNodeModulesItems(
            nodeModules.filter(\.isSelected), moveToTrash: moveToTrash
        )
        entries.append(contentsOf: nodeModulesOutcome.entries)
        errors.append(contentsOf: nodeModulesOutcome.errors)

        return CleanupReport(
            disposal: moveToTrash ? .trash : .permanent,
            entries: entries,
            errors: errors
        )
    }

    // MARK: - Command categories (R17)

    private func cleanViaCommands(
        _ commands: [[String]], for result: ScanResult
    ) -> (entry: CleanupReport.Entry?, errors: [(category: String, error: String)]) {
        let name = result.category.name
        let policy = CategoryAdmissionPolicy(category: result.category, home: home)

        // Every resolved root must pass admission BEFORE any argv runs — a
        // probed root that drifted outside the category's policy blocks the
        // whole command set (R17).
        for url in result.category.resolvedPaths {
            do {
                let admitted = try pathGuard.admitDeletionRoot(url, policy: policy)
                logDriftAdmission(admitted, category: name)
            } catch {
                let reason = "clean commands not run — root refused: \(error.localizedDescription)"
                logRefusal(
                    category: name, tag: Self.refusalTag(error),
                    detail: "\(url.path): \(reason)"
                )
                return (nil, [(name, reason)])
            }
        }

        do {
            for command in commands {
                try runCleanCommand(command)
            }
        } catch {
            return (nil, [(name, error.localizedDescription)])
        }

        // Nothing measures what a command frees: exact 0, estimated =
        // pre-scan measured size (R16).
        logCleanup(category: name, bytesFreed: result.sizeBytes)
        guard result.sizeBytes > 0 else { return (nil, []) }
        return (
            CleanupReport.Entry(
                category: name, exactBytes: 0,
                estimatedUpToBytes: result.sizeBytes
            ),
            []
        )
    }

    // MARK: - Category paths (contents mode)

    private func cleanCategoryPaths(
        for result: ScanResult, moveToTrash: Bool
    ) async -> (entry: CleanupReport.Entry?, errors: [(category: String, error: String)]) {
        let name = result.category.name
        let policy = CategoryAdmissionPolicy(category: result.category, home: home)
        // Per category operation: two roots (or two children) hardlinking the
        // same inode must transfer its bytes once.
        let registry = InodeAccountingRegistry()
        var errors: [(category: String, error: String)] = []
        var exact: Int64 = 0
        var estimated: Int64 = 0

        for url in result.category.resolvedPaths {
            let admitted: AdmittedRoot
            do {
                admitted = try pathGuard.admitDeletionRoot(url, policy: policy)
                logDriftAdmission(admitted, category: name)
            } catch {
                errors.append((name, error.localizedDescription))
                logRefusal(
                    category: name, tag: Self.refusalTag(error),
                    detail: "\(url.path): \(error.localizedDescription)"
                )
                continue
            }

            // Enumerate children under the UNRESOLVED spelling — deletion
            // must remove exactly what sits at the requested location, and a
            // symlink child must be removed AS a link (R4). Containment
            // checks compare against the resolved spelling inside the guard.
            let children: [URL]
            do {
                children = try fileManager.contentsOfDirectory(
                    at: admitted.requestedURL, includingPropertiesForKeys: nil
                )
            } catch {
                errors.append((name, error.localizedDescription))
                continue
            }

            for child in children {
                switch await deleteGuardedChild(
                    child, of: admitted, registry: registry,
                    moveToTrash: moveToTrash, category: name
                ) {
                case .accepted(let components):
                    exact += components.exactBytes
                    estimated += components.estimatedUpToBytes
                case .skippedAlreadyGone:
                    break
                case .failed(let message):
                    errors.append((name, message))
                }
            }
        }

        logCleanup(category: name, bytesFreed: exact + estimated)
        // A partially-refused/failed category still yields ONE entry carrying
        // the per-child accounting that actually succeeded (R1).
        guard exact + estimated > 0 else { return (nil, errors) }
        return (
            CleanupReport.Entry(
                category: name, exactBytes: exact, estimatedUpToBytes: estimated
            ),
            errors
        )
    }

    private enum ChildOutcome {
        case accepted(AcceptedByteComponents)
        case skippedAlreadyGone
        case failed(String)
    }

    /// The guarded per-child pipeline: validate → probe → measure → register
    /// → re-validate → delete → accept. Per-child error isolation (R10): any
    /// failure is returned, never thrown.
    private func deleteGuardedChild(
        _ child: URL, of root: AdmittedRoot,
        registry: InodeAccountingRegistry,
        moveToTrash: Bool, category: String
    ) async -> ChildOutcome {
        // Strict-descendant containment against the admitted root. NOTE:
        // `validateContainedChild` is descendant-only by design (fn-1.1) —
        // cross-device refusal and the deny-list re-check live in item mode
        // (`validateRemovableItem`); a foreign-device subtree under a
        // category root is still never ENTERED by the sizer (mount
        // boundaries), and the root itself was deny-checked at admission.
        do {
            try pathGuard.validateContainedChild(child, of: root)
        } catch {
            logRefusal(
                category: category, tag: Self.refusalTag(error),
                detail: "\(child.path): \(error.localizedDescription)"
            )
            return .failed(error.localizedDescription)
        }

        // Already gone = skip. Decided by OUR probe: an absent leaf yields an
        // EMPTY SizeReport indistinguishable from an empty directory, so
        // "already gone" must never be inferred from the report.
        if provider.probeKind(of: child) == .absent {
            return .skippedAlreadyGone
        }

        // Measure → register (Phase 1) BEFORE deletion. Known inodes
        // contribute zero local bytes but still claim, so a failed sibling's
        // canonical bytes stay transferable by whoever succeeds later (R8).
        let report = sizer.measure(
            at: child, mode: .deletionTarget,
            knownInodes: await registry.knownIdentities
        )

        // A child that is ITSELF a mount boundary (mount point, or foreign
        // device vs its parent) is refused outright — `validateContainedChild`
        // is descendant-only by design, so this is where the mount rule lands
        // for category children (R15). Item mode gets the same refusal from
        // `validateRemovableItem`'s deny-list re-check.
        if report.rootMountBoundary {
            let detail = "\(child.path): mount boundary — refused, not deleted"
            logRefusal(category: category, tag: "mount_boundary", detail: detail)
            return .failed(detail)
        }

        let token = await registry.registerObservations(report.claims)

        do {
            // TOCTOU narrowing: re-validate the parent chain immediately
            // before the destructive call.
            try pathGuard.validateContainedChild(child, of: root)
            if moveToTrash {
                // A trash failure is a child error — it never falls through
                // to a permanent delete (R11).
                try await trash(child)
            } else {
                try await Self.removeItemConcurrently(
                    at: child, fileManager: fileManager
                )
            }
        } catch {
            if error is PathGuardError {
                logRefusal(
                    category: category, tag: Self.refusalTag(error),
                    detail: "\(child.path): \(error.localizedDescription)"
                )
            }
            // Failed deletions never accept — their registrations remain for
            // siblings to transfer later (R8).
            return .failed(error.localizedDescription)
        }

        // Phase 2: transfer canonical bytes exactly once, after success only.
        return .accepted(await registry.acceptSuccessful(token))
    }

    // MARK: - node_modules items (item mode, R15)

    private func cleanNodeModulesItems(
        _ items: [NodeModulesItem], moveToTrash: Bool
    ) async -> (entries: [CleanupReport.Entry], errors: [(category: String, error: String)]) {
        var entries: [CleanupReport.Entry] = []
        var errors: [(category: String, error: String)] = []
        // One registry across the node_modules group: two items hardlinking
        // the same inode within one operation must not double-count.
        let registry = InodeAccountingRegistry()

        for item in items {
            let label = "node_modules: \(item.projectName)"

            // Item-mode admission requires origin-container provenance — an
            // item that cannot name the configured search root it was
            // discovered under is refused, not trusted.
            guard let origin = item.originContainer else {
                let reason = "refused: item carries no origin-container provenance"
                errors.append((label, reason))
                logRefusal(
                    category: label, tag: "no-provenance",
                    detail: "\(item.nodeModulesPath.path): \(reason)"
                )
                continue
            }

            let container: AdmittedContainer
            do {
                container = try pathGuard.admitContainer(origin)
                try pathGuard.validateRemovableItem(
                    item.nodeModulesPath, inside: container
                )
            } catch {
                errors.append((label, error.localizedDescription))
                logRefusal(
                    category: label, tag: Self.refusalTag(error),
                    detail: "\(item.nodeModulesPath.path): \(error.localizedDescription)"
                )
                continue
            }

            // Deliberately NO already-gone skip here: a missing ("ghost")
            // item surfaces as a per-item error, preserving the pre-guard
            // semantics — its absent leaf measures as an empty report and
            // the deletion below reports the ENOENT.
            let report = sizer.measure(
                at: item.nodeModulesPath, mode: .deletionTarget,
                knownInodes: await registry.knownIdentities
            )
            let token = await registry.registerObservations(report.claims)

            do {
                // TOCTOU narrowing, immediately pre-delete.
                try pathGuard.validateRemovableItem(
                    item.nodeModulesPath, inside: container
                )
                if moveToTrash {
                    try await trash(item.nodeModulesPath)
                } else {
                    // Item mode deletes the node_modules directory ITSELF —
                    // never its contents-with-parent-preserved (R1/R15).
                    try await Self.removeItemConcurrently(
                        at: item.nodeModulesPath, fileManager: fileManager
                    )
                }
            } catch {
                if error is PathGuardError {
                    logRefusal(
                        category: label, tag: Self.refusalTag(error),
                        detail: "\(item.nodeModulesPath.path): \(error.localizedDescription)"
                    )
                }
                errors.append((label, error.localizedDescription))
                continue
            }

            let accepted = await registry.acceptSuccessful(token)
            entries.append(CleanupReport.Entry(
                category: label,
                exactBytes: accepted.exactBytes,
                estimatedUpToBytes: accepted.estimatedUpToBytes
            ))
            logCleanup(
                category: "node_modules/\(item.projectName)",
                bytesFreed: accepted.exactBytes + accepted.estimatedUpToBytes
            )
        }

        return (entries, errors)
    }

    // MARK: - Refusal classification

    /// Stable log tag for a refusal — switched over the TYPED
    /// `PathGuardError` cases, never derived from message strings.
    private static func refusalTag(_ error: Error) -> String {
        guard let guardError = error as? PathGuardError else { return "error" }
        switch guardError {
        case .deniedFilesystemRoot: return "filesystem-root"
        case .deniedVolumeRoot: return "volume-root"
        case .deniedHomeDirectory: return "home-directory"
        case .deniedProtectedChild: return "protected-child"
        case .outsideCategoryPolicy: return "outside-policy"
        case .notAConfiguredContainer: return "not-a-container"
        case .isRootItself: return "root-itself"
        case .notADescendant: return "not-a-descendant"
        case .crossDevice: return "cross-device"
        }
    }

    /// Human-readable reason a `.denied` result was refused — classified off
    /// the typed `ScanError.Kind`, never by matching message strings.
    private static func deniedRefusalReason(for result: ScanResult) -> String {
        let label: String
        switch result.scanError?.kind {
        case .admissionRefused: label = "admission refused at scan time"
        case .tccDenied: label = "macOS privacy (TCC) denial"
        case .permissionDenied: label = "permission denial"
        case .other: label = "scan failure"
        case nil: label = "no measurable access"
        }
        var reason = "refused: the scan could not measure this category (\(label))"
        if let message = result.scanError?.message, !message.isEmpty {
            reason += " — \(message)"
        }
        return reason
    }

    // MARK: - Deletion primitives

    /// Run a custom clean command via /usr/bin/env with a 30-second timeout.
    private func runCleanCommand(_ args: [String]) throws {
        guard !args.isEmpty else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.environment = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin",
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path
        ]

        try process.run()

        let deadline = DispatchTime.now() + .seconds(30)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            process.waitUntilExit()
            group.leave()
        }

        if group.wait(timeout: deadline) == .timedOut {
            process.terminate()
            throw NSError(domain: "CacheCleaner", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Clean command timed out after 30s"])
        }

        guard process.terminationStatus == 0 else {
            throw NSError(domain: "CacheCleaner", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "Clean command exited with status \(process.terminationStatus)"])
        }
    }

    /// Synchronous disk I/O offloaded to a GCD background queue so the actor
    /// (and the cooperative thread pool) never blocks on a large unlink.
    nonisolated private static func removeItemConcurrently(at url: URL, fileManager: FileManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try fileManager.removeItem(at: url)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Move one URL to the Trash via the injectable seam (production:
    /// `FileManager.trashItem`, which requires the main actor).
    private func trash(_ url: URL) async throws {
        let handler = trashHandler
        try await MainActor.run { try handler(url) }
    }

    // MARK: - Logging

    private func logCleanup(category: String, bytesFreed: Int64) {
        let size = ByteCountFormatter.sharedFile.string(fromByteCount: bytesFreed)
        appendLog("Cleaned \(category): \(size)")
    }

    private func logRefusal(category: String, tag: String, detail: String) {
        appendLog("REFUSED [\(tag)] \(category): \(detail)")
    }

    /// A version-drift sibling admission is legitimate but noteworthy — log
    /// which declared root vouched for it.
    private func logDriftAdmission(_ admitted: AdmittedRoot, category: String) {
        guard admitted.viaSiblingDrift else { return }
        appendLog(
            "ADMITTED [version-drift] \(category): \(admitted.resolvedURL.path)"
            + " (declared: \(admitted.matchedDeclaredRoot.path))"
        )
    }

    private func appendLog(_ message: String) {
        let logDir = home.appendingPathComponent(".cacheout")
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let dirFd = logDir.withUnsafeFileSystemRepresentation { pathPtr -> Int32 in
            guard let pathPtr = pathPtr else { return -1 }
            return open(pathPtr, O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC)
        }
        guard dirFd >= 0 else { return }
        defer { close(dirFd) }
        guard fchmod(dirFd, 0o700) == 0 else { return }

        let entry = "[\(ISO8601DateFormatter.shared.string(from: Date()))] \(message)\n"

        let fd = openat(dirFd, "cleanup.log", O_CREAT | O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)

        guard fd != -1 else { return }

        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let data = entry.data(using: .utf8) ?? Data()

        if #available(macOS 10.15.4, *) {
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            handle.write(data)
            handle.closeFile()
        }
    }
}
