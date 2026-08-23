//  TrashDisposal.swift
//  The Trash arm's bindings — the disposal the GUI DEFAULTS to
//  (`CacheoutViewModel.moveToTrash = true`).
//
//  IT HAS TWO ENTRY POINTS BECAUSE THE PRODUCT HAS TWO POPULATIONS, AND FOR
//  THREE REVIEW ROUNDS ONLY ONE OF THEM WAS COVERED. Read this before
//  believing anything below it:
//
//  * `dispose(_:expecting:provider:containedIn:via:)` binds the LEAF to a
//    scanner's `PreDeleteRevalidator` verdict. Reachable only for items whose
//    scanner registers one.
//  * `dispose(_:containedIn:provider:via:)` binds the leaf to what stood at
//    its name INSIDE THE ADMITTED CONTAINER. This is the arm for everything
//    else — ALL of contents mode (it runs no probe) and every item whose
//    revalidator yields `.unestablished`.
//
//  Until the round that added the second one, that whole second population
//  went from `CacheCleaner` straight to the seam with a BARE URL, and this
//  header said the Trash arm was bound. It said so because the fix it
//  described was real and the population it did not cover was never named.
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
//  AND THE SAME MEASUREMENT, ON THE POPULATION THIS FILE DID NOT REACH (PR
//  #458 review — the P1 that survived three rounds). Same production cleaner,
//  same `moveToTrash: true`, two real `rename(2)`s at the seam:
//
//    item mode, `.unestablished`  stranger's `artifacts` moved to the Trash,
//                                 entries=[exactBytes: 4096, .trash],
//                                 errors=[]
//    contents mode                identical, on the stranger's `entry`
//    swap INSIDE the seam         stranger's tree LEFT in the Trash and its
//                                 bytes reported freed — no put-back, because
//                                 there was nothing to prove against
//
//  Pinned by `CacheCleanerTests.testTrashMode…` (three cases). The container
//  binding was sitting in the caller for both of those arms and neither used
//  it; see `dispose(_:containedIn:provider:via:)` for what carries it now.
//
//  THE BINDING CANNOT BE CARRIED INTO `trashItem`, AND THAT IS STATED RATHER
//  THAN PAPERED OVER. `FileManager.trashItem(at:resultingItemURL:)` takes a
//  URL and resolves it INSIDE itself; there is no `ftrashItem`, no
//  descriptor-taking Trash primitive anywhere in Foundation, CoreServices or
//  POSIX, and no way to pin a name to an inode for the duration of a call. So
//  a proof taken before the call is exactly that — before the call.
//
//  WHAT THAT DOES *NOT* EXCUSE, AND WAS READ AS EXCUSING FOR THREE ROUNDS.
//  "The binding cannot reach inside the API" is a fact about `trashItem`; it
//  is not a reason to hand the API a URL with NOTHING established about the
//  object at that name. The two are different claims, and the call sites that
//  bypassed this file entirely were justified by the first while relying on
//  the second. A binding that stops one call short of the destructive act is
//  the defect, not the API's shape.
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
//     the user's Trash at all. (The container-bound arm asks the same question
//     one step further in: it opens and PROVES the container first, and reads
//     the leaf under that descriptor with one `fstatat`, which additionally
//     identifies non-directory leaves — see that arm for why that matters.)
//  2. AFTER — the disposal reports WHERE IT PUT THE ITEM, and that object's
//     identity is compared with the inspection's. A mismatch means the Trash
//     took something nobody inspected, so it is PUT BACK
//     (`renamex_np(RENAME_EXCL)`, which never clobbers whatever now stands at
//     the name) and the item is reported as a refusal: no entry, no bytes.
//
//  AND THE AFTER-PROOF HAS TO WORK WHERE THE ITEM ACTUALLY LANDS, WHICH IS A
//  DIRECTORY THIS PROCESS MAY NOT OPEN (PR #460 codex r10, D1). `~/.Trash` is
//  TCC-protected: measured on this machine (Darwin 25.5) from an ordinary CLI
//  process, `open("/Users/<u>/.Trash", O_RDONLY|O_DIRECTORY|O_NOFOLLOW)`
//  returns -1 with errno 1 (EPERM) — while `lstat` and `open` of
//  `~/.Trash/<name>`, the item this process just moved there, both SUCCEED.
//  Full Disk Access is the switch, and the GUI does not have it by default.
//
//  So for every user without it, the after-proof's descriptor-relative read
//  (`facts`, which opens the CONTAINING directory and `fstatat`s the name
//  under it) could not be taken AT ALL, and its `nil` was read as "the Trash
//  took something nobody inspected". The disposal then rolled back — a
//  rollback that could not open the Trash either — and the user was told, of
//  a checkout sitting in the Trash and recoverable in one drag, that it "is
//  no longer at ~/.Trash/<name>, where the Trash reported putting it", with
//  entries=0 and 0 bytes reported. REPRODUCED 3/3 through the real production
//  composition, `moveToTrash` at its shipped default, nothing injected at the
//  seam, by `GitWorktreeEndToEndTests`'
//  `testTheTrashDefaultReportsTheCheckoutItReallyMovedToTheTrash`.
//
//  IT SURVIVED BECAUSE EVERY TRASH CELL IN THE SUITE INJECTED A `trashHandler`
//  LANDING IN A FIXTURE DIRECTORY, whose parent is freely openable — the one
//  property the guard depends on, and the one production does not have. The
//  fix is in `facts`: when the containing directory cannot be opened the
//  landed object is still IDENTIFIED, by the single `lstat` the permission
//  allows, and the comparison the caller makes is unchanged. A failure to
//  VERIFY is not evidence of a wrong disposal, and it is not a licence to
//  skip the verification either — see `facts` for why the weaker binding can
//  never admit what the stronger one would refuse.
//
//  AND THE COVERAGE THAT CLOSED IS ONE ARM OF THREE — RECORDED HERE BECAUSE
//  THE PARAGRAPH ABOVE READS AS IF IT WERE ALL OF THEM (PR #460 codex r11,
//  D4). `GitWorktreeEndToEndTests.testTheTrashDefaultReportsTheCheckoutItReallyMovedToTheTrash`
//  drives the WORKTREE arm through the real `FileManager.trashItem` into the
//  real `~/.Trash`. `CacheCleaner`'s item-mode and contents-mode Trash
//  disposal — the app's primary feature, and the population the
//  container-bound overload was written for — still has ZERO coverage through
//  that seam: every one of those cells injects a `trashHandler:` landing in a
//  fixture directory whose parent is freely openable, which is the exact
//  property that hid this defect for eight rounds. D1 lived in shared code,
//  so the worktree cell would have caught it for all three arms; nothing
//  measured says the other two reach `~/.Trash` correctly.
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
//  `MEASURED-TRASH-WINDOW-NS` (4166 ns at r6, on an idle main thread, with
//  the proof now inside the hop; it was ~21–25 µs idle before).
//
//  THAT PREFIX HAD NO UPPER BOUND — AND SINCE PR #460 codex r6 IT IS NOT WHERE
//  THE PROOF SITS. The prefix is an `@MainActor` HOP (`trashItem` talks to
//  Finder), so its width is a SCHEDULING DELAY, not a syscall cost, and
//  scheduling delays have no maxima. Measured both ways at r5, 12 runs each,
//  same machine, same fixture, with the proof still on the NEAR side of it:
//
//      quiet:     min 21.5 µs   median 24.8 µs   p90 35.5 µs   max 41.2 µs
//      contended: min 23.7 µs   median 59.7 µs   p90 297 µs    max 1382 µs
//
//  (contended = 2×`hw.ncpu` spinners; an incidental sample taken while a
//  parallel `swift build` was running read 5.60 ms — 170× the quiet max.)
//  Those figures are CPU contention. Main-thread QUEUE DEPTH is the larger
//  half and was never measured until r6: under 120 ms work items held on the
//  main thread the same interval is median 175.736 ms (n=5).
//
//  The earlier version of this note drew the wrong conclusion from its own
//  numbers — "narrowing the prefix therefore buys nothing" — by comparing the
//  prefix against the swap syscall and stopping there. What it missed is that
//  the prefix is not a fixed cost to be compared with anything: it is
//  UNBOUNDED, and an unbounded interval between a proof and the act it
//  authorises is not narrowed by argument. `Mover`'s second argument moves the
//  proof to the FAR side of the hop, which takes the same interval to median
//  0.004 ms under the identical load. See `Mover` below.
//
//  The REST of the window is still inside `trashItem`, and its scale is the
//  reason this file exists. Measured on this machine, on the real home volume:
//  one `trashItem` call of a 4 KiB directory takes 262 µs (min) / 288 µs
//  (median) / 456 µs (max) over nine calls, while the ONE syscall that defeats
//  it — `renamex_np(RENAME_SWAP)` of two directories, the atomic form of the
//  fixture's `rename(2)` + `mkdir(2)` — takes 61 µs (min) / 69–83 µs (median)
//  on the same volume. So the swap still fits inside the call that follows the
//  proof, which is why the load-bearing proof here remains the one taken AFTER
//  the disposal: narrowing the prefix removes the unbounded part of the
//  window, it does not close the part `trashItem` owns.
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
/// EVERY production Trash disposal goes through one of the two `dispose`
/// entry points; the cleaner no longer calls the seam directly anywhere. The
/// paragraph that stood here said the opposite — "Used only where an
/// inspection verdict exists to bind to … where none does, the cleaner calls
/// the seam directly and says so at the call site" — and the saying-so was
/// true while the binding was absent, which is how the GUI's default disposal
/// stayed unbound for three review rounds. The difference between the two
/// entry points is now WHICH FACT the leaf is bound to, not WHETHER it is
/// bound.
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
            /// PROVED: an object was still identified at `landed` — by the
            /// rollback's own re-bind, or by the after-proof that sent it
            /// here when the Trash directory cannot be opened at all — and
            /// the move itself could not be performed (the original name is
            /// occupied again, or this process may not open the Trash). The
            /// payload is where the item is, so the user can finish it in one
            /// drag.
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

    // MARK: - The mover seam, and the proof that has to cross its hop

    /// THE MOVER SEAM — and the SECOND argument is the whole reason this is a
    /// named type rather than `(URL) async throws -> URL?` (PR #460 codex r6,
    /// D1).
    ///
    /// `disposal(target, prove)` must call `prove()` **on the far side of
    /// whatever hop it performs, immediately before the move**, and must not
    /// move anything if it throws. The seam owner is the only code that knows
    /// where its mover actually runs, so it is the only code that can put a
    /// proof there.
    ///
    /// WHY. The production mover is `FileManager.trashItem`, which requires
    /// the main actor, so `CacheCleaner` wraps it in a `MainActor.run`. Every
    /// proof this file takes before calling the seam is therefore separated
    /// from the move by the MAIN THREAD'S QUEUE DEPTH, which is not a syscall
    /// and not a constant. MEASURED through the production composition
    /// (`CacheCleaner` → `WorktreeReclaimPerformer` → this file, provider
    /// instrumented so the last pre-move `probeChild` is timestamped, a
    /// 120 ms work item held on the main thread):
    ///
    /// | shape | last proof → the mover is entered (n=5) |
    /// |---|---|
    /// | proof before the hop (through r5) | median **175.736 ms**, 160.352–184.937 |
    /// | proof inside the hop (this) | median **0.004 ms**, 0.004–0.016 |
    ///
    /// The load is real in both rows and is asserted to be: the same run
    /// measures the HOP itself (first leaf binding → last leaf binding) at
    /// median 175.3 ms and 176.1 ms respectively.
    ///
    /// The full figures, the command and the load condition are in
    /// `WorktreeReclaimPerformerTests`'
    /// `testTheTrashProofAndTheMoveAreNotSeparatedByTheMainThreadQueue`.
    ///
    /// The after-proof still runs and still rolls back — this narrows the
    /// window the after-proof exists to catch, it does not replace it.
    typealias Mover = (URL, () throws -> Void) async throws -> URL?

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
        via disposal: Mover
    ) async throws {
        // A NON-DIRECTORY leaf verdict cannot be proved by `look` — its kind
        // gate is an `O_DIRECTORY` open, which can only ever IDENTIFY a
        // directory (ENOTDIR/ELOOP name no inode). The carried identity is
        // bound the way the no-leaf-verdict arm below binds: one `fstatat`
        // under the PROVED container, on BOTH sides of the move, required
        // equal to the identity the revalidator verified (PR #459 review r5
        // — before this branch, ANY `.noDirectoryTree` sighting satisfied
        // the file arm's verdict and a swapped-in file was trashed and KEPT
        // with success reported).
        if case .nonDirectoryLeaf(let expected) = inspected {
            let bound = try boundLeaf(
                of: target, containedIn: admittedParent, provider: provider
            )
            guard bound.identity == expected else {
                // Refused BEFORE the move: the Trash is untouched. The same
                // cause the permanent arm throws for the same event, so the
                // cleaner's log tags both `content-drift`.
                throw DepthSafeRemoval.Failure(
                    path: target.path, cause: .notTheInspectedObject, depth: 0
                )
            }
            // AND AGAIN ON THE FAR SIDE OF THE SEAM'S HOP (D1): the binding
            // above is taken here, the move happens after a main-actor hop,
            // and the interval between them is the main thread's queue depth.
            let landed = try await disposal(target) {
                let atTheInstant = try boundLeaf(
                    of: target, containedIn: admittedParent, provider: provider
                )
                guard atTheInstant == bound else {
                    throw DepthSafeRemoval.Failure(
                        path: target.path, cause: .notTheInspectedObject,
                        depth: 0
                    )
                }
            }
            guard let landed else {
                throw Failure(path: target.path, cause: .destinationUnknown)
            }
            let observed = facts(at: landed, provider: provider)
            guard observed == bound else {
                throw Failure(
                    path: target.path,
                    cause: rollBack(
                        observed, from: landed, to: target,
                        containedIn: admittedParent, provider: provider
                    )
                )
            }
            return
        }

        // (1) The cheap refusal, and the one that keeps the Trash untouched.
        try proveStanding(inspected, at: target, provider: provider)

        // (1b) THE SAME PROOF, ON THE FAR SIDE OF THE SEAM'S HOP (D1). (1) is
        // taken here; the move happens after a main-actor hop whose length is
        // the main thread's queue depth, not a syscall.
        let landed = try await disposal(target) {
            try proveStanding(inspected, at: target, provider: provider)
        }

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
                    identified(sighting), from: landed, to: target,
                    containedIn: admittedParent, provider: provider
                )
            )
        }
    }

    // MARK: - The arm for callers with NO leaf verdict

    /// Move `target` to the Trash through `disposal`, bound to the object
    /// that stood AT THAT NAME INSIDE THE ADMITTED CONTAINER.
    ///
    /// WHY A SECOND ENTRY POINT EXISTS (PR #458 review — the P1 that survived
    /// three rounds). `dispose(_:expecting:…)` above is only reachable when a
    /// scanner's `PreDeleteRevalidator` produced a verdict about the leaf.
    /// The population with NO leaf verdict is large and precisely known — ALL
    /// of contents mode (it runs no probe at all) plus every item whose
    /// scanner registers no revalidator (`preDeleteOutcome` yields
    /// `.unestablished`) — and for three rounds those two call sites handed a
    /// BARE URL straight to the mover. Measured on this branch through the
    /// production cleaner, `moveToTrash: true`, two real `rename(2)`s at the
    /// seam: the stranger's tree went to the Trash and the report read
    /// `entries=[exactBytes: 4096, disposal: .trash]`, `errors=[]` — the byte
    /// count of a tree the app had measured and then not touched.
    ///
    /// THE BINDING IS THE ONE THE CALLER ALREADY HAS, CARRIED ONE CALL
    /// FURTHER. There is no leaf verdict to bind to, but there IS an admitted
    /// container, and a leaf read UNDER a proved container descriptor is a
    /// fact about an OBJECT — which is what the mover needs and what a URL is
    /// not. So:
    ///
    /// 1. BEFORE — the container is opened and `fstat`ed against
    ///    `DepthSafeRemoval.admittedParent`'s identity (the same
    ///    `openAdmittedContainer` the permanent arm proves with, so the two
    ///    cannot drift), and the leaf is bound under THAT descriptor with one
    ///    `fstatat` (`probeChild`: kind and identity from a single
    ///    resolution that no rename can re-point). A container already
    ///    swapped when we get here refuses without disturbing the Trash at
    ///    all; a leaf that is not there refuses with the `ENOENT` the
    ///    disposal would have produced anyway.
    /// 2. AFTER — `trashItem` resolves the URL inside itself, so the swap can
    ///    still land in a window no proof out here reaches. The Trash is
    ///    reversible by construction, so the load-bearing proof is the one
    ///    taken after: what landed is read the same descriptor-relative way
    ///    and compared with the bound facts. A mismatch is PUT BACK through
    ///    `rollBack` — which proves its own destination against the same
    ///    admitted container — and reported as a refusal: no entry, no bytes.
    ///
    /// `probeChild` rather than `look` on both sides ON PURPOSE: `look`'s kind
    /// gate is an `O_DIRECTORY` open, so it can only identify DIRECTORIES,
    /// and contents mode trashes regular files and symlinks by the thousand.
    /// One `fstatat` identifies every kind, which is what makes this arm a
    /// binding for the whole population rather than for the directory-shaped
    /// part of it.
    static func dispose(
        _ target: URL,
        containedIn admittedParent: DepthSafeRemoval.AdmittedParent,
        provider: FileSystemIdentityProvider,
        via disposal: Mover
    ) async throws {
        let bound = try boundLeaf(
            of: target, containedIn: admittedParent, provider: provider
        )

        // AND AGAIN IMMEDIATELY BEFORE THE MOVE, WHEREVER THE MOVER RUNS
        // (PR #460 codex r6, D1). The binding above is the cheap refusal that
        // keeps the Trash untouched; this one is the load-bearing one, because
        // the production seam hops to the main actor and that hop is the main
        // thread's queue depth. Both readings are the SAME `boundLeaf` under
        // the SAME proved container, so a difference between them is a swap
        // inside the hop and nothing else.
        let landed = try await disposal(target) {
            let atTheInstant = try boundLeaf(
                of: target, containedIn: admittedParent, provider: provider
            )
            guard atTheInstant == bound else {
                throw DepthSafeRemoval.Failure(
                    path: target.path, cause: .notTheInspectedObject, depth: 0
                )
            }
        }

        guard let landed else {
            throw Failure(path: target.path, cause: .destinationUnknown)
        }
        let observed = facts(at: landed, provider: provider)
        guard observed == bound else {
            throw Failure(
                path: target.path,
                cause: rollBack(
                    observed, from: landed, to: target,
                    containedIn: admittedParent, provider: provider
                )
            )
        }
    }

    /// WHAT STANDS AT `target`'s NAME INSIDE THE ADMITTED CONTAINER — the
    /// binding the disposal above is proved against.
    ///
    /// The container proof and the leaf read are ONE sequence against ONE
    /// held descriptor: proving the container and then re-resolving the
    /// target's whole path would be a check of a different thing.
    static func boundLeaf(
        of target: URL,
        containedIn admittedParent: DepthSafeRemoval.AdmittedParent,
        provider: FileSystemIdentityProvider
    ) throws -> FileSystemIdentityProvider.ChildFacts {
        let leaf = target.lastPathComponent
        // A PRECONDITION, DISCLOSED AS ONE RATHER THAN DRESSED AS A GUARD —
        // the same disclosure `rollBack` carries for the same call.
        // `probeChild` takes a SINGLE component and would resolve a
        // multi-component one THROUGH the held directory, which is exactly the
        // no-follow guarantee this call exists to keep. No production URL
        // reaching here can violate it (`target` is an admitted item or an
        // enumerated child), so deleting it — measured, both this and the copy
        // in `facts` at once — leaves the FULL suite GREEN. It stays because
        // the precondition is the primitive's, not this call's, and a future
        // caller is what it is for.
        guard FileSystemIdentityProvider.isSafeComponent(leaf) else {
            throw DepthSafeRemoval.Failure(
                path: target.path, cause: .invalidTarget, depth: 0
            )
        }
        let containerFD = try DepthSafeRemoval.openAdmittedContainer(
            at: target.deletingLastPathComponent(),
            provenAgainst: admittedParent, displayPath: target.path,
            provider: provider
        )
        defer { close(containerFD) }
        switch provider.probeChild(
            inDirectory: containerFD, named: leaf, logical: target
        ) {
        case .facts(let facts):
            return facts
        case .absent:
            // The frozen ghost-target behaviour, moved one call earlier: the
            // disposal would have failed `ENOENT` on this name too, and an
            // item-keyed error is what that has always produced. What must
            // NOT happen is proceeding with nothing to prove the move
            // against — whatever answers to the name a moment later is
            // exactly what the Trash would take.
            //
            // LOAD-BEARING, MEASURED: substitute an identity that can never
            // match instead of throwing and
            // `testTrashModeRefusesAChildThatVanishedBeforeItCouldBeBound`
            // goes red, because the disposal then RUNS. (It was subsumed
            // before that test existed — the after-proof refused whatever
            // came back — so the cost of losing it is not a wrong deletion
            // but the user's Trash disturbed for nothing, and a re-scan
            // clears it.)
            throw DepthSafeRemoval.Failure(
                path: target.path, cause: .posix(ENOENT), depth: 0
            )
        case .failed(let code):
            throw DepthSafeRemoval.Failure(
                path: target.path, cause: .posix(code), depth: 0
            )
        }
    }

    /// Kind AND identity of whatever answers to `url`'s NAME inside `url`'s
    /// directory, read descriptor-relative — and, WHEN THAT DIRECTORY CANNOT
    /// BE OPENED AT ALL, from one no-follow `lstat` of the path instead.
    ///
    /// `nil` is "nothing could be identified here", which is never a match
    /// and never a licence: `nil == bound` is false for every `bound`, so the
    /// caller rolls back, and the rollback refuses to move an object it
    /// cannot name. Its `nil` arms are therefore not guards — they are one
    /// fail-closed default that the caller's comparison enforces.
    ///
    /// ## THE FALLBACK, AND THE DEFECT IT CLOSES (PR #460 codex r10, D1)
    ///
    /// `url` is where the DISPOSAL said it put the item: in production that
    /// is `~/.Trash/<name>`, and **a process without Full Disk Access cannot
    /// open `~/.Trash`**. Measured on this machine (Darwin 25.5), from an
    /// ordinary CLI process: `open("/Users/<u>/.Trash",
    /// O_RDONLY|O_DIRECTORY|O_NOFOLLOW)` returns -1 with errno 1 (EPERM),
    /// while `lstat` and `open` of `~/.Trash/<name>` — the item this process
    /// just moved there — both SUCCEED. TCC denies the directory and permits
    /// traversal through it.
    ///
    /// So the descriptor-relative read failed for EVERY Trash disposal on
    /// every machine without Full Disk Access, this returned `nil`, and the
    /// caller read that as "the disposal took something nobody inspected" and
    /// rolled back — a rollback that then could not open the Trash either, so
    /// the user was told, of a checkout sitting in the Trash and recoverable
    /// in one drag, that it "could not be put back — it is no longer at
    /// `~/.Trash/<name>`, where the Trash reported putting it", with
    /// `entries=0` and 0 bytes reported. REPRODUCED 3/3 through the real
    /// production composition (`SpaceScannerRuntime.production` →
    /// `CacheoutViewModel.clean()`, `moveToTrash` at its shipped default,
    /// nothing injected at the seam) by
    /// `GitWorktreeEndToEndTests.testTheTrashDefaultReportsTheCheckoutItReallyMovedToTheTrash`,
    /// which is red without the fallback and green with it.
    ///
    /// A FAILURE TO VERIFY IS NOT EVIDENCE OF A WRONG DISPOSAL, and this is
    /// not a decision to skip the verification: the fallback still IDENTIFIES
    /// the landed object, by the one syscall the permission actually allows.
    /// The comparison the caller makes is unchanged, so a genuinely swapped
    /// object still mismatches and is still refused
    /// (`testAnUnopenableLandingStillCatchesAnObjectThatIsNotOurs`).
    ///
    /// IT IS RESTRICTED TO THE PERMISSION ERRNOS, AND r10 SHIPPED IT
    /// UNRESTRICTED (PR #460 codex r11, D1). r10's header argued that a
    /// per-errno gate "would add an untestable branch and buy nothing"
    /// because the fallback "cannot ADMIT anything the descriptor-relative
    /// read would refuse". **That reasoning is wrong, and the counterexample
    /// is the failure `O_NOFOLLOW` exists to produce.** The two reads do not
    /// resolve the same path: `probeChild` reads a name inside a descriptor,
    /// while `probeLeaf` `lstat`s a PATH, and `lstat`'s no-follow applies to
    /// the FINAL component only. So when the CONTAINER is a symlink the
    /// container open FAILS — and the fallback then resolves that link and
    /// identifies whatever lies on the other side of it.
    ///
    /// MEASURED, in
    /// `TrashDisposalHopProofTests.testASymlinkedLandingContainerIsRefusedRatherThanResolvedThroughIt`:
    /// a mover that returns a landing whose parent is a symlink aimed back at
    /// the item's OWN container makes `lstat` walk through the link, find the
    /// ORIGINAL object still standing at its original path, and return the
    /// identity bound before the move. `observed == bound` then holds and the
    /// disposal reports SUCCESS HAVING MOVED NOTHING — a false success, which
    /// is strictly worse than the false refusal r10 removed. With the gate
    /// that errno is not in the permitted class, `facts` returns `nil`, and
    /// the caller refuses exactly as it did before r10.
    ///
    /// (WHICH errno, measured on Darwin 25.5 rather than assumed: the r11
    /// review named this the `ELOOP` case, and `ELOOP` (62) is indeed what
    /// `open(link, O_RDONLY|O_NOFOLLOW)` returns. This open also carries
    /// `O_DIRECTORY`, and with it the same call returns **`ENOTDIR` (20)** —
    /// the directory check answers first, for a symlink to a directory and
    /// for a self-referential one alike. Neither code is permitted, so the
    /// gate is the same either way.)
    ///
    /// WHY `EPERM`/`EACCES` ARE THE WHOLE PERMITTED CLASS — and the argument
    /// is about what reaching them PROVES, not about how many causes produce
    /// them (corrected, PR #460 codex r12, D3). r11 wrote that they "are the
    /// whole measured cause": TCC's `EPERM`, and `EACCES` as its mode-bit
    /// spelling. THERE IS AT LEAST A THIRD, MEASURED — `open(dir, O_RDONLY)`
    /// needs READ on the container while `lstat(container/name)` needs only
    /// TRAVERSAL, so a container at mode `0111` answers `EACCES` here while
    /// the fallback's path read succeeds
    /// (`testTheErrnoCarryingOpenAnswersOneCodePerFailureAndAdmitsMode0111`).
    ///
    /// It is SOUND anyway, and the enumeration was never what made it sound.
    /// Reaching either code AT ALL means the container's LAST COMPONENT is a
    /// real directory that `O_NOFOLLOW` accepted — a symlink there answers
    /// `ENOTDIR`/`ELOOP` first, before any permission check, measured in the
    /// same cell — so no member of this class can license a resolution the
    /// descriptor-relative read refused, whatever produced it. A missing
    /// directory and a non-directory answer outside the class for the same
    /// reason.
    ///
    /// All three directions are evidenced:
    /// `testAnUnopenableLandingIsIdentifiedRatherThanRefused` (`EPERM` must
    /// SUCCEED), `testAModeDeniedLandingIsIdentifiedRatherThanRefused`
    /// (`EACCES` must SUCCEED) and the symlinked-container cell above (must
    /// REFUSE).
    ///
    /// It is reached only when the container open has ALREADY failed; while
    /// that open succeeds the descriptor-relative answer, including its
    /// `.absent`, is the only one used.
    ///
    /// THE SIBLING ARM, AND THE PARITY THIS HEADER CLAIMED IT ALREADY HAD
    /// (corrected, PR #460 codex r12, D1). r11 wrote here that
    /// `dispose(_:expecting:…)`'s directory path "has always identified the
    /// landing with `look`, which is a DIRECT `open` of `url` and therefore
    /// never needed the Trash directory", and offered that as the reason it
    /// needed no gate. **Never needing the permission is not the same fact as
    /// being sound**: a direct open of the whole path was the SAME
    /// resolution-through-a-symlinked-container this gate exists to refuse,
    /// because `O_NOFOLLOW` guards only the FINAL component. The false
    /// success was reproduced on that arm at 93d6198
    /// (`testTheDirectoryVerdictArmRefusesASymlinkedLandingContainer`), and
    /// `look` now resolves the name inside its container with the same
    /// permission-class fallback this function carries. The two arms are at
    /// parity because both were fixed, not because one never had the defect.
    ///
    /// What r10's D1 broke remains as stated: only the arms that read the
    /// landing descriptor-relative — the container-bound overload (the GUI's
    /// default worktree and contents-mode disposal) and the
    /// `.nonDirectoryLeaf` arm — were unusable without Full Disk Access. The
    /// directory arm reached the landing by path, which TCC permits, so its
    /// fallback is what keeps it working rather than what restored it.
    static func facts(
        at url: URL, provider: FileSystemIdentityProvider
    ) -> FileSystemIdentityProvider.ChildFacts? {
        let name = url.lastPathComponent
        guard FileSystemIdentityProvider.isSafeComponent(name) else {
            return nil
        }
        let fd: Int32
        switch provider.openDirectoryNoFollowCarryingErrno(
            at: url.deletingLastPathComponent()
        ) {
        case .opened(let descriptor):
            fd = descriptor
        case .failed(let code):
            // THE PERMISSION CLASS ONLY. Every other cause — ENOTDIR on a
            // symlinked container above all — is this open refusing to
            // resolve something, and a path `lstat` must not be used to
            // answer around it.
            guard code == EPERM || code == EACCES else { return nil }
            guard case .facts(let facts) = provider.probeLeaf(at: url) else {
                return nil
            }
            return facts
        }
        defer { close(fd) }
        guard case .facts(let facts) = provider.probeChild(
            inDirectory: fd, named: name, logical: url
        ) else { return nil }
        return facts
    }

    /// The `Sighting` → `ChildFacts` narrowing, in ONE place: only a
    /// `.directory` sighting names an object, and every other case is
    /// "nothing identified".
    private static func identified(
        _ sighting: Sighting
    ) -> FileSystemIdentityProvider.ChildFacts? {
        guard case .directory(let identity) = sighting else { return nil }
        return FileSystemIdentityProvider.ChildFacts(
            kind: .directory, identity: identity
        )
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
    ///
    /// ## THE OPEN IS DESCRIPTOR-RELATIVE (PR #460 codex r12, D1)
    ///
    /// Through r11 this was ONE path-spelled
    /// `open(url.path, O_RDONLY|O_DIRECTORY|O_NOFOLLOW)`, and r11's own
    /// header called that the safe end of the trade it made in `facts`,
    /// "a DIRECT `open` of `url` [which] therefore never needed the Trash
    /// directory". **It is the same unsoundness one call away.**
    /// `O_NOFOLLOW` guards only the FINAL component, so that open FOLLOWS a
    /// symlinked landing CONTAINER exactly as `probeLeaf`'s `lstat` did — and
    /// `dispose(_:expecting:…)`'s directory arm identified the landing with
    /// it.
    ///
    /// MEASURED at 93d6198, production provider, real symlink, in
    /// `TrashDisposalHopProofTests.testTheDirectoryVerdictArmRefusesASymlinkedLandingContainer`:
    /// a mover that moves NOTHING and reports a landing whose parent is a
    /// symlink aimed back at the item's own container made this open resolve
    /// through the link onto the ORIGINAL object, hand back the identity the
    /// verdict names, and `dispose` RETURNED NORMALLY with `victim` still on
    /// disk — a disposal that reported success having moved nothing.
    ///
    /// So the name is now resolved INSIDE its container: one
    /// `openDirectoryNoFollowCarryingErrno` of the container, one
    /// `openChildDirectoryCarryingErrno` of the single component under the
    /// held descriptor. Both carry `O_NOFOLLOW`, so a symlink at EITHER level
    /// is a refusal rather than a resolution, and the identity still comes
    /// off the opened inode — which is what the rollback's
    /// `identity(ofDescriptor:)` seam and its `.unidentifiable` arm depend
    /// on, and why this is not `facts`' `probeChild`.
    ///
    /// ## AND THE PERMISSION CLASS IS STILL ANSWERED
    ///
    /// `~/.Trash` is TCC-denied to every process without Full Disk Access
    /// (measured in `facts`: `EPERM` on the directory, traversal THROUGH it
    /// permitted). The path-spelled open never needed that permission, so
    /// this arm was never broken the way r10's D1 broke the others — and a
    /// descriptor-relative rewrite without a fallback would have broken it
    /// for the first time. `EPERM`/`EACCES` on the CONTAINER open therefore
    /// fall back to the path-spelled open, under the identical bound `facts`
    /// carries — and stated there in full, including the THIRD cause that
    /// reaches this class (a container at mode `0111`) and why the class is
    /// sound regardless of how many causes produce it. In short: reaching
    /// either code means the container's last component IS a real directory
    /// that `O_NOFOLLOW` accepted, so the fallback resolves no link this open
    /// refused, and its identity is only ever compared for EQUALITY against
    /// one bound before the move. Every other failure refuses.
    ///
    /// Both directions are evidenced, and each by its own cell:
    /// `…IdentifiesAnUnopenableLanding` (`EPERM` must SUCCEED),
    /// `…IdentifiesAModeDeniedLanding` (`EACCES` must SUCCEED),
    /// `…RefusesASymlinkedLandingContainer` and
    /// `…RefusesALandingThatIsNotADirectory` (must REFUSE).
    static func look(
        at url: URL, provider: FileSystemIdentityProvider
    ) -> Sighting {
        let name = url.lastPathComponent
        // A PRECONDITION, DISCLOSED AS ONE RATHER THAN DRESSED AS A GUARD —
        // the same disclosure `rollBack` makes about the same primitive. A
        // MULTI-COMPONENT name would defeat the whole no-follow guarantee
        // (`O_NOFOLLOW` guards only the last component of whatever `openat`
        // is handed, measured in `probeChild`'s header). No URL that reaches
        // `look` can violate it — `target` comes from an admitted item and
        // `landed` from the mover — so NO CELL FAILS when this is deleted
        // (mutation-tested against the 389-test trash scope: 0 red). It is
        // the family's documented contract, restated where it is called.
        guard FileSystemIdentityProvider.isSafeComponent(name) else {
            return .unreadable(errno: EINVAL)
        }
        switch provider.openDirectoryNoFollowCarryingErrno(
            at: url.deletingLastPathComponent()
        ) {
        case .opened(let container):
            defer { close(container) }
            return look(named: name, inDirectory: container,
                        logical: url, provider: provider)
        case .failed(let code):
            // THE CONTAINER IS GONE. Nothing can stand inside a directory
            // that is not there, and no name was resolved to establish it —
            // so this is the same `.absent` the path-spelled open produced,
            // and it is unspoofable for the same reason (an `ENOENT` cannot
            // come from following anything).
            if code == ENOENT { return .absent }
            // THE PERMISSION CLASS ONLY — see the header. Every other cause,
            // `ENOTDIR`/`ELOOP` on a symlinked container above all, is this
            // open refusing to resolve something, and a path-spelled open
            // must not be used to answer around it.
            guard code == EPERM || code == EACCES else {
                return .unreadable(errno: code)
            }
            return lookAlongThePath(url, provider: provider)
        }
    }

    /// The single component `name`, opened under the HELD container.
    private static func look(
        named name: String, inDirectory container: Int32,
        logical url: URL, provider: FileSystemIdentityProvider
    ) -> Sighting {
        switch provider.openChildDirectoryCarryingErrno(
            inDirectory: container, named: name, logical: url
        ) {
        case .opened(let fd):
            defer { close(fd) }
            guard let identity = provider.identity(ofDescriptor: fd) else {
                return .unidentifiable
            }
            return .directory(identity)
        case .failed(let code):
            return sighting(forOpenFailure: code)
        }
    }

    /// The path-spelled open — the WHOLE of `look` through r11, kept as the
    /// permission-class fallback and reachable from nowhere else.
    private static func lookAlongThePath(
        _ url: URL, provider: FileSystemIdentityProvider
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
        guard fd >= 0 else { return sighting(forOpenFailure: code) }
        defer { close(fd) }
        guard let identity = provider.identity(ofDescriptor: fd) else {
            return .unidentifiable
        }
        return .directory(identity)
    }

    /// The ONE errno taxonomy both opens above are read through, so the
    /// descriptor-relative arm and its fallback can never classify the same
    /// failure differently.
    private static func sighting(forOpenFailure code: Int32) -> Sighting {
        switch code {
        case ENOENT: return .absent
        // ENOTDIR/ELOOP: something that is NOT a directory tree stands here.
        // That is exactly what `.noDirectoryTree` is about. (`O_DIRECTORY`
        // makes a symlink answer ENOTDIR before O_NOFOLLOW's ELOOP on this
        // OS — measured, and both are named so neither OS is a surprise.)
        case ENOTDIR, ELOOP: return .noDirectoryTree
        default: return .unreadable(errno: code)
        }
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
        // `.nonDirectoryLeaf` verdicts never take this path in production —
        // `dispose(_:expecting:…)` binds them by `fstatat` under the proved
        // container, because a `look` cannot IDENTIFY a non-directory — and
        // if one arrives anyway, every arm below refuses it (each `guard
        // case` names a different case), which is the fail-closed default.
        switch sighting {
        case .directory(let seen):
            // Only a `.directory` verdict about THIS inode admits it;
            // `.noDirectoryTree`, `.nonDirectoryLeaf` and `.unestablished`
            // are refusals.
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
        _ observed: FileSystemIdentityProvider.ChildFacts?,
        from landed: URL, to target: URL,
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
        //
        // IT TAKES FACTS, NOT A `Sighting`, because both arms roll back
        // through it and one of them binds NON-DIRECTORIES (see
        // `dispose(_:containedIn:…)`). The verdict-bound arm narrows its own
        // sighting at the call (`identified`), so a `.directory` landing is
        // the only thing that ever reached this code before and the only
        // thing it can produce now.
        guard let observed else {
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

        // THE TRASH DIRECTORY CANNOT BE OPENED — which is the ORDINARY case,
        // not an exotic one: without Full Disk Access this open is EPERM on
        // every macOS machine (measured — see `facts`). What it means here is
        // that the put-back cannot be PERFORMED, not that the item is not
        // where the disposal said. `observed` is non-`nil` on this line — the
        // caller identified an object at `landed` a moment ago, through
        // whichever of the two reads was permitted — so the item IS in the
        // Trash, and `.strandedInTrash` is the cause that says so and gives
        // the user the path to drag it back from. Reporting
        // `.lastSeenInTrash` here told them the opposite of what they can see
        // in the Trash (PR #460 codex r10, D1).
        let trashFD = provider.openDirectoryNoFollow(
            at: landed.deletingLastPathComponent()
        )
        guard trashFD >= 0 else { return .strandedInTrash(landed.path) }
        defer { close(trashFD) }
        let containerFD = provider.openDirectoryNoFollow(
            at: target.deletingLastPathComponent()
        )
        guard containerFD >= 0 else { return .lastSeenInTrash(landed.path) }
        defer { close(containerFD) }

        let bound = FileSystemIdentityProvider.ChildProbe.facts(observed)
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
