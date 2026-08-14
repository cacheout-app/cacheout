/// # DevRootsStore — Configurable Dev Roots (fn-4.1, R8/R16)
///
/// The persisted, seeded, policy-checked list of dev roots the
/// build-artifacts scanner walks. Pure config plumbing: no walking, no
/// sizing, no UI. The pipeline from persisted config to the error surface
/// is pinned by the epic (R16):
///
///     stored-or-seeds (resolved against injected home)
///       → container-root admission policy (rejected → issues)
///       → exact-canonical-duplicate dedupe
///       → DevRootsResolution { keptRoots, issues }
///
/// Every issue produced here is CLASSIFIED, never a silent drop: fn-4.5's
/// scanner stores the resolution at construction, registers `keptRoots` as
/// its `trustedContainerRoots`, and appends `issues` to EVERY scan outcome —
/// so a policy-rejected persisted root (a stored `/`) stays visible on every
/// scan while never being registered or walked, and the stored value is
/// never rewritten (a value this build cannot read may be meaningful to
/// another build — the OrphanedCachesSweepConfig doctrine).

import Foundation

// MARK: - Resolution result (R16, pinned)

/// What dev-roots resolution produced: the roots that survived the policy
/// and dedupe (DECLARED spellings, verbatim) plus the classified config
/// issues for everything that did not.
struct DevRootsResolution: Equatable, Sendable {
    /// The effective roots in declaration order — declared spellings
    /// preserved untouched (registration/`trustedContainerRoots` and the
    /// walker's `originRoot` carry these verbatim; validator origin binding
    /// needs them).
    let keptRoots: [URL]
    /// Classified config issues: policy-rejected roots as the frozen
    /// `.containerRefused` (with the offending declared path), whole-value
    /// parse failures as `.configInvalid` (url nil — no honest filesystem
    /// path exists).
    let issues: [ScanIssue]
}

// MARK: - Store

/// UserDefaults-backed dev-roots config. Injectable suite + injectable
/// identity provider; the home the roots resolve against is a per-call
/// parameter (matching the injectable-home house rule — zero real-`$HOME`
/// reads in tests).
struct DevRootsStore {

    /// Persisted key, per the `cacheout.<scanner>.<knob>` template
    /// (`OrphanedCachesSweepConfig`).
    static let devRootsKey = "cacheout.buildArtifacts.devRoots"

    /// Seed roots — NodeModulesScanner's ten search-root names VERBATIM
    /// (the list the build-artifacts scanner inherits when it subsumes it).
    /// `Documents/GitHub` is deliberately NOT seeded: `~/Documents` covers
    /// it to the walker's depth budget, and a user who needs deeper adds
    /// the nested root, which then walks independently (D7).
    static let seedRootNames: [String] = [
        "Documents",
        "Developer",
        "Projects",
        "Code",
        "Sites",
        "Desktop",
        "Dropbox",
        "repos",
        "src",
        "work",
    ]

    private let defaults: UserDefaults
    private let provider: FileSystemIdentityProvider

    init(
        defaults: UserDefaults = .standard,
        provider: FileSystemIdentityProvider = FileSystemIdentityProvider()
    ) {
        self.defaults = defaults
        self.provider = provider
    }

    // MARK: - Resolution

    /// The effective dev roots for `home`: the persisted list (or the seeds
    /// when nothing valid is persisted) through the R16 pipeline. Never
    /// writes anything.
    func effectiveRoots(home: URL) -> DevRootsResolution {
        switch parseStoredPaths() {
        case .absent:
            return resolve(declaredPaths: Self.seedRootNames, home: home,
                           parseIssues: [])
        case .valid(let paths):
            return resolve(declaredPaths: paths, home: home, parseIssues: [])
        case .corrupt(let stored):
            // Whole-value parse failure (pinned MIXED-CORRUPT semantics):
            // ANY non-string element — `[true, "/"]` — invalidates the
            // WHOLE value. Seeds take effect, the stored value is NOT
            // rewritten, and the fallback is never silent: the `/` hiding
            // inside the corrupt array never reaches the kept set, and the
            // visible parse issue covers it. `url` nil — a config parse
            // failure has no honest filesystem path (non-filesystem kind).
            let described = String(describing: stored)
                .replacingOccurrences(of: "\n", with: " ")
            let issue = ScanIssue(
                url: nil,
                kind: .configInvalid,
                detail: "\(Self.devRootsKey) is not an array of strings "
                    + "(stored value: \(described)) — default dev roots in "
                    + "effect; the stored value was left unchanged"
            )
            return resolve(declaredPaths: Self.seedRootNames, home: home,
                           parseIssues: [issue])
        }
    }

