//  DepthSafeRemoval.swift
//  Recursive removal that traverses by DESCRIPTOR, never by path.
//
//  WHY THIS EXISTS (PR #458 review — the stranding class that MOVED).
//
//  Making the user-data probe descriptor-relative (e9de405 and the ancestor-
//  swap round after it) let INSPECTION walk past `PATH_MAX`. Deletion was
//  left on `FileManager.removeItem(at:)`, which composes an absolute path per
//  entry, so the codebase started manufacturing items that are provably clean
//  and permanently undeletable. Measured on real chains built with `mkdirat`
//  (the only way one can exist), depths 300 / 446 / 600 / 2000 / 4000 —
//  threshold exactly `PATH_MAX`:
//
//  - probe          `complete=true, obstructions=[]` at every depth;
//  - `DirectorySizer` `itemCount=0, exact=0, denials=1`, detail "The item
//    couldn't be opened because the file name "d" is invalid";
//  - `removeItem`   NSCocoaErrorDomain 514 (underlying NSPOSIXErrorDomain 63,
//    ENAMETOOLONG) in 0.03 s — deterministically, forever;
//  - `rm -rf`       removes the identical tree, status 0.
//
//  The refusal was the app's own, not the OS's: `rm` uses `fts`, which
//  `chdir`s/`openat`s its way down and therefore never spells a long path.
//  So does this. Below the deletion root, no operation here takes a path;
//  containment in a held parent descriptor is the proof, exactly as in the
//  scanner's bounded walk — which is also why both sides ask the SAME
//  `FileSystemIdentityProvider` about mount boundaries, so scan-time and
//  delete-time cannot drift.
//
//  Descriptor cost is a CONSTANT (parent + current + one in-flight handle),
//  not a function of depth: the traversal keeps one descriptor and climbs
//  back with `openat(cur, "..")`, verifying at every step that `..` landed on
//  the directory it left — a `rename` of the current directory into a foreign
//  parent otherwise redirects the rest of the deletion into somebody else's
//  tree.
//
//  EVERY PROOF IS TAKEN AGAINST THE HELD PARENT, AND BEFORE THE DESTRUCTION,
//  never against the object being judged and never after the fact. Both
//  halves are load-bearing:
//
//  - anchored to the parent, because a root that supplies its own reference
//    point cannot disagree with itself — read the mount identity FROM the
//    opened root and a volume attached onto the target is invisible, every
//    descendant matching the mounted filesystem it was compared against;
//  - taken first, because a descriptor survives a `rename(2)` intact, so a
//    check made on the way back up passes judgement on entries that are
//    already unlinked.
//
//  THE DELETION ALSO PROVES *WHOSE* TREE IT IS (PR #458 review — the P1 the
//  descriptor-relative rewrite left open). Every proof above answers "am I
//  still inside the parent I was admitted under?", which a swap of the TARGET
//  ITSELF answers `yes` to: the replacement directory is created at the same
//  name, in the same parent, on the same volume. The caller's inspection
//  verdict is a fact about an OBJECT, so `remove(at:expecting:provider:)`
//  takes that object's identity and `fstat`s the ROOT DESCRIPTOR IT OPENED
//  before the first `unlinkat`. A path re-checked after the descriptor is
//  held is not a proof of anything; the held inode is.
//
//  AND THE SAME QUESTION IS ASKED OF THE PARENT (PR #458 review — the P1 at
//  the one remaining path-based open). The parent is the only thing here
//  reached BY PATH, and it is reached after a queue hop: a `rename(2)` pair
//  in that window puts a stranger's directory at that path, and then every
//  descriptor-relative proof below — containment, mount, even the leaf's own
//  `..` — is perfectly self-consistent INSIDE THE STRANGER'S TREE. Measured,
//  with two real renames: an unbound removal deleted a foreign same-named
//  tree and returned SUCCESS. So `containedIn:` carries the caller's
//  admitted container identity and is proved against the `fstat` of the
//  opened parent BEFORE the leaf is opened. Where the caller has a LEAF
//  binding instead, the same swap is already refused transitively — a
//  foreign parent cannot hold the inspected inode at that name (measured:
//  `.notTheInspectedObject`, stranger's tree intact).
//
//  BOUNDARIES ARE FOUND BEFORE ANYTHING IS DESTROYED, NOT WHERE THEY ARE
//  MET (PR #458 review — the P2). A per-child mount comparison is a guard,
//  not an order: it fires when the traversal reaches the boundary, by which
//  time the level's ordinary files are unlinked. The kernel's mount table
//  answers "is there a boundary anywhere in this tree" in one call, so it is
//  asked first, and the refusal is wholesale — the same answer the cleaner
//  gives for trees its sizer CAN measure.
//
//  AND NO PASS ALLOCATES IN PROPORTION TO WHAT IT IS DELETING (PR #458
//  review — the P2, and the third instance on this project of a budget that
//  bounds attention rather than resources). Enumeration stops at
//  `subdirectoryBatchLimit` names and resumes later; a refill is a NEW
//  destruction and therefore carries a NEW proof, which is why proof and
//  enumeration are ONE function (`destructivePass`) and not two lines
//  someone has to keep in the right order.
//
//  RESIDUALS, MEASURED — not "one directory's enumeration", which is what
//  this comment used to claim and is false:
//
//  1. A relocated directory's ENTIRE REMAINING SUBTREE. `rename(2)` of a
//     directory the traversal is standing in (or of any ancestor of where it
//     is standing, up to the deletion root) leaves every descriptor and every
//     containment proof below it perfectly valid — `..` from a child still
//     names the relocated directory. So the traversal keeps going: it
//     `readdir`s each not-yet-visited subdirectory AFTER the relocation and
//     unlinks what it finds, at every depth, including entries the new owner
//     wrote there. The bound is the relocated directory's own subtree (the
//     unwind's `..` re-anchor refuses the moment it tries to climb OUT of
//     it, so the damage never spreads to the new owner's siblings), and the
//     deletion then fails `.relocated` — it does not report success.
//     Evidenced by `testAncestorRelocationDestroysTheNewOwnersWholeSubtree`.
//  2. The deletion root's final `rmdir`. There is no `frmdir(2)`: the last
//     act names the leaf in the parent descriptor. Measured on this
//     platform, that names what can be lost: `unlinkat(AT_REMOVEDIR)`
//     returns `ENOTDIR` on a non-directory and `ENOTEMPTY` (errno 66) on a
//     non-empty one, so a name swapped in that window costs at most ONE
//     EMPTY directory — never a tree, never a file.
//  3. THE WINDOW BEFORE THE CALLER'S CAPTURE. All FOUR production disposal
//     sites now pass `containedIn: .identity(…)` — `removeGuardedItem` and
//     `cleanContents`, each on BOTH arms, since the Trash arm takes the same
//     binding through `TrashDisposal` (`openAdmittedContainer` below is the
//     one spelling both arms prove with). The sentence that stood here said
//     "both production call sites", counted only the PERMANENT ones, and was
//     read for three review rounds as though the product were covered. Each
//     capture is taken through
//     `admittedParent(directory:displayPath:provider:)` on THIS side of
//     `removeItemConcurrently`'s queue hop (measured at 0.095–0.126 ms, the
//     race this closes). What the binding cannot see is a swap that landed
//     BEFORE the capture: both opens then find the stranger and agree about
//     it. For item mode the container root itself is covered by
//     `PathGuard.admitContainer`'s snapshot identity; what neither covers is
//     an INTERMEDIATE directory between an admitted container root and a
//     deeper target (`<dev-root>/proj/node_modules` — nothing binds `proj`)
//     swapped before the capture. Pinned by
//     `testAnItemWhoseParentIsSwappedAtTheQueueHopIsRefused`, whose fixture
//     performs the swap after the capture and is refused; move the same two
//     `rename(2)`s one step earlier and the deletion proceeds inside the
//     stranger.
//
//  4. A NON-DIRECTORY leaf under a `.noDirectoryTree` verdict. That case
//     carries no identity and does not separate "nothing was there" from
//     "something that is not a directory was there", so any non-directory at
//     the name satisfies it — the kernel refuses only a DIRECTORY appearing
//     there, which is a kind check and not an identity one. Measured and
//     pinned by `testANonDirectoryVerdictCannotTellAbsenceFromAReplacement`.
//
//     ITS SCOPE, STATED RATHER THAN LEFT TO BE INFERRED (re-measured PR #459
//     review r5): it is a residual of that one CASE, not of the verdict
//     type. `.nonDirectoryLeaf(Identity)` closed it for every producer that
//     HOLDS the leaf's identity — `EphemeralTempScanner`'s revalidator,
//     whose regular-file arm is that case's only producer today — by making
//     this file's `ENOTDIR` arm `fstatat` the leaf against the carried
//     identity and `TrashDisposal.dispose(_:expecting:…)` bind the same
//     facts on both sides of the move. What remains on `.noDirectoryTree`
//     is exactly its one remaining producer, the probe whose root open
//     FAILED (`OrphanedCachesScanner.swift` — ENOENT/ENOTDIR, so it never
//     had an identity to carry), plus this file's one-syscall
//     `fstatat`→`unlinkat` window (no `funlinkat(2)` on macOS; residual 2's
//     shape, one leaf, never a tree). None of it applies to
//     `TrashDisposal.dispose(_:containedIn:…)`, which always bound by
//     `fstatat` under a proved container. A future note here must not
//     generalise "the Trash arm binds the same way" in either direction:
//     the arms bind differently, on purpose, because they have different
//     facts available.
//
//  POSIX offers no primitive that closes 1, 2 or 3: there is no way to pin a
//  directory to its parent for the duration of a read, no way to remove a
//  directory by descriptor, and no way to hand a deletion the descriptor an
//  admission opened instead of the path it was opened from. What is left of
//  4 is one identity-free case kept for the one producer that never held an
//  identity, plus the missing `funlinkat(2)`.

