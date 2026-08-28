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

    /// Every mount point on this machine, as the kernel spells it — the ONE
    /// stall-free mount detector (PR #459 review r5, lifted from
    /// `DepthSafeRemoval` so the scanner and the removal share a single
    /// spelling).
    ///
    /// `getfsstat(MNT_NOWAIT)` reads the kernel's own mount table and touches
    /// no filesystem. That property is load-bearing: `lstat(2)` or
    /// `statfs(2)` OF a mount point cross INTO the mounted filesystem (the
    /// getattr is served by the foreign fs), so on a hard-mounted
    /// unresponsive volume they block in the kernel — a detector built on
    /// them would hang exactly where it is needed. Only the table answers
    /// without first contact.
    ///
    /// A buffer of our own rather than `getmntinfo`, which returns a pointer
    /// to a STATIC buffer: scans and permanent deletions run concurrently.
    ///
    /// An INSTANCE method on purpose: it is the hermetic override point for
    /// mount fixtures no real `hdiutil` volume backs (the same rule as every
    /// other probe on this type).
    func mountPointPaths() -> [String] {
        let needed = getfsstat(nil, 0, MNT_NOWAIT)
        guard needed > 0 else { return [] }
        // Room for filesystems mounted between the two calls; anything past
        // it is simply not seen by THIS read, and the callers' later guards
        // still hold (the removal's per-child mount comparison; the
        // scanner's candidate-device arm).
        let capacity = Int(needed) + 8
        let table = UnsafeMutablePointer<statfs>.allocate(capacity: capacity)
        defer { table.deallocate() }
        let got = getfsstat(
            table, Int32(capacity * MemoryLayout<statfs>.stride), MNT_NOWAIT
        )
        guard got > 0 else { return [] }
        return (0..<Int(got)).map { index in
            withUnsafeBytes(of: &table[index].f_mntonname) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
        }
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

    /// `openDirectoryNoFollow(at:)` with its `errno` CAPTURED AT THE CALL.
    ///
    /// WHY IT EXISTS (PR #460 codex r11, D1). One caller —
    /// `TrashDisposal.facts` — must distinguish WHY the open failed, because
    /// its `probeLeaf` fallback is sound for exactly one class of failure
    /// (the TCC denial of `~/.Trash`, measured `EPERM`) and UNSOUND for the
    /// class `O_NOFOLLOW` exists to produce: `ELOOP` says the last component
    /// IS a symlink, and `probeLeaf`'s path `lstat` would then resolve the
    /// very link the descriptor-relative read refused. "Failed" is not one
    /// fact, so it is not returned as one.
    ///
    /// DELEGATES to `openDirectoryNoFollow(at:)` rather than re-spelling the
    /// `open` on purpose: any subclass override of that method still governs
    /// this call, so the two can never disagree about which directories are
    /// refusable. (COUNTED, PR #460 codex r12, D3, rather than left as the
    /// plural "the suite's TCC doubles among them": there is exactly ONE
    /// override in the repo — `TrashDeniedProvider` in
    /// `TrashDisposalHopProofTests`.)
    ///
    /// WHAT THE ERRNO READ ACTUALLY PROMISES, corrected in the same round.
    /// This paragraph used to say the global `errno` "is read on the
    /// statement immediately after, with no intervening call". It is not:
    /// between the `open(2)` and the read sit the delegated call and its
    /// return, `url.path`'s String construction and teardown, and this
    /// function's own epilogue. None of them makes a syscall or touches
    /// `errno` — which is a property of THIS delegation as compiled, not a
    /// guarantee the language gives, so it is MEASURED and not asserted:
    /// `TrashDisposalHopProofTests.testTheErrnoCarryingOpenAnswersOneCodePerFailureAndAdmitsMode0111`
    /// runs 500 consecutive real failing opens and requires exactly one code
    /// out of all of them.
    ///
    /// The spelling with genuinely NO intervening work is the `withCString`
    /// closure form — the errno read INSIDE the closure, next to the call
    /// that set it — which `openChildDirectoryCarryingErrno` and
    /// `TrashDisposal.look`'s path fallback both use. This one buys the
    /// override seam instead, and pays for it with an empirical claim rather
    /// than a structural one.
    func openDirectoryNoFollowCarryingErrno(at url: URL) -> DescriptorOpen {
        let fd = openDirectoryNoFollow(at: url)
        return fd >= 0 ? .opened(fd) : .failed(errno: errno)
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
    /// The bytes and identity of a SMALL REGULAR file, read through ONE
    /// no-follow descriptor (PR #461 codex r2).
    ///
    /// Three defects, all of them the same one: the call sites this replaces
    /// asked `probeKind` about a PATH, then handed that PATH to
    /// `String(contentsOf:)`/`Data(contentsOf:)`, which resolves it again and
    /// FOLLOWS symlinks. A `HEAD` or `config` replaced by a symlink between
    /// the two reads is then opened through the replacement, so a scan of a
    /// dev root can be steered into a TCC-protected or unresponsive target
    /// despite a check that just said "regular file". A path is not an
    /// identity, and asking twice is asking about two objects.
    ///
    /// Second, the read was UNBOUNDED. Any directory under a dev root with
    /// the cheap bare-repository shape but a multi-gigabyte `HEAD` was loaded
    /// and UTF-8 decoded in full before anything decided it was not a
    /// repository — a memory spike no scan deadline can cancel, because the
    /// read is synchronous. `limit` is checked against the DESCRIPTOR's size
    /// and the file is REFUSED rather than truncated: truncating would let a
    /// huge file whose first bytes read `ref: refs/…` pass as a valid HEAD.
    ///
    /// Third, kind and identity now come from the same descriptor as the
    /// bytes, so a caller that needs "these bytes belong to THAT object" gets
    /// it without a second resolution.
    ///
    /// `O_NONBLOCK` because `O_NOFOLLOW` alone does not save an open of a
    /// FIFO: a named pipe left at one of these names would park the opening
    /// thread until a writer appeared. Non-regular kinds are refused by the
    /// `fstat` below, but only if the open returns to run it.
    /// The two sizes these readers use. A git pointer file — `HEAD`,
    /// `gitdir`, `commondir`, a `.git` pointer — is tens of bytes; a repo
    /// `config` can legitimately reach a few kilobytes. Both are generous by
    /// orders of magnitude, and anything past them is refused, not truncated.
    /// A real repository whose config exceeds this stays UNDISCOVERED, which
    /// is the same silence every bare repository had before fn-4.28 — never a
    /// refusal dressed as retryable.
    static let gitPointerByteLimit = 64 * 1024
    static let gitConfigByteLimit = 1024 * 1024

    func smallRegularFile(
        at url: URL, limit: Int
    ) -> (bytes: Data, identity: Identity)? {
        url.withUnsafeFileSystemRepresentation { pathPointer in
            guard let pathPointer else { return nil }
            let descriptor = open(
                pathPointer, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
            )
            guard descriptor >= 0 else { return nil }
            defer { close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_size >= 0, info.st_size <= limit
            else { return nil }
            let identity = Identity(
                device: UInt64(bitPattern: Int64(info.st_dev)),
                inode: UInt64(info.st_ino)
            )
            var bytes = Data()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while bytes.count <= limit {
                let got = buffer.withUnsafeMutableBytes {
                    read(descriptor, $0.baseAddress, $0.count)
                }
                if got < 0 {
                    if errno == EINTR { continue }
                    return nil
                }
                if got == 0 { break }
                bytes.append(contentsOf: buffer[0..<got])
            }
            // A file that GREW past the limit between the fstat and the last
            // read is refused too, for the same reason the size check exists.
            guard bytes.count <= limit else { return nil }
            return (bytes, identity)
        }
    }

    /// `smallRegularFile` decoded as UTF-8 — the text form the git metadata
    /// readers want. Invalid UTF-8 is `nil`, exactly as
    /// `String(contentsOf:encoding:.utf8)` threw.
    func smallRegularFileText(at url: URL, limit: Int) -> String? {
        guard let found = smallRegularFile(at: url, limit: limit) else {
            return nil
        }
        return String(data: found.bytes, encoding: .utf8)
    }

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

    /// The SAME two facts about the object at `url`'s own path, from ONE
    /// no-follow `lstat` — `probeChild`'s path-resolved twin.
    ///
    /// THIS IS NOT A REPLACEMENT FOR `probeChild` AND HAS EXACTLY ONE
    /// SANCTIONED USE: reading an object inside a directory this process is
    /// not permitted to OPEN. Measured on this machine (Darwin 25.5), from a
    /// process without Full Disk Access:
    ///
    ///     open("/Users/<u>/.Trash", O_RDONLY|O_DIRECTORY|O_NOFOLLOW)
    ///         → -1, errno 1 (EPERM)
    ///     lstat("/Users/<u>/.Trash/<name>")              → 0
    ///     open("/Users/<u>/.Trash/<name>", O_DIRECTORY)  → a descriptor
    ///
    /// TCC denies the DIRECTORY and permits traversal THROUGH it, so a
    /// descriptor-relative read of a trashed item is impossible for every
    /// user who has not granted Full Disk Access while a path read is not.
    /// `TrashDisposal.facts` is the only caller and uses it only where the
    /// container open has already failed.
    ///
    /// WHY THE WEAKER BINDING IS STILL SOUND THERE, STATED RATHER THAN
    /// ASSUMED: its result is only ever compared for EQUALITY against an
    /// identity bound before the move, and a difference refuses. A re-pointed
    /// name resolves to some other inode, which cannot equal the bound one —
    /// so this call can never ADMIT what the descriptor-relative form would
    /// refuse. It can only supply the identity the descriptor-relative form
    /// is not permitted to read.
    func probeLeaf(at url: URL) -> ChildProbe {
        var st = stat()
        guard lstat(url.path, &st) == 0 else {
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

    // MARK: - Symlink content (read, never followed)

    /// The LITERAL content of the symlink at `url` — one `readlink(2)`.
    ///
    /// The difference from `canonicalize`/`resolveTargetKeepingLeaf` is the
    /// whole point: `readlink(2)` walks the link's ANCESTORS and then reads
    /// the link's own data. It never names the destination, so it cannot
    /// block on an unresponsive destination volume and cannot reach a
    /// destination the process has no right to. What comes back is a
    /// STRING — possibly relative, possibly non-canonical, possibly pointing
    /// at nothing — and callers must treat it as such: turning it into a
    /// canonical path is exactly the resolution this call exists to avoid.
    ///
    /// `nil` on every failure, including `EINVAL` for a path that is not a
    /// symlink. Truncation is not a case: `symlink(2)` refuses a target
    /// longer than `PATH_MAX - 1` (measured on this machine, Darwin 25.5: a
    /// 2000-byte target is refused `ENAMETOOLONG` (63)), so a link the kernel
    /// accepted always fits the buffer below.
    func symlinkTarget(of url: URL) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        // `readlink` does NOT NUL-terminate; one byte is held back so the
        // terminator below is always in bounds.
        let written = readlink(url.path, &buffer, buffer.count - 1)
        guard written > 0 else { return nil }
        buffer[written] = 0
        return String(cString: buffer)
    }

    /// `content` as an absolute path, folded LEXICALLY — no syscall of any
    /// kind. A relative target is joined to `link`'s own directory (which the
    /// caller must hand over parent-canonical); `.` is dropped and `..` pops
    /// a component in the STRING, because popping it against the filesystem
    /// is precisely the resolution this avoids.
    ///
    /// Born as `EphemeralTempRoots.lexicalTargetPath` (fn-6.1, PR #459 codex
    /// r12); hoisted here in fn-4.11 so the dev-root resolution, the
    /// cross-scanner union, and the container-root policy share the ONE
    /// folding rule with the temp-root resolution (that symbol now delegates
    /// here).
    ///
    /// `nil` for anything that is not a usable comparison subject: empty
    /// content, a `..` that walks off the root, and a target of `/` itself —
    /// note the latter two both NAME the filesystem root, and a caller that
    /// must refuse such a target (the container-root policy) treats `nil`
    /// from non-empty content as exactly that.
    static func lexicalTargetPath(ofLink link: URL, content: String) -> String? {
        guard !content.isEmpty else { return nil }
        let joined = content.hasPrefix("/")
            ? content
            : link.deletingLastPathComponent().path + "/" + content
        var components: [String] = []
        for component in joined.split(separator: "/") {
            switch component {
            case ".":
                continue
            case "..":
                guard !components.isEmpty else { return nil }
                components.removeLast()
            default:
                components.append(String(component))
            }
        }
        guard !components.isEmpty else { return nil }
        return "/" + components.joined(separator: "/")
    }

    /// The absolute path a symlink's content NAMES, or `nil` when `url` is
    /// not a readable symlink or the content is not a usable comparison
    /// subject (see `lexicalTargetPath`). One `readlink(2)` of the link
    /// itself plus the lexical fold above, positioned at the link's
    /// PARENT-canonical spelling so a relative target and a canonically
    /// declared sibling compare equal. The parent-chain `realpath(3)` never
    /// names the destination — only the link's own ancestors.
    ///
    /// The result is a NAME, never a resolved location: callers compare it,
    /// and must never register, walk, or open it (fn-4.11 — the whole point
    /// is that `realpath(3)` on a symlink leaf is first contact with
    /// whatever answers for the destination).
    final func lexicalAliasTarget(of url: URL) -> String? {
        guard let content = symlinkTarget(of: url) else { return nil }
        let position = canonicalize(url.deletingLastPathComponent())
            .appendingPathComponent(url.lastPathComponent)
        return Self.lexicalTargetPath(ofLink: position, content: content)
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