    /// The non-persisted per-invocation REPLACEMENT path (CLI `--dev-root`,
    /// fn-4.6): the given declared roots replace the effective set for this
    /// resolution only — seeds are not consulted, nothing is read from or
    /// written to the suite. The same policy + dedupe pipeline applies.
    func effectiveRoots(replacing declaredRoots: [URL], home: URL)
        -> DevRootsResolution
    {
        resolve(declaredRoots: declaredRoots, home: home, parseIssues: [])
    }

    // MARK: - Declared-string convention (ONE definition)

    /// A declared path string → its URL: absolute when `/`-prefixed,
    /// HOME-RELATIVE otherwise (the `CategoryAdmissionPolicy` probed-fallback
    /// convention — the seeds are home-relative names).
    ///
    /// The ONE definition, shared by this store's resolution and by fn-4.6's
    /// Settings editor (which must persist a string that resolves back to the
    /// URL it validated — a second convention would let the editor validate
    /// one path and the scanner walk another).
    static func declaredURL(for path: String, home: URL) -> URL {
        path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : home.appendingPathComponent(path)
    }

    // MARK: - Mutations (fn-4.6 Settings surface)

    /// The declared list the Settings editor renders and mutates: the valid
    /// persisted value, else the seeds (a fresh install shows the seeds it
    /// actually walks, and "remove one" then persists seeds-minus-one).
    func declaredPaths() -> [String] { declaredPathList() }

    /// ADD-TIME validation for the Settings editor (fn-4.6, R16): the SHARED
    /// container-root admission policy (`PathGuard.validateContainerRoot`),
    /// run with THIS store's provider — the very component
    /// `effectiveRoots` runs on every resolution. Deliberately a
    /// call-through: a UI-local re-implementation is exactly what R16
    /// forbids, and routing the editor through the store keeps one provider
    /// and one policy per layer.
    func validateCandidateRoot(_ url: URL, home: URL) throws {
        try PathGuard.validateContainerRoot(url, home: home, provider: provider)
    }

    /// Append `path` to the persisted declared list (the persisted value,
    /// or the seeds when nothing valid is persisted). Exact-string no-op if
    /// already declared. Policy enforcement stays at RESOLUTION (and at
    /// fn-4.6's add-time validation, which calls the shared policy) — the
    /// store never silently drops what the user wrote.
    func add(_ path: String) {
        var current = declaredPathList()
        guard !current.contains(path) else { return }
        current.append(path)
        defaults.set(current, forKey: Self.devRootsKey)
    }

    /// Remove every exact-string occurrence of `path` from the persisted
    /// declared list.
    func remove(_ path: String) {
        let current = declaredPathList().filter { $0 != path }
        defaults.set(current, forKey: Self.devRootsKey)
    }

    /// Back to the seeds: the key is removed entirely (seeds are a
    /// fallback, never persisted).
    func resetToDefaults() {
        defaults.removeObject(forKey: Self.devRootsKey)
    }

    // MARK: - Parsing (CFBoolean/NSNumber-guard doctrine)

    private enum StoredPathsParse {
        case absent
        case valid([String])
        case corrupt(Any)
    }

