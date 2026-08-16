//  TrashDisposal.swift
//  The Trash arm of the inspection binding — the disposal the GUI DEFAULTS
//  to (`CacheoutViewModel.moveToTrash = true`).
//
//  WHY THIS EXISTS (PR #458 review — the P1 the permanent-delete fix left
//  open). Threading `UserDataProbeResult.InspectedRoot` into
//  `DepthSafeRemoval.remove(at:expecting:provider:)` closed the swap window on
//  the PERMANENT arm, where the deletion holds a descriptor and can simply ask
//  it who it is. `moveToTrash` never went through that code at all: it called
//  `trashItem` with the target's URL, behind nothing but the layer-two `lstat`
//  a fixture already beats. Measured on this branch, through the production
//  runtime, with `moveToTrash: true` and the same swap fixture the permanent
//  arm uses (`testTrashDisposalOfATargetReplacedAfterTheFinalPathCheckIsRefused`):
//  the replacement's `Photos Library.photoslibrary` was moved to the Trash and
//  the report read `entries=1, exactBytes=4096, errors=[]` — the byte count of
//  the OTHER tree, the one still sitting at the stash path.
//
//  THE BINDING CANNOT BE CARRIED INTO `trashItem`, AND THAT IS STATED RATHER
//  THAN PAPERED OVER. `FileManager.trashItem(at:resultingItemURL:)` takes a
//  URL and resolves it INSIDE itself; there is no `ftrashItem`, no
//  descriptor-taking Trash primitive anywhere in Foundation, CoreServices or
//  POSIX, and no way to pin a name to an inode for the duration of a call. So
//  a proof taken before the call is exactly that — before the call.
//
//  What closes the OUTCOME instead is the one property this disposal has and
//  the permanent one does not: IT IS REVERSIBLE BY CONSTRUCTION. Moving to the
//  Trash destroys nothing. So the proof is taken TWICE, and the second one is
//  taken where it can still be acted on:
//
//  1. BEFORE — `open(O_DIRECTORY|O_NOFOLLOW)` of the target and `fstat` of
//     THAT descriptor, not an `lstat` of the path. The kind gate is the open,
//     so there is no window between deciding what stands there and holding it,
//     and the identity is read from the object rather than from a second
//     resolution of a name. This refuses the ordinary case without disturbing
//     the user's Trash at all.
//  2. AFTER — the disposal reports WHERE IT PUT THE ITEM, and that object's
//     identity is compared with the inspection's. A mismatch means the Trash
//     took something nobody inspected, so it is PUT BACK
//     (`renamex_np(RENAME_EXCL)`, which never clobbers whatever now stands at
//     the name) and the item is reported as a refusal: no entry, no bytes.
//
//  THE RESIDUAL, WITH ITS ENDPOINTS AND ITS SIZE MEASURED — not "a syscall
//  wide", which is what an unmeasured version of this note would have claimed
//  and which is false.
//
//  The window OPENS at (1)'s `fstat` and CLOSES when `trashItem` resolves the
//  URL inside itself. Only the first part of it can be timed from out here,
//  and it is timed: through the production cleaner, from the pre-proof's
//  question about the opened inode to the instant the disposal seam is
//  entered, printed by
//  `testATrashDisposalThatTookTheWrongObjectPutsItBackAndRefuses` as
//  `MEASURED-TRASH-WINDOW-NS`.
//
//  AND IT HAS NO UPPER BOUND, which an earlier version of this note quoted a
//  five-sample idle range as if it did. That prefix is an `@MainActor` HOP —
//  `trashItem` talks to Finder — so its width is a SCHEDULING DELAY, not a
//  syscall cost, and scheduling delays do not have maxima. Measured both
//  ways, 12 runs each, same machine, same fixture:
//
//      quiet:     min 21.5 µs   median 24.8 µs   p90 35.5 µs   max 41.2 µs
//      contended: min 23.7 µs   median 59.7 µs   p90 297 µs    max 1382 µs
//
//  (contended = 2×`hw.ncpu` spinners; an incidental sample taken while a
//  parallel `swift build` was running read 5.60 ms — 170× the quiet max.)
//
//  The REST of the window is inside `trashItem`, and its scale is the reason
//  this file exists. Measured on this machine, on the real home volume: one
//  `trashItem` call of a 4 KiB directory takes 262 µs (min) / 288 µs (median)
//  / 456 µs (max) over nine calls, while the ONE syscall that defeats it —
//  `renamex_np(RENAME_SWAP)` of two directories, the atomic form of the
//  fixture's `rename(2)` + `mkdir(2)` — takes 61 µs (min) / 69–83 µs (median)
//  on the same volume. So the swap fits several times over inside the call
//  that follows the prefix, and on a BUSY machine it fits inside the prefix
//  as well. Narrowing the prefix therefore buys nothing, which is precisely
//  why the load-bearing proof here is the one taken AFTER the disposal: the
//  window stays open — unboundedly so — and stops deciding the outcome.
//
//  WHAT REMAINS AFTER THE PUT-BACK, HONESTLY: the wrongly-taken item is in the
//  Trash for the width of one `renamex_np`, and if the put-back cannot be
//  performed — something else already occupies the original name — it STAYS in
//  the Trash and the error says so by path. Recoverable in one drag, never
//  destroyed, and never reported as freed.
//
//  AND THE PUT-BACK NEEDS A BINDING OF ITS OWN (PR #458 review — the P2 on
//  this very fix). The rollback is not a read. It MOVES an object INTO the
//  user's cache tree, which makes it the same kind of destructive call as the
//  disposal it is undoing, and it was written as `renamex_np(landed, target)`
//  — two PATHS, re-resolved, binding nothing. A Finder "Put Back" of the real
//  item between the failed proof and the rollback vacates `landed`; any other
//  Trash entry arriving at that name is then what gets moved into
//  `~/Library/Caches`, while the wrongly-taken tree stays in the Trash under a
//  name the error never mentions and the report says `.putBack` — a recovery
//  that did not happen. Measured on this branch through the production
//  cleaner (`testAPutBackWillNotMoveAnObjectItNeverSawTheTrashTake`).
//
//  So the rollback carries the SIGHTING the proof took, and asks the same two
//  questions the disposal does, on the same two sides:
//
//  * BEFORE — the Trash directory is held by DESCRIPTOR and the name is
//    re-bound under it (`fstatat`, via `probeChild`) to the identity the proof
//    actually looked at. An identity that does not match is not moved at all.
//  * AFTER — `renameatx_np(RENAME_EXCL)` returning 0 says A NAME MOVED, not
//    that OUR object did, so the arrival is proved under the held destination
//    descriptor before `.putBack` is reported.
//
//  AND THE DESTINATION IS PROVED AGAINST SOMETHING OUTSIDE ITSELF (PR #458
//  review — the P2 on the P2). Holding the put-back's destination directory
//  by descriptor is not the same as knowing WHICH directory it is: the
//  descriptor was opened from a path, across the whole disposal, and never
//  interrogated. A container swap in that window aims the undo at a
//  stranger's directory — and the arrival proof above, taken under that SAME
//  unproven descriptor, then CONFIRMS the arrival and reports `.putBack` for
//  a restore into somebody else's folder. Self-confirmation is not proof, so
//  the rollback now compares that descriptor's `fstat` with the admitted
//  container identity the cleaner captured BEFORE the disposal
//  (`DepthSafeRemoval.admittedParent`), and moves nothing when they disagree
//  — `.destinationNotTheAdmittedContainer`, item still in the Trash, nothing
//  reported freed. Evidenced by
//  `testAPutBackWillNotRestoreIntoAContainerItCannotProve`.
//
//  The descriptors are what make the re-bind and the rename talk about the
//  same directory, and that is EVIDENCED rather than asserted: spell the
//  rename `renamex_np(landed.path, target.path)` and
//  `testAPutBackFollowsTheTrashDirectoryItCheckedNotItsName` goes red,
//  because re-pointing the Trash DIRECTORY between the two sends a
//  path-spelled rename into a different directory to move whatever answers
//  to the same leaf.
//
//  THE RESIDUAL OF THE ROLLBACK, NAMED AND MEASURED — not called narrow and
//  left at that. Between that `fstatat` and the `renameatx_np` the name can
//  still be re-pointed inside the pinned directory, and it is NOT closable:
//  macOS has no rename that takes its SOURCE as a descriptor (`renameatx_np`
//  takes a directory descriptor and a NAME).
//
//  Its width, on this machine and on the real home volume, 25 pairs per run
//  over three runs: from the `fstatat` returning to the `renameatx_np`
//  RETURNING — which OVER-states it, because the true close is the kernel's
//  own lookup of the source name partway through that call — 32.6 / 32.6 /
//  32.7 µs (min), 37.6 / 37.8 / 38.1 µs (median). The `renamex_np(RENAME_SWAP)`
//  that defeats it costs 44.3 / 44.4 / 45.2 µs (min) on the same volume.
//
//  THAT COMPARISON IS NOT A SAFETY ARGUMENT AND IS NOT OFFERED AS ONE — an
//  attacker's swap can already be in flight. It is offered because the
//  numbers are the reason the outcome is not left resting on the race: the
//  window is exercised
//  (`testAPutBackThatMovedSomethingElseSaysSoRatherThanClaimingRecovery`) and
//  the after-proof turns losing it into an honest report — the item is
//  refused, the bytes are not reported, and the error says plainly that what
//  now stands at the cache path came out of the Trash.

