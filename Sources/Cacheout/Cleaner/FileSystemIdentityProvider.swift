/// # FileSystemIdentityProvider — Canonical Path Resolution & Inode Identity
///
/// The single source of truth for filesystem identity questions asked by the
/// deletion-safety layer (`PathGuard`) and, later, the shared sizer. Two distinct
/// canonicalization operations exist ON PURPOSE — do not merge them:
///
/// - **Root resolution** (`canonicalize`): full `realpath(3)` of the whole path.
///   A symlink handed to us as a deletion/scan ROOT is judged (and would be
///   walked) by its real location. When the path does not exist, the deepest
///   existing ancestor is resolved and the remaining components are appended
///   unresolved (this is what makes `/var/folders` ↔ `/private/var/folders`
///   interchangeable even for not-yet-existing leaves).
/// - **Target resolution** (`resolveTargetKeepingLeaf`): ancestors fully
///   resolved, the LEAF NEVER resolved. A deletion target that is itself a
///   symlink must keep its own identity — deleting it removes the link, not
///   the destination. `URL.resolvingSymlinksInPath()` is wrong for both jobs
///   (lexical past a symlink, misses `/private` aliasing, leaves ancestors
///   unresolved on non-existent leaves) — hence `realpath(3)` here.
///
/// Identity comparisons are `(st_dev, st_ino)` via `lstat(2)` (no-follow):
/// three spellings of `$HOME` (direct, symlink alias, case variant) share one
/// inode even though no amount of string canonicalization collapses them.
///
/// The class is intentionally the ONLY production implementation. It is a
/// non-final class solely so tests (via `@testable`) can subclass and override
/// `identity(of:)` to inject device ids for hermetic cross-device / mount-point
/// cases.
///
/// ## The DESCRIPTOR-RELATIVE family (PR #457/#458 review r5)
///
/// > Below a walk root, no filesystem operation takes a path. Every child is
/// > discovered and opened relative to an open, vetted parent descriptor, by
/// > single-component basename. A child's safety is established by CONTAINMENT
/// > in a held parent inode, not by comparing a recorded identity.
///
/// The path-based family above answers questions about a SPELLING and is right
/// for roots, identity, and display. It is structurally wrong for traversal:
/// between any two path operations an attacker can replace an ANCESTOR
/// component with a symlink, and every subsequent absolute-path call — the
/// kind probe, the metadata lstat, the open — silently re-resolves through it.
/// `O_NOFOLLOW` cannot help, because it guards only the FINAL component; and an
/// identity re-proof cannot help either, because if the ancestor was swapped
/// BEFORE the vetting `lstat`, the identity that gets recorded as "vetted" is
/// already the foreign object's, so the re-proof compares foreign against
/// foreign and passes.
///
/// The descriptor family below closes that by construction: `openat`,
/// `fstatat`, `fstat`, `fstatfs` are all relative to a descriptor the walk
/// already holds open and already vetted, and a held descriptor is INODE-PINNED
/// — no rename, no symlink, and no remount can redirect it.
///
/// `logical` parameters are the UNRESOLVED spelling of the same object. They
/// are the display/identity value the walk carries anyway, and they are the
/// key hermetic tests override on. PRODUCTION NEVER OPENS, STATS, OR RESOLVES
/// THEM in this family — they are carried, not used.

import Foundation

class FileSystemIdentityProvider {

    /// Inode identity: device + inode number, from `lstat` (never follows a
    /// symlink leaf — a link's identity is the link itself).
    /// `Sendable` because it is two immutable integers: it travels inside
    /// `PreDeleteInspectedObject`, which rides the `Sendable`
    /// `PreDeleteVerdict` from a scanner's revalidator to the cleaner.
    struct Identity: Hashable, Sendable {
        let device: UInt64
        let inode: UInt64
    }

