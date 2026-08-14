//
//  InstalledAppResolver.swift
//  Cacheout
//
//  fn-3.3 — the production answer to "is an app with bundle id X
//  installed?" (epic R2). Standalone component: fn-3.4 wires
//  `status(ofBundleID:)` in as `OrphanedCacheClassifier`'s tri-state
//  `installedAppStatus` predicate.
//

import AppKit
import Darwin
import Foundation

/// Resolves bundle-id presence from three signals, any of which
/// establishes presence:
///
/// 1. **LaunchServices** — `NSWorkspace.shared.urlForApplication(
///    withBundleIdentifier:)` covers anything LS-registered anywhere on
///    disk. Gated behind `useLaunchServices` so hermetic tests can disable
///    it: it queries the REAL machine and cannot be fixtured.
/// 2. **Directory census** — a lazy ONE-SHOT enumeration of `*.app`
///    bundles under the injectable census roots (production defaults:
///    /Applications, ~/Applications against the injected home, and both
///    Homebrew caskroom prefixes). Covers a stale/incomplete LS database
///    and caskroom-only copies.
/// 3. **Spotlight** — a bounded `mdfind` count query for
///    `kMDItemCFBundleIdentifier` (see `SpotlightBundleIDProbe`). The only
///    signal that covers ARBITRARY install locations (`/Volumes/Work/Apps`,
///    `~/Developer`, …) for apps never LS-registered — the census roots
///    alone must not be mistaken for the whole disk (PR #456 review P2).
///    Injectable closure so hermetic tests never spawn a subprocess.
///
/// ## Tri-state contract (epic API contract)
///
/// Orphan classification asserts a NEGATIVE ("no installed app"), so
/// `.notInstalled` must mean the machine was searched completely enough to
/// establish absence — GLOBALLY, not merely under the census roots:
///
/// - `.installed` wins over everything the moment ANY signal matches —
///   even an incomplete census can establish presence, and a Spotlight hit
///   establishes presence the other two signals cannot see.
/// - `.notInstalled` requires a no-match against a COMPLETE census, no
///   LaunchServices match (when that signal is enabled), AND a clean
///   Spotlight miss from a HEALTHY index (canary-verified — see the probe).
///   Census + LS alone cover only four roots plus whatever LS happens to
///   have registered; only Spotlight extends the search to arbitrary
///   indexed locations, so without its clean miss global absence is not
///   established.
/// - `.unknown` when absence cannot be asserted: the census was INCOMPLETE
///   (a root that could not be statted or enumerated, an enumeration
///   failure partway, or a bundle whose metadata was present (or possibly
///   present) but unreadable — see below), or Spotlight was UNAVAILABLE (disabled,
///   unhealthy index, query failure or timeout) while the other signals
///   produced no match. Fail closed: a partial search never asserts a
///   global negative.
///
/// MISSING roots (no Caskroom on a non-Homebrew machine) are normal
/// absence — they never make the census incomplete. MISSING means
/// POSITIVELY missing: the root probe stats with errno preserved, and only
/// ENOENT/ENOTDIR (including a dangling symlinked root — the probe follows
/// links) counts as absence. Any OTHER stat failure — EACCES, or EPERM
/// (TCC denials surface as both), ELOOP, EIO, … — means the root may exist
/// unread, so the census is INCOMPLETE. Likewise a root that exists but is
/// not a directory: it contains no app bundles, with certainty.
///
/// Residual gap, accepted: an app on a volume EXCLUDED from Spotlight
/// indexing that was also never LS-registered is invisible to all three
/// signals and would still resolve `.notInstalled`. The classifier's orphan
/// evidence therefore names the basis of the claim ("checked
/// LaunchServices, Spotlight, and standard app folders") instead of
/// asserting bare global absence — and the orphan tier is review-only,
/// never bulk-eligible, by frozen epic policy.
///
/// Metadata failures fail CLOSED, but only genuine failures: an `.app`
/// directory with POSITIVELY no `Contents/Info.plist` (lstat fails with
/// ENOENT/ENOTDIR — the path is provably absent, not merely unreadable)
/// has no bundle identifier at all, so it cannot hide a match and does not
/// degrade completeness. When `Bundle(url:)` yields no identifier and the
/// plist's absence CANNOT be positively established (EACCES on an
/// unreadable bundle, a present-but-unparseable plist), the census is
/// INCOMPLETE.
///
/// ## Census rules
///
/// - **NO depth cap — prune at `.app` instead.** A depth bound that leaves
///   directories unexplored would let a nested installed app (e.g.
///   `/Applications/Utilities/Vendor X/Foo.app`, caskroom
///   `Caskroom/<cask>/<version>/<Name>.app`) be missed and `.notInstalled`
///   falsely asserted; completeness must not depend on layout depth. The
///   walk descends freely but STOPS at the first `.app` path component —
///   it never looks for nested apps inside a bundle — so app-root trees
///   stay shallow-by-prune in practice.
/// - Built ONCE, lazily, on the first query that needs it — never per
///   entry (the sweep asks once per orphan candidate).
/// - Bundle-id comparison is case-insensitive (LaunchServices treats ids
///   case-insensitively): the id set and every query are lowercased.
/// - Hidden entries included; symlinked directories are never descended
///   (`FileManager.DirectoryEnumerator` semantics, so no link cycles). A
///   symlink NAMED `Foo.app` still contributes its target's id via
///   `Bundle(url:)` — a positive-only signal; a broken link provably has
///   no Info.plist and is skipped. The census is READ-ONLY, so the
///   deletion-path no-follow doctrine does not apply here.
///
/// ## Concurrency
///
/// The public API is SYNCHRONOUS by contract: fn-3.2's classifier takes a
/// non-async `(String) -> InstalledAppStatus` predicate, so an actor is
/// not an option. The Spotlight signal stays inside that contract as a
/// BOUNDED synchronous subprocess wait (house 2s probe-timeout doctrine —
/// see `SpotlightBundleIDProbe`), and its unavailability latch caps the
/// worst case at one canary round plus one query, never per-candidate
/// stalls. Final class, `@unchecked Sendable` under this lock discipline:
/// `cachedCensus` is read/written ONLY while `lock` is held; every other
/// stored property is an immutable `let` (the probe closure's own state is
/// lock-guarded inside the probe). Compatible with fn-2's
/// `SpaceScanner: Sendable`.
///
/// Deliberately NOT MainActor-isolated, on the type or any query path:
/// the resolver runs inside `scan(context:) async` and in `--cli` mode
/// where NO NSApplication event loop exists — MainActor hops deadlock the
/// headless CLI (project history: CLI audit). `urlForApplication(
/// withBundleIdentifier:)` is documented thread-safe and carries no actor
/// isolation in the SDK (verified: typechecks from a nonisolated
/// synchronous context under `-swift-version 6`).
final class InstalledAppResolver: @unchecked Sendable {