import Foundation

/// Trash disposal that proves WHICH OBJECT it disposed of.
///
/// Used only where an inspection verdict exists to bind to (the sweep's
/// `automaticCleanEligible` items). Where none does, the cleaner calls the
/// seam directly and says so at the call site.
enum TrashDisposal {

    /// Why a Trash disposal was refused AFTER the fact — the causes that
    /// exist only because the disposal cannot be given a descriptor.
    ///
    /// THE FOUR ROLLBACK CAUSES ARE FOUR DIFFERENT PROOFS, not one outcome
    /// with adjectives (PR #458 review — the P2). Each says exactly what was
    /// established: that the object is back, that it is still in the Trash,
    /// that it is no longer where the Trash said, or that the rollback moved
    /// something else. Collapsing them is how `.putBack` came to be reported
    /// for a recovery nobody had verified.
    struct Failure: LocalizedError {
        enum Cause: Equatable {
            /// PROVED: the object the Trash took is not the inspected one,
            /// and it now stands at the original name again — the arrival
            /// was identified under the held destination descriptor.
            case putBack
            /// PROVED: the object was still at `landed` when the rollback
            /// re-bound it, and the move itself could not be performed
            /// (typically the original name is occupied again). The payload
            /// is where the item is, so the user can finish it in one drag.
            case strandedInTrash(String)
            /// NOT PROVED, so NOTHING WAS MOVED: the object the disposal took
            /// is no longer at the name the disposal reported (it was moved,
            /// replaced, or cannot be read). The payload is the last place it
            /// was seen. Moving whatever took its place is the bug, not the
            /// undo.
            case lastSeenInTrash(String)
            /// The rollback moved an object out of the Trash and the arrival
            /// is NOT the one it looked at — the name was re-pointed inside
            /// the one-syscall window the Trash directory descriptor cannot
            /// close. The payload is the Trash name it came from. Nothing
            /// further is attempted: a second unproven move is not a fix.
            case putBackTookAnotherObject(String)
            /// NOT PROVED, so NOTHING WAS MOVED: the directory the put-back
            /// would restore INTO is not the container the caller admitted.
            /// The payload is where the item still is. A separate cause from
            /// `strandedInTrash` for the same reason
            /// `DepthSafeRemoval.Failure.Cause` separates its two: the item
            /// is fine and something happened to the FOLDER THAT HOLDS IT,
            /// which is the thing the user has to go and look at.
            case destinationNotTheAdmittedContainer(String)
            /// The disposal would not say where it put the item, so what it
            /// took cannot be established at all.
            case destinationUnknown
        }

