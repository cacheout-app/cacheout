/// # DirectorySizer — The One Shared Sizing Routine (D2/D3/D7/D8)
///
/// Replaces the two divergent `directorySize` implementations that previously
/// lived in `CacheScanner` and `NodeModulesScanner` (D7). Every byte the app
/// reports — scan rows, node_modules items, and (fn-1.3) delete-time
/// measurement — comes from this walk.
///
/// ## Rules the walk enforces (measured, not folklore)
///
/// - **No `.skipsPackageDescendants`** (D2): `totalFileAllocatedSize` is nil on
///   directories, so a bundle yielded as a single entry contributes 0 bytes —
///   a measured 17%/550MB undercount on real cache trees.
/// - **No `.skipsHiddenFiles`** (D3): pnpm puts ~all node_modules bytes under
///   `.pnpm`; hidden trees (`.claude/worktrees`, 23G field case) vanish
///   entirely under the old options.
/// - **Always the 4-arg enumerator** with an `errorHandler` (D6): the 3-arg
///   form silently skips unreadable subtrees. Every enumerator error and every
///   per-item metadata failure is classified (EPERM → TCC, EACCES → BSD
///   permissions, via the `NSUnderlyingErrorKey` chain on Cocoa 257) and
///   recorded as a `SizeDenial` — never `catch { continue }`.
/// - **Symlinks are 0 bytes and never descended.** The Foundation enumerator
///   never follows symlinked directories, and this type never resolves an
///   enumerated entry.
/// - **Directory inode blocks are not counted** — only regular files carry
///   bytes.
/// - **Mount boundaries are not crossed** (R15): a directory is a boundary
///   when its device id differs from the walk root's OR the provider's
///   `statfs`-based `isMountPoint(_:)` says so. BOTH signals are required —
///   a unified APFS volume group presents ONE `st_dev` across `/` and
///   `/System/Volumes/Data`, so device comparison alone is blind to the Data
///   firmlink. Boundaries are recorded and their subtrees skipped, uncounted.
/// - **Hardlink honesty** (D8 mitigation): a regular file with `st_nlink > 1`
///   is counted once per walk (within-walk inode dedupe) and its bytes land in
///   `estimatedUpToBytes`, never `exactAllocatedBytes` — deleting one link of
///   a multi-link inode frees nothing while the other links survive.
///
/// ## Claims (the delete-time accounting currency, R8)
///
/// EVERY measured regular-file inode emits exactly one `InodeClaim` — including
/// newly-encountered `st_nlink == 1` files and inodes already present in
/// `knownInodes`. Acceptance (fn-1.3) transfers ONLY claimed bytes, so an
/// unclaimed unique file would report zero freed bytes after its own
/// successful deletion, and a failed sibling's bytes could never be transferred
/// by the child that eventually succeeds. Known inodes contribute ZERO to the
/// local byte components but still claim their canonical value. The sizer
/// never mutates shared state; `knownInodes` is a read-only view.
///
/// ## Modes
///
/// - `.scanRoot`: the root is fully resolved via the provider (symlink roots
///   are walked at their real location — admission already judged that
///   location), then enumerated. Scan-time, post-admission.
/// - `.deletionTarget`: the leaf is `lstat`ed FIRST and dispatched explicitly:
///   symlink → 0 bytes, never walked (deleting it removes the link only);
///   regular file → its own allocated size; directory → enumerated;
///   fifo/socket/device → 0 bytes plus a recorded skip.

import Foundation

// MARK: - Report types

/// A recorded refusal or failure encountered during a walk. "Denied" is a
/// first-class visible state (D6) — TCC denials read as silently-tiny numbers
/// otherwise (a real `du` on `~/Pictures` returned 8.0K for a multi-GB tree).
struct SizeDenial: Equatable {
    enum Kind: Equatable {
        /// EPERM(1) under the Cocoa error — macOS TCC (privacy) denial.
        case tcc
        /// EACCES(13) — classic BSD permission denial.
        case permission
        /// Metadata unavailable (lstat/resourceValues failed mid-walk).
        case metadata
        /// Anything else — recorded, never swallowed.
        case other
    }

    let url: URL
    let kind: Kind
    let detail: String
}

/// One measured regular-file inode, returned as data for the delete-time
/// claim-based accounting registry (fn-1.3). `canonicalByteSize` is the
/// allocated size observed at measurement time — retained canonically because
/// deleting a link DECREMENTS the survivors' `st_nlink`, so later observations
/// cannot be trusted for classification or size.
struct InodeClaim: Equatable {
    let identity: FileSystemIdentityProvider.Identity
    let canonicalByteSize: Int64
    let observedHardlinked: Bool
}

