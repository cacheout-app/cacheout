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
///
/// ## RESIDUAL: this walk is still PATH-BASED (PR #457 review r6)
///
/// Unlike `ProjectTreeWalker` and `ValuablesDetector`, this type has not been
/// converted to the descriptor-anchored doctrine ("below a walk root, no
/// filesystem operation takes a path"): `FileManager.enumerator` yields
/// resolved child URLs and every per-entry check here re-`lstat`s one. An
/// attacker who can replace an ANCESTOR of the measured root between the
/// caller's own checks and this walk therefore redirects the MEASUREMENT.
///
/// What that buys, stated precisely so nobody has to re-derive it: BYTES,
/// DATES, and DENIAL CLASSIFICATIONS — the figures an item displays. It buys
/// NO acknowledgement token (`ValuablesDetector`'s descriptor-anchored probe
/// is that token's only preimage), NO deletion authorization, and NO change of
/// deletion target (the target is the caller's unresolved spelling, re-admitted
/// by `PathGuard` and re-proven by the item's pre-delete revalidator at delete
/// time). A boundary HIDDEN from this walk is likewise re-checked by the
/// cleaner, which refuses any tree containing one whole.
///
/// Converting it is a larger change than the security value justifies right
/// now: this is the shared sizer for every scanner and for delete-time
/// claim-based accounting, and a rewrite must reproduce
/// `totalFileAllocatedSize` sparse semantics, hardlink claims, and Cocoa error
/// classification exactly. Tracked separately, deliberately not smuggled into
/// a security fix.

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
        /// ENAMETOOLONG(63)/ELOOP(62): this walk composes an ABSOLUTE PATH per
        /// entry, and something about that path defeats resolution — either
        /// its LENGTH or its SYMLINKS. ONE KIND, TWO CAUSES, and the two are
        /// distinguished in the `detail` rather than folded into a single
        /// sentence about `PATH_MAX` (PR #458 review r11): the remedy class is
        /// genuinely shared — restructure the path, which no re-scan does —
        /// but the sentence a user acts on is not, and only the LENGTH cause
        /// may promise that deletion still works. See `classifyDenial`.
        ///
        /// ITS OWN KIND BECAUSE THE MESSAGE WAS A LIE (PR #458 review). The
        /// Cocoa error Foundation raises here reads "The item couldn't be
        /// opened because the file name "d" is invalid" — measured, on a
        /// chain of perfectly valid single-letter names whose only sin is
        /// being 446 levels down. Folded into `.other`, that sentence was
        /// what the sweep showed a user as the reason their cache could not
        /// be measured, and it names a cause that does not exist: no rename
        /// of "d" would ever help. The remedy that would — restructuring or
        /// shortening the tree — is only sayable once the class is
        /// distinguished. What it is NOT any more is a reason the item
        /// cannot be DELETED: `DepthSafeRemoval` addresses this tree.
        case unaddressablePath
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
    /// EVERY directory entry this walk enumerated — files, directories,
    /// symlinks, specials, and entries that raced away mid-walk — excluding
    /// the root itself. `itemCount` counts regular files ONLY, so it is not
    /// a census; this is.
    ///
    /// It exists because it is the closest count of the same subject the
    /// bounded valuables probe walks that this pass can take for free: the
    /// probe's STARTING entry budget is derived from it
    /// (`ValuablesProbeBudget`), which is what stops a fixed constant from
    /// deterministically stranding the largest real artifact trees.
    ///
    /// A FLOOR, never a bound (PR #457 review r8). THIS walk is path-based and
    /// the probe's is descriptor-anchored, so they truncate in different
    /// places: a walk that hit denials, a mount boundary, or a path past
    /// `PATH_MAX` (ENAMETOOLONG — measured: 44 entries counted of a 151-entry
    /// tree) counted nothing past them, while the probe keeps walking. Nothing
    /// may treat this number as an upper bound on the probe's work; the
    /// probe's own doubling is what guarantees it finishes.
    var enumeratedEntries: Int = 0
    var denials: [SizeDenial] = []
    /// Directories recorded as mount boundaries; their subtrees are uncounted.
    var mountBoundaries: [URL] = []
    /// The measured root ITSELF is a mount boundary (mount point, or device
    /// mismatch against its parent). The tree was never enumerated; a
    /// `.deletionTarget` caller must refuse to delete it (R15).
    var rootMountBoundary: Bool = false
    /// Non-regular, non-directory, non-symlink entries (fifos, sockets, …)
    /// recorded as skips.
    var skippedSpecialFiles: [URL] = []
    /// One claim per measured regular-file inode — see the type doc.
    var claims: [InodeClaim] = []
    /// Newest `contentModificationDate` among measured REGULAR FILES (fn-3
    /// R8 input, produced by the SAME walk — never a second sizing
    /// enumeration). Regular files only: directory mtimes change on any
    /// child churn and lie about content age. `nil` when no regular file's
    /// date could be read.
    var newestContentDate: Date?

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
        switch provider.probeKind(of: resolved) {
        case .absent:
            // 0 bytes, no denials — ENOENT on a deletion child means
            // "already gone" (the caller's skip case); a missing scan root is
            // the scanner's `.missing`/`.empty` derivation input.
            break
        case .failed(let code):
            // A leaf we cannot even lstat is a classified, recorded denial —
            // never a silent zero (D6).
            report.denials.append(Self.denial(forFailedProbe: resolved, errno: code))
        case .kind(.symlink):
            // 0 bytes, NEVER walked: deleting a symlink removes the link only.
            break
        case .kind(.regularFile):
            var claimed = Set<FileSystemIdentityProvider.Identity>()
            recordRegularFile(
                resolved, knownInodes: knownInodes,
                claimedInodes: &claimed, report: &report
            )
        case .kind(.directory):
            // The root itself can be a mount boundary — the within-walk check
            // only sees entries YIELDED by the enumerator, so a mount-point
            // target handed directly to `measure` would otherwise be walked
            // (and, in `.deletionTarget` mode, deleted through). Both signals,
            // same as the within-walk rule (R15).
            let parent = resolved.deletingLastPathComponent()
            let device = provider.deviceID(of: resolved)
            let parentDevice = provider.deviceID(of: parent)
            if (device != nil && parentDevice != nil && device != parentDevice)
                || provider.isMountPoint(resolved) {
                report.rootMountBoundary = true
                report.mountBoundaries.append(resolved)
            } else {
                report = enumerateTree(at: resolved, knownInodes: knownInodes)
            }
        case .kind(.other):
            report.skippedSpecialFiles.append(resolved)
        }
        return report
    }

    // MARK: - Enumeration

    /// Prefetched during enumeration to avoid a second stat per entry.
    /// `.contentModificationDateKey` is prefetch-only here — the read that
    /// actually consumes it lives in `recordRegularFile`, which is also the
    /// only path a regular-file ROOT takes (it never passes through the
    /// enumerator at all).
    private static let prefetchKeys: [URLResourceKey] = [
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
        .totalFileSizeKey, .isRegularFileKey, .contentModificationDateKey,
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
            // The CENSUS, counted before any classification: every entry the
            // enumerator yielded, whatever it turns out to be and whether or
            // not it survives to contribute bytes.
            report.enumeratedEntries += 1
            let kind: FileSystemIdentityProvider.FileKind
            switch provider.probeKind(of: itemURL) {
            case .kind(let probed):
                kind = probed
            case .absent:
                // Deleted between enumeration and probe — a benign mid-walk
                // race, not a denial.
                continue
            case .failed(let code):
                // Classified by errno (EPERM → TCC, EACCES → permission) —
                // never collapsed into a generic metadata failure (D6).
                report.denials.append(Self.denial(forFailedProbe: itemURL, errno: code))
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
                .totalFileSizeKey, .contentModificationDateKey,
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

        // Newest-content date: max-merged BEFORE the dedupe/known-inode
        // guards — a second hardlink or a known inode contributes zero bytes
        // but its content age is still real evidence for this tree (and an
        // inode's links share one mtime anyway).
        if let modified = values.contentModificationDate {
            if let newest = report.newestContentDate {
                report.newestContentDate = max(newest, modified)
            } else {
                report.newestContentDate = modified
            }
        }

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
        // The one class whose Cocoa message names the WRONG cause, so the
        // detail is replaced rather than passed through: Foundation blames
        // the basename, and the basename is innocent.
        //
        // TWO ERRNOS, TWO CAUSES, TWO SENTENCES (PR #458 review r11, thread
        // `PRRT_kwDORmg6_86Zn1Ph`). Both share the KIND — the shared taxonomy
        // already words this class for both causes: see
        // `UserDataProbeObstruction.unaddressablePath.guidance`, "it is too
        // long, or it resolves through too many links". What was wrong was
        // that the sizer told a SECOND, narrower story on top of it, so an
        // `ELOOP` came out as a claim about `PATH_MAX`. Measured with a real
        // `rename(2)`+`symlink(2)` swapping a directory for a
        // self-referential link mid-walk: errno 62 at a 60-byte path,
        // reported as "runs deeper than an absolute path can address
        // (1024-byte limit)". Every clause of that is false.
        case .some(Int(ENAMETOOLONG)):
            return SizeDenial(
                url: url, kind: .unaddressablePath,
                detail: "this folder runs deeper than an absolute path can "
                    + "address (\(PATH_MAX)-byte limit), so its size could "
                    + "not be measured — deletion is unaffected"
            )
        case .some(Int(ELOOP)):
            // AND IT PROMISES NOTHING ABOUT DELETION, because that depends on
            // WHERE the cycle is and this errno does not say. Measured, both
            // directions: a self-referential symlink INSIDE the tree is
            // removed cleanly by `DepthSafeRemoval` (it never follows a link,
            // it unlinks it), while a cycle in an ANCESTOR fails the one path
            // the removal does resolve — `open(url.deletingLastPathComponent())`
            // returned errno 62 and `remove` threw `posix(62)`. The
            // path-length sentence's "deletion is unaffected" is earned;
            // repeating it here would not be.
            return SizeDenial(
                url: url, kind: .unaddressablePath,
                detail: "a symbolic link in this folder's path resolves "
                    + "through too many links to follow (a cycle, or a chain "
                    + "past the system limit), so its size could not be "
                    + "measured — removing or re-pointing that link allows a "
                    + "full measurement"
            )
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

    /// Classify a raw failed `lstat` probe by errno: EPERM is TCC, EACCES is
    /// BSD permissions, anything else a metadata failure.
    static func denial(forFailedProbe url: URL, errno code: Int32) -> SizeDenial {
        let kind: SizeDenial.Kind
        switch code {
        case EPERM: kind = .tcc
        case EACCES: kind = .permission
        default: kind = .metadata
        }
        return SizeDenial(
            url: url, kind: kind,
            detail: "lstat failed: \(String(cString: strerror(code)))"
        )
    }
}

// MARK: - Scan-error mapping

extension SizeDenial.Kind {
    /// The `ScanError` classification a scanner derives from this denial.
    var scanErrorKind: ScanError.Kind {
        switch self {
        case .tcc: return .tccDenied
        case .permission: return .permissionDenied
        case .metadata, .other, .unaddressablePath: return .other
        }
    }
}