        let path: String
        let cause: Cause

        var errorDescription: String? {
            switch cause {
            case .putBack:
                // Deliberately opens with the SAME clause the pre-delete
                // checks produce: to the user this is one event, and the only
                // new information is that it was undone.
                return "\(path): the folder at this path is no longer the one "
                    + "that was inspected — it was replaced between the safety "
                    + "check and the disposal, so the item the Trash took has "
                    + "been PUT BACK. Nothing was moved to the Trash and "
                    + "nothing was freed; refused, re-scan required"
            case .strandedInTrash(let landed):
                return "\(path): the folder at this path is no longer the one "
                    + "that was inspected, and what the Trash took could not "
                    + "be put back automatically — it is in the Trash at "
                    + "\(landed). Move it back from there; nothing was "
                    + "reported freed; refused, re-scan required"
            case .lastSeenInTrash(let landed):
                return "\(path): the folder at this path is no longer the one "
                    + "that was inspected, and what the Trash took could not "
                    + "be put back — it is no longer at \(landed), where the "
                    + "Trash reported putting it, so nothing was moved rather "
                    + "than moving whatever took its place. Look in the Trash "
                    + "for it; nothing was reported freed; refused, re-scan "
                    + "required"
            case .putBackTookAnotherObject(let landed):
                return "\(path): the folder at this path is no longer the one "
                    + "that was inspected, and putting back what the Trash "
                    + "took moved a DIFFERENT object — the Trash name it came "
                    + "from (\(landed)) was re-used while the undo was "
                    + "running. Whatever now stands at \(path) came out of "
                    + "the Trash and was NOT put there by you, and the item "
                    + "the Trash took is still in the Trash; nothing was "
                    + "reported freed; refused, re-scan required"
            case .destinationNotTheAdmittedContainer(let landed):
                return "\(path): the folder at this path is no longer the one "
                    + "that was inspected, and the folder that HOLDS it is no "
                    + "longer the one the safety check admitted either — so "
                    + "what the Trash took was NOT put back into it. It is in "
                    + "the Trash at \(landed). Move it back once the folder "
                    + "at \(path) is the one you expect; nothing was reported "
                    + "freed; refused, re-scan required"
            case .destinationUnknown:
                return "\(path): the Trash did not report where it put the "
                    + "item, so which folder it took cannot be established — "
                    + "nothing was reported freed. Check the Trash, and use "
                    + "permanent delete (turn off Move to Trash) for a "
                    + "disposal that proves the folder it acts on"
            }
        }
    }