/// The result of one measurement walk. Byte components are SPLIT (R16):
/// `exactAllocatedBytes` holds bytes whose deletion verifiably frees them
/// (`st_nlink == 1`); `estimatedUpToBytes` holds hardlinked bytes that MAY be
/// freed ("up to") depending on surviving links elsewhere.
struct SizeReport {
    var exactAllocatedBytes: Int64 = 0
    var estimatedUpToBytes: Int64 = 0
    /// Logical (apparent) bytes — sparse files diverge hugely (57.1G logical
    /// vs 31G allocated on a real Rust target dir). Secondary figure only.
    var logicalBytes: Int64 = 0
    /// Regular-file directory entries encountered (links, not inodes).
    var itemCount: Int = 0
    var denials: [SizeDenial] = []
    /// Directories recorded as mount boundaries; their subtrees are uncounted.
    var mountBoundaries: [URL] = []
    /// Non-regular, non-directory, non-symlink entries (fifos, sockets, …)
    /// recorded as skips.
    var skippedSpecialFiles: [URL] = []
    /// One claim per measured regular-file inode — see the type doc.
    var claims: [InodeClaim] = []

    /// The two byte components summed — what a scan row displays today.
    var measuredBytes: Int64 { exactAllocatedBytes + estimatedUpToBytes }
}

// MARK: - DirectorySizer

struct DirectorySizer {

    /// How the URL handed to `measure` is interpreted — see the file header.
    enum Mode {
        case scanRoot
        case deletionTarget
    }

    private let provider: FileSystemIdentityProvider
    private let fileManager = FileManager.default

    init(provider: FileSystemIdentityProvider = FileSystemIdentityProvider()) {
        self.provider = provider
    }

    /// Measure the tree (or leaf) at `url`. Pure function: never mutates
    /// shared state — `knownInodes` is a read-only view whose members
    /// contribute zero local bytes while still emitting claims.
    func measure(
        at url: URL,
        mode: Mode,
        knownInodes: Set<FileSystemIdentityProvider.Identity> = []
    ) -> SizeReport {
        switch mode {
        case .scanRoot:
            // Root resolution: a symlink root is walked at its real location
            // (admission already judged that location). A DANGLING symlink
            // keeps its leaf unresolved and dispatches to .symlink → 0.
            let root = provider.canonicalize(url)
            return dispatch(root, knownInodes: knownInodes)

        case .deletionTarget:
            // Target resolution: ancestors resolve, the leaf NEVER does — a
            // symlink deletion target keeps the link's own identity.
            let target = provider.resolveTargetKeepingLeaf(url)
            return dispatch(target, knownInodes: knownInodes)
        }
    }

    /// Explicit leaf dispatch, shared by both modes (the modes differ only in
    /// how the root URL was resolved above).
    private func dispatch(
        _ resolved: URL,
        knownInodes: Set<FileSystemIdentityProvider.Identity>
    ) -> SizeReport {
        var report = SizeReport()
        switch provider.kind(of: resolved) {
        case .none:
            // Absent: 0 bytes, no denials — ENOENT on a deletion child means
            // "already gone" (the caller's skip case); a missing scan root is
            // the scanner's `.missing`/`.empty` derivation input.
            break
        case .symlink:
            // 0 bytes, NEVER walked: deleting a symlink removes the link only.
            break
        case .regularFile:
            var claimed = Set<FileSystemIdentityProvider.Identity>()
            recordRegularFile(
                resolved, knownInodes: knownInodes,
                claimedInodes: &claimed, report: &report
            )
        case .directory:
            report = enumerateTree(at: resolved, knownInodes: knownInodes)
        case .other:
            report.skippedSpecialFiles.append(resolved)
        }
        return report
    }

    // MARK: - Enumeration

    /// Prefetched during enumeration to avoid a second stat per entry.
    private static let prefetchKeys: [URLResourceKey] = [
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
        .totalFileSizeKey, .isRegularFileKey,
    ]

    private func enumerateTree(
        at root: URL,
        knownInodes: Set<FileSystemIdentityProvider.Identity>
    ) -> SizeReport {
        var report = SizeReport()
        var claimedInodes = Set<FileSystemIdentityProvider.Identity>()
        // The errorHandler escapes into the enumerator, so it appends to a
        // captured box rather than the inout-hostile `report`.
        var handlerDenials: [SizeDenial] = []

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Self.prefetchKeys,
            options: [],  // deliberately NOT .skipsHiddenFiles / .skipsPackageDescendants (D2/D3)
            errorHandler: { url, error in
                handlerDenials.append(Self.classifyDenial(error, at: url))
                return true  // record and continue — never a silent partial walk
            }
        ) else {
            // The 4-arg form practically never returns nil, but nil must not
            // read as "0 bytes found" (D6).
            report.denials.append(SizeDenial(
                url: root, kind: .other, detail: "enumerator unavailable"
            ))
            return report
        }

        let rootDevice = provider.deviceID(of: root)