import Foundation

/// Depth-independent, no-follow, mount-respecting recursive removal.
///
/// The ONE removal primitive behind `CacheCleaner`'s permanent-delete paths.
/// It is deliberately not a general `rm`: it refuses rather than guesses
/// whenever it cannot prove where it is standing.
enum DepthSafeRemoval {

    /// A directory-entry name as the filesystem gave it: raw, NUL-terminated
    /// bytes.
    ///
    /// NOT a `String`. `d_name` is whatever the filesystem driver wrote, and
    /// decoding it through Swift's repairing initializer produces a name that
    /// addresses a DIFFERENT entry (or none). The probe refuses undecodable
    /// names because it must reason about them; deletion only has to unlink
    /// them, and it can — bytes in, bytes out.
    typealias RawName = [CChar]

    /// WHAT THE CALLER ADMITTED AS THE TARGET'S CONTAINER — a fact about an
    /// OBJECT, exactly like the inspection verdict, and for the same reason:
    /// the parent is reached by PATH, and a path is what a `rename(2)`
    /// re-points.
    ///
    /// The identity must be taken the way this file proves it — `fstat` of a
    /// descriptor opened on the container (`identity(ofDescriptor:)`), NOT
    /// `lstat` of its path: a container legitimately reached through a
    /// symlinked ancestor would otherwise compare a link's inode against the
    /// directory's and refuse every deletion under it.
    enum AdmittedParent: Equatable {
        /// The identity the caller's admission bound, captured BEFORE the
        /// hop that separates it from this removal.
        case identity(FileSystemIdentityProvider.Identity)
        /// The caller has nothing to bind. NEVER a licence: it leaves the
        /// deletion resting on the leaf binding (`expecting:`) and on every
        /// gate the caller already ran, and widens nothing.
        case unbound
    }

    /// How many subdirectory names ONE enumeration pass may hold.
    ///
    /// A DELETION MUST NOT ALLOCATE IN PROPORTION TO A DIRECTORY IT IS
    /// DELETING (PR #458 review — the third time this project has shipped a
    /// budget that bounds attention rather than resources). The traversal
    /// keeps one name list per level of the CURRENT path; unbounded, a single
    /// directory a million entries wide is a million heap-allocated names —
    /// held while its non-directory siblings are already being unlinked, so
    /// an out-of-memory kill lands mid-deletion.
    ///
    /// Bounded, the pass stops at this many subdirectory names and says it
    /// has more; the level is re-enumerated when the batch is spent. That
    /// re-read is not free — see `emptyOfNonDirectories` for the measured
    /// cost and why it is nonetheless linear in practice — and this value is
    /// the knob, not a policy: correctness does not depend on it (the tests
    /// drive the same trees at `limit: 1`).
    static let subdirectoryBatchLimit = 4096

    /// Why a removal stopped, in the caller's language.
    struct Failure: LocalizedError {
        enum Cause: Equatable {
            /// A syscall failed; the errno is carried verbatim.
            case posix(Int32)
            /// A directory below the target sits on another filesystem —
            /// the R15 mount doctrine, enforced where the sizer cannot see
            /// (a tree it could not measure), not only where it can.
            case mountBoundary
            /// `..` did not land on the directory it was left from: the tree
            /// was restructured mid-deletion. Continuing would delete
            /// entries by name inside a FOREIGN directory.
            case relocated
            /// A descriptor whose device/mount could not be read at all.
            /// Unprovable ⇒ refused.
            case unprovableLocation
            /// A target with no removable leaf ("/", ".", "..").
            case invalidTarget
            /// The object opened at the target's name is NOT the object the
            /// caller's pre-delete inspection was about — or its identity
            /// could not be read at all. Unprovable ⇒ refused.
            case notTheInspectedObject
            /// The directory opened at the target's PARENT path is not the
            /// container the caller admitted — or its identity could not be
            /// read at all. Unprovable ⇒ refused.
            ///
            /// A separate cause from `notTheInspectedObject` because it is a
            /// different event: the item is where it always was and something
            /// happened to the FOLDER THAT HOLDS IT, which is what the user
            /// has to go and look at.
            case notTheAdmittedContainer
        }