    // MARK: - Census model

    /// What one census walk produced. Immutable once built.
    private struct Census {
        /// Lowercased bundle identifiers of every `.app` discovered under
        /// the census roots.
        let identifiers: Set<String>
        /// True when every EXISTING root enumerated fully with readable
        /// bundle metadata — the precondition for asserting absence.
        let complete: Bool
    }

    // MARK: - Stored state

    private let censusRoots: [URL]
    private let useLaunchServices: Bool
    private let fileManager: FileManager
    /// Signal 3 — Spotlight presence, consulted ONLY after both other
    /// signals miss (a subprocess spawn is never paid for an id the census
    /// or LS already resolves). Injectable so hermetic tests script all
    /// three outcomes without touching the real index.
    private let spotlightPresence: (String) -> SpotlightPresence

    /// Guards `cachedCensus` (the only mutable state; see the header's
    /// lock discipline).
    private let lock = NSLock()
    private var cachedCensus: Census?

    // MARK: - Init

    /// Injectable-roots initializer — hermetic tests use this with
    /// `useLaunchServices: false` and an injected `spotlightPresence`
    /// closure so they never touch the real machine. `nil` (the default,
    /// and the production path) means the live `SpotlightBundleIDProbe`.
    init(
        censusRoots: [URL],
        useLaunchServices: Bool = true,
        fileManager: FileManager = .default,
        spotlightPresence: ((String) -> SpotlightPresence)? = nil
    ) {
        self.censusRoots = censusRoots
        self.useLaunchServices = useLaunchServices
        self.fileManager = fileManager
        self.spotlightPresence = spotlightPresence
            ?? { [probe = SpotlightBundleIDProbe()] in probe.presence(ofBundleID: $0) }
    }

