/// # PathGuard — Deletion-Target Admission & Containment (D4)
///
/// The single source of truth for "may I delete this URL?". Nothing in the
/// clean path may remove, trash, or hand to a subprocess any path that has not
/// passed through this type. Two admission layers exist:
///
/// 1. **Category-scoped deletion roots** (`admitDeletionRoot`): a URL is
///    admitted ONLY against the requesting category's own
///    `CategoryAdmissionPolicy` — the exact declared roots from all three
///    path-bearing discovery kinds (`.staticPath`, `.absolutePath`, `.probed`
///    fallbacks), or a constrained version drift of a static/probed root in
///    one of two shapes: a one-component SIBLING (same parent, basename
///    matching the declared stem modulo a trailing version suffix:
///    `store/v11` is fine when `v10` was declared) or a pure-version CHILD
///    directly below the declared root (`store/v10` when `store` was
///    declared — probes like `pnpm store path` return the versioned store
///    below the declared fallback, and the child is strictly inside a root
///    already admissible in full). Drift is never a parent grant — the
///    parent of `~/Library/Caches/Homebrew` is the whole cache namespace and
///    the parent of `~/.npm` is `$HOME` itself. `.absolutePath` roots admit
///    exactly, no drift.
/// 2. **Containers** (`admitContainer`): the configured node_modules search
///    roots, and only those. Deliberately split from deletion roots — a
///    search root like `~/Documents` is a valid place to LOOK for
///    node_modules while remaining refused as a deletion target.
///
/// A deny list applies regardless of policy: `/`, any volume root (device-id
/// change against the parent — this also catches the `/System/Volumes/Data`
/// firmlink), `$HOME` in any spelling, and the protected first-level `$HOME`
/// children (`Applications`, `Desktop`, `Documents`, `Downloads`, `Library`,
/// `Movies`, `Music`, `Pictures`, `Public` — dot-directories deliberately
/// unprotected; they are governed by category policy instead).
///
/// Validation modes for things INSIDE an admitted root/container:
/// - `validateContainedChild(_:of:)` — strict descendant of an admitted root,
///   compared as `pathComponents` arrays (never `hasPrefix`: `/a/bc` is not
///   inside `/a/b`). Ancestors of the child resolve; the leaf never does.
/// - `validateRemovableItem(_:inside:)` — strict descendant of an admitted
///   container PLUS the deny-list re-check (including volume-root/mount-point
///   and cross-device refusal, R15).
///
/// All location comparisons go through `FileSystemIdentityProvider` inodes,
/// never strings. Deletion itself always uses the UNRESOLVED URL (the caller's
/// `AdmittedRoot.requestedURL`) so a symlink is removed as a link.

import Foundation

// MARK: - Policy

/// The set of roots one category may delete, derived from its own discovery
/// declarations. Built per category — policies are never shared or unioned.
struct CategoryAdmissionPolicy {

    struct DeclaredRoot {
        /// Declared location (home-relative entries already resolved against
        /// the injectable home).
        let url: URL
        /// Version drift (one-component sibling or pure-version child)
        /// allowed? True for `.staticPath` and `.probed` fallbacks; false
        /// for `.absolutePath` (exact only).
        let allowsSiblingDrift: Bool
    }

    let declaredRoots: [DeclaredRoot]

    init(declaredRoots: [DeclaredRoot]) {
        self.declaredRoots = declaredRoots
    }

    /// Derive a policy from a category's discovery entries. Mirrors
    /// `CacheCategory.resolvedPaths(home:)` path construction — both anchor
    /// to the SAME injected home: `.staticPath` and
    /// non-`/`-prefixed probed fallbacks are home-relative; `.probed` COMMAND
    /// output contributes nothing (probe stdout is untrusted — it must be
    /// admitted against the declared roots like any other candidate).
    init(category: CacheCategory, home: URL) {
        var roots: [DeclaredRoot] = []
        for entry in category.discovery {
            switch entry {
            case .staticPath(let relative):
                roots.append(DeclaredRoot(
                    url: home.appendingPathComponent(relative),
                    allowsSiblingDrift: true
                ))
            case .absolutePath(let absolute):
                roots.append(DeclaredRoot(
                    url: URL(fileURLWithPath: absolute),
                    allowsSiblingDrift: false
                ))
            case .probed(_, _, let fallbacks):
                for fallback in fallbacks {
                    let url = fallback.hasPrefix("/")
                        ? URL(fileURLWithPath: fallback)
                        : home.appendingPathComponent(fallback)
                    roots.append(DeclaredRoot(url: url, allowsSiblingDrift: true))
                }
            }
        }
        self.declaredRoots = roots
    }
}