        let path: String
        let cause: Cause
        /// Where inside the tree, in levels below the target — the honest
        /// locator when the path itself cannot be spelled.
        let depth: Int

        var errorDescription: String? {
            let place = depth == 0
                ? path
                : "\(path) (\(depth) level\(depth == 1 ? "" : "s") down)"
            switch cause {
            case .posix(let code):
                return "\(place): \(String(cString: strerror(code)))"
            case .mountBoundary:
                // WHERE the boundary is changes what the user has to do
                // about it, so the two are not one sentence: a volume ON the
                // target is ejected, a volume INSIDE it is a nested mount.
                return depth == 0
                    ? "\(place): a volume is mounted here and the deletion "
                        + "never crosses a mount boundary — refused, not "
                        + "deleted"
                    : "\(place): a volume is mounted inside this folder and "
                        + "the deletion never crosses a mount boundary — "
                        + "refused, not deleted"
            case .relocated:
                return "\(place): the folder moved while it was being "
                    + "deleted — refused, re-scan required"
            case .unprovableLocation:
                return "\(place): the deletion could not prove which volume "
                    + "this folder is on — refused, not deleted"
            case .invalidTarget:
                return "\(place): not a removable item"
            case .notTheInspectedObject:
                // Deliberately the SAME sentence the cleaner's own path
                // check produces: to the user these are one event, and the
                // only difference is which layer caught it.
                return "\(place): the folder at this path is no longer the "
                    + "one that was inspected — it was replaced between the "
                    + "safety check and the deletion; refused, re-scan "
                    + "required"
            case .notTheAdmittedContainer:
                return "\(place): the folder that holds this item is no "
                    + "longer the one the safety check admitted — it was "
                    + "replaced between the safety check and the deletion; "
                    + "refused, re-scan required"
            }
        }
    }