    /// Production initializer: default census roots resolved against the
    /// injectable home.
    convenience init(home: URL, useLaunchServices: Bool = true) {
        self.init(
            censusRoots: Self.defaultCensusRoots(home: home),
            useLaunchServices: useLaunchServices
        )
    }

    /// Production census roots. Both Homebrew prefixes (arm64 + intel) are
    /// listed, the same stance as the category prober's PATH
    /// (`CacheCategory.toolExists`); whichever is absent on this machine is
    /// normal absence.
    static func defaultCensusRoots(home: URL) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/opt/homebrew/Caskroom", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/Caskroom", isDirectory: true),
        ]
    }

    // MARK: - Query

    /// Tri-state presence for one bundle id. Synchronous, thread-safe,
    /// callable from any isolation context (see the header).
    func status(ofBundleID bundleID: String) -> InstalledAppStatus {
        // Signal 1 — LaunchServices. A hit needs no census at all.
        if useLaunchServices,
           NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil {
            return .installed
        }

        // Signal 2 — the one-shot census.
        let census = censusBuildingIfNeeded()
        if census.identifiers.contains(bundleID.lowercased()) {
            return .installed
        }

        // Signal 3 — Spotlight, the only signal covering arbitrary install
        // locations for never-LS-registered apps. Consulted only now that
        // both cheaper signals have missed. A clean miss from a HEALTHY
        // index is REQUIRED before the census verdict may claim global
        // absence; an unavailable index fails closed (header contract).
        switch spotlightPresence(bundleID) {
        case .present:
            return .installed
        case .absent:
            return census.complete ? .notInstalled : .unknown
        case .unavailable:
            return .unknown
        }
    }

    // MARK: - Census (lazy, one-shot)

    private func censusBuildingIfNeeded() -> Census {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cachedCensus {
            return cached
        }
        let built = buildCensus()
        cachedCensus = built
        return built
    }

    private func buildCensus() -> Census {
        var identifiers: Set<String> = []
        var complete = true

        for root in censusRoots {
            switch Self.probeRoot(atPath: root.path) {
            case .positivelyAbsent:
                // MISSING root (stat fails ENOENT/ENOTDIR — including a
                // dangling symlinked root, since the probe follows links):
                // normal absence, never incompleteness.
                continue
            case .notADirectory:
                // Exists but is not a directory: contains no app bundles,
                // with certainty — absence stays established.
                continue
            case .unreadable:
                // The root MAY exist but cannot even be statted — EACCES/
                // EPERM from an ancestor lacking search permission (TCC
                // denials surface as EPERM as well as EACCES), ELOOP, EIO,
                // …. `fileExists` conflated this with ENOENT; it is NOT
                // positive absence — apps could hide under the unreadable
                // root, so fail closed (PR #456 review r3). Keep walking:
                // `.installed` can still win from the remaining roots.
                complete = false
                continue
            case .directory:
                break
            }

            // The probe FOLLOWS a symlinked root, but `DirectoryEnumerator`
            // does NOT walk through a top-level symlink — resolve the root
            // first so the follow policy actually holds (a symlinked root
            // whose target is enumerable is a complete, ordinary root).
            // Entries WITHIN the walk keep the enumerator's no-descend
            // symlink semantics.
            guard let enumerator = fileManager.enumerator(
                at: root.resolvingSymlinksInPath(),
                includingPropertiesForKeys: [],
                // options: [] deliberately — hidden entries INCLUDED;
                // symlinked directories are never descended regardless.
                options: [],
                errorHandler: { _, _ in
                    // An EXISTING root (or a branch under one) that refuses
                    // enumeration means absence can no longer be asserted —
                    // fail closed. Keep walking: `.installed` wins even
                    // from an incomplete census.
                    complete = false
                    return true
                }
            ) else {
                complete = false
                continue
            }

            while let entry = enumerator.nextObject() as? URL {
                guard entry.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
                    continue
                }
                // First `.app` component: record and PRUNE — never look
                // for nested apps inside a bundle.
                enumerator.skipDescendants()
                record(bundleAt: entry, into: &identifiers, complete: &complete)
            }
        }

        return Census(identifiers: identifiers, complete: complete)
    }

    /// Reads one discovered bundle's id via `Bundle(url:)` (Contents/
    /// Info.plist; works on plain unsigned fixture directories). No id is
    /// tolerated ONLY when the metadata file is provably absent — see the
    /// header's metadata-failure rules.
    private func record(
        bundleAt url: URL,
        into identifiers: inout Set<String>,
        complete: inout Bool
    ) {
        if let id = Bundle(url: url)?.bundleIdentifier {
            identifiers.insert(id.lowercased())
            return
        }
        if !Self.infoPlistPositivelyAbsent(inBundleAt: url) {
            // Metadata present (or possibly present) but unreadable: this
            // bundle could hide any id — fail closed.
            complete = false
        }
    }

    /// Errno-preserving census-root probe outcome — see `probeRoot`.
    private enum RootProbe {
        /// Resolves to a directory: enumerate it.
        case directory
        /// Resolves to something that is not a directory (a regular file,
        /// or a symlink to one): contains no app bundles, with certainty.
        case notADirectory
        /// stat failed ENOENT/ENOTDIR: the root provably does not exist —
        /// normal absence (no Caskroom on a non-Homebrew machine).
        case positivelyAbsent
        /// stat failed with any OTHER errno (EACCES, EPERM, ELOOP, EIO,
        /// …): the root may exist unread — census incompleteness.
        case unreadable
    }

    /// Stats one census root with errno preserved, because
    /// `fileManager.fileExists` answers `false` for an unreadable root
    /// (EACCES/EPERM on an ancestor without search permission) exactly as
    /// it does for a genuinely missing one — and only the latter may leave
    /// the census complete (PR #456 review r3).
    ///
    /// Deliberately FOLLOWS a symlinked root (`stat`, not `lstat`): the
    /// census asks "could an app exist under this root", and enumeration
    /// itself resolves the top-level path. A DANGLING symlinked root
    /// therefore stats ENOENT — positive absence — while an unreadable or
    /// cyclic target (EACCES/EPERM/ELOOP) is incompleteness.
    private static func probeRoot(atPath path: String) -> RootProbe {
        var st = stat()
        guard stat(path, &st) != 0 else {
            return (st.st_mode & S_IFMT) == S_IFDIR ? .directory : .notADirectory
        }
        switch errno {
        case ENOENT, ENOTDIR:
            return .positivelyAbsent
        default:
            return .unreadable
        }
    }

    /// True only when `Contents/Info.plist` is POSITIVELY absent: lstat
    /// fails with ENOENT (no such path) or ENOTDIR (a path component is
    /// not a directory — e.g. a regular file named `Foo.app`). An EACCES
    /// or any other failure means absence cannot be established.
    private static func infoPlistPositivelyAbsent(inBundleAt url: URL) -> Bool {
        let plistPath = url
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist", isDirectory: false)
            .path
        var st = stat()
        guard lstat(plistPath, &st) != 0 else {
            // The plist EXISTS yet Bundle yielded no id — metadata failure.
            return false
        }
        return errno == ENOENT || errno == ENOTDIR
    }
}