    /// Guarded read of the persisted value. `as? [String]` is the honest
    /// whole-shape class check for a string array: a non-array, or an array
    /// with ANY non-string element (an NSNumber, a toll-free-bridged
    /// CFBoolean `true`, NSNull, …), fails the cast — no element-level
    /// bridging masks a foreign type the way `NSNumber` masks a persisted
    /// Bool for numeric reads (the fn-3 memory entry). Mixed corruption is
    /// therefore a WHOLE-value failure by construction.
    private func parseStoredPaths() -> StoredPathsParse {
        guard let stored = defaults.object(forKey: Self.devRootsKey) else {
            return .absent
        }
        guard let paths = stored as? [String] else {
            return .corrupt(stored)
        }
        return .valid(paths)
    }

    /// The declared list mutations operate on: the valid persisted value,
    /// else the seeds (so "add one root" on a fresh install yields
    /// seeds + 1, not a 1-element list). An explicit USER mutation may
    /// overwrite a corrupt stored value — only RESOLUTION is bound by
    /// never-rewrite.
    private func declaredPathList() -> [String] {
        if case .valid(let paths) = parseStoredPaths() { return paths }
        return Self.seedRootNames
    }

    // MARK: - Pipeline

    /// Declared strings → URLs against `home` through the ONE shared
    /// convention (`declaredURL(for:home:)`).
    private func resolve(
        declaredPaths: [String], home: URL, parseIssues: [ScanIssue]
    ) -> DevRootsResolution {
        let declaredRoots = declaredPaths.map {
            Self.declaredURL(for: $0, home: home)
        }
        return resolve(declaredRoots: declaredRoots, home: home,
                       parseIssues: parseIssues)
    }

    /// The R16 pipeline over already-formed declared URLs:
    ///
    /// 1. **Container-root admission policy** on EVERY root, canonicalized
    ///    before the check (the shared `PathGuard.validateContainerRoot` —
    ///    ONE definition, epic R16). Rejected roots are EXCLUDED from the
    ///    kept set and carried as frozen `.containerRefused` issues with
    ///    their offending declared path.
    /// 2. **Exact-canonical-duplicate dedupe ONLY** (no keep-ancestor drop,
    ///    D7 — nested real roots remain independent walks). TWO values per
    ///    root: a normalized comparison KEY (canonical path — symlinks and
    ///    `..` resolved) used ONLY for duplicate comparison, and the
    ///    ORIGINAL declared URL preserved untouched in the kept set. Only
    ///    roots proven real directories by lstat NO-FOLLOW on the LEAF
    ///    participate (symlinked ANCESTORS are legal — `/var` → `/private/
    ///    var` — and resolve into the key); symlink-LEAF, absent, and
    ///    non-directory roots are SET ASIDE and pass through verbatim —
    ///    the walk-time per-root gates classify them (symlink/non-directory
    ///    → classified issue; absent → honest no-item omission).
    private func resolve(
        declaredRoots: [URL], home: URL, parseIssues: [ScanIssue]
    ) -> DevRootsResolution {
        var issues = parseIssues
        var kept: [URL] = []
        var seenCanonicalKeys = Set<String>()

        for declared in declaredRoots {
            // (1) Policy — on the CANONICAL root (alias doctrine): a
            // symlink alias of `/`, of a volume root, or of $HOME is caught
            // here because the policy canonicalizes before checking.
            do {
                try PathGuard.validateContainerRoot(
                    declared, home: home, provider: provider
                )
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription
                    ?? String(describing: error)
                issues.append(ScanIssue(
                    url: declared,
                    kind: .containerRefused,
                    detail: "configured dev root refused: \(reason)"
                ))
                continue
            }

            // (2) Exact-canonical-duplicate dedupe — real directories only
            // (leaf lstat no-follow).
            if provider.probeKind(of: declared) == .kind(.directory) {
                let key = provider.canonicalize(declared).path
                guard seenCanonicalKeys.insert(key).inserted else {
                    continue // exact duplicate of an earlier declared root
                }
            }
            kept.append(declared)
        }

        return DevRootsResolution(keptRoots: kept, issues: issues)
    }
}
