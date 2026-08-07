/// # NodeModulesScanner — Recursive node_modules Finder
///
/// An `actor` that recursively searches configured developer project
/// directories for `node_modules` folders. Designed to find abandoned or
/// stale dependencies that consume significant disk space.
///
/// ## Safety model (fn-1.2, R19)
///
/// This scanner's recursion is MANUAL — it is not the Foundation enumerator
/// and gets none of the enumerator's symlink guarantees. Three lstat gates
/// close the escape vectors:
///
/// 1. **Search roots** are admitted through `PathGuard.admitContainer(_:)`
///    (configured containers only) AND must themselves be real directories —
///    a symlink search root is never traversed.
/// 2. **Every manual descent** re-checks `provider.kind(of:) == .directory`
///    (lstat, no-follow) — a nested symlink to an external tree is never
///    followed.
/// 3. **Every `node_modules` CANDIDATE** is lstat-checked before it is sized
///    or returned — a symlink candidate handed to the sizer's `.scanRoot`
///    mode would enumerate its external target, so it is never sized and
///    never returned.
///
/// ## Search Strategy
///
/// 1. Scans the search roots in parallel using `TaskGroup`.
/// 2. Recursively descends into subdirectories up to `maxDepth` (default: 6).
///    Hidden directories ARE traversed (D3 — a 23G `.claude/worktrees` field
///    case was invisible purely because the dir is hidden); the skip list and
///    depth bound keep the walk tame.
/// 3. When a real `node_modules` directory is found, it is sized via the
///    shared `DirectorySizer` (hidden files included — pnpm keeps ~all bytes
///    under `.pnpm`) and recorded **without recursing further**.
/// 4. Skips noise directories (`.git`, `.build`, `DerivedData`, etc.).
///
/// ## Outcome
///
/// `scan` returns a `NodeModulesScanOutcome`: discovered items (each carrying
/// its origin-container provenance, R14) plus classified non-fatal errors —
/// a denied `node_modules` root or an unreadable subtree is a visible,
/// classified issue (D6), never a silent skip.
///
/// ## Deduplication
///
/// Results are deduplicated by absolute path (using `Set<String>` insertion)
/// to handle overlapping search roots, then sorted by size descending.

import Foundation

// MARK: - Outcome types

/// A classified, non-fatal problem encountered during a node_modules scan.
struct NodeModulesScanIssue: Equatable {
    enum Kind: Equatable {
        /// `PathGuard.admitContainer` refused the search root — not one of
        /// the configured containers; never traversed.
        case containerRefused
        /// The search root is a symlink (or otherwise not a real directory)
        /// — never traversed.
        case symlinkRoot
        /// macOS TCC (privacy) denial — EPERM under the Cocoa error.
        case tccDenied
        /// BSD permission denial — EACCES.
        case permissionDenied
        /// Enumeration or metadata failure that is not a permission problem.
        case unreadable
    }

    let url: URL
    let kind: Kind
    let detail: String
}

/// What a node_modules scan produced: items plus classified errors.
struct NodeModulesScanOutcome {
    var items: [NodeModulesItem]
    var errors: [NodeModulesScanIssue]
}

// MARK: - Scanner