    /// Move `target` to the Trash through `disposal`, proving on BOTH sides of
    /// it that the object disposed of is the one `inspected` is a verdict
    /// about.
    ///
    /// Throws — and nothing is left in the Trash — when the proof fails on
    /// either side, except in the disclosed cases where the put-back itself
    /// cannot be performed or cannot be proved, each of which names where the
    /// item was last seen.
    ///
    /// `containedIn` is the caller's admitted container, and it is what the
    /// ROLLBACK's destination is proved against — see `rollBack`. It has NO
    /// DEFAULT, the same rule `DepthSafeRemoval.remove` follows: a default
    /// would make a caller that supplies nothing silently restore into an
    /// unproven directory instead of failing to compile.
    static func dispose(
        _ target: URL,
        expecting inspected: UserDataProbeResult.InspectedRoot,
        provider: FileSystemIdentityProvider,
        containedIn admittedParent: DepthSafeRemoval.AdmittedParent,
        via disposal: (URL) async throws -> URL?
    ) async throws {
        // (1) The cheap refusal, and the one that keeps the Trash untouched.
        try proveStanding(inspected, at: target, provider: provider)

        let landed = try await disposal(target)

        // (2) The disposal happened. From here on the question is not "may we
        // proceed" but "what did it actually take", and every unprovable
        // answer is undone rather than reported.
        guard let landed else {
            throw Failure(path: target.path, cause: .destinationUnknown)
        }
        // THE SIGHTING IS KEPT, NOT JUST JUDGED (PR #458 review — the P2).
        // The rollback below moves an object into the user's cache tree, so
        // it needs to know WHICH object the proof looked at. A `throws`-only
        // proof discards exactly that and leaves the undo to re-resolve a
        // path — which is the defect it is undoing, one layer down.
        let sighting = look(at: landed, provider: provider)
        guard disagreement(inspected, with: sighting, absenceProves: false)
                == nil
        else {
            throw Failure(
                path: target.path,
                cause: rollBack(
                    sighting, from: landed, to: target,
                    containedIn: admittedParent, provider: provider
                )
            )
        }
    }

    // MARK: - The proofs

