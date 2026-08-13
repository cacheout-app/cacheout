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

/// Resolves bundle-id presence from two signals, either of which
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
///
/// ## Tri-state contract (epic API contract)
///
/// Orphan classification asserts a NEGATIVE ("no installed app"), so
/// `.notInstalled` must mean the census was complete enough to establish
/// absence:
///
/// - `.installed` wins over everything the moment EITHER signal matches —
///   even an incomplete census can establish presence.
/// - `.notInstalled` requires a no-match against a COMPLETE census (and no
///   LaunchServices match when that signal is enabled).
/// - `.unknown` when the census was INCOMPLETE and LaunchServices produced
///   no match either: an EXISTING root that could not be enumerated, an
///   enumeration failure partway, or a bundle whose metadata was present
///   (or possibly present) but unreadable — see below.
///
/// MISSING roots (no Caskroom on a non-Homebrew machine) are normal
/// absence — they never make the census incomplete. Likewise a root that
/// exists but is not a directory: it contains no app bundles, with
/// certainty.
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
/// not an option. Final class, `@unchecked Sendable` under this lock
/// discipline: `cachedCensus` is read/written ONLY while `lock` is held;
/// every other stored property is an immutable `let`. Compatible with
/// fn-2's `SpaceScanner: Sendable`.
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

    /// Guards `cachedCensus` (the only mutable state; see the header's
    /// lock discipline).
    private let lock = NSLock()
    private var cachedCensus: Census?

    // MARK: - Init

    /// Injectable-roots initializer — hermetic tests use this with
    /// `useLaunchServices: false` so they never touch the real machine.
    init(
        censusRoots: [URL],
        useLaunchServices: Bool = true,
        fileManager: FileManager = .default
    ) {
        self.censusRoots = censusRoots
        self.useLaunchServices = useLaunchServices
        self.fileManager = fileManager
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
        return census.complete ? .notInstalled : .unknown
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
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
                // MISSING root: normal absence, never incompleteness.
                continue
            }
            guard isDirectory.boolValue else {
                // Exists but is not a directory: contains no app bundles,
                // with certainty — absence stays established.
                continue
            }

            guard let enumerator = fileManager.enumerator(
                at: root,
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