// MARK: - Spotlight signal

/// Outcome of one Spotlight bundle-id presence probe.
enum SpotlightPresence {
    /// The index has at least one item carrying this bundle identifier.
    case present
    /// A HEALTHY index (canary-verified) answered and has none — and no
    /// query failure had latched the probe when the zero was accepted.
    case absent
    /// No trustworthy answer: Spotlight disabled or its index missing the
    /// canary apps, a query failure, or a timeout. Callers must fail
    /// closed — this can never support an absence claim.
    case unavailable
}

/// Spotlight bundle-id presence via a bounded `/usr/bin/mdfind -count`
/// subprocess.
///
/// ## Why a subprocess and not the query APIs
///
/// Measured on macOS 26 (Darwin 25): `MDQueryExecute` (synchronous, with
/// an explicit computer scope) SUCCEEDS yet returns 0 results for ids
/// `mdfind` resolves instantly — Finder and Safari included — from an
/// unentitled third-party process; metadata results are filtered for such
/// clients, and `NSMetadataQuery` rides the same mds connection. The
/// Apple-signed `mdfind` sees the real index, so it is the only avenue
/// that actually works — and this codebase already runs bounded
/// subprocess probes (`CacheCategory.toolExists`, house 2s probe-timeout
/// doctrine, `Process.waitForExit(within:)`).
///
/// ## Query shape
///
/// `kMDItemCFBundleIdentifier = "<escaped id>"c` — the trailing `c` flag
/// is the case-insensitivity form that WORKS with mdfind (bundle ids
/// compare case-insensitively, and plain `==` is case-sensitive: a query
/// for `com.apple.SAFARI` misses `com.apple.Safari`). The `==[c]`
/// modifier syntax empirically returns 0 for known-present ids on macOS
/// 26 and must not be used. The id is passed inside argv (never a shell),
/// with `\` and `"` escaped so a hostile cache-directory NAME cannot
/// inject query syntax.
///
/// ## Canary, health, and the fail-closed latch
///
/// `mdfind` reports a malformed query and a disabled/rebuilding index the
/// SAME way as genuine absence: exit 0, count 0. A zero is therefore only
/// trustworthy after a canary proves the index can see apps that exist on
/// every macOS installation (Finder, Dock, System Settings). The pass runs
/// EVERY canary: with no query failures, any one hit proves health; ANY
/// canary query failure latches unavailable regardless of hits in either
/// ordering — a hit proves the index answers some queries, not that its
/// zeros are trustworthy (any-failure-poisons doctrine, PR #456 review
/// r3). The canary runs ONCE per probe instance and uses the same query
/// shape as real queries, so a shape regression fails the canary rather
/// than minting false absences. Any failure — canary miss, spawn error,
/// non-zero exit, unparseable output, timeout — LATCHES the probe
/// unavailable so a broken mds costs bounded time once, not 2s per
/// candidate.
///
/// Thread-safe (`lock` guards the latch state; queries themselves run
/// outside the lock — a racing duplicate canary is idempotent and
/// harmless). Because queries run unlocked, a zero-count RECHECKS the
/// latch before it may become `.absent`: a concurrent query's failure
/// poisons every in-flight absence (the canary path already has this
/// property — its verdict is recomputed under the lock, first writer
/// wins). `@unchecked Sendable` under that discipline.
final class SpotlightBundleIDProbe: @unchecked Sendable {

