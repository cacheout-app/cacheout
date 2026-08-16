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
//  entered (an `@MainActor` hop, because `trashItem` talks to Finder) —
//  19.2 / 21.1 / 22.5 / 22.5 / 33.5 µs over five runs, printed by
//  `testATrashDisposalThatTookTheWrongObjectPutsItBackAndRefuses` as
//  `MEASURED-TRASH-WINDOW-NS`.
//
//  The REST of the window is inside `trashItem`, and its scale is the reason
//  this file exists. Measured on this machine, on the real home volume: one
//  `trashItem` call of a 4 KiB directory takes 262 µs (min) / 288 µs (median)
//  / 456 µs (max) over nine calls, while the ONE syscall that defeats it —
//  `renamex_np(RENAME_SWAP)` of two directories, the atomic form of the
//  fixture's `rename(2)` + `mkdir(2)` — takes 61 µs (min) / 69–83 µs (median)
//  on the same volume. The swap does NOT fit inside the 19–34 µs prefix that
//  can be timed; it fits several times over inside the call that follows it.
//  Narrowing the prefix therefore buys nothing, which is precisely why the
//  load-bearing proof here is the one taken AFTER the disposal: the window
//  stays open, and stops deciding the outcome.
//
//  WHAT REMAINS AFTER THE PUT-BACK, HONESTLY: the wrongly-taken item is in the
//  Trash for the width of one `renamex_np`, and if the put-back cannot be
//  performed — something else already occupies the original name — it STAYS in
//  the Trash and the error says so by path. Recoverable in one drag, never
//  destroyed, and never reported as freed.

import Foundation

/// Trash disposal that proves WHICH OBJECT it disposed of.
///
/// Used only where an inspection verdict exists to bind to (the sweep's
/// `automaticCleanEligible` items). Where none does, the cleaner calls the
/// seam directly and says so at the call site.
enum TrashDisposal {

    /// Why a Trash disposal was refused AFTER the fact — the causes that
    /// exist only because the disposal cannot be given a descriptor.
    struct Failure: LocalizedError {
        enum Cause: Equatable {
            /// The Trash took an object that is not the inspected one, and it
            /// has been moved back to where it was.
            case putBack
            /// Same, but the put-back could not be performed. The payload is
            /// where the item is now, so the user can do it by hand.
            case strandedInTrash(String)
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
    /// either side, except in the one disclosed case where the put-back itself
    /// cannot be performed (`.strandedInTrash`, which names where the item is).
    static func dispose(
        _ target: URL,
        expecting inspected: UserDataProbeResult.InspectedRoot,
        provider: FileSystemIdentityProvider,
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
        do {
            try proveTaken(inspected, at: landed, provider: provider)
        } catch {
            guard putBack(landed, to: target) else {
                throw Failure(
                    path: target.path, cause: .strandedInTrash(landed.path)
                )
            }
            throw Failure(path: target.path, cause: .putBack)
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
    /// unestablished is refused (the put-back then has nothing to move, and
    /// the caller reports `.strandedInTrash` — which is the honest answer,
    /// because the item is somewhere we cannot name).
    static func proveTaken(
        _ inspected: UserDataProbeResult.InspectedRoot,
        at url: URL, provider: FileSystemIdentityProvider
    ) throws {
        try prove(inspected, at: url, provider: provider, absenceProves: false)
    }

    /// THE KIND GATE **IS** THE OPEN, and the identity comes off the OPENED
    /// INODE — the same shape `DepthSafeRemoval.remove` uses, for the same
    /// reason: a gate beside an open is a swap window by construction, and an
    /// `lstat` of a path is a second resolution of a name anyone can re-point.
    ///
    /// The refusal is `DepthSafeRemoval.Failure(.notTheInspectedObject)` on
    /// purpose, not a private twin: the user is told the same thing whichever
    /// disposal they chose, and the cleaner's log keeps classifying it under
    /// the one `content-drift` tag.
    private static func prove(
        _ inspected: UserDataProbeResult.InspectedRoot,
        at url: URL, provider: FileSystemIdentityProvider,
        absenceProves: Bool
    ) throws {
        let fd = url.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else {
            let code = errno
            // ENOTDIR/ELOOP: something that is NOT a directory tree stands
            // here — a file, a symlink (never followed), a fifo, a device.
            // That is exactly what `.noDirectoryTree` is a verdict about.
            let noTree = code == ENOTDIR || code == ELOOP
                || (code == ENOENT && absenceProves)
            guard noTree, case .noDirectoryTree = inspected else {
                // An unreadable target (EACCES, EIO, …) lands here too, and
                // it must: unprovable is refused, never admitted.
                throw DepthSafeRemoval.Failure(
                    path: url.path,
                    cause: code == ENOENT || code == ENOTDIR || code == ELOOP
                        ? .notTheInspectedObject
                        : .posix(code),
                    depth: 0
                )
            }
            return
        }
        defer { close(fd) }
        // A directory stands here. Only a `.directory` verdict about THIS
        // inode admits it; `.noDirectoryTree` and `.unestablished` are
        // refusals, and so is an identity that cannot be read.
        guard case .directory(let expected) = inspected,
              provider.identity(ofDescriptor: fd) == expected else {
            throw DepthSafeRemoval.Failure(
                path: url.path, cause: .notTheInspectedObject, depth: 0
            )
        }
    }

    // MARK: - Undo

    /// Move `landed` back to `target`, refusing to overwrite whatever may now
    /// stand there.
    ///
    /// `renamex_np(RENAME_EXCL)` rather than `FileManager.moveItem`: the
    /// exclusion is enforced by the KERNEL in the same call that moves, so an
    /// undo cannot itself destroy something that appeared at the target's name
    /// while we were in the Trash. `moveItem` checks the destination first and
    /// then renames — two operations, and the second one clobbers.
    private static func putBack(_ landed: URL, to target: URL) -> Bool {
        landed.path.withCString { from in
            target.path.withCString { to in
                renamex_np(from, to, UInt32(RENAME_EXCL)) == 0
            }
        }
    }
}