    /// BEFORE the disposal: does the inspected object still stand at `url`?
    ///
    /// An ABSENCE is consistent with a `.noDirectoryTree` verdict here — that
    /// verdict is precisely a statement that no directory tree of ours was at
    /// this name, and a target that is gone entirely still satisfies it. The
    /// disposal then fails with its own ENOENT, which is the frozen
    /// ghost-target behaviour (an item-keyed error, never a silent skip).
    static func proveStanding(
        _ inspected: UserDataProbeResult.InspectedRoot,
        at url: URL, provider: FileSystemIdentityProvider
    ) throws {
        try prove(inspected, at: url, provider: provider, absenceProves: true)
    }

    /// AFTER the disposal: is the object that landed the inspected one?
    ///
    /// An ABSENCE proves NOTHING here. The disposal said it put an item at
    /// this URL; if nothing is there, what it took cannot be established, and
    /// unestablished is refused (the rollback then has nothing it may move,
    /// and the caller reports `.lastSeenInTrash` — the honest answer, because
    /// the item is somewhere we cannot name).
    static func proveTaken(
        _ inspected: UserDataProbeResult.InspectedRoot,
        at url: URL, provider: FileSystemIdentityProvider
    ) throws {
        try prove(inspected, at: url, provider: provider, absenceProves: false)
    }

    /// The `throws` face of `look` + `disagreement`, for the call sites that
    /// only need the verdict. `dispose` uses the two halves directly, because
    /// its rollback needs the SIGHTING and not merely the verdict.
    private static func prove(
        _ inspected: UserDataProbeResult.InspectedRoot,
        at url: URL, provider: FileSystemIdentityProvider,
        absenceProves: Bool
    ) throws {
        if let cause = disagreement(
            inspected, with: look(at: url, provider: provider),
            absenceProves: absenceProves
        ) {
            throw DepthSafeRemoval.Failure(
                path: url.path, cause: cause, depth: 0
            )
        }
    }

    /// WHAT ONE LOOK AT A NAME SAW — the evidence, before anyone judges it.
    ///
    /// Kept as a value rather than folded into a `throws` because two callers
    /// need two different things from the same look: `prove` needs the
    /// verdict, and the rollback needs the IDENTITY, so that the object it
    /// moves is the object the proof rejected rather than whatever answers to
    /// the name a moment later.
    enum Sighting: Equatable {
        /// A directory was OPENED here, and this is its `fstat` identity.
        case directory(FileSystemIdentityProvider.Identity)
        /// Nothing is here at all (ENOENT).
        case absent
        /// Something is here and it is NOT a directory tree of ours — a
        /// regular file, a symlink (never followed), a fifo, a device.
        case noDirectoryTree
        /// A directory was opened but would not say who it is.
        case unidentifiable
        /// The look itself failed (EACCES, EIO, …). Unprovable, never
        /// admitted, and never a licence to move anything.
        case unreadable(errno: Int32)
    }