    /// Bundle ids present on every macOS installation; any one hit proves
    /// the index healthy PROVIDED no canary query failed (see the header's
    /// any-failure-poisons rule).
    static let canaryBundleIDs = [
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.systempreferences",
    ]

    /// House probe-timeout doctrine (`CacheCategory.toolExists`): mdfind
    /// count queries answer in tens of milliseconds; anything slower than
    /// this is a hung mds and latches the probe unavailable.
    static let queryTimeout: TimeInterval = 2

    private enum HealthState {
        case unprobed
        case healthy
        case unavailable
    }

    /// Bundle id → match count; `nil` on any query failure. Injectable so
    /// hermetic tests script canary/latch behavior without subprocesses.
    private let runQuery: (String) -> Int?

    private let lock = NSLock()
    private var state: HealthState = .unprobed

    init(runQuery: ((String) -> Int?)? = nil) {
        self.runQuery = runQuery ?? Self.liveMDFindCount
    }

    /// Tri-state presence for one bundle id. Synchronous and bounded; see
    /// the type header for the canary/latch semantics.
    func presence(ofBundleID bundleID: String) -> SpotlightPresence {
        guard ensureHealthy() else { return .unavailable }
        guard let count = runQuery(bundleID) else {
            latchUnavailable()
            return .unavailable
        }
        if count > 0 { return .present }
        // A zero is only trustworthy while the latch is still clean:
        // queries run OUTSIDE the lock by design, so a CONCURRENT query's
        // failure may have latched the probe while this one was in flight —
        // and after ANY failure no absence is trustworthy (the same mds
        // that failed one query may be answering others with spurious
        // zeros). Recheck under the lock before converting the zero into
        // `.absent` (PR #456 review r2). A positive needs no recheck:
        // presence is a positive signal and `.installed` wins over
        // everything. Full serialization — holding the lock ACROSS the
        // subprocess — would stall every concurrent `status()` call behind
        // the 2s worst-case wait; the recheck closes the observable window
        // instead (a failure latching after this point is
        // indistinguishable from one latching after return).
        return latchedUnavailable() ? .unavailable : .absent
    }