// MARK: - Admission tokens

/// Proof that a deletion root passed admission. Carries both spellings:
/// `requestedURL` (unresolved — what deletion must use) and `resolvedURL`
/// (canonical — what containment checks compare against).
struct AdmittedRoot {
    let requestedURL: URL
    let resolvedURL: URL
    let matchedDeclaredRoot: URL
    let viaSiblingDrift: Bool
}

/// Proof that a container (node_modules search root) passed admission.
struct AdmittedContainer {
    let requestedURL: URL
    let resolvedURL: URL
}

// MARK: - Errors

enum PathGuardError: Error, Equatable {
    /// The filesystem root `/`.
    case deniedFilesystemRoot(path: String)
    /// A volume root / mount point (device id differs from its parent's).
    case deniedVolumeRoot(path: String)
    /// `$HOME` itself, in any spelling.
    case deniedHomeDirectory(path: String)
    /// A protected first-level `$HOME` child (`~/Documents`, `~/Library`, …).
    case deniedProtectedChild(path: String, name: String)
    /// Not a declared root of the requesting category and not an admissible
    /// version-drift sibling.
    case outsideCategoryPolicy(path: String)
    /// Not one of the configured container search roots.
    case notAConfiguredContainer(path: String)
    /// Child validation: the URL is the root/container itself, not a descendant.
    case isRootItself(path: String)
    /// Child validation: not a strict descendant (includes name-prefix
    /// siblings and symlink-ancestor escapes).
    case notADescendant(path: String, root: String)
    /// Item sits on a different device than its container (R15).
    case crossDevice(path: String, containerPath: String)
}

extension PathGuardError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .deniedFilesystemRoot(let path):
            return "Refusing to touch the filesystem root: \(path)"
        case .deniedVolumeRoot(let path):
            return "Refusing to touch a volume root / mount point: \(path)"
        case .deniedHomeDirectory(let path):
            return "Refusing to touch the home directory: \(path)"
        case .deniedProtectedChild(let path, let name):
            return "Refusing to touch protected folder ~/\(name): \(path)"
        case .outsideCategoryPolicy(let path):
            return "Path is not a declared root of this category: \(path)"
        case .notAConfiguredContainer(let path):
            return "Path is not a configured search root: \(path)"
        case .isRootItself(let path):
            return "Path is the root itself, not a child: \(path)"
        case .notADescendant(let path, let root):
            return "Path is not strictly inside \(root): \(path)"
        case .crossDevice(let path, let containerPath):
            return "Path is on a different volume than its container \(containerPath): \(path)"
        }
    }
}

// MARK: - PathGuard

final class PathGuard {

    /// First-level `$HOME` children refused as deletion targets regardless of
    /// policy. Dot-directories (`~/.npm`, `~/.gradle`, …) are deliberately
    /// absent — they are governed by category policy.
    static let protectedFirstLevelChildren: Set<String> = [
        "Applications", "Desktop", "Documents", "Downloads",
        "Library", "Movies", "Music", "Pictures", "Public",
    ]

    private let provider: FileSystemIdentityProvider
    private let home: URL
    private let resolvedHome: URL
    private let containerRoots: [URL]

    /// - Parameters:
    ///   - home: the home directory admission is anchored to (injectable —
    ///     tests use a fixture home; production passes the real one).
    ///   - containerRoots: configured node_modules search roots for
    ///     `admitContainer`.
    ///   - provider: identity provider (tests may subclass to inject devices).
    init(
        home: URL,
        containerRoots: [URL] = [],
        provider: FileSystemIdentityProvider = FileSystemIdentityProvider()
    ) {
        self.provider = provider
        self.home = home
        self.resolvedHome = provider.canonicalize(home)
        self.containerRoots = containerRoots
    }

    // MARK: Deletion-root admission