        while let next = enumerator.nextObject() {
            guard let itemURL = next as? URL else { continue }
            guard let kind = provider.kind(of: itemURL) else {
                report.denials.append(SizeDenial(
                    url: itemURL, kind: .metadata,
                    detail: "lstat failed mid-walk"
                ))
                continue
            }

            switch kind {
            case .regularFile:
                recordRegularFile(
                    itemURL, knownInodes: knownInodes,
                    claimedInodes: &claimedInodes, report: &report
                )

            case .directory:
                // Foreign-device subtrees are recorded, skipped, uncounted.
                // BOTH signals (see header): device-id change against the
                // walk root, and the statfs mount-root check that catches
                // same-st_dev firmlink mounts.
                let device = provider.deviceID(of: itemURL)
                if (rootDevice != nil && device != nil && device != rootDevice)
                    || provider.isMountPoint(itemURL) {
                    report.mountBoundaries.append(itemURL)
                    enumerator.skipDescendants()
                }
                // Directory inode blocks deliberately not counted.

            case .symlink:
                // 0 bytes; never resolved, never descended.
                break

            case .other:
                report.skippedSpecialFiles.append(itemURL)
            }
        }

        report.denials.append(contentsOf: handlerDenials)
        return report
    }

    /// Measure one regular file: bytes into the correct split component,
    /// exactly one claim per inode, within-walk hardlink dedupe, known-inode
    /// bytes locally excluded.
    private func recordRegularFile(
        _ url: URL,
        knownInodes: Set<FileSystemIdentityProvider.Identity>,
        claimedInodes: inout Set<FileSystemIdentityProvider.Identity>,
        report: inout SizeReport
    ) {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [
                .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
                .totalFileSizeKey,
            ])
        } catch {
            report.denials.append(Self.classifyDenial(error, at: url))
            return
        }
        guard let identity = provider.identity(of: url),
              let linkCount = provider.linkCount(of: url) else {
            report.denials.append(SizeDenial(
                url: url, kind: .metadata, detail: "lstat failed mid-walk"
            ))
            return
        }

        // totalFileAllocatedSize accounts for sparse files (allocated blocks,
        // the number that predicts freed disk space); fileAllocatedSize is the
        // documented fallback.
        let allocated = Int64(
            values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0
        )
        let logical = Int64(values.totalFileSize ?? 0)

        report.itemCount += 1

        // Within-walk hardlink dedupe: a second link to an already-claimed
        // inode is a directory entry (itemCount above) but contributes no
        // bytes and no duplicate claim.
        guard claimedInodes.insert(identity).inserted else { return }

        let hardlinked = linkCount > 1
        // EVERY measured inode claims — including unique files and known
        // inodes (R8/r9: acceptance transfers only claimed bytes).
        report.claims.append(InodeClaim(
            identity: identity,
            canonicalByteSize: allocated,
            observedHardlinked: hardlinked
        ))

        // Known inodes: claim only, zero local components — this walk's
        // caller must not double-count bytes another walk already carries.
        guard !knownInodes.contains(identity) else { return }

        if hardlinked {
            report.estimatedUpToBytes += allocated
        } else {
            report.exactAllocatedBytes += allocated
        }
        report.logicalBytes += logical
    }

    // MARK: - Denial classification

    /// Classify a walk error by its POSIX root cause: EPERM(1) is TCC, EACCES
    /// (13) is BSD permissions — surfaced via the `NSUnderlyingErrorKey` chain
    /// on Cocoa 257 (`NSFileReadNoPermissionError`).
    static func classifyDenial(_ error: Error, at url: URL) -> SizeDenial {
        let nsError = error as NSError

        var posixCode: Int?
        var cursor: NSError? = nsError
        var hops = 0
        while let current = cursor, hops < 8 {
            if current.domain == NSPOSIXErrorDomain {
                posixCode = current.code
                break
            }
            cursor = current.userInfo[NSUnderlyingErrorKey] as? NSError
            hops += 1
        }

        let kind: SizeDenial.Kind
        switch posixCode {
        case .some(Int(EPERM)):
            kind = .tcc
        case .some(Int(EACCES)):
            kind = .permission
        default:
            // A bare Cocoa "read no permission" without a POSIX underlying
            // error is still a permission denial, not "other".
            if nsError.domain == NSCocoaErrorDomain,
               nsError.code == CocoaError.fileReadNoPermission.rawValue {
                kind = .permission
            } else {
                kind = .other
            }
        }
        return SizeDenial(url: url, kind: kind, detail: nsError.localizedDescription)
    }
}

// MARK: - Scan-error mapping

extension SizeDenial.Kind {
    /// The `ScanError` classification a scanner derives from this denial.
    var scanErrorKind: ScanError.Kind {
        switch self {
        case .tcc: return .tccDenied
        case .permission: return .permissionDenied
        case .metadata, .other: return .other
        }
    }
}
