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
//  1. BEFORE — the container is opened and PROVED against the identity the
//     cleaner captured (`DepthSafeRemoval.openAdmittedContainer`), and then
//     the leaf is read: `fstatat` of the name under that held descriptor on
//     the three arms that can use it, or `open(O_DIRECTORY|O_NOFOLLOW)` +
//     `fstat` of THAT descriptor on the `.directory` verdict's arm, whose
//     rollback needs an OPENED inode. Never an `lstat` of the path: the kind
//     gate is the read itself, so there is no window between deciding what
//     stands there and holding it, and the identity comes off the object
//     rather than off a second resolution of a name. This refuses the
//     ordinary case without disturbing the user's Trash at all.
//
//     THE PARAGRAPH THAT STOOD HERE DESCRIBED ONLY THE SECOND HALF OF THAT
//     SENTENCE, AND IT WAS FALSE FOR ONE ARM (PR #460 codex r13, A3). It
//     said step (1) was an `open(O_DIRECTORY|O_NOFOLLOW)` of the target —
//     which on a `.noDirectoryTree` verdict ALWAYS fails by construction,
//     because the target is a non-directory, so no identity was ever read —
//     and it mentioned the container proof only as something "the
//     container-bound arm" does, when in fact `dispose(_:expecting:…)`'s
//     `.noDirectoryTree` arm opened no container at all and bound nothing.
//     See that arm for what was measured and what it now does.
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
//  ONE OF THOSE TWO IS NOW MEASURED, AND THE SIZE OF WHAT IS LEFT IS STATED
//  (PR #460 codex r13, A4).
//  `CacheCleanerTests.testTrashDefaultReallyTrashesANoTreeSweepItemIntoTheRealTrash`
//  builds a real `CacheCleaner` with NO `trashHandler:` — the constructor's
//  default is `FileManager.trashItem` — and drives ITEM MODE on a
//  `.noDirectoryTree` sweep item into the real `~/.Trash`, asserting the
//  landing, the entry and the bytes. That closes the arm and the verdict this
//  round's P1 lived on; the paragraph above must not now be read as closing
//  the rest. STILL UNCOVERED through the real seam: item mode on the
//  `.directory` and `.nonDirectoryLeaf` verdicts, and ALL of contents mode.
//  The gap that hid A was this one, and it is the one that was closed.
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
//  proof, which is why narrowing the prefix removes the unbounded part of the
//  window and does not close the part `trashItem` owns.
//
//  WHICH PROOF IS LOAD-BEARING DEPENDS ON THE ARM, AND THIS PARAGRAPH USED TO
//  SAY IT WAS ALWAYS THE ONE TAKEN AFTER (corrected, PR #460 codex r13, A1).
//  The after-proof is load-bearing wherever it can DISCRIMINATE — the three
//  arms that bind an object compare `facts(at: landed)` for equality with a
//  bound identity, and a stranger fails that. It cannot discriminate for a
//  verdict that carries no identity: with the container swapped inside the
//  mover, `look(at: landed)` answers `.noDirectoryTree`, the verdict IS
//  `.noDirectoryTree`, and `disagreement` returns nil. Measured — the
//  stranger's file was trashed with `errors=[]` by a probe that had added the
//  container proof on both sides of the seam but kept this after-proof. For
//  that verdict the BINDING is the load-bearing half, which is why
//  `.noDirectoryTree` now goes through `disposeBoundLeaf` like every other
//  non-directory arm.
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
///
/// THAT SENTENCE WAS WRITTEN ONE ROUND TOO EARLY, AND ONE ARM MADE IT FALSE
/// (PR #460 codex r13, A3). `dispose(_:expecting:…)`'s `.noDirectoryTree`
/// path bound NOTHING: it never opened `admittedParent`, and the verdict
/// carries no identity, so both of its proofs reduced to "some non-directory
/// answers to this name" — satisfied by any non-directory in any directory.
/// Measured at 0139713 through the production composition and again through
/// the shipped `FileManager.trashItem` into the real `~/.Trash`: a stranger's
/// file trashed, `entries=[… exactBytes: 4096, disposal: .trash]`,
/// `errors=[]`. It is true now because that arm was routed through the same
/// `disposeBoundLeaf` the other three use, not because it was true then.
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
            /// could not be shown to be at the name the disposal reported.
            /// The payload is the last place it was seen. Moving whatever
            /// took its place is the bug, not the undo.
            ///
            /// WHAT ACTUALLY PRODUCES IT, ENUMERATED RATHER THAN SUMMARISED
            /// (PR #460 codex r14, V1-D1). The sentence that stood here said
            /// the object "is no longer at the name the disposal reported (it
            /// was moved, replaced, or cannot be read)", and the arm that
            /// broke it made all three false at once: a NON-DIRECTORY landing
            /// reached `rollBack` as `nil` because `identified` narrowed to
            /// `.directory` alone, so this cause was reported for an object
            /// that was at that name, had not been replaced, and HAD been
            /// read (`look` classified it `.noDirectoryTree`, which takes a
            /// real open attempt). That arm is fixed — `identified` now names
            /// every kind — and these are the four ways left in:
            ///
            /// * the landing is ABSENT (`ENOENT`) — the object is genuinely
            ///   not where the disposal said;
            /// * `rollBack`'s re-bind under the held Trash descriptor found
            ///   something ELSE at the name — it was replaced;
            /// * the put-back's own `renameatx_np` answered `ENOENT` — the
            ///   source went away inside the one-syscall window;
            /// * the landing could not be READ — `look` answered
            ///   `.unreadable(errno)` or `.unidentifiable`, or `facts` could
            ///   not name a non-directory at it.
            ///
            /// The FOURTH is the one where the user-facing wording ("it is no
            /// longer at …") is STRONGER than what was established: something
            /// may well still be there. It is disclosed rather than dressed:
            /// reaching it needs the landing to become unreadable AFTER
            /// `proveStanding` read the same object at the target, since
            /// `disagreement` refuses `.unreadable` on the way IN
            /// (`.posix(errno)`, before any disposal), and the four shipped
            /// arms all pass through it. `.strandedInTrash` is what the two
            /// cases that DO establish the object's presence report instead —
            /// the Trash open and the destination open, both below.
            ///
            /// AND THE CLAUSE THAT WAS NOT DISCLOSED, NOW RETIRED RATHER THAN
            /// DISCLOSED (PR #460 codex r15, D-P3). The paragraph above
            /// discloses that "it is no longer at …" is stronger than what was
            /// established. The message ALSO opened by asserting that the
            /// folder at the target's path had been replaced — and the
            /// after-proof never re-reads the target at all. MEASURED, event
            /// `moverMovedNothing`, all four Trash paths: this cause, zero
            /// moves, and the target untouched at the same inode. The opening
            /// is now the one proposition every row does establish; see
            /// `errorDescription`.
            case lastSeenInTrash(String)
            /// The rollback moved an object out of the Trash and the arrival
            /// is NOT the one it looked at — the name was re-pointed inside
            /// the one-syscall window the Trash directory descriptor cannot
            /// close. The payload is the Trash name it came from. Nothing
            /// further is attempted: a second unproven move is not a fix.
            ///
            /// AND WHERE THE INSPECTED OBJECT WENT IS NOT ESTABLISHED HERE,
            /// WHICH THE MESSAGE USED TO DENY (PR #460 codex r16, A-P1). The
            /// message ended "…and the item the Trash took is still in the
            /// Trash". Nothing on this path shows that: the re-bind proved
            /// the object stood at the landing NAME, and the rename then
            /// moved something ELSE out of that name — a fact about the NAME.
            /// MEASURED with the swap in the real window between the two, the
            /// taken object is moved OUT of the landing's own container
            /// entirely and its inode is present nowhere under it. The
            /// message now says the whereabouts were not established.
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

        /// ONE PROPOSITION A REFUSAL MESSAGE CAN CARRY — and the reason this
        /// is a TYPE rather than a list of banned phrases (PR #460 codex r17,
        /// M1).
        ///
        /// r15 fenced the OPENING clause of these messages; r16 found two
        /// false TAILS behind that fence and widened it to the whole message
        /// by adding a list of FORBIDDEN PHRASES. Measured at e6afc9f, that
        /// widening catches only the sentences somebody had already written
        /// down: restoring either retired tail reddens the guard, and saying
        /// the SAME FALSE THING IN NEW WORDS passes — `"Check your Trash for
        /// the item."` on `.lastSeenInTrash` was green on all 36 cells. A
        /// blocklist of strings is phrasing-fencing, which is the failure
        /// this branch has now repeated eight times.
        ///
        /// So the message is no longer a string literal per cause. It is a
        /// sequence of `Claim`s, each of which names exactly ONE proposition
        /// out of this closed vocabulary, and `established(for:)` says which
        /// propositions each cause's own code path actually proved. A new
        /// sentence cannot be added to a message without being tagged, and a
        /// tag the cause does not establish fails — WITHOUT anyone having
        /// predicted the sentence's wording.
        ///
        /// The last two cases are here precisely because NO arm establishes
        /// them: they are the two propositions this file has shipped and
        /// retired (r15's "the folder was replaced", r16/r17's net-effect
        /// claims), kept nameable so the fence can assert that no cause
        /// claims them.
        enum Established: String, CaseIterable, Sendable {
            /// The one proposition every row of the after-proof licenses:
            /// the disposal could not be PROVED to have moved the inspected
            /// item. Raised by every arm that reaches a comparison at all.
            case theDisposalWasNotProvedToHaveMovedTheItem
            /// `rollBack` completed its `renameatx_np` and IDENTIFIED the
            /// arrival at the target under the held, admitted destination
            /// descriptor. Only `.putBack` reaches that line.
            case theItemIsBackAtTheTarget
            /// An object WAS identified at `landed` — by the after-proof's
            /// own read or by `rollBack`'s re-bind — and it was not moved
            /// away afterwards, so it is still there.
            case theItemIsAtTheLanding
            /// The after-proof read the landing the disposal reported and
            /// could NOT name the inspected object there (absent, replaced,
            /// or unreadable). A negative fact about one name.
            case theLandingDidNotYieldTheItem
            /// The put-back's `renameatx_np` moved an object out of the
            /// landing name and the arrival was NOT the object the re-bind
            /// had identified there, so that NAME was re-pointed inside the
            /// one-syscall window.
            case theLandingNameWasRepointed
            /// …and what the put-back moved is now standing at the target.
            case aStrangerStandsAtTheTarget
            /// The directory the put-back would restore INTO is not the
            /// container the caller admitted — the identity comparison on
            /// `DepthSafeRemoval.openAdmittedContainer` failed.
            case theHoldingFolderIsNotTheAdmittedOne
            /// The mover returned no landing URL at all, so which object it
            /// took cannot be established.
            case theLandingWasNotReported
            /// The mover is a TRASH disposal and it returned without
            /// throwing, so whatever it took went to the Trash — only the
            /// name it went to is unknown. Established on
            /// `.destinationUnknown` and on nothing else: every other cause
            /// has read the landing the mover DID report.
            case theTrashHoldsWhatItTook
            /// The disclosure, not a claim: where the item is now was NOT
            /// established on this path.
            case theItemsWhereaboutsAreNotEstablished
            /// A fact about the REPORT this code writes — no entry, no
            /// bytes. Every cause establishes it, because every cause is a
            /// refusal.
            case nothingWasReportedFreed
            /// What the user can do next. Carries no proposition about the
            /// file system and may name no place.
            case theRemedyForThisRefusal
            /// NEVER ESTABLISHED BY ANY ARM: a claim about the DISK. Nothing
            /// after the mover returns counts bytes or re-reads the target's
            /// contents. `.putBack` shipped it as "nothing was freed" until
            /// r17's M4.
            case nothingWasFreedOnDisk
            /// NEVER ESTABLISHED BY ANY ARM: the target is never re-read
            /// after the move. Five messages opened with it until r15's
            /// D-P3.
            case theTargetWasReplaced
        }

        /// One clause of a refusal message, and the single proposition it
        /// asserts. `errorDescription` is the JOIN of these and contains no
        /// free text of its own, which is what makes the tag mandatory.
        struct Claim: Equatable, Sendable {
            let establishes: Established
            let text: String
        }

        /// WHAT THE PATH THAT RAISES EACH CAUSE ACTUALLY ESTABLISHED —
        /// derived from the code, cause by cause, and the reference every
        /// message is checked against.
        ///
        /// This `switch` has no `default:`, so a seventh cause cannot be
        /// added without answering this question for it.
        static func established(for cause: Cause) -> Set<Established> {
            // Every one of the six is a REFUSAL, so no entry and no bytes are
            // written for it, and every one of the six may say what to do
            // next.
            let always: Set<Established> = [
                .nothingWasReportedFreed, .theRemedyForThisRefusal,
            ]
            switch cause {
            case .putBack:
                // `rollBack` got past the Trash open, re-bound the landing,
                // opened AND PROVED the destination against the admitted
                // container, renamed, and identified the arrival there.
                return always.union([
                    .theDisposalWasNotProvedToHaveMovedTheItem,
                    .theItemIsBackAtTheTarget,
                ])
            case .strandedInTrash:
                // Reached from two places, and BOTH have an object identified
                // at the landing: the Trash open failed (`observed` is
                // non-`nil` on that line) or the destination open failed
                // after the re-bind matched. Nothing was moved either way, so
                // the object is still where the disposal put it.
                return always.union([
                    .theDisposalWasNotProvedToHaveMovedTheItem,
                    .theItemIsAtTheLanding,
                ])
            case .lastSeenInTrash:
                // The landing could not be named — absent, replaced,
                // unreadable, or the rename answered ENOENT. Nothing was
                // moved, and where the object is was NOT established: it may
                // never have left the target, and it may be somewhere this
                // process could not read.
                return always.union([
                    .theDisposalWasNotProvedToHaveMovedTheItem,
                    .theLandingDidNotYieldTheItem,
                    .theItemsWhereaboutsAreNotEstablished,
                ])
            case .putBackTookAnotherObject:
                // The re-bind identified an object at the landing NAME and
                // the rename then moved a DIFFERENT one out of it. That is a
                // fact about the name and about what now stands at the
                // target; it says nothing about where the first object went
                // (r16, A-P1 — measured: it is not under the landing's
                // container at all).
                return always.union([
                    .theDisposalWasNotProvedToHaveMovedTheItem,
                    .theLandingNameWasRepointed, .aStrangerStandsAtTheTarget,
                    .theItemsWhereaboutsAreNotEstablished,
                ])
            case .destinationNotTheAdmittedContainer:
                // The destination open+prove failed on IDENTITY, after the
                // re-bind had matched at the landing. So the object is still
                // at the landing and the folder that holds the target is not
                // the admitted one.
                return always.union([
                    .theDisposalWasNotProvedToHaveMovedTheItem,
                    .theHoldingFolderIsNotTheAdmittedOne,
                    .theItemIsAtTheLanding,
                ])
            case .destinationUnknown:
                // Raised before anything about a landing is known — the
                // mover returned `nil`. It did NOT throw, and the seam's
                // contract is a move to the Trash, so what it took is in the
                // Trash under a name this code was never told.
                // `.theDisposalWasNotProvedToHaveMovedTheItem` is NOT here:
                // this message never carried the shared opening, and must not
                // gain one (r15, D-P3).
                return always.union([
                    .theLandingWasNotReported, .theTrashHoldsWhatItTook,
                ])
            }
        }

        /// THE MESSAGE, CLAUSE BY CLAUSE.
        ///
        /// THE SHARED OPENING, AND WHY IT IS THIS ONE (PR #460 codex r15,
        /// D-P3). Five of these six messages used to open "the folder at this
        /// path is no longer the one that was inspected — it was replaced
        /// between the safety check and the disposal". NO ARM'S AFTER-PROOF
        /// TESTS THAT. Everything this file establishes after the mover
        /// returns is about the LANDING: `facts(at: landed)` / `look(at:
        /// landed)` compared with what was bound. THE TARGET IS NEVER
        /// RE-READ. MEASURED at df551b1, event `moverMovedNothing` (the mover
        /// proves, moves nothing, and reports a landing where nothing
        /// stands), all four Trash paths: `.lastSeenInTrash`, zero moves, and
        /// the target still on disk, untouched, SAME INODE. The message told
        /// the user their folder had been replaced — and told them to go and
        /// look in the Trash — for an item that never left.
        ///
        /// AND THE OPENING WAS ONLY THE OPENING (PR #460 codex r16,
        /// A-P1/A-P2). r15's two guards inspected the FIRST CLAUSE and
        /// nothing else, so two false TAILS walked straight through them:
        /// `.lastSeenInTrash` ended "Look in the Trash for it" (measured on
        /// the `moverMovedNothing` fixture at 3110d1e: this cause, ZERO
        /// moves, the item STILL AT THE TARGET at the SAME INODE, nothing in
        /// the Trash at all), and `.putBackTookAnotherObject` ended "…and the
        /// item the Trash took is still in the Trash" (measured at 3110d1e
        /// with the swap in the real one-syscall window: the taken object is
        /// moved OUT of the landing's container entirely).
        ///
        /// AND THE FENCE THAT CAUGHT THOSE TWO CAUGHT ONLY THOSE TWO (PR #460
        /// codex r17, M1) — see `Established`. The messages are assembled
        /// here from tagged clauses so that the FENCE CAN BE A PROPERTY: no
        /// clause may assert a proposition its own cause did not establish,
        /// and there is no untagged text for a new false sentence to hide in.
        ///
        /// Pinned by `TrashDisposalHopProofTests`'
        /// `…NoTrashFailureMessageAssertsAnythingItsOwnProofDidNotEstablish`
        /// (the property fence, off the type),
        /// `…NoFailureMessageAssertsTheTargetWasReplacedWithoutReadingIt` and
        /// `…EveryTrashFailureMessageOpensWithWhatWasActuallyProved` (r15's
        /// opening guards, kept), and the two fixture cells that prove the
        /// retired propositions FALSE on the events their causes are named
        /// for —
        /// `…TheLastSeenMessageDoesNotSendTheUserToTheTrashForAnItemStillOnDisk`
        /// and `…APutBackThatTookAnotherObjectDoesNotClaimWhereTheTakenOneIs`.
        static func claims(path: String, cause: Cause) -> [Claim] {
            let unproved = Claim(
                establishes: .theDisposalWasNotProvedToHaveMovedTheItem,
                text: "\(path): the disposal could not be proved to have "
                    + "moved the item that was inspected"
            )
            let nothingFreed = Claim(
                establishes: .nothingWasReportedFreed,
                text: "; nothing was reported freed"
            )
            let rescan = Claim(
                establishes: .theRemedyForThisRefusal,
                text: "; refused, re-scan required"
            )
            switch cause {
            case .putBack:
                // THIS MESSAGE HAS CARRIED TWO NET-EFFECT CLAIMS AND BOTH
                // ARE RETIRED, one round apart.
                //
                // "Nothing was moved to the Trash" (retired r16, A-P4b) was
                // false about the net effect: an object WAS moved to the
                // Trash and then retrieved from it. What this arm PROVED is
                // narrower and is what the clause below says — the object
                // was moved back out under the held Trash descriptor and
                // IDENTIFIED at this path under the held, admitted
                // destination descriptor.
                //
                // "nothing was freed" (retired r17, M4) survived that fix by
                // one clause, and was the only one of the six messages to
                // make the claim BARE — the other five say "nothing was
                // REPORTED freed", which is a fact about the report this
                // code writes. "Nothing was freed" is a fact about the DISK,
                // and this arm establishes no such thing: on the fixture
                // that produces the cause the inspected object really is
                // gone from where it stood, and the after-proof never looks
                // at bytes. r16's whole-message guard did not catch it,
                // because that guard was a list of phrases somebody had
                // already thought of and this phrase was not on it. What
                // keeps the class out now is `Established`'s
                // `.nothingWasFreedOnDisk` — a proposition NO arm
                // establishes, against which every clause carrying a
                // net-effect word is checked.
                return [
                    unproved,
                    Claim(
                        establishes: .theItemIsBackAtTheTarget,
                        text: ", so what it did take has been PUT BACK: it "
                            + "was moved back out of the Trash and identified "
                            + "at this path"
                    ),
                    nothingFreed, rescan,
                ]
            case .strandedInTrash(let landed):
                return [
                    unproved,
                    Claim(
                        establishes: .theItemIsAtTheLanding,
                        text: ", and what it did take could not be put back "
                            + "automatically — it is in the Trash at "
                            + "\(landed)."
                    ),
                    Claim(
                        establishes: .theItemIsAtTheLanding,
                        text: " Move it back from there"
                    ),
                    nothingFreed, rescan,
                ]
            case .lastSeenInTrash(let landed):
                return [
                    unproved,
                    Claim(
                        establishes: .theLandingDidNotYieldTheItem,
                        text: ", and nothing could be put back — what it "
                            + "reported putting at \(landed) cannot be found "
                            + "there now, so nothing was moved rather than "
                            + "moving whatever took its place."
                    ),
                    Claim(
                        establishes: .theItemsWhereaboutsAreNotEstablished,
                        text: " Where the item is now was NOT established: it "
                            + "may never have left \(path), and it may be "
                            + "somewhere this could not read."
                    ),
                    Claim(
                        establishes: .nothingWasReportedFreed,
                        text: " Nothing was reported freed"
                    ),
                    rescan,
                ]
            case .putBackTookAnotherObject(let landed):
                return [
                    unproved,
                    Claim(
                        establishes: .theLandingNameWasRepointed,
                        text: ", and putting back what it did take moved a "
                            + "DIFFERENT object — the Trash name it came from "
                            + "(\(landed)) was re-used while the undo was "
                            + "running."
                    ),
                    Claim(
                        establishes: .aStrangerStandsAtTheTarget,
                        text: " Whatever now stands at \(path) came out of "
                            + "the Trash and was NOT put there by you."
                    ),
                    Claim(
                        establishes: .theItemsWhereaboutsAreNotEstablished,
                        text: " Where the item the Trash took is now was NOT "
                            + "established — all that was proved is that its "
                            + "Trash name was re-pointed"
                    ),
                    nothingFreed, rescan,
                ]
            case .destinationNotTheAdmittedContainer(let landed):
                return [
                    unproved,
                    Claim(
                        establishes: .theHoldingFolderIsNotTheAdmittedOne,
                        text: ", and the folder that HOLDS this path is no "
                            + "longer the one the safety check admitted — so "
                            + "what the Trash took was NOT put back into it."
                    ),
                    Claim(
                        establishes: .theItemIsAtTheLanding,
                        text: " It is in the Trash at \(landed)."
                    ),
                    Claim(
                        establishes: .theHoldingFolderIsNotTheAdmittedOne,
                        text: " Move it back once the folder at \(path) is "
                            + "the one you expect"
                    ),
                    nothingFreed, rescan,
                ]
            case .destinationUnknown:
                return [
                    Claim(
                        establishes: .theLandingWasNotReported,
                        text: "\(path): the Trash did not report where it put "
                            + "the item, so which folder it took cannot be "
                            + "established"
                    ),
                    Claim(
                        establishes: .nothingWasReportedFreed,
                        text: " — nothing was reported freed."
                    ),
                    Claim(
                        establishes: .theTrashHoldsWhatItTook,
                        text: " Check the Trash,"
                    ),
                    Claim(
                        establishes: .theRemedyForThisRefusal,
                        text: " and use permanent delete (turn off Move to "
                            + "Trash) for a disposal that proves the folder "
                            + "it acts on"
                    ),
                ]
            }
        }

        /// The join, and NOTHING ELSE. Every word the user sees comes from a
        /// `Claim` that named the proposition it asserts; there is no free
        /// text here for an unfenced sentence to live in.
        var errorDescription: String? {
            Self.claims(path: path, cause: cause).map(\.text).joined()
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
        // WHICH ARM, AND WHY TWO OF THE FOUR VERDICTS LEAVE THIS FUNCTION
        // IMMEDIATELY (PR #460 codex r13, A).
        //
        // `look` is the only proof `proveStanding` has, and `look`'s kind
        // gate is an `O_DIRECTORY` open: it can IDENTIFY a directory and
        // nothing else. So it answers a verdict ABOUT a directory
        // (`.directory(identity)`) and cannot answer either verdict about a
        // non-directory — `.nonDirectoryLeaf` because ENOTDIR/ELOOP name no
        // inode, `.noDirectoryTree` because the verdict itself carries no
        // identity to compare against and so reduces, on BOTH sides of the
        // move, to "some non-directory answers to this name". ANY
        // non-directory in ANY directory satisfies that, and until r13 this
        // arm never opened `admittedParent` at all: the parameter was
        // consulted only inside `.nonDirectoryLeaf`'s `boundLeaf` and inside
        // `rollBack`.
        //
        // MEASURED AT 0139713, three ways, with the production provider and
        // two real `rename(2)`s: at this level the stranger's file was moved
        // to the landing and `dispose` RETURNED NORMALLY; through the
        // production composition (real `CacheCleaner`, real
        // `OrphanedCachesScanner.preDeleteRevalidator`, real PathGuard
        // admission, `moveToTrash: true` — the GUI's shipped default) the
        // report read `entries=[… exactBytes: 4096, disposal: .trash],
        // errors=[]`; and with NOTHING injected at the seam — the shipped
        // `FileManager.trashItem`, into the REAL `~/.Trash` — the stranger's
        // file was left sitting in the user's Trash and its bytes reported
        // freed. The PERMANENT arm refuses the identical event on the
        // identical fixture, because `DepthSafeRemoval.remove` goes through
        // `openAdmittedContainer` for EVERY verdict; so does the sibling
        // overload below. This was the one destructive path in the product
        // that did not bind its container.
        //
        // BINDING THE CONTAINER ALONE IS NOT ENOUGH, AND THAT WAS MEASURED
        // TOO. A probe that only added `openAdmittedContainer` on both sides
        // of the seam still trashed the stranger with `errors=[]` when the
        // container was swapped INSIDE the mover — the window `trashItem`'s
        // own resolution owns, the window the file header says the
        // after-proof exists to catch — because the after-proof then reads
        // `look(at: landed) == .noDirectoryTree` and
        // `disagreement(.noDirectoryTree, .noDirectoryTree)` is `nil`. FOR
        // THIS VERDICT THE AFTER-PROOF IS NOT LOAD-BEARING; THE BINDING IS.
        //
        // So both non-directory verdicts take the one shape that binds an
        // OBJECT: `boundLeaf` under the PROVED container, on both sides of
        // the move. `disposeBoundLeaf` is that shape, spelled once, and the
        // container-bound overload below is the same call with the widest
        // admission — three arms that cannot drift because they are one
        // function.
        switch inspected {
        case .nonDirectoryLeaf(let expected):
            // The revalidator held this leaf open and read its inode (PR
            // #459 review r5 — before that, ANY `.noDirectoryTree` sighting
            // satisfied the file arm's verdict and a swapped-in file was
            // trashed and KEPT with success reported).
            try await disposeBoundLeaf(
                target, containedIn: admittedParent, provider: provider,
                admitting: .exactly(expected), via: disposal
            )
            return
        case .noDirectoryTree:
            // NO IDENTITY EXISTS TO REQUIRE — the verdict's one producer is
            // the probe whose root open FAILED (`OrphanedCachesScanner`), so
            // it never held one. What CAN be required is the residual's own
            // shape: a directory appearing at that name since voids the
            // verdict (`PreDeleteInspectedObject.noDirectoryTree` says so),
            // and it is a kind the permanent arm gets refused by the kernel
            // — `unlinkat` without `AT_REMOVEDIR` cannot remove a directory,
            // measured EPERM — while `trashItem` takes it happily. So the
            // kind check is kept HERE, where it is the only thing keeping
            // the two arms level, and the identity-free residual ("any
            // non-directory at the name satisfies it") is now bounded to ONE
            // directory: the admitted container, proved on both sides.
            //
            // GHOST TARGETS MOVE ONE CALL EARLIER, DELIBERATELY. Through r12
            // an absent target satisfied `proveStanding`
            // (`absenceProves: true`) and the disposal produced its own
            // ENOENT; `boundLeaf` throws `.posix(ENOENT)` before the move
            // instead. Both are item-keyed POSIX errors and neither is a
            // silent skip, so the choice is between two spellings of one
            // outcome — and this one keeps the user's Trash UNTOUCHED for an
            // item that was never there, which the other cannot promise,
            // because it hands the NAME to `trashItem` and whatever answers
            // to it a moment later is what gets taken.
            try await disposeBoundLeaf(
                target, containedIn: admittedParent, provider: provider,
                admitting: .anythingButADirectory, via: disposal
            )
            return
        case .directory, .unestablished:
            break
        }

        // (0) WHOSE FOLDER IS THIS? (PR #460 codex r13, A2.) Asked before
        // anything is read at the target's name, and asked the way every
        // other destructive arm asks it — `DepthSafeRemoval`'s
        // `openAdmittedContainer`, which opens the container and `fstat`s
        // the descriptor against the identity the cleaner captured.
        //
        // The `.directory` arm SURVIVED a container swap without this, but
        // only INCIDENTALLY: `Identity` is dev+inode, so a stranger's
        // directory can never equal the inspected inode and the refusal came
        // back as `.notTheInspectedObject` — logged `content-drift`, the tag
        // for "the item changed", for an event in which the item did not
        // change and its FOLDER did. The permanent arm and the
        // container-bound overload both answer `.notTheAdmittedContainer` /
        // `container-drift` for the identical event. A user told the wrong
        // fact goes and looks at the wrong thing.
        //
        // `.unestablished` reaches here too and every arm below refuses it
        // (`disagreement`'s `guard case`s each name a different case), which
        // is the fail-closed default rather than a fourth shape.
        //
        // (1) …AND THE LEAF IS READ UNDER THAT SAME DESCRIPTOR — the cheap
        // refusal, and the one that keeps the Trash untouched. The two used
        // to be separate acts, and the second one re-opened the container by
        // PATH with `O_NOFOLLOW` (see `proveStandingUnderAdmittedContainer`
        // for what that cost).
        try proveStandingUnderAdmittedContainer(
            inspected, at: target, containedIn: admittedParent,
            provider: provider
        )

        // (1b) THE SAME PROOF, ON THE FAR SIDE OF THE SEAM'S HOP (D1). (0)
        // and (1) are taken here; the move happens after a main-actor hop
        // whose length is the main thread's queue depth, not a syscall. The
        // container is opened and proved AGAIN here rather than carried
        // across the hop on a descriptor: a descriptor held across it would
        // still be the pre-hop container, and what this has to catch is a
        // container swapped INSIDE it.
        let landed = try await disposal(target) {
            try proveStandingUnderAdmittedContainer(
                inspected, at: target, containedIn: admittedParent,
                provider: provider
            )
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
                    identified(sighting, at: landed, provider: provider),
                    from: landed, to: target,
                    containedIn: admittedParent, provider: provider
                )
            )
        }
    }

    /// WHAT THE PRE-MOVE BINDING MUST SHOW for a disposal to proceed — the
    /// ONLY thing that differs between the three arms that bind a leaf under
    /// a proved container.
    ///
    /// A value rather than a closure so nothing about an arm can be
    /// captured, escape, or cross the mover's hop.
    enum LeafAdmission: Equatable {
        /// NO leaf verdict exists (all of contents mode, plus every item
        /// whose scanner registers no revalidator): the binding under the
        /// proved container IS the whole proposition, and the after-proof
        /// carries the rest.
        case whateverStandsThere
        /// `.nonDirectoryLeaf(identity)` — the revalidator held the leaf open
        /// and read its inode, so equality is available and required.
        case exactly(FileSystemIdentityProvider.Identity)
        /// `.noDirectoryTree` — identity-free by construction (its producer's
        /// root open FAILED), so the only proposition the verdict carries is
        /// that no directory TREE of ours stood at the name.
        case anythingButADirectory

        func admits(_ facts: FileSystemIdentityProvider.ChildFacts) -> Bool {
            switch self {
            case .whateverStandsThere: return true
            case .exactly(let identity): return facts.identity == identity
            case .anythingButADirectory: return facts.kind != .directory
            }
        }
    }

    /// THE CONTAINER IS PROVED AND THEN THE LEAF IS READ UNDER IT — the
    /// `.directory` verdict's whole pre-move proof, as ONE act.
    ///
    /// It is `boundLeaf`'s shape with one difference, and the difference is
    /// forced: this verdict's rollback depends on `look`'s `.unidentifiable`
    /// arm, which only an OPENED inode can produce, so the leaf is opened
    /// (`openat`, `O_NOFOLLOW`) rather than `fstatat`ed. The CONTAINER half is
    /// identical — `DepthSafeRemoval.openAdmittedContainer`, the same call the
    /// permanent arm and `boundLeaf` make, so the three cannot answer
    /// differently about whose folder this is.
    ///
    /// ## AND THAT IS THE FIX (PR #460 codex r14, V1-D2)
    ///
    /// r13 proved the container, CLOSED the descriptor, and then read the leaf
    /// with `look(at:)`, which re-opened the container BY PATH with
    /// `O_NOFOLLOW`. `DepthSafeRemoval.openContainer` deliberately FOLLOWS,
    /// and its header states the reason verbatim: "a no-follow open would
    /// refuse it while `remove`'s open succeeded — a binding that refuses
    /// every deletion under a symlinked cache root". So the two opens
    /// disagreed by construction, and this one arm refused what the other four
    /// destructive paths perform.
    ///
    /// MEASURED at 6866012 on `base/link -> base/real`, target
    /// `base/link/victim`, production provider, one `AdmittedParent`:
    /// permanent DELETED, `dispose(_:containedIn:)` TRASHED, the
    /// `.noDirectoryTree` arm TRASHED, the `.nonDirectoryLeaf` arm TRASHED,
    /// and this arm REFUSED `.posix(20)` — surfaced to the user as
    /// "…/victim: Not a directory" about a directory that plainly is one. No
    /// shipped scanner reached it (both `.directory` producers emit only
    /// direct children of their admitted roots), so it was latent rather than
    /// shipping. Evidenced by
    /// `TrashDisposalHopProofTests.testEveryDestructivePathDisposesUnderASymlinkedContainer`
    /// — the FORWARD half, all five paths. The undo half is r15's D-P1, and
    /// until that round it was where the paths still disagreed:
    /// `rollBack`'s destination open was left on `openDirectoryNoFollow`, so
    /// this fix moved the arm from "refuses before the move" to "moves the
    /// item to the Trash and then cannot put it back".
    ///
    /// The re-open also went away with it: the container was being resolved
    /// twice per proof, and the second resolution was the unbound one.
    ///
    /// THE LANDING'S CONTAINER OPEN IS UNCHANGED AND MUST STAY SO. `look(at:)`
    /// still opens ITS container `O_NOFOLLOW`, because the Trash's container
    /// is proved against nothing — see `look`'s header and
    /// `…RefusesASymlinkedLandingContainer`. Following there identified the
    /// object on the other side of a link and reported a move that never
    /// happened; following HERE is the only way to agree with the open that
    /// the deletion itself uses.
    private static func proveStandingUnderAdmittedContainer(
        _ inspected: UserDataProbeResult.InspectedRoot,
        at target: URL,
        containedIn admittedParent: DepthSafeRemoval.AdmittedParent,
        provider: FileSystemIdentityProvider
    ) throws {
        let fd = try DepthSafeRemoval.openAdmittedContainer(
            at: target.deletingLastPathComponent(),
            provenAgainst: admittedParent, displayPath: target.path,
            provider: provider
        )
        defer { close(fd) }
        // `absenceProves: true` — the frozen ghost-target behaviour, and the
        // same value `proveStanding` passes. See `proveStanding`.
        if let cause = disagreement(
            inspected,
            with: look(
                named: target.lastPathComponent, inDirectory: fd,
                logical: target, provider: provider
            ),
            absenceProves: true
        ) {
            throw DepthSafeRemoval.Failure(
                path: target.path, cause: cause, depth: 0
            )
        }
    }

    /// THE ONE DISPOSAL SHAPE THAT BINDS AN OBJECT — used by every arm that
    /// can have one, which since PR #460 codex r13 is every arm except the
    /// `.directory` verdict's (whose proof must come off an OPENED inode,
    /// because its rollback depends on `look`'s `.unidentifiable`).
    ///
    /// 1. BEFORE — the container is opened and `fstat`ed against
    ///    `DepthSafeRemoval.admittedParent`'s identity, and the leaf is bound
    ///    under THAT descriptor with one `fstatat` (`probeChild`: kind and
    ///    identity from a single resolution no rename can re-point). What the
    ///    binding must SHOW is `admission`'s business and nothing else's.
    /// 2. AGAIN, IMMEDIATELY BEFORE THE MOVE, wherever the mover runs — the
    ///    load-bearing one, because the production seam hops to the main
    ///    actor and that hop is the main thread's queue depth (PR #460 codex
    ///    r6, D1). Both readings are the SAME `boundLeaf` under the SAME
    ///    proved container, so a difference is a swap inside the hop and
    ///    nothing else.
    /// 3. AFTER — what landed is read the same descriptor-relative way and
    ///    required EQUAL to the bound facts. A mismatch is PUT BACK through
    ///    `rollBack`, which proves its own destination against the same
    ///    admitted container, and reported as a refusal: no entry, no bytes.
    private static func disposeBoundLeaf(
        _ target: URL,
        containedIn admittedParent: DepthSafeRemoval.AdmittedParent,
        provider: FileSystemIdentityProvider,
        admitting admission: LeafAdmission,
        via disposal: Mover
    ) async throws {
        let bound = try boundLeaf(
            of: target, containedIn: admittedParent, provider: provider
        )
        guard admission.admits(bound) else {
            // Refused BEFORE the move: the Trash is untouched. The same
            // cause the permanent arm throws for the same event, so the
            // cleaner's log tags both `content-drift`.
            throw DepthSafeRemoval.Failure(
                path: target.path, cause: .notTheInspectedObject, depth: 0
            )
        }
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
        // THE SAME SHAPE THE OTHER ENTRY POINT'S TWO NON-DIRECTORY ARMS TAKE,
        // SPELLED ONCE (PR #460 codex r13, A). This arm has no verdict, so
        // its admission is the widest one there is — but the binding, the
        // proof across the hop, the after-proof and the rollback are
        // literally the same code, which is what stops the arms drifting.
        try await disposeBoundLeaf(
            target, containedIn: admittedParent, provider: provider,
            admitting: .whateverStandsThere, via: disposal
        )
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
        // enumerated child), so no DISPOSAL fixture can kill it: measured at
        // r13, deleting it alone leaves 361 tests across the six destructive
        // suites GREEN, because `probeChild` carries the identical
        // precondition and answers `EINVAL` itself.
        //
        // WHAT ITS REMOVAL DOES CHANGE IS THE CAUSE, AND THAT IS EVIDENCED
        // RATHER THAN CONCEDED (PR #460 codex r13, E). This guard answers
        // BEFORE anything is resolved; without it the malformed name is
        // resolved first and the refusal reports whatever that resolution
        // says — measured on the cell's fixture, `.notTheAdmittedContainer`,
        // which tells the user the FOLDER changed about a target whose name
        // was never valid. Pinned by
        // `TrashDisposalHopProofTests.testALookAtAnUnsafeNameIsRefusedRatherThanResolvedAlongThePath`.
        // The claim that stood here — that deleting this AND the copy in
        // `facts` together leaves the full suite green — was true when it was
        // written and is false now: `facts`' copy is load-bearing over its
        // `probeLeaf` fallback, and both have cells.
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
        // THE SAME GUARD OVER THE SAME HOLE AS `look`'s, and load-bearing for
        // the same reason (PR #460 codex r13, E): this function's
        // permission-class fallback is `probeLeaf`, an `lstat` of the PATH
        // with no name check beneath it. Measured with the guard deleted:
        // `facts` at a name of `..` under a permission-denied container
        // returns `ChildFacts(kind: .directory, identity: <the container>)`
        // where the guard returns `nil`. Same cell as `look`'s.
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

    /// The `Sighting` → `ChildFacts` narrowing, in ONE place: what the
    /// landing IS, for the rollback that has to name the object it moves.
    ///
    /// ## THE NON-DIRECTORY LANDING WAS ABANDONED, AND THE USER WAS TOLD IT
    /// ## WAS NOT THERE (PR #460 codex r14, V1-D1)
    ///
    /// Through r13 this was `guard case .directory` and nothing else, so
    /// EVERY other sighting reached `rollBack` as `nil` — including a landing
    /// that is a perfectly ordinary regular file, symlink or fifo, sitting
    /// exactly where the Trash said it put it. `rollBack`'s first guard then
    /// returned `.lastSeenInTrash`, whose message tells the user the object
    /// "is no longer at <landing>, where the Trash reported putting it, so
    /// nothing was moved".
    ///
    /// MEASURED through the production composition (real `CacheCleaner`, real
    /// `OrphanedCachesScanner.preDeleteRevalidator`, real PathGuard, real
    /// `ContainerSnapshot`, `moveToTrash: true` — the GUI's shipped default —
    /// with only the seam injected, to put the swap in the window
    /// `trashItem`'s own URL resolution owns): that message was reported with
    /// the object STILL AT THE LANDING and the target NOT restored,
    /// `entries=0`. The identical event through `dispose(_:containedIn:…)`
    /// yields `.putBack`, because the `disposeBoundLeaf` arms read their
    /// landing with `facts(at:)` — which identifies every KIND — instead of
    /// this narrowing.
    ///
    /// WHY A SECOND READ RATHER THAN A RICHER `Sighting`: `look`'s kind gate
    /// IS its `O_DIRECTORY` open, so a non-directory landing is classified by
    /// ERRNO (`ENOTDIR`/`ELOOP`) and no inode is ever read. There is no
    /// identity in the sighting to hand over — naming the object requires the
    /// `fstatat` `facts` takes, and that is what this now does for exactly
    /// that case.
    ///
    /// THE `.directory` CASE STILL COMES OFF THE OPENED INODE and is NOT
    /// re-read: it is the stronger fact (an `fstat` of a descriptor `look`
    /// held open, versus a name resolved a second time), and `rollBack`'s
    /// re-bind is what turns either into a move. `.absent`, `.unreadable` and
    /// `.unidentifiable` stay `nil` — nothing was identified, so nothing may
    /// be moved.
    private static func identified(
        _ sighting: Sighting, at landed: URL,
        provider: FileSystemIdentityProvider
    ) -> FileSystemIdentityProvider.ChildFacts? {
        switch sighting {
        case .directory(let identity):
            return FileSystemIdentityProvider.ChildFacts(
                kind: .directory, identity: identity
            )
        case .noDirectoryTree:
            return facts(at: landed, provider: provider)
        case .absent, .unidentifiable, .unreadable:
            return nil
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
    /// ## AND THIS ENTRY POINT IS THE LANDING'S, NOT THE TARGET'S (r14, V1-D2)
    ///
    /// Everything above is about a container NOBODY PROVED — `~/.Trash`, whose
    /// spelling comes from the mover. The TARGET's container is proved, so its
    /// leaf is read through `proveStandingUnderAdmittedContainer` instead,
    /// under the descriptor `DepthSafeRemoval.openAdmittedContainer` returns —
    /// an open that deliberately FOLLOWS, because every other destructive path
    /// follows and a no-follow open here refused what all four of them
    /// performed. The two containers get two different opens because they are
    /// two different questions; the leaf is `O_NOFOLLOW` in both.
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
        // LOAD-BEARING ON THE FALLBACK, AND THE COMMENT THAT STOOD HERE SAID
        // THE OPPOSITE (PR #460 codex r13, E). It called this a precondition
        // "restated where it is called" and recorded that NO CELL FAILS when
        // it is deleted — which r12's mutation M5 confirmed, red_count 0.
        // Both readings were about the DESCRIPTOR-RELATIVE arm, where
        // `openChildDirectory` carries the identical precondition and answers
        // `EINVAL` itself, so nothing can tell the two apart.
        //
        // `lookAlongThePath` is the arm this holds. It is a path-spelled
        // `open(url.path, …)` with NO name check anywhere beneath it, and
        // `O_NOFOLLOW` does not object to `..` — measured, with the guard
        // deleted: `look` at a name of `..` under a permission-denied
        // container returns `.directory(<the container's identity>)`, an
        // identity for a directory two levels above the name the caller
        // asked about, where the guard returns `.unreadable(errno: EINVAL)`.
        // The denial that routes it there is the ORDINARY production one:
        // `~/.Trash` answers `EPERM` to every process without Full Disk
        // Access. Evidenced by
        // `TrashDisposalHopProofTests.testALookAtAnUnsafeNameIsRefusedRatherThanResolvedAlongThePath`.
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
    ///
    /// THE PRECONDITION IS CHECKED HERE, NOT ONLY AT THE PATH-SPELLED CALLER
    /// (PR #460 codex r14, V1-D2). `look(at:)` guards before it reaches this,
    /// because ITS fallback is a path open with no name check beneath it; this
    /// function has a second caller now —
    /// `proveStandingUnderAdmittedContainer`, which resolves the target's own
    /// last component under the PROVED container — and `openat` would happily
    /// walk a `..` out of the descriptor it was handed. Guarding the shared
    /// spelling rather than each call site is what stops the next caller from
    /// having to remember.
    ///
    /// WHAT IT BUYS IS THE CAUSE, MEASURED rather than assumed: with it
    /// deleted the disposal is still REFUSED, because
    /// `URL.deletingLastPathComponent()` does not cancel a `..` (it answers
    /// `<child>/../`), so the container open and the `openat` under it land
    /// one level apart and the identity comparison disagrees. The refusal that
    /// comes back is then `.notTheInspectedObject` — the user is told the ITEM
    /// changed about a target whose NAME was never valid, which is exactly the
    /// wrong-fact-to-the-user class r13's A2 was about. Evidenced by
    /// `TrashDisposalHopProofTests.testTheDirectoryVerdictArmRefusesATargetSpelledOutOfItsOwnContainer`
    /// (full suite under the mutation: 1532 executed / 1 failure, that cell
    /// alone).
    private static func look(
        named name: String, inDirectory container: Int32,
        logical url: URL, provider: FileSystemIdentityProvider
    ) -> Sighting {
        guard FileSystemIdentityProvider.isSafeComponent(name) else {
            return .unreadable(errno: EINVAL)
        }
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
            // NOTHING IS AT THE NAME, AND "NOTHING" IS NOT "SOMETHING ELSE"
            // (PR #460 codex r15, D-P2).
            //
            // The two positions are two different questions, so they get two
            // different refusals rather than one.
            guard absenceProves else {
                // THE LANDING. The disposal CLAIMED to put an item at this
                // URL; an empty name establishes nothing about what it took,
                // and unestablished is refused. The clause is literally true
                // here — nothing at the landing is the inspected object — and
                // no production caller surfaces this value anyway: `dispose`
                // reads only whether it is `nil` and reports `rollBack`'s own
                // cause, and `proveTaken` has no production caller.
                return .notTheInspectedObject
            }
            guard case .noDirectoryTree = inspected else {
                // THE TARGET, BEFORE THE MOVE — a plain race: the item
                // vanishes between the revalidator's verdict and the
                // disposal. MEASURED at 48073c9 on one absent-target fixture:
                // `DepthSafeRemoval.remove`, `dispose(_:containedIn:)`, the
                // `.noDirectoryTree` arm and the `.nonDirectoryLeaf` arm all
                // answered `.posix(2)` — the other four reach `boundLeaf`'s
                // `.absent` arm or the removal's own leaf open, both of which
                // keep ENOENT — while THIS arm answered
                // `.notTheInspectedObject`, surfaced as "it was replaced
                // between the safety check and the deletion" and logged
                // `content-drift`. Nothing was replaced; the name is empty,
                // and a user told the wrong fact goes and looks at the wrong
                // thing (the r13-A2 class, one arm over).
                return .posix(ENOENT)
            }
            // THE FROZEN GHOST-TARGET BEHAVIOUR, and the one absence that
            // PROVES its verdict: `.noDirectoryTree` is precisely a statement
            // that no directory tree of ours stood at this name.
            //
            // AND IT IS NO LONGER ON A PRODUCTION PATH, WHICH IS WORTH
            // SAYING RATHER THAN LEAVING TO BE INFERRED (PR #460 codex r16,
            // A-P4c). `absenceProves: true` is reached in production only
            // through `proveStandingUnderAdmittedContainer`, which
            // `dispose(_:expecting:…)` calls for the `.directory` and
            // `.unestablished` verdicts — never for `.noDirectoryTree`,
            // which r13 routed to `disposeBoundLeaf`. That arm throws
            // `.posix(ENOENT)` one call EARLIER, which is the deliberate
            // choice recorded at the `case .noDirectoryTree` above: it keeps
            // the user's Trash untouched for an item that was never there.
            // So this line is held alive by a TEST-ONLY entry point:
            // `TrashDisposal.proveStanding`, whose only callers are
            // `TrashDisposalHopProofTests`'
            // `…ALookInsideAContainerThatIsGoneIsStillAnAbsence` and
            // `OrphanedCachesScannerTests`'
            // `…AnAbsenceProvesTheVerdictBeforeTheDisposalOnly`.
            //
            // MEASURED at 073371c: replacing this `return nil` with
            // `.posix(ENOENT)` and running the FULL SUITE reddens exactly
            // those TWO cells and nothing else — 1558 executed / 2 skipped /
            // 2 failures, exit 1, 205 s. Neither reaches production; both
            // call `proveStanding` directly. It is kept because the asymmetry
            // it encodes is the contract `absenceProves` exists to express,
            // and because a deleted branch is a contract nobody can
            // re-check.
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
        // AND A LANDING THAT IS SIMPLY NOT A DIRECTORY IS NOT ONE OF THOSE
        // (PR #460 codex r14, V1-D1). It used to arrive here as `nil` — the
        // fourth case this comment did not enumerate, and the one that made
        // the enumeration false — because the verdict-bound caller narrowed
        // its sighting with a `guard case .directory`. It now arrives NAMED,
        // through the same `facts` the bound arms read their landing with, so
        // the three cases above are again the whole of what reaches this
        // guard as `nil`.
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
        // through it and BOTH of them can bind non-directories: the bound
        // arms by construction (see `dispose(_:containedIn:…)`), and the
        // verdict-bound one since r14 — its `identified` reads a
        // non-directory landing with `facts` rather than discarding it.
        guard let observed else {
            return .lastSeenInTrash(landed.path)
        }
        let source = landed.lastPathComponent
        let destination = target.lastPathComponent
        // A PRECONDITION, DISCLOSED AS ONE RATHER THAN DRESSED AS A GUARD.
        // `probeChild`/`renameatx_np` take a SINGLE component and resolve a
        // multi-component one through the held directory, which would let a
        // symlinked middle component out of it.
        //
        // THIS IS THE ONE COPY THAT STAYS DISCLOSED RATHER THAN EVIDENCED,
        // AND THE REASON IS STATED (PR #460 codex r13, E). Its SOURCE half is
        // subsumed — `probeChild` answers `EINVAL`, the comparison below
        // fails, and `.lastSeenInTrash` comes back either way, so there is
        // no observable difference to assert. Its DESTINATION half is NOT
        // subsumed: `renameatx_np` is a raw syscall and would resolve a
        // multi-component `to` through `containerFD`. But that half is
        // UNREACHABLE from either entry point, because `boundLeaf` refuses
        // the same target with `.invalidTarget` before any disposal runs, so
        // no cell can drive it. Unevidenceable is not the same as unexamined:
        // `look`'s and `facts`' copies WERE reachable, and both now have
        // cells (r13, E).
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
        //
        // AND THIS GUARD IS WHERE THE DEFAULT USER'S UNDO ENDS — WHICH IS THE
        // REACHABILITY EVERY NOTE BELOW WAS MISSING (PR #460 codex r16,
        // A-P3). Three statements below this one, r15's D-P1 taught the
        // DESTINATION open to follow a symlinked container, and its CHANGELOG
        // entry said the undo "puts the item back under either spelling".
        // Through the shipped seam it puts it back under NEITHER: this open
        // is `~/.Trash`, and without Full Disk Access it is EPERM, so
        // `rollBack` returns HERE and never reaches the line D-P1 changed.
        //
        // MEASURED at 3110d1e with NO `trashHandler` injected — the shipped
        // `FileManager.trashItem` inside the production main-actor hop, into
        // the real `~/.Trash` — all four verdict arms, 8/8 runs
        // (`TrashDisposalHopProofTests`'
        // `…WithoutFullDiskAccessEveryUndoStrandsTheItemInTheRealTrash`): the
        // FORWARD disposal succeeds every time, and the undo answers
        // `.strandedInTrash` every time, leaving the object in the user's real
        // Trash and the target's name EMPTY.
        //
        // SO THE CAUSES SPLIT — BY VOLUME FIRST, AND ONLY THEN BY
        // PERMISSION (PR #460 codex r17, M2). r16 wrote this list with the
        // VOLUME axis missing and published "the default user never gets a
        // put-back" off it. That is over-broad, and the axis it left out is
        // the one that decides which directory this open is even about: the
        // argument is `landed.deletingLastPathComponent()`, and the Trash
        // `FileManager.trashItem` picks is PER VOLUME.
        //
        // * A HOME-VOLUME item lands in `~/.Trash`, which TCC gates. Without
        //   Full Disk Access this open is EPERM, so the only causes reachable
        //   are `.strandedInTrash` — from HERE, whatever the container
        //   spelling — plus `.lastSeenInTrash` and `.destinationUnknown`,
        //   both of which are decided before this line. WITH the permission
        //   the other three become reachable.
        // * AN ITEM ON ANY OTHER MOUNTED VOLUME lands in
        //   `<volume>/.Trashes/<uid>`, which TCC does not gate AT ALL. This
        //   open SUCCEEDS for a process with no Full Disk Access, so the undo
        //   runs to completion and the last three causes are reachable for
        //   the DEFAULT user.
        //
        // MEASURED at be445a0 with `~/.Trash` answering -1/EPERM throughout,
        // no `trashHandler` injected — the shipped `FileManager.trashItem`
        // inside the production main-actor hop — on a temporary APFS disk
        // image attached under the test's own directory and detached in
        // teardown (`TrashDisposalHopProofTests`'
        // `…ANonHomeVolumeUndoPutsTheItemBackWithoutFullDiskAccess`, all four
        // verdict arms, 8/8 runs):
        //
        //     other volume, ordinary swap       .putBack
        //     other volume, container swapped   .destinationNotTheAdmittedContainer
        //
        // and the home-volume row it is the counterpart of —
        // `…WithoutFullDiskAccessEveryUndoStrandsTheItemInTheRealTrash`, all
        // four arms `.strandedInTrash` — is green in the same tree. Both
        // cells assert AGAINST the permission they read, so each is a fact
        // about the machine either way.
        //
        // What stays true from r16 is the FIXTURE warning: every cell that
        // evidences the last three causes with an INJECTED landing proves
        // only what a fixture directory proves, which is exactly the property
        // this file's r11 D4 note records as having hidden a defect for eight
        // rounds. The two cells above are the ones that use no fixture
        // landing at all.
        //
        // D-P1's fix is not undone by that and is not being questioned: it is
        // what makes the second row true, and it removed a real regression for
        // the population that has the permission. What was wrong was
        // publishing it as a change to what the DEFAULT user sees.
        let trashFD = provider.openDirectoryNoFollow(
            at: landed.deletingLastPathComponent()
        )
        guard trashFD >= 0 else { return .strandedInTrash(landed.path) }
        defer { close(trashFD) }

        let bound = FileSystemIdentityProvider.ChildProbe.facts(observed)
        guard provider.probeChild(
            inDirectory: trashFD, named: source, logical: landed
        ) == bound else {
            return .lastSeenInTrash(landed.path)
        }

        // THE DESTINATION IS OPENED AND PROVED AS ONE ACT, THROUGH THE ONE
        // SPELLING EVERY OTHER DESTRUCTIVE OPEN OF THIS CONTAINER USES (PR
        // #460 codex r15, D-P1).
        //
        // Until r15 this was `provider.openDirectoryNoFollow`, and the
        // identity comparison was a separate guard below it. Both halves were
        // wrong in the same way. `DepthSafeRemoval.openContainer` — which
        // `remove`, `boundLeaf`, `admittedParent`'s capture and (since r14's
        // V1-D2) `proveStandingUnderAdmittedContainer` all go through —
        // deliberately FOLLOWS, and its header says why verbatim: "a
        // no-follow open would refuse it while `remove`'s open succeeded — a
        // binding that refuses every deletion under a symlinked cache root".
        // So the undo refused exactly the spelling the forward path had just
        // been taught to accept.
        //
        // MEASURED at 8f71459, identical event (the object replaced inside
        // the mover and the replacement really moved), same fixture, ONLY the
        // container spelling differing: PLAIN — all four Trash arms `.putBack`,
        // landing emptied, object restored to the target's name. SYMLINKED —
        // all four `.strandedInTrash`, the put-back NEVER ATTEMPTED, the
        // target left ABSENT and the object left in the Trash. r14's V1-D2
        // made this arm STRICTLY WORSE rather than fixing it: commit d6bdde2
        // measured the `.directory` arm at 6866012 as refusing `.posix(20)`
        // BEFORE the move on this exact fixture; after the fix it moved the
        // item to the Trash and then could not put it back. Evidenced by
        // `TrashDisposalHopProofTests`'
        // `…UndoPutsBackUnderASymlinkedContainerWhatItPutsBackUnderAPlainOne`.
        //
        // AND EVERY FIGURE IN THAT PARAGRAPH WAS TAKEN THROUGH AN INJECTED
        // LANDING, SO IT IS A FACT ABOUT A POPULATION AND NOT ABOUT THE
        // DEFAULT (PR #460 codex r16, A-P3). This line is reached ONLY when
        // the Trash-open guard above succeeded, i.e. only with Full Disk
        // Access. Without it `rollBack` has already returned
        // `.strandedInTrash` three statements up — measured at 3110d1e
        // through the shipped `FileManager.trashItem` into the real
        // `~/.Trash`, all four arms, 8/8 runs. Read the paragraph above as
        // "what the undo does once it can open the Trash at all".
        //
        // THE TWO ERRORS THE PAIR THROWS ARE THE TWO CAUSES THIS FUNCTION
        // ALREADY HAD, and they are kept apart for the reason
        // `DepthSafeRemoval.Failure.Cause` keeps its own two apart:
        //
        // * THE OPEN FAILED — the SAME fact as the Trash-open guard above,
        //   one directory over, and until r14 it answered the opposite cause
        //   (PR #460 codex r14, V1-D1). `observed` is non-`nil` on this line,
        //   so the item IS in the Trash; what failed is the put-back, not the
        //   finding. `.lastSeenInTrash` told the user to go and look for an
        //   item whose exact path we are holding.
        // * THE IDENTITY DISAGREED — WHOSE FOLDER ARE WE RESTORING INTO?
        //   Asked of the HELD DESTINATION INODE, against a fact taken OUTSIDE
        //   it: the identity the cleaner captured before the disposal.
        //   `containerFD` used to be held across the whole disposal and never
        //   interrogated, so a container swap in that window aimed the undo at
        //   a stranger's directory; and the arrival proof below runs under
        //   THIS SAME descriptor, so it confirmed the move rather than
        //   catching it. A descriptor cannot be its own reference point.
        //
        // TAKEN AFTER THE RE-BIND ON PURPOSE: by here the object is known to
        // still be at `landed`, which is exactly what the refusal tells the
        // user to go and get.
        let containerFD: Int32
        do {
            containerFD = try DepthSafeRemoval.openAdmittedContainer(
                at: target.deletingLastPathComponent(),
                provenAgainst: admittedParent, displayPath: target.path,
                provider: provider
            )
        } catch let refusal as DepthSafeRemoval.Failure
            where refusal.cause == .notTheAdmittedContainer {
            return .destinationNotTheAdmittedContainer(landed.path)
        } catch {
            return .strandedInTrash(landed.path)
        }
        defer { close(containerFD) }

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