    /// Admit `url` as a deletion root for the category described by `policy`.
    /// The URL is judged by its fully-resolved location (a symlink root is
    /// admitted or refused based on where it really points), but the returned
    /// token retains the unresolved `requestedURL` for the actual deletion.
    func admitDeletionRoot(
        _ url: URL, policy: CategoryAdmissionPolicy
    ) throws -> AdmittedRoot {
        let resolved = provider.canonicalize(url)
        try denyCheck(resolved)

        for declared in policy.declaredRoots {
            let declaredResolved = provider.canonicalize(declared.url)
            if provider.sameLocation(resolved, declaredResolved) {
                return AdmittedRoot(
                    requestedURL: url,
                    resolvedURL: resolved,
                    matchedDeclaredRoot: declared.url,
                    viaSiblingDrift: false
                )
            }
            if declared.allowsSiblingDrift,
               isVersionDrift(resolved, ofDeclared: declaredResolved) {
                return AdmittedRoot(
                    requestedURL: url,
                    resolvedURL: resolved,
                    matchedDeclaredRoot: declared.url,
                    viaSiblingDrift: true
                )
            }
        }
        throw PathGuardError.outsideCategoryPolicy(path: resolved.path)
    }

    // MARK: Container admission

    /// Admit `url` as a container: it must be one of the configured search
    /// roots (by inode identity). Containers are places to LOOK, not to
    /// delete — items inside them go through `validateRemovableItem`, which
    /// re-applies the deny list. This is why `~/Documents` can be a container
    /// while `admitDeletionRoot` refuses it.
    func admitContainer(_ url: URL) throws -> AdmittedContainer {
        let resolved = provider.canonicalize(url)
        for root in containerRoots {
            if provider.sameLocation(resolved, provider.canonicalize(root)) {
                return AdmittedContainer(requestedURL: url, resolvedURL: resolved)
            }
        }
        throw PathGuardError.notAConfiguredContainer(path: resolved.path)
    }

    // MARK: Containment validation

    /// `child` must be a STRICT descendant of the admitted root. Ancestors of
    /// the child are resolved (a symlink ancestor that escapes the root makes
    /// the check fail); the leaf itself never is — a symlink child stays a
    /// link, and a non-existent leaf still validates (already-gone children
    /// are the caller's skip case). Comparison is by `pathComponents` arrays,
    /// never `hasPrefix`.
    func validateContainedChild(_ child: URL, of root: AdmittedRoot) throws {
        try requireStrictDescendant(child, of: root.resolvedURL)
    }

    /// `item` must be a strict descendant of the admitted container AND
    /// survive the deny-list re-check (volume roots / mount points included)
    /// AND sit on the container's device (R15 mount rule).
    func validateRemovableItem(
        _ item: URL, inside container: AdmittedContainer
    ) throws {
        let resolved = try requireStrictDescendant(item, of: container.resolvedURL)
        try denyCheck(resolved)
        if let itemDevice = provider.deviceID(of: resolved),
           let containerDevice = provider.deviceID(of: container.resolvedURL),
           itemDevice != containerDevice {
            throw PathGuardError.crossDevice(
                path: resolved.path, containerPath: container.resolvedURL.path
            )
        }
    }

    // MARK: - Deny list

    /// Refusals that apply regardless of any policy. `resolved` must already
    /// be canonical (root- or target-resolved by the caller).
    private func denyCheck(_ resolved: URL) throws {
        let components = resolved.pathComponents
        if components == ["/"] || components.isEmpty {
            throw PathGuardError.deniedFilesystemRoot(path: resolved.path)
        }

        // Volume root / mount point, two complementary signals:
        // (a) device-id change against the parent (also catches injected test
        //     devices and foreign volumes), and
        // (b) statfs mount-root detection — required because a unified APFS
        //     volume group presents ONE st_dev across the system/Data pair,
        //     so the /System/Volumes/Data firmlink mount is invisible to (a).
        // Identity is lstat-based, so a symlink LEAF pointing at a volume
        // root keeps the link's own device and passes — deleting it only
        // removes the link (statfs would follow the link, but its path never
        // equals the mount's f_mntonname).
        let parent = resolved.deletingLastPathComponent()
        if let device = provider.deviceID(of: resolved),
           let parentDevice = provider.deviceID(of: parent),
           device != parentDevice {
            throw PathGuardError.deniedVolumeRoot(path: resolved.path)
        }
        if provider.isMountPoint(resolved) {
            throw PathGuardError.deniedVolumeRoot(path: resolved.path)
        }

        // $HOME in any spelling: inode identity collapses direct, symlink-
        // alias, case-variant, and NFC/NFD spellings onto one object.
        if provider.sameLocation(resolved, resolvedHome) {
            throw PathGuardError.deniedHomeDirectory(path: resolved.path)
        }

        // Protected first-level children. Inode identity when the child
        // exists; canonical-components fallback (inside sameLocation) covers
        // protected names that do not exist in this home.
        for name in Self.protectedFirstLevelChildren {
            let protectedChild = resolvedHome.appendingPathComponent(name)
            if provider.sameLocation(resolved, protectedChild) {
                throw PathGuardError.deniedProtectedChild(
                    path: resolved.path, name: name
                )
            }
        }
    }