actor NodeModulesScanner {
    private let fileManager = FileManager.default
    private let searchRoots: [URL]
    private let provider: FileSystemIdentityProvider
    private let pathGuard: PathGuard

    /// Common directories where developers keep projects
    private static let searchRootNames: [String] = [
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

    /// Directories to skip during recursive search
    private static let skipDirs: Set<String> = [
        ".Trash", ".git", ".hg", "node_modules", ".build",
        "DerivedData", "Pods", ".next", "dist", "build",
        "Library", ".cache", ".npm", ".yarn",
    ]

    /// Search-root folder names macOS gates behind a TCC consent prompt.
    /// Enumerating one of these from a fresh install is what fires the
    /// "Cacheout would like to access your Documents folder" dialog — so
    /// they are walked only on user-initiated scans (fn-1.4, R9). Matched
    /// by basename so injected fixture roots behave identically.
    static let tccProtectedRootNames: Set<String> = [
        "Documents", "Desktop", "Downloads",
    ]

    /// The default container roots for `home` — the single source
    /// `CacheCleaner` shares so delete-time `admitContainer` accepts exactly
    /// the roots discovery used (fn-1.3).
    static func defaultSearchRoots(home: URL) -> [URL] {
        searchRootNames.map { home.appendingPathComponent($0) }
    }

    /// - Parameters:
    ///   - home: home the default search roots resolve against (injectable).
    ///   - searchRoots: explicit container roots (tests); nil uses the
    ///     default home-relative list.
    ///   - provider: identity provider shared with `PathGuard` and the sizer.
    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        searchRoots: [URL]? = nil,
        provider: FileSystemIdentityProvider = FileSystemIdentityProvider()
    ) {
        let roots = searchRoots ?? Self.defaultSearchRoots(home: home)
        self.searchRoots = roots
        self.provider = provider
        self.pathGuard = PathGuard(
            home: home, containerRoots: roots, provider: provider
        )
    }

    /// - Parameters:
    ///   - maxDepth: recursion bound below each search root.
    ///   - includeProtectedRoots: when false (automatic/background scans),
    ///     TCC-prompting roots (`tccProtectedRootNames`) are skipped
    ///     entirely — deliberately silent, a policy skip is not a scan
    ///     problem (R9). User-initiated scans pass true.
    func scan(
        maxDepth: Int = 6,
        includeProtectedRoots: Bool = true
    ) async -> NodeModulesScanOutcome {
        var allItems: [NodeModulesItem] = []
        var allIssues: [NodeModulesScanIssue] = []

        let currentFileManager = self.fileManager
        let provider = self.provider
        let sizer = DirectorySizer(provider: provider)

        // Scan each admitted search root in parallel
        await withTaskGroup(of: NodeModulesScanOutcome.self) { group in
            for root in searchRoots {
                // TCC gating (R9): a background rescan must never be the
                // thing that fires a macOS privacy prompt.
                if !includeProtectedRoots,
                   Self.tccProtectedRootNames.contains(root.lastPathComponent) {
                    continue
                }
                guard currentFileManager.fileExists(atPath: root.path) else { continue }

                // Container admission BEFORE any traversal (R19).
                do {
                    _ = try pathGuard.admitContainer(root)
                } catch {
                    allIssues.append(NodeModulesScanIssue(
                        url: root, kind: .containerRefused,
                        detail: error.localizedDescription
                    ))
                    continue
                }

                // lstat gate: an escaping-symlink search root is NEVER
                // traversed — its real target may sit anywhere. A root we
                // cannot even lstat is a classified, visible failure (D6).
                switch provider.probeKind(of: root) {
                case .kind(.directory):
                    break
                case .failed(let code):
                    allIssues.append(Self.issue(forFailedProbe: root, errno: code))
                    continue
                case .kind, .absent:
                    allIssues.append(NodeModulesScanIssue(
                        url: root, kind: .symlinkRoot,
                        detail: "search root is not a real directory"
                    ))
                    continue
                }

                group.addTask {
                    await Self.findNodeModules(
                        in: root,
                        originContainer: root,
                        fileManager: currentFileManager,
                        provider: provider,
                        sizer: sizer,
                        skipDirs: Self.skipDirs,
                        maxDepth: maxDepth
                    )
                }
            }
            for await outcome in group {
                allItems.append(contentsOf: outcome.items)
                allIssues.append(contentsOf: outcome.errors)
            }
        }

        // Deduplicate by path and sort by size
        var seen = Set<String>()
        let items = allItems
            .filter { seen.insert($0.nodeModulesPath.path).inserted }
            .sorted { $0.sizeBytes > $1.sizeBytes }
        return NodeModulesScanOutcome(items: items, errors: allIssues)
    }

    private static func findNodeModules(
        in directory: URL,
        originContainer: URL,
        fileManager: FileManager,
        provider: FileSystemIdentityProvider,
        sizer: DirectorySizer,
        skipDirs: Set<String>,
        maxDepth: Int,
        currentDepth: Int = 0
    ) async -> NodeModulesScanOutcome {
        var outcome = NodeModulesScanOutcome(items: [], errors: [])
        guard currentDepth < maxDepth else { return outcome }

        let candidate = directory.appendingPathComponent("node_modules")

        // Candidate gate (lstat, no-follow): only a REAL directory is a find.
        // A symlink candidate is never sized and never returned — `.scanRoot`
        // resolves roots by design, so an unchecked symlink would enumerate
        // its external target. `.absent` is the normal "no node_modules here"
        // case and stays silent; a FAILED probe is a classified, recorded
        // issue, never a silent "not found" (D6/R14).
        let candidateProbe = provider.probeKind(of: candidate)
        if case .failed(let code) = candidateProbe {
            outcome.errors.append(Self.issue(forFailedProbe: candidate, errno: code))
        }
        if candidateProbe == .kind(.directory) {
            let report = sizer.measure(at: candidate, mode: .scanRoot)

            // A denied node_modules root (or partially denied tree) is a
            // classified, visible outcome error (R14/D6).
            for denial in report.denials {
                outcome.errors.append(Self.issue(from: denial))
            }

            let size = report.measuredBytes
            if size > 0 {
                let modified = (try? candidate.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ))?.contentModificationDate
                outcome.items.append(NodeModulesItem(
                    projectName: directory.lastPathComponent,
                    projectPath: directory,
                    nodeModulesPath: candidate,
                    sizeBytes: size,
                    lastModified: modified,
                    originContainer: originContainer
                ))
            }
            // Don't recurse into projects that have node_modules — they won't
            // have nested projects.
            return outcome
        }

        // Recurse into subdirectories. Hidden directories are deliberately
        // NOT skipped (D3); the skip list and maxDepth bound the walk.
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )
        } catch {
            // Real capture, never a silent skip (D6).
            outcome.errors.append(
                Self.issue(from: DirectorySizer.classifyDenial(error, at: directory))
            )
            return outcome
        }

        for item in contents {
            let name = item.lastPathComponent
            guard !skipDirs.contains(name) else { continue }
            // lstat gate before EVERY manual descent: a symlinked directory
            // is never followed. A listed entry whose metadata cannot be read
            // is a classified, recorded issue (D6); `.absent` is a benign
            // mid-scan deletion race.
            switch provider.probeKind(of: item) {
            case .kind(.directory):
                break
            case .failed(let code):
                outcome.errors.append(Self.issue(forFailedProbe: item, errno: code))
                continue
            case .kind, .absent:
                continue
            }
            let sub = await findNodeModules(
                in: item,
                originContainer: originContainer,
                fileManager: fileManager,
                provider: provider,
                sizer: sizer,
                skipDirs: skipDirs,
                maxDepth: maxDepth,
                currentDepth: currentDepth + 1
            )
            outcome.items.append(contentsOf: sub.items)
            outcome.errors.append(contentsOf: sub.errors)
        }

        return outcome
    }

    private static func issue(from denial: SizeDenial) -> NodeModulesScanIssue {
        let kind: NodeModulesScanIssue.Kind
        switch denial.kind {
        case .tcc: kind = .tccDenied
        case .permission: kind = .permissionDenied
        case .metadata, .other: kind = .unreadable
        }
        return NodeModulesScanIssue(
            url: denial.url, kind: kind, detail: denial.detail
        )
    }

    /// Classify a failed `lstat` probe by errno (EPERM → TCC, EACCES → BSD
    /// permissions) — same taxonomy as the sizer's denial classification.
    private static func issue(
        forFailedProbe url: URL, errno code: Int32
    ) -> NodeModulesScanIssue {
        issue(from: DirectorySizer.denial(forFailedProbe: url, errno: code))
    }
}
