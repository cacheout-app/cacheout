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

    /// Seed roots — the retired node_modules scanner's ten search-root
    /// names VERBATIM (the list the build-artifacts scanner inherited when
    /// it subsumed it, fn-4.5/fn-4.7).
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
    ///
    /// - Returns: whether the persisted value actually CHANGED. fn-4.6's
    ///   editor rebuilds the runtime only on a real change: a rebuild is
    ///   unconditional-by-design for an actual dev-roots change, but doing
    ///   it for a no-op would invalidate destructive freshness (gating every
    ///   clean until the next scan) for a configuration nobody changed.
    @discardableResult
    func add(_ path: String) -> Bool {
        var current = declaredPathList()
        guard !current.contains(path) else { return false }
        current.append(path)
        defaults.set(current, forKey: Self.devRootsKey)
        return true
    }

    /// Remove every exact-string occurrence of `path` from the persisted
    /// declared list.
    ///
    /// - Returns: whether the persisted value actually CHANGED. A path that
    ///   is not declared writes NOTHING — on a fresh install that would
    ///   otherwise materialize the seeds into the suite as a side effect of
    ///   removing something that was never there.
    @discardableResult
    func remove(_ path: String) -> Bool {
        let current = declaredPathList()
        let remaining = current.filter { $0 != path }
        guard remaining.count != current.count else { return false }
        defaults.set(remaining, forKey: Self.devRootsKey)
        return true
    }

    /// Back to the seeds: the key is removed entirely (seeds are a
    /// fallback, never persisted).
    ///
    /// - Returns: whether anything was persisted to remove.
    @discardableResult
    func resetToDefaults() -> Bool {
        guard defaults.object(forKey: Self.devRootsKey) != nil else {
            return false
        }
        defaults.removeObject(forKey: Self.devRootsKey)
        return true
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
    /// 1. **Container-root admission policy** on EVERY root (the shared
    ///    `PathGuard.validateContainerRoot` — ONE definition, epic R16;
    ///    since fn-4.11 it answers from the as-spelled probe, the kernel
    ///    mount table, and — for a symlink leaf — the link's own content,
    ///    never the destination). Rejected roots are EXCLUDED from the
    ///    kept set and carried as frozen `.containerRefused` issues with
    ///    their offending declared path.
    /// 2. **Exact-canonical-duplicate dedupe ONLY** (no keep-ancestor drop,
    ///    D7 — nested real roots remain independent walks). TWO values per
    ///    root: a normalized comparison KEY (canonical path — the leaf a
    ///    real directory, so nothing foreign is resolved) used ONLY for
    ///    duplicate comparison, and the ORIGINAL declared URL preserved
    ///    untouched in the kept set. Only roots proven real directories by
    ///    lstat NO-FOLLOW on the LEAF participate (symlinked ANCESTORS are
    ///    legal — `/var` → `/private/var` — and resolve into the key);
    ///    symlink-LEAF, absent, and non-directory roots are SET ASIDE and
    ///    pass through verbatim — the walk-time per-root gates classify
    ///    them (symlink/non-directory → classified issue; absent → honest
    ///    no-item omission).
    /// 3. **Alias suppression**: a set-aside root whose own link content
    ///    NAMES a kept real-directory root is DROPPED with a classified
    ///    issue instead of passing through (see below) — the one case where
    ///    "set aside" would break the root it aliases rather than merely
    ///    itself.
    ///    THIS LIST ONLY, by construction: dev roots resolve before any
    ///    runtime exists, so a dev root aliasing ANOTHER SCANNER's root
    ///    (`~/Library/Caches`, registered by the orphaned-caches sweep) is
    ///    invisible here. `SpaceScannerRuntime.suppressingAliasShadows`
    ///    re-runs exactly this rule over the FINAL registration union, which
    ///    is the first place every root is known; the two are the same
    ///    doctrine at the two scopes, and neither weakens the walk-time or
    ///    delete-time gates.
    private func resolve(
        declaredRoots: [URL], home: URL, parseIssues: [ScanIssue]
    ) -> DevRootsResolution {
        var issues = parseIssues

        // (1) Policy (alias doctrine): a symlink alias of `/`, of a mounted
        // volume root, or of $HOME is caught here from the link's own
        // CONTENT — the policy probes as spelled and never resolves a
        // symlink leaf's destination (fn-4.11; the canonical check still
        // runs for every non-symlink spelling).
        var admissible: [URL] = []
        for declared in declaredRoots {
            do {
                try PathGuard.validateContainerRoot(
                    declared, home: home, provider: provider
                )
                admissible.append(declared)
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription
                    ?? String(describing: error)
                issues.append(ScanIssue(
                    url: declared,
                    kind: .containerRefused,
                    detail: "configured dev root refused: \(reason)"
                ))
            }
        }

        // Probed ONCE per surviving root, AS SPELLED FIRST (fn-4.11): the
        // no-follow leaf lstat decides directory-ness, and only a spelling
        // PROVEN a real directory is `realpath(3)`'d for its canonical
        // comparison KEY — the resolved leaf then IS the directory the
        // lstat touched, so no symlink destination is ever named. A
        // symlink-leaf spelling contributes what its own CONTENT names
        // instead (`FileSystemIdentityProvider.lexicalAliasTarget` — one
        // `readlink(2)` + string folding, the fn-6 technique), which walks
        // the link's ancestors and reads its data block but never contacts
        // the destination. The previous shape canonicalized EVERY root here
        // — leaf included — so a persisted symlink root aimed at an
        // unresponsive mounted volume blocked runtime construction on the
        // main thread before any window existed. The key is a comparison
        // value ONLY and never reaches the kept set, so the
        // `resolveTargetKeepingLeaf` doctrine is untouched.
        let probed = admissible.map {
            declared -> (declared: URL, key: String?, aliasTarget: String?) in
            switch provider.probeKind(of: declared) {
            case .kind(.directory):
                return (declared, provider.canonicalize(declared).path, nil)
            case .kind(.symlink):
                return (declared, nil, provider.lexicalAliasTarget(of: declared))
            default:
                return (declared, nil, nil)
            }
        }
        // The spellings a REAL-DIRECTORY root already covers — its canonical
        // key and its declared path, each mapped to the covering root's
        // declared path. A set-aside root whose link content NAMES one of
        // these is a redundant ALIAS of it — and an ACTIVELY HARMFUL one:
        // `PathGuard.matchConfiguredRoot` resolves both spellings, returns
        // the FIRST configured root that matches, and `admitContainer`'s
        // no-follow gate then refuses THAT spelling without trying the real
        // root behind it — so an alias declared first makes every item the
        // real root discovered fail to clean with `containerUnavailable`.
        // The comparison is by NAME, never by resolution: a target written
        // through a third spelling matches nothing and the alias passes
        // through verbatim (the recorded fn-4.11 residual, pinned by
        // `testAliasNamingItsTargetThroughAThirdSpellingKeepsBothRoots`).
        var coveredByRealDirectory: [String: String] = [:]
        for root in probed {
            guard let key = root.key else { continue }
            if coveredByRealDirectory[key] == nil {
                coveredByRealDirectory[key] = root.declared.path
            }
            if coveredByRealDirectory[root.declared.path] == nil {
                coveredByRealDirectory[root.declared.path] = root.declared.path
            }
        }

        var kept: [URL] = []
        var seenCanonicalKeys = Set<String>()
        for root in probed {
            // (2) Exact-canonical-duplicate dedupe — real directories only.
            guard let key = root.key else {
                // (3) Alias suppression. Dropping is strictly fail-CLOSED:
                // the alias could never be walked (the walker's lstat root
                // gate refuses it) nor admitted as a container, so it
                // contributes nothing but the shadow. Never a silent drop —
                // the same `.symlinkRoot` kind the walk-time gate would have
                // produced, naming the root that already covers it.
                if let target = root.aliasTarget,
                   let covering = coveredByRealDirectory[target] {
                    issues.append(ScanIssue(
                        url: root.declared,
                        kind: .symlinkRoot,
                        detail: "configured dev root is not a real directory "
                            + "and aliases \(covering), which is configured "
                            + "separately — the alias was dropped"
                    ))
                    continue
                }
                kept.append(root.declared)
                continue
            }
            guard seenCanonicalKeys.insert(key).inserted else {
                continue // exact duplicate of an earlier declared root
            }
            kept.append(root.declared)
        }

        return DevRootsResolution(keptRoots: kept, issues: issues)
    }
}