    // MARK: - Descendant check

    /// Target-resolve `url` (ancestors only; leaf untouched) and require its
    /// components to strictly extend `root`'s components.
    @discardableResult
    private func requireStrictDescendant(
        _ url: URL, of root: URL
    ) throws -> URL {
        let resolved = provider.resolveTargetKeepingLeaf(url)
        let childComponents = resolved.pathComponents
        let rootComponents = root.pathComponents

        if childComponents == rootComponents {
            throw PathGuardError.isRootItself(path: resolved.path)
        }
        guard childComponents.count > rootComponents.count,
              Array(childComponents.prefix(rootComponents.count)) == rootComponents
        else {
            throw PathGuardError.notADescendant(
                path: resolved.path, root: root.path
            )
        }
        return resolved
    }

    // MARK: - Version drift rule

    /// Constrained one-component version drift, two shapes:
    ///
    /// - **Sibling**: same parent (by inode identity) and same basename STEM
    ///   after stripping a trailing version suffix from each side.
    ///   `store/v11` matches declared `store/v10` (both stems empty, same
    ///   parent); `~/.ssh` never matches `~/.npm` (stems differ); DerivedData
    ///   never matches an npm root (parents differ).
    /// - **Version child**: the candidate's parent IS the declared root and
    ///   the candidate's basename is purely a version (`v10`, `3.1` — stem
    ///   empty after stripping). Probes return this shape: `pnpm store path`
    ///   yields `…/pnpm/store/v10` while the declared fallback is
    ///   `…/pnpm/store`. The child is strictly inside a root already
    ///   admissible in full, so this grants nothing new; named children
    ///   (`store/files`) and deeper descendants stay refused.
    private func isVersionDrift(
        _ candidate: URL, ofDeclared declared: URL
    ) -> Bool {
        guard candidate.pathComponents.count > 1,
              declared.pathComponents.count > 1 else { return false }
        let candidateParent = candidate.deletingLastPathComponent()

        // Version child: parent is the declared root itself, basename is
        // purely a version suffix.
        if provider.sameLocation(candidateParent, declared) {
            return Self.versionStem(of: candidate.lastPathComponent).isEmpty
        }

        // Sibling: same parent as the declared root, same stem.
        let declaredParent = declared.deletingLastPathComponent()
        guard provider.sameLocation(candidateParent, declaredParent) else {
            return false
        }
        return Self.versionStem(of: candidate.lastPathComponent)
            == Self.versionStem(of: declared.lastPathComponent)
    }

    /// Strip one trailing version suffix: optional `-`/`_`/`.` separator,
    /// optional `v`/`V`, then digits (dotted groups allowed).
    /// `"v10"` → `""`, `"store-2"` → `"store"`, `"cache_v3.1"` → `"cache"`,
    /// `".npm"` → `".npm"` (no digits — untouched).
    static func versionStem(of name: String) -> String {
        var s = name[...]
        var strippedDigits = false

        while let last = s.last, last.isASCII, last.isNumber {
            while let l = s.last, l.isASCII, l.isNumber {
                s = s.dropLast()
            }
            strippedDigits = true
            // Continue through dotted version groups ("3.1" after "cache_v").
            if s.last == ".", let beforeDot = s.dropLast().last,
               beforeDot.isASCII, beforeDot.isNumber {
                s = s.dropLast()
            } else {
                break
            }
        }
        guard strippedDigits else { return name }

        if s.last == "v" || s.last == "V" {
            s = s.dropLast()
        }
        if let l = s.last, l == "-" || l == "_" || l == "." {
            s = s.dropLast()
        }
        return String(s)
    }
}