    /// What kind of filesystem object sits at a URL (via `lstat`, no-follow).
    /// (Explicitly `Equatable` for documentation's sake — `KindProbe`'s
    /// synthesized conformance and callers' `==` checks rely on it, though
    /// associated-value-free enums conform automatically.)
    enum FileKind: Equatable {
        case regularFile
        case directory
        case symlink
        case other
    }

    init() {}

    // MARK: - Identity (override point for tests)

    /// `(st_dev, st_ino)` of the object at `url` itself (lstat: a symlink's
    /// identity is the link, not its target). `nil` when the path is absent
    /// or unreadable. Tests override THIS method to inject device cases;
    /// `deviceID(of:)` derives from it so overrides flow through.
    func identity(of url: URL) -> Identity? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        return Identity(
            device: UInt64(bitPattern: Int64(st.st_dev)),
            inode: UInt64(st.st_ino)
        )
    }

    /// Device id of the object at `url` (derived from `identity(of:)`).
    final func deviceID(of url: URL) -> UInt64? {
        identity(of: url)?.device
    }

    /// The ALL-INTEGER no-follow metadata ONE `lstat(2)` yields (fn-4.4,
    /// R17): inode identity, leaf allocation, and modification time as
    /// integers. `device`/`inode` follow `Identity`'s convention exactly.
    /// No `Date` — a `Date` round trip loses the nanosecond and is what the
    /// valuables identity path exists to avoid.
    struct LeafMetadata: Hashable {
        let device: UInt64
        let inode: UInt64
        /// `st_blocks * 512` — the LEAF's own allocation (a directory's own
        /// inode allocation, for a directory).
        let allocatedBytes: Int64
        /// `st_mtimespec.tv_sec`.
        let modifiedSeconds: Int64
        /// `st_mtimespec.tv_nsec`, guaranteed in `[0, 1e9)` by the accessor.
        let modifiedNanoseconds: Int64
    }

    /// ONE no-follow `lstat` of `url` → the five integers above; `nil` when
    /// the path is absent, unreadable, OR reports metadata OUTSIDE the pinned
    /// value domains (a nanosecond field outside `[0, 1e9)`, a
    /// seconds×1e9+ns product that would overflow `Int64`, or a block count
    /// whose byte figure overflows). Fail-CLOSED at the source: a caller can
    /// never build an out-of-domain identity from real filesystem metadata,
    /// so a hostile or broken filesystem cannot malform a whole scan outcome
    /// downstream — it can only make the inspection INCOMPLETE. Checked with
    /// overflow-reporting arithmetic; nothing is ever saturated.
    func leafMetadata(of url: URL) -> LeafMetadata? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        return Self.leafMetadata(from: st)
    }

    /// The ONE domain-checked `stat` → `LeafMetadata` derivation, shared by
    /// the path-based `leafMetadata(of:)` and the descriptor-relative
    /// `fstatat` probe below, so the two can never disagree on the pinned
    /// value domains.
    static func leafMetadata(from st: stat) -> LeafMetadata? {
        let (allocated, blocksOverflow) = Int64(st.st_blocks)
            .multipliedReportingOverflow(by: 512)
        guard !blocksOverflow, allocated >= 0 else { return nil }
        let seconds = Int64(st.st_mtimespec.tv_sec)
        let nanoseconds = Int64(st.st_mtimespec.tv_nsec)
        // The PINNED domain, named ONCE beside the model it belongs to — the
        // source check, the derivation, and the validator cannot disagree.
        let scale = ValuableIdentity.nanosecondsPerSecond
        guard nanoseconds >= 0, nanoseconds < scale else { return nil }
        let (scaled, scaleOverflow) = seconds
            .multipliedReportingOverflow(by: scale)
        guard !scaleOverflow,
              !scaled.addingReportingOverflow(nanoseconds).overflow
        else { return nil }
        return LeafMetadata(
            device: UInt64(bitPattern: Int64(st.st_dev)),
            inode: UInt64(st.st_ino),
            allocatedBytes: allocated,
            modifiedSeconds: seconds,
            modifiedNanoseconds: nanoseconds
        )
    }

    /// The `S_IFMT` → `FileKind` mapping, shared by the path probe and the
    /// descriptor-relative probe.
    static func fileKind(from st: stat) -> FileKind {
        switch st.st_mode & S_IFMT {
        case S_IFREG: return .regularFile
        case S_IFDIR: return .directory
        case S_IFLNK: return .symlink
        default: return .other
        }
    }

    /// `st_nlink` of the object at `url` (no-follow). Hardlink detection:
    /// `linkCount > 1` on a regular file.
    func linkCount(of url: URL) -> UInt64? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        return UInt64(st.st_nlink)
    }

    /// Is `url` itself a mount point (the root directory of a mounted
    /// filesystem)? Implemented via `statfs(2)`: the path is a mount root iff
    /// it IS the containing filesystem's `f_mntonname`.
    ///
    /// This exists because device-id change alone is NOT sufficient on modern
    /// macOS: volumes in a unified APFS volume group present ONE `st_dev` —
    /// measured on macOS 15: `/` and `/System/Volumes/Data` both report
    /// device 16777230, while a genuinely separate volume like
    /// `/System/Volumes/Update` reports its own. `statfs` still names the
    /// Data firmlink mount as its own `f_mntonname`, so both signals are used
    /// by the deny list. Note `statfs` follows a symlink leaf — callers pass
    /// canonical paths, and a mere LINK to a volume root correctly reports
    /// `false` (deleting the link touches only the link).
    func isMountPoint(_ url: URL) -> Bool {
        var fs = statfs()
        guard statfs(url.path, &fs) == 0 else { return false }
        let mountedOn = withUnsafeBytes(of: &fs.f_mntonname) { raw -> String in
            guard let baseAddress = raw.bindMemory(to: CChar.self).baseAddress else {
                return ""
            }
            return String(cString: baseAddress)
        }
        return mountedOn == url.path
    }

    /// Can this directory's ENTRIES be read — i.e. would a walk that reached
    /// it be able to enumerate what is inside?
    ///
    /// Asked by ATTEMPTING THE OPEN, never by `access(2)`: `access` consults
    /// the mode bits and misses ACLs, and the question here is exactly "would
    /// the enumeration succeed", not "do the permission bits suggest it
    /// would". A directory with mode `0111` is SEARCHABLE (paths through it
    /// resolve, so a root configured beneath it opens fine) while its own
    /// entries are unreadable — the split this exists to see.
    ///
    /// This is a DISPLAY-LAYER question only (the candidate dedupe's
    /// ancestor drop). It never authorizes anything: every candidate that
    /// survives the drop is still re-proven by the containment descent, the
    /// sizer, the valuables probe, and the delete-time revalidator.
    func canEnumerateDirectory(_ url: URL) -> Bool {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    /// Errno-aware kind probe result: distinguishes "nothing there" (the
    /// callers' silent-skip case) from a real metadata failure that must be
    /// recorded, never swallowed (D6).
    enum KindProbe: Equatable {
        case kind(FileKind)
        /// ENOENT/ENOTDIR — the path simply is not there.
        case absent
        /// `lstat` failed for a reason other than absence (EACCES, EIO, …).
        case failed(errno: Int32)
    }

    /// `lstat`-based kind probe at `url` (no-follow), with errno retained on
    /// failure. This is the override point for tests; `kind(of:)` derives
    /// from it so overrides flow through.
    func probeKind(of url: URL) -> KindProbe {
        var st = stat()
        guard lstat(url.path, &st) == 0 else {
            let code = errno
            return (code == ENOENT || code == ENOTDIR)
                ? .absent
                : .failed(errno: code)
        }
        switch st.st_mode & S_IFMT {
        case S_IFREG: return .kind(.regularFile)
        case S_IFDIR: return .kind(.directory)
        case S_IFLNK: return .kind(.symlink)
        default: return .kind(.other)
        }
    }

    /// File kind at `url` (no-follow): a symlink reports `.symlink` regardless
    /// of what it points at. `nil` collapses both "absent" and "failed" —
    /// callers that must distinguish (D6 classification) use `probeKind(of:)`.
    final func kind(of url: URL) -> FileKind? {
        if case .kind(let kind) = probeKind(of: url) { return kind }
        return nil
    }

    // MARK: - Ownership (fn-6.2, epic D12 — override point for tests)

    /// Errno-aware OWNERSHIP probe result. Deliberately NOT a `uid_t?`: a nil
    /// would collapse three outcomes a caller must route differently —
    /// absence (a benign race), a permission/IO failure (which has to stay
    /// VISIBLE, per the app's no-silent-zero doctrine), and a genuinely
    /// observed foreign owner. Mirrors `KindProbe`'s split exactly.
    enum OwnerProbe: Equatable {
        /// The owning uid actually read from the entry itself (no-follow).
        case owner(uid_t)
        /// ENOENT/ENOTDIR — the path simply is not there.
        case absent
        /// `lstat` failed for a reason other than absence (EACCES, EPERM, …).
        case failed(errno: Int32)
    }

    /// `st_uid` of the object at `url` ITSELF (`lstat`, no-follow — a
    /// symlink's owner is the link's, never its target's), with errno
    /// retained on failure.
    ///
    /// Its one consumer today is the ephemeral-temp scanner's sticky-root
    /// ownership gate (epic D12): under a world-writable temp root, another
    /// user's entry is readable yet UNDELETABLE by sticky-directory rules, so
    /// listing it would claim reclaimable bytes known false at scan time.
    /// This is the override point for tests — a genuine cross-user fixture
    /// cannot be created from a single uid.
    func ownerProbe(of url: URL) -> OwnerProbe {
        var st = stat()
        guard lstat(url.path, &st) == 0 else {
            let code = errno
            return (code == ENOENT || code == ENOTDIR)
                ? .absent
                : .failed(errno: code)
        }
        return .owner(st.st_uid)
    }

    // MARK: - Descriptor-relative traversal (the no-path family)

    /// Kind AND all-integer metadata from ONE descriptor-relative no-follow
    /// `fstatat`. Replaces the `probeKind(of:)` + `leafMetadata(of:)` PAIR:
    /// two independent path `lstat`s of the same name are two independent
    /// re-resolutions, and on the valuables path the identity that authorises
    /// a deletion came from the SECOND one — so a swapped ancestor could put
    /// a foreign file's size/inode/mtime into the acknowledgement-token
    /// preimage while the kind check saw the real object.
    ///
    /// `metadata` is `nil` only when the object's metadata falls outside the
    /// pinned value domains (`LeafMetadata`); the KIND is still reported, so
    /// a directory with a hostile mtime is still traversable while a FILE
    /// with one is still undescribable and fails its caller closed.
    enum DescriptorKindProbe: Equatable {
        case kind(FileKind, identity: Identity, metadata: LeafMetadata?)
        /// ENOENT/ENOTDIR — the name is not there (the benign vanish race).
        case absent
        /// `fstatat` failed for another reason (EACCES, EPERM, EIO, …).
        case failed(errno: Int32)
    }

    /// The mount identity of an OPEN descriptor: `f_fsid` plus `st_dev`.
    ///
    /// `f_fsid` is the discriminator that actually works. Measured on this
    /// machine (Darwin 25.5), `st_dev` is `16777230` for LITERALLY EVERY path
    /// including `/` and `/System/Volumes/Data`, so a device comparison is
    /// blind to the APFS system/data firmlink split it was partly meant to
    /// catch; `f_fsid` separates them (`{16777235,26}` vs `{16777230,26}`).
    /// `st_dev` is kept because it still catches ordinary external volumes and
    /// is the value hermetic tests inject.
    ///
    /// Read from a DESCRIPTOR, never a path (PR #458): the path form
    /// (`isMountPoint`) compares `f_mntonname` against the SPELLING it was
    /// handed, so an aliased spelling silently answered `false` — a whole
    /// failure class that dies with the descriptor family.
    ///
    /// ONE shape for both branches' walks (merge of #457/#458): #458 modelled
    /// the same two facts as a `(Int32, Int32)` tuple plus a hand-written
    /// `==`. Named fields are the same information with a synthesized
    /// `Equatable`, and every consumer on both sides compares whole values.
    struct MountIdentity: Equatable {
        let fsidMajor: Int32
        let fsidMinor: Int32
        let device: UInt64
    }

    /// Is `name` a single, safe path COMPONENT?
    ///
    /// MANDATORY, not belt-and-braces: measured on this machine,
    /// `openat(base, "cache/mid/secret.bin", O_NOFOLLOW)` SUCCEEDS through a
    /// symlinked `mid`, because `O_NOFOLLOW` guards only the final component.
    /// A multi-component name handed to any call in this family therefore
    /// defeats the entire no-follow guarantee. `readdir` cannot produce one
    /// today; this turns a future refactor into a refusal instead of a hole.
    static func isSafeComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && !name.utf8.contains(UInt8(ascii: "/"))
    }

    /// The ONE path-based open of a walk: its ROOT.
    ///
    /// `O_NOFOLLOW` refuses a root that IS (or became) a symlink; `O_DIRECTORY`
    /// refuses a non-directory. RESIDUAL, documented and accepted: this still
    /// resolves the root's ANCESTORS, so an attacker who already owns the scan
    /// root's parent directory can redirect the whole walk. Not closable at
    /// this layer — `O_NOFOLLOW_ANY` would close it but refuses ANY symlink
    /// anywhere in the path, breaking the legitimate aliased roots this
    /// codebase supports (`/tmp` → `/private/tmp`, a symlinked `$HOME`).
    /// Returns a negative value with `errno` set on failure.
    func openDirectoryNoFollow(at url: URL) -> Int32 {
        open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    }

    /// `fstatat(parent, name, AT_SYMLINK_NOFOLLOW)` — kind + metadata, one
    /// atomic call, no path resolution. `logical` is carried for tests only.
    func probeKind(
        inDirectory parent: Int32, named name: String, logical url: URL
    ) -> DescriptorKindProbe {
        guard Self.isSafeComponent(name) else { return .failed(errno: EINVAL) }
        var st = stat()
        guard fstatat(parent, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
            let code = errno
            return (code == ENOENT || code == ENOTDIR)
                ? .absent
                : .failed(errno: code)
        }
        return .kind(
            Self.fileKind(from: st),
            identity: Identity(
                device: UInt64(bitPattern: Int64(st.st_dev)),
                inode: UInt64(st.st_ino)
            ),
            metadata: Self.leafMetadata(from: st)
        )
    }

    /// `openat(parent, name, O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW)`.
    /// SINGLE COMPONENT only (see `isSafeComponent`). Negative + `errno` on
    /// failure; note a symlink `name` fails with **ENOTDIR**, not ELOOP,
    /// because `O_DIRECTORY` is checked first — measured on this OS and
    /// pinned by a test.
    func openChildDirectory(
        inDirectory parent: Int32, named name: String, logical url: URL
    ) -> Int32 {
        guard Self.isSafeComponent(name) else {
            errno = EINVAL
            return -1
        }
        return openat(
            parent, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
    }

    /// A FRESH enumeration description for an already-open directory.
    ///
    /// `openat(fd, ".")`, never `dup` and never `fcntl(F_DUPFD_CLOEXEC)`:
    /// measured, both of those SHARE THE FILE OFFSET with the anchor, so a
    /// second enumeration through them returns zero entries, and plain `dup`
    /// additionally CLEARS `FD_CLOEXEC`, leaking directory descriptors into
    /// every `posix_spawn` (this app spawns a privileged helper). `closedir`
    /// on the resulting handle closes only this description; the anchor `fd`
    /// survives.
    func openSelfForEnumeration(_ fd: Int32) -> Int32 {
        openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    }

    /// `openat(fd, "..")` — the RE-ANCHOR step. `..` is never a symlink, so
    /// `O_NOFOLLOW` is unnecessary. The caller MUST verify the result's
    /// identity against the frame it is restoring: a mismatch means the
    /// subtree was moved out from under the walk, which is not recoverable.
    func openParentDirectory(of fd: Int32) -> Int32 {
        openat(fd, "..", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    }

    /// `(st_dev, st_ino)` of an OPEN descriptor. The corroborator: what we
    /// opened must BE what the parent-relative `fstatat` vetted. Sound now in
    /// a way the path version never was, because the vetted value came from
    /// `fstatat` on the SAME held parent descriptor.
    ///
    /// It is also the only way to catch a leaf swapped for a DIFFERENT
    /// DIRECTORY (PR #458): `O_NOFOLLOW` refuses a leaf swapped for a
    /// symlink at the open itself, but a directory-for-directory swap passes
    /// every path check there is, and only this comparison sees it.
    ///
    /// PAIRING RULE for tests: production reads both sides from the same
    /// object (`fstatat` then `fstat`), so they always agree. A test that
    /// overrides `identity(of:)` for a directory the walk actually OPENS
    /// must override this in step, or the re-proof sees a divergence
    /// production cannot produce and refuses.
    func identity(ofDescriptor fd: Int32) -> Identity? {
        var st = stat()
        guard fstat(fd, &st) == 0 else { return nil }
        return Identity(
            device: UInt64(bitPattern: Int64(st.st_dev)),
            inode: UInt64(st.st_ino)
        )
    }

    /// `st_uid` of an OPEN descriptor — the descriptor-shaped twin of
    /// `ownerProbe(of:)`, read from the object the caller is already holding
    /// rather than from a path that can be re-pointed underneath it.
    ///
    /// `nil` when `fstat` fails on a descriptor we hold, which callers MUST
    /// treat as unprovable (never as "ours"). Override point for the hermetic
    /// foreign-ownership case: a real cross-uid fixture needs a second user
    /// account, so injecting here is how that gate is exercised at all.
    func ownerUID(ofDescriptor fd: Int32) -> UInt32? {
        var st = stat()
        guard fstat(fd, &st) == 0 else { return nil }
        return st.st_uid
    }

    /// `fstatfs`/`fstat` of an OPEN descriptor → its mount identity. `nil`
    /// when either call fails, which callers MUST treat as unvetted.
    ///
    /// Override point for hermetic mount tests: injecting a foreign
    /// `fsidMajor`/`fsidMinor` (or `device`) here is the descriptor-shaped
    /// equivalent of the retired `isMountPoint` inode injection, and it
    /// cannot be defeated by path spelling.
    func mountIdentity(ofDescriptor fd: Int32) -> MountIdentity? {
        var fs = statfs()
        guard fstatfs(fd, &fs) == 0 else { return nil }
        var st = stat()
        guard fstat(fd, &st) == 0 else { return nil }
        return MountIdentity(
            fsidMajor: fs.f_fsid.val.0,
            fsidMinor: fs.f_fsid.val.1,
            device: UInt64(bitPattern: Int64(st.st_dev))
        )
    }

    // MARK: - Descriptor-relative traversal, LAZY-SPELLING variant (PR #458)
    //
    // The sweep's walk (`OrphanedCachesScanner`) and the depth-safe removal
    // reach the same syscalls through their OWN seams. The two families are
    // NOT redundant and neither may be deleted in favour of the other:
    //
    //  * the `probeKind(inDirectory:named:logical:)` family above carries an
    //    EAGER `logical: URL` and returns `LeafMetadata` — the valuables
    //    identity path needs the metadata, and its walkers already hold the
    //    composed URL;
    //  * the `probeChild` family below takes `logical` as an `@autoclosure`
    //    and returns no metadata — the sweep keeps its spelling as one
    //    basename per level precisely so the per-entry
    //    `appendingPathComponent` (O(depth) work per entry, O(depth²)
    //    retained bytes down a deep chain) is never performed in production,
    //    and its bounded frame bookkeeping is measured against exactly that.
    //
    // They are also two independent TEST SEAMS: every hermetic swap/denial
    // fixture on either branch overrides one of them by name.

    /// Kind AND identity of one child, from ONE atomic `fstatat`.
    ///
    /// Two separate path `lstat`s of the same name (one for the kind, one
    /// for the identity) are two independent resolutions with a window
    /// between them; one `fstatat` against a HELD parent descriptor is a
    /// single resolution that cannot be re-pointed, because the parent is
    /// an inode we already hold rather than a path anyone can swap.
    struct ChildFacts: Equatable {
        let kind: FileKind
        let identity: Identity
    }

    /// Errno-aware descriptor-relative probe result — the `KindProbe`
    /// shape, carrying the identity the same stat established.
    enum ChildProbe: Equatable {
        case facts(ChildFacts)
        /// ENOENT/ENOTDIR — the entry simply is not there any more.
        case absent
        /// `fstatat` failed for another reason (EACCES, EIO, …).
        case failed(errno: Int32)
    }

    /// `fstatat(descriptor, name, AT_SYMLINK_NOFOLLOW)` — the sweep walk's
    /// ONE per-entry syscall below its root.
    ///
    /// `logical` is the walk's UNRESOLVED spelling of the child. Production
    /// IGNORES it completely (no path ever reaches a syscall here); it is
    /// carried solely so tests can key overrides and touch-recording on the
    /// path the walk believes it is at.
    ///
    /// IT IS AN `@autoclosure` PRECISELY BECAUSE PRODUCTION IGNORES IT (see
    /// the family note above). Overrides evaluate `logical()` once and pass
    /// the value on.
    ///
    /// `name` MUST be a single safe component — callers validate with
    /// `isSafeComponent` before calling, because `openat`/`fstatat` happily
    /// accept a MULTI-COMPONENT relative path and `O_NOFOLLOW` then guards
    /// only its last component (measured: `openat(base,
    /// "cache/mid/secret.bin", O_NOFOLLOW)` opens a foreign file through a
    /// symlinked `mid`).
    func probeChild(
        inDirectory descriptor: Int32, named name: String,
        logical: @autoclosure () -> URL
    ) -> ChildProbe {
        var st = stat()
        guard fstatat(descriptor, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
            let code = errno
            return (code == ENOENT || code == ENOTDIR)
                ? .absent
                : .failed(errno: code)
        }
        return .facts(ChildFacts(
            kind: Self.fileKind(from: st),
            identity: Identity(
                device: UInt64(bitPattern: Int64(st.st_dev)),
                inode: UInt64(st.st_ino)
            )
        ))
    }

    /// The outcome of a descriptor-relative directory open — errno carried
    /// rather than left in the global, which an override could clobber.
    enum DescriptorOpen: Equatable {
        case opened(Int32)
        case failed(errno: Int32)
    }

    /// `openat(descriptor, name, O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW)`,
    /// CARRYING ITS ERRNO in the result.
    ///
    /// Distinct from `openChildDirectory(inDirectory:named:logical:)` above
    /// in exactly that: the raw-`Int32` form leaves the code in the global
    /// `errno`, which a test override (or any intervening call) can clobber
    /// before the caller reads it, and the sweep's obstruction taxonomy is
    /// keyed on the ACTUAL cause. Named apart rather than overloaded because
    /// the two differ only in return type and in `logical`'s
    /// eager/`@autoclosure` spelling, which makes a same-named pair
    /// ambiguous at every call site.
    ///
    /// Single component only (see `probeChild`). The descent's safety comes
    /// from CONTAINMENT — the child is resolved inside an inode we hold —
    /// not from re-checking a recorded identity, which an ancestor swap
    /// makes meaningless (the recorded value is then already the foreign
    /// object's). `logical` is lazy for the same reason as `probeChild`'s:
    /// production never composes it.
    func openChildDirectoryCarryingErrno(
        inDirectory descriptor: Int32, named name: String,
        logical: @autoclosure () -> URL
    ) -> DescriptorOpen {
        let fd = openat(
            descriptor, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        return fd >= 0 ? .opened(fd) : .failed(errno: errno)
    }

    // MARK: - Canonicalization

    /// `realpath(3)` of `path`; `nil` when it fails (typically ENOENT).
    func realPath(of path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buffer) != nil else { return nil }
        return String(cString: buffer)
    }

    /// Root resolution: full canonical path. If `url` exists this is exactly
    /// `realpath(3)` — every component including the leaf resolved. If it does
    /// not exist, the deepest existing ancestor is resolved and the remaining
    /// components are appended unresolved.
    func canonicalize(_ url: URL) -> URL {
        if let resolved = realPath(of: url.path) {
            return URL(fileURLWithPath: resolved)
        }
        var current = url.standardizedFileURL
        var tail: [String] = []
        while current.pathComponents.count > 1 {
            tail.insert(current.lastPathComponent, at: 0)
            current = current.deletingLastPathComponent()
            if let resolved = realPath(of: current.path) {
                var out = URL(fileURLWithPath: resolved)
                for component in tail {
                    out.appendPathComponent(component)
                }
                return out
            }
        }
        return url.standardizedFileURL
    }

    /// Target resolution: ancestors fully resolved, leaf appended UNRESOLVED.
    /// The deletion target's own name is never followed — a symlink leaf keeps
    /// the link's identity, and a non-existent leaf still yields a canonical
    /// position (its parent chain resolves).
    func resolveTargetKeepingLeaf(_ url: URL) -> URL {
        let leaf = url.lastPathComponent
        let parent = url.deletingLastPathComponent()
        guard parent.pathComponents.count >= 1, leaf != "/" else {
            return canonicalize(url)
        }
        return canonicalize(parent).appendingPathComponent(leaf)
    }

    // MARK: - Location comparison

    /// Same filesystem object? Inode identity when both sides exist (immune to
    /// case, NFC/NFD, and spelling differences); canonical path-components
    /// equality as the fallback when either side does not exist yet.
    final func sameLocation(_ a: URL, _ b: URL) -> Bool {
        if let ia = identity(of: a), let ib = identity(of: b) {
            return ia == ib
        }
        return canonicalize(a).pathComponents == canonicalize(b).pathComponents
    }
}

// MARK: - SecureDirectory

/// An OPEN, no-follow-vetted directory that OWNS its descriptor.
///
/// A class, not a struct, on purpose: the number-one hazard in a
/// descriptor-anchored walk is leaking a descriptor on an early exit — a
/// `break walk`, a `guard … else { return }`, a thrown cancellation. ARC's
/// `deinit` covers every exit path; review vigilance does not. NEVER store a
/// bare `Int32` for a directory anywhere in a walk.
///
/// Its `identity` and `mount` are captured from the DESCRIPTOR at open time
/// (`fstat`/`fstatfs`), never from a path — a held descriptor is inode-pinned,
/// so these values cannot be invalidated by a later rename, symlink swap, or
/// overmount.
final class SecureDirectory {
    let fd: Int32
    let identity: FileSystemIdentityProvider.Identity
    let mount: FileSystemIdentityProvider.MountIdentity

    /// Takes OWNERSHIP of `fd`. Returns nil — after closing `fd`, so the
    /// failure path leaks nothing either — when the descriptor cannot be
    /// characterised, which is fail-closed: an unverifiable open is never
    /// treated as a vetted one.
    init?(fd: Int32, provider: FileSystemIdentityProvider) {
        guard fd >= 0,
              let identity = provider.identity(ofDescriptor: fd),
              let mount = provider.mountIdentity(ofDescriptor: fd)
        else {
            if fd >= 0 { close(fd) }
            return nil
        }
        self.fd = fd
        self.identity = identity
        self.mount = mount
    }

    deinit { close(fd) }
}