    /// The exact query handed to mdfind — exposed for the escaping tests.
    static func queryString(forBundleID bundleID: String) -> String {
        let escaped = bundleID
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "kMDItemCFBundleIdentifier = \"\(escaped)\"c"
    }

    // MARK: - Health

    /// One-shot canary, double-checked around the lock (canary queries run
    /// OUTSIDE it — they spawn subprocesses; a racing duplicate computes
    /// the same verdict).
    private func ensureHealthy() -> Bool {
        lock.lock()
        let current = state
        lock.unlock()
        switch current {
        case .healthy: return true
        case .unavailable: return false
        case .unprobed: break
        }

        // Run EVERY canary — a hit must NOT short-circuit the pass. A hit
        // proves the index answers SOME queries, not that its zeros are
        // trustworthy, and the doctrine is any-failure-poisons: a canary
        // failure in EITHER ordering (failure-then-hit, hit-then-failure)
        // latches unavailable rather than being laundered into an ordinary
        // miss (PR #456 review r3 — the canary-pass sibling of the r2
        // post-query latch recheck). Only a FAILURE short-circuits: the
        // verdict cannot recover, and breaking caps a broken mds at one
        // timeout instead of three. Worst case stays 3 × queryTimeout,
        // once per probe instance.
        var sawHit = false
        var sawFailure = false
        for id in Self.canaryBundleIDs {
            guard let count = runQuery(id) else {
                sawFailure = true
                break
            }
            if count > 0 { sawHit = true }
        }
        let healthy = sawHit && !sawFailure
        lock.lock()
        // First writer wins; an unavailable latch set meanwhile sticks.
        if state == .unprobed {
            state = healthy ? .healthy : .unavailable
        }
        let verdict = state == .healthy
        lock.unlock()
        return verdict
    }

    private func latchUnavailable() {
        lock.lock()
        state = .unavailable
        lock.unlock()
    }

    /// Post-query latch recheck — see `presence(ofBundleID:)`.
    private func latchedUnavailable() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == .unavailable
    }

    // MARK: - Live mdfind runner

    private static func liveMDFindCount(forBundleID bundleID: String) -> Int? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["-count", queryString(forBundleID: bundleID)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        guard process.waitForExit(within: queryTimeout) else {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }

        // The output is one tiny count line — far below the 64 KiB pipe
        // buffer, so the child can never block on write before exit, and
        // reading to EOF after exit terminates promptly (the parent's copy
        // of the write end was closed at spawn).
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