    /// Remove `url` — the item ITSELF, in its UNRESOLVED spelling: a symlink
    /// is removed AS a link, never through it (R4).
    ///
    /// `inspected` is WHAT THE CALLER'S PRE-DELETE INSPECTION WAS ABOUT, and
    /// it is proved against the descriptor this call opens, before anything
    /// is destroyed. `nil` says that no inspection ran and there is nothing to
    /// bind to; it is not a way to skip the check.
    ///
    /// THE PARAMETER HAS NO DEFAULT, AND BOTH CALL SITES STATE THEIR `nil`
    /// (PR #458 review — this sentence used to be true of only one of them).
    /// `CacheCleaner.deleteGuardedChild` passes a literal `nil` under a
    /// paragraph saying contents mode runs no probe;
    /// `CacheCleaner.removeGuardedItem` used to let an implicitly-nil `var`
    /// fall past its `if` and arrive here having said nothing, and now writes
    /// the `else` arm out with the two populations it covers. A comment that
    /// claims a property the code lacks is worse than no comment, so if a
    /// third call site appears, either it states its `nil` or this paragraph
    /// stops being true and must change with it.
    ///
    /// `provider` answers the mount question, and it is the same object the
    /// scanner's walk asks, so the two cannot classify a boundary
    /// differently. It is also the tests' injection seam.
    ///
    /// `containedIn` is THE SAME KIND OF FACT ABOUT THE PARENT (PR #458
    /// review — the P1 at the parent open). The one path this operation
    /// resolves is the target's parent, and it resolves it AFTER the queue
    /// hop, so a `rename(2)` of the admitted container between the cleaner's
    /// checks and this `open` lands the whole traversal inside a FOREIGN
    /// directory in which every descriptor-relative proof below is then
    /// perfectly self-consistent. Measured with a real rename+rename pair at
    /// that seam: with no leaf binding the removal deleted a stranger's
    /// same-named tree and returned SUCCESS.
    ///
    /// The leaf binding closes the same window whenever there IS one — a
    /// foreign parent cannot hold the inspected INODE at that name, so
    /// `expecting: .directory` refuses (measured: `.notTheInspectedObject`,
    /// the stranger's tree intact). This parameter is what the callers with
    /// NOTHING to bind at the leaf — contents mode, and any scanner whose
    /// revalidator says `.unestablished` — use instead.
    ///
    /// IT HAS NO DEFAULT, AND THAT IS THE POINT (PR #458 review — the round
    /// that shipped one). A default turns "this caller forgot" into silence
    /// instead of a compile error, and the forgetting is exactly what
    /// happened: the round that added this parameter gave it `= .unbound` and
    /// wired it to ZERO production call sites, so the mechanism was proved
    /// and the product was unchanged. Both call sites now state their binding
    /// (`CacheCleaner`, via `admittedParent(directory:displayPath:provider:)`),
    /// and a third that states nothing does not compile. Same rule as
    /// `expecting:` above, for the same reason.
    static func remove(
        at url: URL,
        expecting inspected: UserDataProbeResult.InspectedRoot?,
        provider: FileSystemIdentityProvider,
        containedIn admittedParent: AdmittedParent,
        batchLimit: Int = subdirectoryBatchLimit
    ) throws {
        let leafName = url.lastPathComponent
        guard !leafName.isEmpty, leafName != "/", leafName != ".",
              leafName != ".." else {
            throw Failure(path: url.path, cause: .invalidTarget, depth: 0)
        }
        let leaf = RawName(leafName.utf8CString)

        // The ONE path this whole operation resolves, and it is the target's
        // PARENT — always inside `PATH_MAX`, because the target itself came
        // through the path guard's admission. Everything below is relative
        // to the descriptor opened here.
        //
        // WHOSE PARENT IS THIS? Asked of the OPENED INODE, before the leaf
        // is even opened — an `openat` inside a foreign parent is already
        // the wrong question, and everything after it agrees with the wrong
        // answer. `fstat` of the held descriptor, never a re-`lstat` of the
        // path that produced it. The open and that question are ONE function
        // (`openAdmittedContainer`) because the Trash arm needs the identical
        // pair, and two spellings of one proof is how the two arms drift.
        let parentFd = try openAdmittedContainer(
            at: url.deletingLastPathComponent(),
            provenAgainst: admittedParent, displayPath: url.path,
            provider: provider
        )
        defer { close(parentFd) }

        // THE KIND GATE **IS** THE OPEN — one syscall, so there is no window
        // between deciding what stands here and taking hold of it (a gate
        // BESIDE an open is a swap window by construction; this is the same
        // shape the scanner's root open already has). `O_NOFOLLOW` is what
        // makes the answer trustworthy rather than merely fast: measured on
        // this platform, `openat(parent, link-to-dir, O_DIRECTORY)` WITHOUT
        // it opens the link's target and the traversal below would then
        // recursively empty a directory that is not the item at all, while
        // WITH it the same call fails `ENOTDIR` and the link is unlinked AS
        // a link (R4). `O_DIRECTORY` is what makes it safe to point at any
        // leaf: on a fifo, a socket or a device node it fails `ENOTDIR`
        // without ever entering the driver's open (measured — `/dev/tty`,
        // `/dev/null`, `/dev/zero` and a real `mkfifo`, none of which
        // blocked).
        let root = openat(
            parentFd, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard root >= 0 else {
            let code = errno
            guard code == ENOTDIR else {
                throw Failure(path: url.path, cause: .posix(code), depth: 0)
            }
            // Symlink, regular file, fifo, socket, device: one unlink, and
            // never a resolution through it.
            if let inspected {
                switch inspected {
                case .noDirectoryTree:
                    // The IDENTITY-FREE verdict — its one remaining producer
                    // is the probe whose root open FAILED and never held an
                    // identity to carry (`OrphanedCachesScanner.swift`).
                    // THE ONLY BINDING THIS ARM HAS IS A KIND CHECK, AND
                    // THAT IS A RESIDUAL, NOT A PROOF (PR #458 review):
                    // `unlinkat` WITHOUT `AT_REMOVEDIR` cannot remove a
                    // directory — measured on this platform: `EPERM` — so a
                    // DIRECTORY created here since the failed open is refused
                    // by the kernel. What the kernel cannot refuse is a
                    // different NON-directory: this verdict carries neither
                    // the leaf's identity nor whether anything was there at
                    // all, so an absence the probe saw and a stranger's file
                    // the deletion finds are the same value. Measured and
                    // pinned by
                    // `testANonDirectoryVerdictCannotTellAbsenceFromAReplacement`.
                    // A producer that HOLDS the leaf's identity must say
                    // `.nonDirectoryLeaf` instead and take the arm below.
                    break
                case .nonDirectoryLeaf(let expected):
                    // THE LEAF IS PROVED BEFORE IT IS UNLINKED (PR #459
                    // review r5). One `fstatat` under the PROVED parent
                    // descriptor — a single resolution no rename can
                    // re-point — compared against the identity the
                    // revalidator verified on its held descriptor. Absence,
                    // a probe failure, and a different object are all
                    // refusals: unprovable is never unlinked.
                    //
                    // RESIDUAL, macOS has no `funlinkat(2)`: between this
                    // `fstatat` and the `unlinkat` below there is a
                    // one-syscall window in the proved parent — the same
                    // shape as residual 2 (the final `rmdir`), and like it
                    // the cost is bounded to ONE leaf at this name, never a
                    // tree (a directory swapped in fails the `unlinkat`
                    // itself). An `O_NOFOLLOW` open + `fstat` would buy
                    // nothing: the unlink still acts on the NAME.
                    switch provider.probeChild(
                        inDirectory: parentFd, named: leafName, logical: url
                    ) {
                    case .facts(let facts) where facts.identity == expected:
                        break
                    case .facts, .absent, .failed:
                        throw Failure(
                            path: url.path, cause: .notTheInspectedObject,
                            depth: 0
                        )
                    }
                case .directory, .unestablished:
                    throw Failure(
                        path: url.path, cause: .notTheInspectedObject,
                        depth: 0
                    )
                }
            }
            guard unlinkat(parentFd, leaf, 0) == 0 else {
                throw Failure(path: url.path, cause: .posix(errno), depth: 0)
            }
            return
        }

        // WHOSE TREE IS THIS? Asked of the OPENED INODE, before one entry is
        // unlinked. Every other proof in this file answers "am I inside the
        // parent I was admitted under?" — and a replacement directory
        // created at the target's own name answers that `yes`, in the right
        // parent, on the right volume, holding content nobody inspected.
        do {
            try proveInspectedRoot(
                inspected, is: root, provider: provider, displayPath: url.path
            )
        } catch {
            close(root)
            throw error
        }

        try removeTree(
            from: root, named: leaf, in: parentFd, displayPath: url.path,
            provider: provider, batchLimit: batchLimit
        )
    }

    /// THE ONE SPELLING OF THE CONTAINER OPEN — the open `remove` proves
    /// against, and the open `admittedParent` captures from.
    ///
    /// Two spellings here would be two different questions wearing one name.
    /// It deliberately FOLLOWS symlinks (no `O_NOFOLLOW`): a container
    /// legitimately reached through a symlinked ancestor, or spelled with a
    /// symlinked last component, is a real directory that both sides must
    /// arrive at, and a no-follow open would refuse it while `remove`'s open
    /// succeeded — a binding that refuses every deletion under a symlinked
    /// cache root. The leaf, which is the thing being destroyed, is opened
    /// `O_NOFOLLOW` further down; this is its container.
    private static func openContainer(at url: URL) -> Int32 {
        url.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
    }

    /// OPEN THE CONTAINER AND PROVE IT, AS ONE ACT — the pair every
    /// destructive arm needs, spelled once (PR #458 review — the Trash arm's
    /// P1).
    ///
    /// `remove` opens the target's parent and `fstat`s it against the
    /// caller's admitted identity; `TrashDisposal` has to do the IDENTICAL
    /// thing, because `trashItem` resolves a URL inside itself and the only
    /// place the container can be interrogated is out here. Two copies of
    /// that pair are two places a later edit can let the arms drift apart —
    /// which is exactly the drift that left the Trash arm unbound for three
    /// review rounds while the permanent one was fixed.
    ///
    /// FAIL CLOSED, AND THE CALLER OWNS THE DESCRIPTOR. An unopenable
    /// container throws its errno; an identity that disagrees (or cannot be
    /// read at all) throws `.notTheAdmittedContainer` AFTER closing the
    /// descriptor, so the refusal path leaks nothing.
    static func openAdmittedContainer(
        at url: URL,
        provenAgainst admittedParent: AdmittedParent,
        displayPath: String,
        provider: FileSystemIdentityProvider
    ) throws -> Int32 {
        let fd = openContainer(at: url)
        guard fd >= 0 else {
            throw Failure(path: displayPath, cause: .posix(errno), depth: 0)
        }
        if case .identity(let expected) = admittedParent {
            guard provider.identity(ofDescriptor: fd) == expected else {
                close(fd)
                throw Failure(
                    path: displayPath, cause: .notTheAdmittedContainer,
                    depth: 0
                )
            }
        }
        return fd
    }

    /// THE BINDING A CALLER MUST TAKE, TAKEN THE WAY THIS FILE PROVES IT.
    ///
    /// `remove` resolves exactly one path — the target's container — and it
    /// resolves it AFTER a queue hop. A caller that wants that open bound has
    /// to read the same fact the same way, which is why this lives here and
    /// not at the call site: it goes through `openContainer` and `fstat`s the
    /// descriptor, so a caller cannot accidentally hand over an `lstat` of
    /// the path (a symlinked container would then never match and every
    /// deletion under it would be refused) or a no-follow open (which would
    /// not even open it).
    ///
    /// FAIL CLOSED, AND AT NO COST: an unopenable container throws its errno
    /// and an unreadable identity throws `.unprovableLocation`, and neither
    /// strands anything, because `remove` performs the IDENTICAL open one
    /// moment later and would fail on it too. What the caller loses is
    /// nothing; what it gains is that the failure is named where the caller
    /// can attribute it.
    ///
    /// THE TWO ARMS ARE NOT EQUALLY EVIDENCED, AND THAT IS DISCLOSED RATHER
    /// THAN IMPLIED (PR #458 review — the guard census). The IDENTITY arm is
    /// load-bearing: replace its throw with `return .unbound` and
    /// `testACaptureThatCannotReadTheContainerRefusesRatherThanUnbinding`
    /// fails, because "I could not read it" would otherwise become "there is
    /// nothing to bind", which is the silently-permissive shape this whole
    /// parameter exists to prevent. The OPEN arm is SUBSUMED — measured, by
    /// replacing its throw with `return .unbound`: the full suite stays
    /// GREEN, because a container this call cannot open is a container
    /// `remove` cannot open either, and the removal then refuses with the
    /// identical `Failure(path:cause:.posix(errno))`. It stays because a
    /// capture that quietly hands back "unbound" for a failure is a lie about
    /// what happened, and because the two arms must not have to be read as
    /// one to be understood.
    ///
    /// `displayPath` is the caller's own spelling of what it is about to
    /// destroy, so the refusal names the ITEM rather than its folder — the
    /// same locator every other `Failure` in this file carries.
    static func admittedParent(
        directory url: URL, displayPath: String,
        provider: FileSystemIdentityProvider
    ) throws -> AdmittedParent {
        let fd = openContainer(at: url)
        guard fd >= 0 else {
            throw Failure(path: displayPath, cause: .posix(errno), depth: 0)
        }
        defer { close(fd) }
        guard let identity = provider.identity(ofDescriptor: fd) else {
            throw Failure(
                path: displayPath, cause: .unprovableLocation, depth: 0
            )
        }
        return .identity(identity)
    }

    /// Prove that the directory `root` names IS the object the caller's
    /// pre-delete inspection was about.
    ///
    /// `fstat` OF THE HELD DESCRIPTOR, never a re-`lstat` of the path: the
    /// path is exactly what an attacker re-points, and re-resolving it after
    /// the descriptor is held re-opens the race the descriptor closed. An
    /// identity that cannot be read is not a match — fail closed.
    private static func proveInspectedRoot(
        _ inspected: UserDataProbeResult.InspectedRoot?,
        is root: Int32,
        provider: FileSystemIdentityProvider,
        displayPath: String
    ) throws {
        // No inspection ran (contents mode): nothing to bind to. The caller
        // states this explicitly.
        guard let inspected else { return }
        // Only a `.directory` verdict about THIS inode admits an opened
        // directory: `.noDirectoryTree`, `.nonDirectoryLeaf` and
        // `.unestablished` all say a directory here is NOT the inspected
        // object, and the `guard case` refuses each of them.
        guard case .directory(let expected) = inspected,
              provider.identity(ofDescriptor: root) == expected else {
            throw Failure(
                path: displayPath, cause: .notTheInspectedObject, depth: 0
            )
        }
    }

    // MARK: - The traversal

    /// One level of the unwind: the name to `rmdir` from the level above,
    /// and the identity that level MUST still have when `..` lands on it.
    private struct Ascent {
        let name: RawName
        let parent: FileSystemIdentityProvider.Identity
    }

    /// Empty the tree `root` names depth-first, then remove `leaf` itself
    /// from `parentFd`. TAKES OWNERSHIP of `root`.
    ///
    /// Iterative on purpose: recursion would hold one descriptor per level,
    /// which is the resource bill the scanner's walk already paid to retire.
    /// Here the bill is a constant — `parentFd`, the current directory, and
    /// at most one handle in flight — at ANY depth.
    private static func removeTree(
        from root: Int32,
        named leaf: RawName, in parentFd: Int32, displayPath: String,
        provider: FileSystemIdentityProvider,
        batchLimit: Int
    ) throws {
        var current = root
        defer { if current >= 0 { close(current) } }

        // THE ROOT'S MOUNT IS JUDGED AGAINST THE PARENT, NEVER AGAINST
        // ITSELF. Taking the reference from the tree being deleted makes the
        // one case that matters most invisible: a volume attached ONTO the
        // target after the admission-time path check and before this
        // descriptor was opened (this runs on a background queue, so that
        // window is real and is not small) supplies its OWN filesystem id as
        // the baseline, every descendant then agrees with it, and the
        // traversal recursively empties somebody else's volume while
        // believing it never crossed a boundary. `removefile(3)`, which this
        // type replaces, does not cross mount points; inheriting that
        // guarantee means proving the root's mount from OUTSIDE the root.
        guard let parentMount = provider.mountIdentity(ofDescriptor: parentFd)
        else {
            throw Failure(
                path: displayPath, cause: .unprovableLocation, depth: 0
            )
        }
        guard let rootMount = provider.mountIdentity(ofDescriptor: current)
        else {
            throw Failure(
                path: displayPath, cause: .unprovableLocation, depth: 0
            )
        }
        guard rootMount == parentMount else {
            throw Failure(
                path: displayPath, cause: .mountBoundary, depth: 0
            )
        }
        // LAYER TWO, AND STATED RATHER THAN IMPLIED (PR #458 review — the
        // guard census). This arm alone is UNEVIDENCED: replacing the
        // refusal with any fallback leaves the suite green, because the
        // proof it feeds asks about the SAME inode one syscall later —
        // `proveContainment` opens `current/..`, which IS the parent, and
        // refuses `.unprovableLocation` on the identical unreadable answer.
        // What IS evidenced is the pair: deleting this arm together with the
        // proof it guards fails
        // `testRefusesWhenAnIdentityCannotBeRead` (case 1), and so does
        // breaking `proveContainment`'s own arm (case 3). It stays because
        // reading the parent's identity BEFORE opening `..` says what is
        // wrong at the level it is wrong at, and because a value the next
        // line needs should not be produced by an optional the next line
        // silently reinterprets.
        guard let parentIdentity = provider.identity(ofDescriptor: parentFd)
        else {
            throw Failure(
                path: displayPath, cause: .unprovableLocation, depth: 0
            )
        }
        // NOTE: the root's own containment proof is NOT taken here. It is
        // taken by the `destructivePass` below, immediately before the
        // enumeration it licences — one proof, at the seam that destroys,
        // rather than one here and another one there that a later edit can
        // let drift apart.

        // EVERY BOUNDARY IN THE WHOLE TREE, BEFORE THE FIRST `unlinkat`
        // (PR #458 review — the P2 the per-child check could not answer).
        // The per-child `childMount` comparison below is the guard; it is not
        // an ORDER. Reached level by level it refuses a nested volume only
        // once the traversal walks into it, which is after this level's
        // ordinary files and any subtree the `readdir` order happened to
        // reach first are already gone — measured, with a real `hdiutil`
        // volume attached one level down: `keep.bin` unlinked, then the
        // refusal, then zero bytes reported freed. The cleaner refuses such
        // an item WHOLESALE when the sizer could measure it
        // (`CacheCleaner.swift`'s two `report.mountBoundaries` gates); this
        // is the same answer for the trees it could NOT measure, which is
        // exactly the population this file exists for.
        try refuseATreeThatAlreadyContainsAMount(
            root: current, displayPath: displayPath
        )

        /// Subdirectory names not yet descended into, one BOUNDED batch per
        /// level of the CURRENT path — never the whole width of a directory
        /// and never the whole tree (`subdirectoryBatchLimit`).
        var pending: [Batch] = []
        var ascent: [Ascent] = []

        /// The identity the CURRENT directory must still be contained in.
        /// The root's is the parent descriptor's; every level below carries
        /// its own on the ascent stack.
        func containingIdentity() -> FileSystemIdentityProvider.Identity {
            ascent.last?.parent ?? parentIdentity
        }

        pending.append(
            try destructivePass(
                current, containedIn: containingIdentity(), limit: batchLimit,
                provider: provider, displayPath: displayPath, depth: 0
            )
        )

        while true {
            let depth = ascent.count
            // THE REST OF A LEVEL TOO WIDE TO HOLD AT ONCE. A refill is a
            // NEW destructive pass, taken at a NEW instant, so it is proven
            // again like any other — `destructivePass` is the only door.
            if pending[pending.count - 1].isSpent {
                pending[pending.count - 1] = try destructivePass(
                    current, containedIn: containingIdentity(),
                    limit: batchLimit, provider: provider,
                    displayPath: displayPath, depth: depth
                )
                continue
            }
            if let name = pending[pending.count - 1].names.popLast() {
                guard let identity = provider.identity(ofDescriptor: current)
                else {
                    throw Failure(
                        path: displayPath, cause: .unprovableLocation,
                        depth: depth
                    )
                }
                let child = openat(
                    current, name,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                guard child >= 0 else {
                    let code = errno
                    switch code {
                    case ENOENT:
                        // Gone since the read — nothing left to remove.
                        continue
                    case ENOTDIR, ELOOP:
                        // Replaced by a file or a symlink since the read.
                        // Remove it AS what it now is; never through it.
                        guard unlinkat(current, name, 0) == 0
                                || errno == ENOENT else {
                            throw Failure(
                                path: displayPath, cause: .posix(errno),
                                depth: depth
                            )
                        }
                        continue
                    default:
                        throw Failure(
                            path: displayPath, cause: .posix(code),
                            depth: depth
                        )
                    }
                }
                guard let childMount = provider.mountIdentity(
                    ofDescriptor: child
                ) else {
                    close(child)
                    throw Failure(
                        path: displayPath, cause: .unprovableLocation,
                        depth: depth + 1
                    )
                }
                guard childMount == rootMount else {
                    // We did not look past it and we do not delete past it —
                    // the same refusal the sizer's `mountBoundaries` check
                    // makes for trees it CAN measure (R15).
                    close(child)
                    throw Failure(
                        path: displayPath, cause: .mountBoundary,
                        depth: depth + 1
                    )
                }
                close(current)
                current = child
                ascent.append(Ascent(name: name, parent: identity))
                // The containment proof for this newly-entered level is
                // taken INSIDE `destructivePass`, immediately before the
                // enumeration that unlinks — see there for why it lives at
                // that seam and nowhere else.
                pending.append(
                    try destructivePass(
                        current, containedIn: identity, limit: batchLimit,
                        provider: provider, displayPath: displayPath,
                        depth: depth + 1
                    )
                )
                continue
            }

            // This level holds nothing but itself now.
            pending.removeLast()
            guard let step = ascent.popLast() else {
                // Back at the deletion root: remove it through the parent
                // descriptor held since the very first line.
                close(current)
                current = -1
                guard unlinkat(parentFd, leaf, AT_REMOVEDIR) == 0 else {
                    throw Failure(
                        path: displayPath, cause: .posix(errno), depth: 0
                    )
                }
                return
            }
            let up = openat(current, "..", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            close(current)
            current = up
            // LAYER TWO, AND STATED (PR #458 review — the guard census).
            // Deleting this arm leaves the suite green: `up` is then `-1`,
            // `identity(ofDescriptor: -1)` fails, and the comparison below
            // refuses `.relocated`. So the SAFETY is carried by that
            // comparison (evidenced by the three relocation tests) and this
            // arm buys the honest sentence — an ascent that could not open
            // `..` at all reports ITS errno instead of accusing the user's
            // filesystem of a rename that did not happen. Unlike its twin in
            // `proveContainment`, which
            // `testAContainmentProofThatCannotOpenDotDotKeepsItsErrno`
            // reaches with a real `chmod(2)`, this one has no seam: between
            // the proof on the way down and this open on the way up the
            // traversal asks the provider nothing, so no injectable fixture
            // can make the same directory readable then and unreadable now.
            guard up >= 0 else {
                throw Failure(
                    path: displayPath, cause: .posix(errno), depth: depth
                )
            }
            // `..` IS NOT A PROOF, it is a lookup. A directory renamed into
            // a foreign parent while we stood inside it makes `..` name that
            // foreign parent, and every remaining entry in `pending` would
            // then be unlinked THERE, by name, out of somebody else's tree.
            // Measured with a real `rename(2)` fired at this exact instant.
            guard provider.identity(ofDescriptor: up) == step.parent else {
                throw Failure(
                    path: displayPath, cause: .relocated, depth: depth - 1
                )
            }
            guard unlinkat(current, step.name, AT_REMOVEDIR) == 0
                    || errno == ENOENT else {
                throw Failure(
                    path: displayPath, cause: .posix(errno), depth: depth - 1
                )
            }
        }
    }

    /// ONE ENUMERATION PASS OVER ONE DIRECTORY, AND THE PROOF THAT LICENCES
    /// IT — in that order, at the only seam that unlinks.
    ///
    /// THE CLASS THIS SEAM CLOSES (PR #458 review): a proof taken at a
    /// distance from the destruction it authorizes is not a proof of the
    /// destruction. The traversal enters a directory, and then — a `readdir`,
    /// a refill, a whole subtree later — unlinks things in it; anything that
    /// re-runs the destruction must re-run the proof, or the second pass is
    /// running on the first pass's evidence. Making the two ONE function
    /// makes that structural instead of remembered: there is no way to reach
    /// `emptyOfNonDirectories` without `proveContainment` having just
    /// succeeded, and adding a third caller cannot forget it.
    ///
    /// AND THAT SENTENCE IS NOW TRUE OF THE TESTS TOO (PR #458 review — the
    /// P2). It was false: `emptyOfNonDirectories` was `static` rather than
    /// `private static`, and `testAnEnumerationPassStopsAtItsLimit` reached
    /// it directly — a structural claim with a live counterexample inside
    /// the same target. The enumeration is private now and THIS is the seam
    /// the test drives, so exercising the bound cannot bypass the proof that
    /// licences it.
    ///
    /// WHAT IT DOES NOT CLOSE, and this is measured, not assumed: a
    /// `rename(2)` of an ANCESTOR of this directory leaves this directory's
    /// own `..` untouched, so the proof still passes and residual #1 in the
    /// header stands (`testAncestorRelocationDestroysTheNewOwnersWholeSubtree`
    /// pins its exact scope). Closing that would mean re-walking the whole
    /// ascent chain before every enumeration — O(depth) per directory, i.e.
    /// ~8M extra `openat`/`fstat` pairs on the 4000-level chains this file
    /// exists to delete — and it would still leave the window between the
    /// walk and the `unlinkat`. POSIX has no primitive that pins a directory
    /// to its parent for the duration of a read.
    static func destructivePass(
        _ fd: Int32,
        containedIn parent: FileSystemIdentityProvider.Identity,
        limit: Int,
        provider: FileSystemIdentityProvider,
        displayPath: String,
        depth: Int
    ) throws -> Batch {
        try proveContainment(
            of: fd, in: parent, provider: provider,
            displayPath: displayPath, depth: depth
        )
        return try emptyOfNonDirectories(
            fd, limit: limit, displayPath: displayPath, depth: depth
        )
    }

    /// Prove that `directory` is STILL inside the inode we are holding, and
    /// throw if it is not — or if the question cannot be answered.
    ///
    /// The proof is containment, taken at this instant: `..` opened from the
    /// held descriptor, and its identity compared with the parent's. It is
    /// deliberately NOT a comparison against an identity recorded for
    /// `directory` itself — the descriptor keeps that identity through any
    /// number of renames, so a recorded-identity check agrees with a
    /// relocation instead of catching it.
    ///
    /// Errno classes are kept apart: a `..` that cannot be OPENED is a posix
    /// failure with its own code, while a `..` that opens but whose identity
    /// cannot be read is unprovable. Neither is treated as containment.
    private static func proveContainment(
        of directory: Int32,
        in parent: FileSystemIdentityProvider.Identity,
        provider: FileSystemIdentityProvider,
        displayPath: String,
        depth: Int
    ) throws {
        let up = openat(directory, "..", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard up >= 0 else {
            throw Failure(
                path: displayPath, cause: .posix(errno), depth: depth
            )
        }
        defer { close(up) }
        guard let here = provider.identity(ofDescriptor: up) else {
            throw Failure(
                path: displayPath, cause: .unprovableLocation, depth: depth
            )
        }
        guard here == parent else {
            throw Failure(
                path: displayPath, cause: .relocated, depth: depth
            )
        }
    }

    /// A SECOND, INDEPENDENT description of the directory `fd` names, for
    /// `fdopendir` to take ownership of.
    ///
    /// `dup(fd)` is wrong twice, both measured on this platform:
    ///
    /// - it CLEARS `FD_CLOEXEC` (`fcntl(F_GETFD)` reports 0 on the copy),
    ///   so the handle is inheritable by anything this process spawns while
    ///   a permanent deletion is in flight, and
    /// - it SHARES the file offset with `fd`, so a second enumeration of the
    ///   same directory returns 0 entries (measured: 5, then 0) — a directory
    ///   silently reported as empty is the worst possible answer for a
    ///   deleter.
    ///
    /// `openat(fd, ".", O_CLOEXEC)` has neither property (measured: 5, then
    /// 5, `FD_CLOEXEC` set), and it is the SAME shape the scanner's bounded
    /// read uses — scan-time and delete-time do not get to drift.
    static func enumerationDescriptor(for fd: Int32) -> Int32 {
        openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    }

    /// What one enumeration pass left for the traversal to descend into.
    struct Batch: Equatable {
        /// Subdirectory names, in reverse traversal order (the caller pops
        /// from the end). At most `limit` of them.
        var names: [RawName]
        /// The pass STOPPED AT THE LIMIT: this directory holds subdirectory
        /// names this batch does not carry, and possibly non-directories it
        /// did not get to unlink. The level must be enumerated again once
        /// these are spent.
        let hasMore: Bool

        /// Nothing left in hand, and more waiting on disk.
        var isSpent: Bool { names.isEmpty && hasMore }
    }

    /// Unlink every non-directory child of `fd` and return the names of the
    /// directories left behind, in reverse traversal order (the caller pops
    /// from the end) — AT MOST `limit` of them.
    ///
    /// ONE `readdir` pass per directory, and the names are kept rather than
    /// re-read: coming back up, the subdirectory just finished is gone and
    /// the rest are still in hand, so the whole traversal stays linear in
    /// entries. Re-opening and re-reading on every return is what makes a
    /// naive descriptor-relative `rm` quadratic in a wide directory.
    ///
    /// `limit` IS WHAT KEEPS THAT FROM BEING PAID IN MEMORY (PR #458 review
    /// — the P2). Held names are the deletion's only allocation that scales
    /// with the tree, and unbounded it scales with the WIDEST DIRECTORY: a
    /// pass over a directory a million entries wide holds a million
    /// heap-allocated byte arrays, and it holds them at the moment that
    /// directory's ordinary files have already been unlinked, so an
    /// out-of-memory kill lands mid-deletion rather than before it. Stopping
    /// at `limit` caps the level's cost at `limit` names.
    ///
    /// WHAT THE CAP COSTS, MEASURED. A level wider than the cap is
    /// re-enumerated, and each re-enumeration sees only what is LEFT —
    /// finished subdirectories have been `rmdir`ed and non-directories
    /// unlinked — so a directory of `W` subdirectories reads about `W²/2L`
    /// entries rather than `W`. At the shipped cap that is nothing for any
    /// real directory (`W ≤ 4096` ⇒ one pass, no re-read at all), and
    /// bounded rather than fatal above it: measured on this machine, one
    /// directory 20 000 subdirectories wide each holding one file, wall
    /// clock for the whole removal — unbounded (one pass) 2.93 s,
    /// `L = 4096` 3.20 s (+9%, four refills), `L = 64` 3.97 s (+36%),
    /// `L = 1` 8.21 s (2.8x). The knob trades a constant factor for a memory
    /// bound; it never trades correctness, and the tests drive real trees at
    /// `L = 1`.
    ///
    /// A hostile process that keeps re-filling the directory faster than the
    /// deletion empties it keeps this level going — it does not corrupt
    /// anything, and it is the same adversary that makes ANY deleter's final
    /// `rmdir` fail `ENOTEMPTY`. Progress against a passive filesystem is
    /// structural: `hasMore` is set only when `limit ≥ 1` names were
    /// collected, and every one of them is removed before the level is read
    /// again.
    ///
    /// PRIVATE, AND THE HEADER'S CLAIM DEPENDS ON IT (PR #458 review — the
    /// P2). `destructivePass` says there is no way to reach this enumeration
    /// without a fresh `proveContainment`; while this was `static` that was
    /// simply untrue inside the test target, and a comment asserting a
    /// property the code lacks is worse than no comment.
    private static func emptyOfNonDirectories(
        _ fd: Int32, limit: Int, displayPath: String, depth: Int
    ) throws -> Batch {
        // `fdopendir` takes ownership of the descriptor it is handed, and
        // the caller still needs `fd`.
        let handle = enumerationDescriptor(for: fd)
        guard handle >= 0 else {
            throw Failure(path: displayPath, cause: .posix(errno), depth: depth)
        }
        guard let stream = fdopendir(handle) else {
            let code = errno
            close(handle)
            throw Failure(path: displayPath, cause: .posix(code), depth: depth)
        }
        defer { closedir(stream) }

        var subdirectories: [RawName] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                let code = errno
                guard code == 0 else {
                    throw Failure(
                        path: displayPath, cause: .posix(code), depth: depth
                    )
                }
                break
            }
            let length = Int(entry.pointee.d_namlen)
            guard length > 0 else { continue }
            var name = RawName(repeating: 0, count: length + 1)
            withUnsafeBytes(of: entry.pointee.d_name) { raw in
                _ = name.withUnsafeMutableBytes { destination in
                    memcpy(destination.baseAddress!, raw.baseAddress!, length)
                }
            }
            if isDotEntry(name, length: length) { continue }

            let isDirectory: Bool
            switch entry.pointee.d_type {
            case UInt8(DT_DIR):
                isDirectory = true
            case UInt8(DT_UNKNOWN):
                // Not every filesystem fills `d_type` in (a userland one need
                // not), so ask — no-follow, against THIS held descriptor.
                //
                // UNEVIDENCED, AND THAT IS DISCLOSED RATHER THAN IMPLIED
                // (PR #458 review — the guard census): no filesystem the
                // tests can create returns `DT_UNKNOWN`, so deleting this
                // arm leaves the suite green — measured. Its absence is not
                // a safety hole in the destructive direction: a directory
                // classified as a leaf is handed to `unlinkat` WITHOUT
                // `AT_REMOVEDIR`, which cannot remove a directory (measured:
                // `EPERM`), so the removal would REFUSE rather than delete
                // anything unintended. What it costs is the ability to
                // delete at all on such a filesystem.
                var st = stat()
                guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
                    if errno == ENOENT { continue }
                    throw Failure(
                        path: displayPath, cause: .posix(errno), depth: depth
                    )
                }
                isDirectory = (st.st_mode & S_IFMT) == S_IFDIR
            default:
                isDirectory = false
            }

            if isDirectory {
                subdirectories.append(name)
                // THE BOUND, TAKEN THE MOMENT IT IS REACHED — not after the
                // append that would exceed it. Everything still unread stays
                // on disk, where it costs nothing, and the caller comes back
                // for it.
                if subdirectories.count >= max(1, limit) {
                    return Batch(names: subdirectories, hasMore: true)
                }
            } else if unlinkat(fd, name, 0) != 0, errno != ENOENT {
                throw Failure(
                    path: displayPath, cause: .posix(errno), depth: depth
                )
            }
        }
        return Batch(names: subdirectories, hasMore: false)
    }

    // MARK: - Mount boundaries, ANYWHERE in the tree, BEFORE the first unlink

    /// Refuse if any filesystem is mounted strictly inside the tree `root`
    /// names — asked ONCE, of the kernel's own mount table, before a single
    /// entry is unlinked.
    ///
    /// WHY A TABLE LOOKUP AND NOT A SECOND DESCRIPTOR WALK. The question is
    /// "does this tree contain a boundary anywhere", and the kernel already
    /// holds the answer as a list of a few dozen mount points; a
    /// non-destructive pre-walk would answer it by reading every directory
    /// in the tree twice AND would have to remember every name it had
    /// already visited — the unbounded allocation the batch limit exists to
    /// prevent, reintroduced by the fix for the boundary ordering.
    ///
    /// THE PATH IS DERIVED FROM THE HELD DESCRIPTOR (`F_GETPATH`), never
    /// re-resolved from the caller's spelling: the kernel spells both sides
    /// canonically (measured: `/var/folders/…` comes back
    /// `/private/var/folders/…`), so the comparison is between two of the
    /// kernel's own answers rather than between a guess and an answer.
    ///
    /// THIS IS AN ORDERING GUARANTEE, NOT THE BOUNDARY GUARD. The guard is
    /// the per-child `mountIdentity` comparison in the traversal, which is
    /// taken from held descriptors, cannot be fooled by a spelling, and
    /// still refuses a volume attached DURING the deletion. So when this
    /// preflight cannot answer — `F_GETPATH` failing on a root whose
    /// canonical path does not fit `PATH_MAX`, a mount table that cannot be
    /// read — it says nothing and lets the traversal proceed under the
    /// guard that was always there, rather than refusing a deletion for a
    /// question that is not about safety. Fail-closed here would strand
    /// exactly the over-`PATH_MAX` trees this file exists to delete, with a
    /// re-scan remedy that could never clear it.
    private static func refuseATreeThatAlreadyContainsAMount(
        root: Int32, displayPath: String
    ) throws {
        guard let rootPath = canonicalPath(of: root) else { return }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        var shallowest: String?
        for mountPoint in mountPoints() where mountPoint.hasPrefix(prefix) {
            if shallowest == nil
                || mountPoint.utf8.count < shallowest!.utf8.count {
                shallowest = mountPoint
            }
        }
        guard let shallowest else { return }
        // Levels below the target, the same locator every other refusal in
        // this file uses — the two paths are both canonical, so this is a
        // count of real components and not an estimate.
        let depth = shallowest.split(separator: "/").count
            - rootPath.split(separator: "/").count
        throw Failure(
            path: displayPath, cause: .mountBoundary, depth: max(1, depth)
        )
    }

    /// The canonical path of a HELD descriptor, from the kernel.
    static func canonicalPath(of fd: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard fcntl(fd, F_GETPATH, &buffer) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// Every mount point on this machine, as the kernel spells it.
    ///
    /// `getfsstat` with a buffer of our own rather than `getmntinfo`, which
    /// returns a pointer to a STATIC buffer: permanent deletions run on a
    /// background queue and more than one can be in flight.
    static func mountPoints() -> [String] {
        let needed = getfsstat(nil, 0, MNT_NOWAIT)
        guard needed > 0 else { return [] }
        // Room for filesystems mounted between the two calls; anything past
        // it is simply not seen by THIS preflight, and the per-child guard
        // still refuses it.
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

    /// `.` and `..` by BYTES — the two names the traversal must never take.
    private static func isDotEntry(_ name: RawName, length: Int) -> Bool {
        let dot = CChar(bitPattern: UInt8(ascii: "."))
        if length == 1 { return name[0] == dot }
        if length == 2 { return name[0] == dot && name[1] == dot }
        return false
    }
}