    /// THE KIND GATE **IS** THE OPEN, and the identity comes off the OPENED
    /// INODE — the same shape `DepthSafeRemoval.remove` uses, for the same
    /// reason: a gate beside an open is a swap window by construction, and an
    /// `lstat` of a path is a second resolution of a name anyone can re-point.
    static func look(
        at url: URL, provider: FileSystemIdentityProvider
    ) -> Sighting {
        // The errno is READ INSIDE the closure, next to the call that set it
        // — the same discipline as
        // `FileSystemIdentityProvider.openChildDirectoryCarryingErrno`.
        // Anything at all between the `open` and a later `errno` read may
        // clobber the global, and this one decides whether the object is
        // absent, not-a-tree, or merely unreadable.
        var code: Int32 = 0
        let fd = url.path.withCString { path -> Int32 in
            let descriptor = open(
                path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            if descriptor < 0 { code = errno }
            return descriptor
        }
        guard fd >= 0 else {
            switch code {
            case ENOENT: return .absent
            // ENOTDIR/ELOOP: something that is NOT a directory tree stands
            // here. That is exactly what `.noDirectoryTree` is about.
            case ENOTDIR, ELOOP: return .noDirectoryTree
            default: return .unreadable(errno: code)
            }
        }
        defer { close(fd) }
        guard let identity = provider.identity(ofDescriptor: fd) else {
            return .unidentifiable
        }
        return .directory(identity)
    }

    /// Why `sighting` does NOT satisfy `inspected` — `nil` when it does.
    ///
    /// The refusal is `DepthSafeRemoval.Failure.Cause` on purpose, not a
    /// private twin: the user is told the same thing whichever disposal they
    /// chose, and the cleaner's log keeps classifying it under the one
    /// `content-drift` tag.
    ///
    /// `absenceProves` is the ONE asymmetry between the two sides of the
    /// disposal, and it is a parameter rather than a second copy of this
    /// function so the two can never drift apart.
    ///
    /// THE ONE PLACE THE TWO REPRESENTATIONS MEET. `Sighting` already keeps
    /// `.absent` and `.noDirectoryTree` apart, because the rollback needs to
    /// know whether there was anything there at all; `InspectedRoot` folds
    /// them into one case today, and `absenceProves` is how that fold is
    /// unfolded per side. If the verdict type ever splits them for real, this
    /// function is the whole of the change — no other site in this file looks
    /// at either enum.
    static func disagreement(
        _ inspected: UserDataProbeResult.InspectedRoot,
        with sighting: Sighting, absenceProves: Bool
    ) -> DepthSafeRemoval.Failure.Cause? {
        switch sighting {
        case .directory(let seen):
            // Only a `.directory` verdict about THIS inode admits it;
            // `.noDirectoryTree` and `.unestablished` are refusals.
            guard case .directory(let expected) = inspected, seen == expected
            else { return .notTheInspectedObject }
            return nil
        case .noDirectoryTree:
            guard case .noDirectoryTree = inspected else {
                return .notTheInspectedObject
            }
            return nil
        case .absent:
            guard absenceProves, case .noDirectoryTree = inspected else {
                return .notTheInspectedObject
            }
            return nil
        case .unidentifiable:
            return .notTheInspectedObject
        case .unreadable(let code):
            // Unprovable is refused, never admitted — and the errno is kept,
            // because "we could not look" is a different fact from "it is not
            // the object", and only one of them clears on a re-scan.
            return .posix(code)
        }
    }

    // MARK: - Undo

    /// Move the object `sighting` saw at `landed` back to `target`, or refuse
    /// and say why — never move an object nobody looked at.
    ///
    /// The two proofs, and what each one buys:
    ///
    /// * The Trash directory and the destination directory are HELD BY
    ///   DESCRIPTOR, and the re-bind (`fstatat`, through `probeChild`) and
    ///   the move (`renameatx_np`) both go through those descriptors. An
    ///   `fstatat` under one dirfd followed by a rename through a re-resolved
    ///   PATH would be a check of a different thing.
    /// * `RENAME_EXCL` is enforced by the KERNEL in the same call that moves,
    ///   so an undo cannot destroy something that appeared at the target's
    ///   name while we were in the Trash. `FileManager.moveItem` checks the
    ///   destination first and then renames — two operations, and the second
    ///   one clobbers.
    /// * The ARRIVAL is proved, because a rename returning 0 says a name
    ///   moved, not that OUR object did.
    /// * The DESTINATION DIRECTORY is proved against the caller's admitted
    ///   container, which is a fact from OUTSIDE it (PR #458 review — the
    ///   P2 on this fix). The destination was held by descriptor and never
    ///   PROVED: a container swap in that window put a stranger's directory
    ///   at the cache path, the undo moved the user's tree into it, and the
    ///   arrival proof — taken under that same unproven descriptor — agreed,
    ///   so `.putBack` was reported for a restore into somebody else's
    ///   folder. A descriptor cannot vouch for itself; the identity the
    ///   cleaner captured before the disposal can.
    private static func rollBack(
        _ sighting: Sighting, from landed: URL, to target: URL,
        containedIn admittedParent: DepthSafeRemoval.AdmittedParent,
        provider: FileSystemIdentityProvider
    ) -> Failure.Cause {
        // NOTHING IDENTIFIED, NOTHING MOVED. An absent, unreadable or
        // unidentifiable landing means the object the disposal took cannot be
        // named, and an undo that moves an unnamed object is the bug.
        //
        // NOT AN INDEPENDENTLY-EVIDENCED GUARD, AND SAID SO: it is the
        // extraction of the value everything below binds to, and it is
        // SUBSUMED by the re-bind — measured, by substituting an identity
        // that can never match instead of removing it, which leaves the whole
        // trash suite GREEN because the re-bind refuses on its own. Its
        // partner (the `probeChild` comparison below) carries the refusal;
        // this arm buys two `open` calls and a cause that names the right
        // fact.
        guard case .directory(let observed) = sighting else {
            return .lastSeenInTrash(landed.path)
        }
        let source = landed.lastPathComponent
        let destination = target.lastPathComponent
        // A PRECONDITION, DISCLOSED AS ONE RATHER THAN DRESSED AS A GUARD.
        // `probeChild`/`renameatx_np` take a SINGLE component and resolve a
        // multi-component one through the held directory, which would let a
        // symlinked middle component out of it. No production URL reaching
        // here can violate that (`landed` comes from `trashItem`, `target`
        // from an admitted item), so no test FAILS when this is deleted —
        // it is the same precondition `FileSystemIdentityProvider` documents
        // on both primitives, restated where they are called.
        guard FileSystemIdentityProvider.isSafeComponent(source),
              FileSystemIdentityProvider.isSafeComponent(destination)
        else { return .lastSeenInTrash(landed.path) }

        let trashFD = provider.openDirectoryNoFollow(
            at: landed.deletingLastPathComponent()
        )
        guard trashFD >= 0 else { return .lastSeenInTrash(landed.path) }
        defer { close(trashFD) }
        let containerFD = provider.openDirectoryNoFollow(
            at: target.deletingLastPathComponent()
        )
        guard containerFD >= 0 else { return .lastSeenInTrash(landed.path) }
        defer { close(containerFD) }

        let bound = FileSystemIdentityProvider.ChildProbe.facts(
            .init(kind: .directory, identity: observed)
        )
        guard provider.probeChild(
            inDirectory: trashFD, named: source, logical: landed
        ) == bound else {
            return .lastSeenInTrash(landed.path)
        }

        // WHOSE FOLDER ARE WE RESTORING INTO? Asked of the HELD DESTINATION
        // INODE, against a fact taken OUTSIDE it — the identity the cleaner
        // captured before the disposal. `containerFD` was held across the
        // whole disposal and never interrogated, so a container swap in that
        // window aimed the undo at a stranger's directory; and the arrival
        // proof below runs under THIS SAME descriptor, so it confirmed the
        // move rather than catching it. A descriptor cannot be its own
        // reference point.
        //
        // Taken AFTER the re-bind on purpose: by here the object is known to
        // still be at `landed`, which is exactly what the refusal tells the
        // user to go and get. Comparing an `fstat` of this descriptor with an
        // identity captured through `DepthSafeRemoval.admittedParent` is
        // apples to apples — both are `fstat`s of a following open, and
        // reaching this line at all means `openDirectoryNoFollow` succeeded,
        // i.e. the container's last component is a real directory and not a
        // link the two opens could disagree about.
        if case .identity(let expected) = admittedParent {
            guard provider.identity(ofDescriptor: containerFD) == expected
            else {
                return .destinationNotTheAdmittedContainer(landed.path)
            }
        }

        var failure: Int32 = 0
        let moved = source.withCString { from in
            destination.withCString { to in
                if renameatx_np(
                    trashFD, from, containerFD, to, UInt32(RENAME_EXCL)
                ) == 0 { return true }
                failure = errno
                return false
            }
        }
        guard moved else {
            // ERRNO CLASSES, NOT ONE OUTCOME. ENOENT means the source went
            // away between the re-bind and the rename, so the item is NOT
            // where this would otherwise claim; every other failure
            // (EEXIST/ENOTEMPTY from `RENAME_EXCL`, EACCES, EROFS, EXDEV)
            // leaves the source exactly where it was, which is a fact worth
            // telling the user by path.
            return failure == ENOENT
                ? .lastSeenInTrash(landed.path)
                : .strandedInTrash(landed.path)
        }
        guard provider.probeChild(
            inDirectory: containerFD, named: destination, logical: target
        ) == bound else {
            return .putBackTookAnotherObject(landed.path)
        }
        return .putBack
    }
}
