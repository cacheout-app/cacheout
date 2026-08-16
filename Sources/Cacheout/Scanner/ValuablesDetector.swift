/// # ValuablesDetector — the valuables gate (fn-4.4, R3/R17)
///
/// Build directories are NOT uniformly disposable. The field case: a signed,
/// notarized 42MB `Murmur_0.1.7_aarch64.dmg` existed ONLY inside
/// `target/release/bundle/dmg/` — rebuilding it needs a full sign+notarize
/// pipeline. This file owns the bounded no-follow probe that finds such
/// release artifacts INSIDE a matched artifact dir, the ALL-INTEGER identity
/// model that describes them, and the acknowledgement-token derivation both
/// authorization paths (GUI confirm, CLI flag) share.
///
/// ## One bounded core, two call sites (R17 drift-proofing)
/// `probe(at:provider:entryLimit:)` is the ONLY walk. The scan-time face
/// (`BuildArtifactsScanner`, injectable cap) and the delete-time face
/// (`BuildArtifactsScanner.preDeleteValuablesProbe`, the PRODUCTION cap) both
/// route through it, exactly as `OrphanedCachesScanner`'s user-data probe does
/// (`OrphanedCachesScanner.swift:193,571`) — scan-time and delete-time bounds
/// CANNOT drift, because there is only one bound.
///
/// ## Fail closed, always
/// A probe that could not finish (entry budget spent, unreadable branch,
/// a mount boundary left uncrossed, unreadable metadata, an undecodable
/// basename, a bundle whose bounded subtree sizing truncated) is INCOMPLETE.
/// An incomplete probe has the SAME consequence as a hit: risk forced off
/// safe, selection forced false, "couldn't fully inspect" evidence — and,
/// uniformly across every surface, NO acknowledgement token exists. Absence of
/// valuables is only meaningful when the inspection actually finished.
///
/// ## BELOW THE ROOT, NOTHING TAKES A PATH (PR #457 review r5)
///
/// > Every child is discovered and opened relative to an open, vetted parent
/// > descriptor, by single-component basename. A child's safety is
/// > established by CONTAINMENT in a held parent inode, not by comparing a
/// > recorded identity.
///
/// The probe used to re-resolve each child by absolute path three times over
/// — a kind `lstat`, a metadata `lstat`, and an `opendir` — which left the
/// ANCESTOR-swap hole: replace a directory the walk has already passed
/// through with a symlink, and every one of those calls silently re-resolves
/// through it. `O_NOFOLLOW` cannot help (it guards only the FINAL component)
/// and neither can an identity re-proof: if the swap lands before the vetting
/// stat, the identity recorded as "vetted" is ALREADY the foreign object's,
/// so the re-proof compares foreign against foreign and passes. The probe
/// would then enumerate up to its full 20,000-entry budget outside the
/// artifact dir — and on THIS scanner what it reads there enters the
/// acknowledgement-token preimage, corrupting the value that AUTHORIZES
/// DELETION.
///
/// So: ONE path-based open (the root, `O_NOFOLLOW | O_DIRECTORY`), and from
/// there a descriptor-anchored DFS — `fstatat` to vet, `openat` to descend,
/// `openat(fd, ".")` to enumerate. A held descriptor is inode-pinned; no
/// rename, symlink, or remount can redirect it. The `fstat` identity check
/// survives as a cheap CORROBORATOR (it catches a directory re-bound to a
/// different REAL directory, which no no-follow flag can see), never as the
/// guarantee.
///
/// The UNRESOLVED spelling is unaffected and is now strictly safer: it is
/// carried for DISPLAY only (`Frame.logicalURL`), and below the root it is
/// never opened, stat'd, or resolved.
///
/// ## THE IDENTITY PATH IS ANCHORED THE SAME WAY (PR #457 review, P2 #1)
/// The walk was anchored and the identity DERIVATION was not: each disclosed
/// valuable's `canonicalIdentityPath` came from
/// `resolveTargetKeepingLeaf(discovered spelling)`, which re-resolves the
/// whole parent chain — including directories this walk had already opened
/// and was holding. Rename one of them and drop a symlink in its place while
/// the probe is inside it (a real `rename(2)` + `symlink(2)`, driven from the
/// `didReadNames` hook, pinned by a test) and the disclosure published the
/// REAL held inode's integers under a path pointing OUTSIDE the artifact dir
/// — measured: two different tokens over one unchanged file. That value is
/// the acknowledgement-token preimage, so the same failure class as the
/// anchored-probe defect: the walk was anchored, the authorization was not.
///
/// So the identity path is now COMPOSED, exactly as the traversal is: the
/// root's canonical path is resolved ONCE, at core entry, BEFORE the walk
/// holds anything (it is the value the root mount check already computed — the
/// anchoring costs no extra resolution), and every level below appends the
/// exact basename `readdir` produced and `openat` descended
/// (`Frame.identityURL`). No ancestor is ever named to the kernel again after
/// its descriptor is open.
///
/// Byte-identical to the old derivation for every non-attack tree, and by
/// construction rather than by luck: below the root the composed components
/// are the on-disk basenames `readdir` returned, which is precisely what
/// `realpath` would have produced for a chain of real directories — and the
/// walk descends nothing else (`O_NOFOLLOW` on every `openat`). Both faces
/// enter through the same core, so scan time and delete time compose the
/// identical path and therefore the identical token.
///
/// The ROOT is the one thing the caller supplies, and there are now TWO ways
/// to supply it. `probe(at:root:…)` takes a root the caller has ALREADY OPENED
/// and reached by containment — that is what the scan-time face does, from the
/// dev-root descriptor it has held since admission — so the walk never RE-opens
/// or re-resolves an ancestor once it holds a descriptor for it.
///
/// It does NOT follow that the contained face resolves no ancestors (this
/// header said exactly that, and PR #457 review r11 measured it false). Exactly
/// ONE path resolution survives, and it is authorization-bearing: the identity
/// anchor, `provider.canonicalize(directory)` in `probeCore`, whose output is
/// the base of every disclosed `canonicalIdentityPath` and therefore of the
/// acknowledgement-token preimage. Swap the artifact dir's PARENT between the
/// caller's open and the probe and that anchor resolves through the swap, so a
/// file genuinely inside the held inode is published under a foreign path and
/// its token rotates — reproduced with a real `rename(2)`+`symlink(2)` against
/// a held `SecureDirectory`.
///
/// What the anchoring change actually bought, stated exactly: it cut the
/// hostile-resolvable resolutions from (1 root + N valuables) to (1 root), and
/// the surviving one is measured byte-identical in exposure to the derivation
/// it replaced — strictly fewer, never more. It is fail-closed downstream: the
/// rotated token does not match at delete time, so the clean is REFUSED rather
/// than performed against the wrong tree (`testAdvScanTimeTokenAuthorizesThe`
/// `ProductionRevalidator` pins the honest round trip; a rotated token refuses).
/// Closing it entirely needs `F_GETPATH` on the held anchor, which would change
/// the identity doctrine for every scanner — deliberately out of scope here.
///
/// `probe(at:provider:…)` opens the root by path, so it carries the same
/// residual plus the root's own open. `O_NOFOLLOW_ANY` would close both and
/// would also break the legitimate aliased roots this codebase supports
/// (`/tmp` → `/private/tmp`, a symlinked `$HOME`). The DELETE-TIME face is
/// still that shape — it is handed a bare URL and has no descriptor to
/// descend from. Its exposure is narrower in one direction and unchanged in
/// the other: for an item that DISCLOSED valuables, a redirected probe cannot
/// reproduce the acknowledged token and the deletion is refused; for an item
/// that disclosed none, a redirected CLEAN probe allows, and what is then
/// deleted is whatever the cleaner's own path admission accepts. Delete-time
/// path safety is `PathGuard`'s and `CacheCleaner`'s layer, not this one's,
/// and it is tracked there. Also unclosed: a vetted subtree
/// RELOCATED mid-walk keeps being read (correctly — those are the vetted
/// inodes) even though "inside this artifact dir" has gone stale;
/// delete-time re-proves separately, so that is scan-time staleness, not an
/// authorization hole.
///
/// ## Mount boundaries are NEVER crossed (PR #457 review, R15)
/// The probe stops at every mount boundary. The signal that CARRIES the check
/// is the child descriptor's own `f_fsid` against the root's: measured on
/// this machine, `st_dev` is identical for literally every path INCLUDING
/// `/` and `/System/Volumes/Data`, so the device comparison is blind to
/// exactly the APFS firmlink split it was partly meant to catch. The two
/// path-based signals the sizer (`DirectorySizer.swift:202,287`) and the
/// project walker already use are retained beside it — they are the seam
/// hermetic tests inject through, and they can only ever push the answer
/// toward refusal. There is still exactly ONE notion of "mount boundary" in
/// this codebase and this is it; nothing here re-derives a second one.
///
/// Why the probe needs its own check rather than trusting the caller's size
/// report: this walk has TWO faces and only one of them has a report. At scan
/// time `BuildArtifactsScanner` already knows the tree holds a boundary and
/// has already denied the item — but at DELETE time
/// `preDeleteValuablesProbe` is handed a bare URL, with no report to consult,
/// and a volume can be mounted into a build directory between the scan and
/// the clean. Gating on the scan-time `hasBoundary` alone would fix the face
/// that was already safe and leave the other one walking through the mount:
/// exactly the scan/delete drift the one-core rule above exists to prevent.
///
/// What it costs to cross one: a mounted volume beneath a matched artifact
/// dir is network, removable, or FUSE storage. Descending it spends the entry
/// budget — up to 20,000 entries — on reads OUTSIDE the configured dev root,
/// which means network round trips, spin-up, and privacy-sensitive access to
/// a filesystem the user never pointed this scanner at. And it buys nothing:
/// an artifact dir containing a boundary is `.denied` at scan time and
/// refused whole by the cleaner (`CacheCleaner.swift:875,970`), so no
/// valuable found past the mount could ever change an outcome.
///
/// UNCROSSED ⇒ INCOMPLETE, never "clean": the honest report is "we did not
/// look there", and that is fail-closed. It strands nothing, because the
/// boundary that stops the probe is the same fact that already makes the item
/// unclean-able, and it is CLEARABLE in the way a depth cap never was —
/// unmount the volume and the next scan probes the tree whole.
///
/// ## ONE budget, PROPORTIONATE, and no depth cap (PR #457 review r7)
/// The shared ENTRY budget is the probe's only bound, and it alone guarantees
/// termination: every directory the walk descends into cost one entry to
/// discover, so at most `entryLimit` directories are ever popped — true even
/// of a hypothetical directory cycle. A fixed depth cap therefore bounded
/// nothing the budget did not already bound, while manufacturing INCOMPLETE
/// verdicts on ordinary artifact trees that no re-scan could clear.
///
/// The FIXED budget that outlived it had the same shape and the same effect,
/// one size larger: measured on this machine it fired on `node_modules` up to
/// 44,468 entries and `.build` up to 53,924, against a 20,000-entry cap. So
/// the bound is now PROPORTIONATE to its subject — see `ValuablesProbeBudget`
/// — starting from the subject's own census and DOUBLING until the walk
/// finishes, so that no tree THIS walk can read is stranded by a count some
/// OTHER walk took (review r8: the census is path-based and stops at
/// `PATH_MAX`; this walk is descriptor-anchored and does not). Budget
/// exhaustion survives only as what it should always have been: the
/// non-deterministic, retry-clearable case of a tree that is still growing.
///
/// The probe is INCOMPLETE for two separately reported REASONS
/// (`ValuablesDisclosure.ProbeIncompleteness`), because they clear
/// differently: an ENTRY BUDGET is cleared by a bigger one (which the policy
/// grants automatically, doubling from the subject's own census), an
/// OBSTRUCTION only by removing the impediment. When both stop one walk the
/// OBSTRUCTION is reported — it is the one no escalation can help.
///
/// ## IT WINDS DOWN WHEN CANCELLED (PR #457 review, P2 #2)
/// The bound above is what made this urgent: while the budget was a flat
/// 20,000 entries, the longest stretch of synchronous work between a
/// cancellation and the walk noticing was 20,000 `readdir`s; census-
/// proportionate escalation raised that ceiling to `20_000 << 16` ≈ 1.31e9,
/// so our own fix widened the window by five orders of magnitude. The GUI
/// deliberately AWAITS the producer's real completion after cancelling
/// (`CacheoutViewModel`: `await session.untilProducerFinishes()`, holding the
/// scan-in-progress guard so a new scan or a clean cannot overlap the trees
/// still being walked), and a pending runtime replacement is applied in the
/// same epilogue — so every entry read after the cancel is UI time.
///
/// `Task.isCancelled` is therefore polled at exactly three places — the three
/// loops that can run long, and no more, because a guard no test can kill is
/// one a refactor keeps for the wrong reason:
/// - the `readdir` of ONE directory (`boundedChildNames`), which reports a
///   cancelled read through the SAME `obstructed` channel an unreadable branch
///   uses — one mapping, no second cancellation vocabulary to drift;
/// - the per-name VETTING loop that consumes those names, one `fstatat` each,
///   for a directory whose names are ALREADY read (the readdir poll cannot
///   help there);
/// - the DFS pop/descend loop, which would otherwise `openat` + `fdopendir`
///   its way through every pending sibling on the stack.
/// Each is pinned by a test that measures the work actually performed —
/// entries read, `fstatat`s issued, children opened — and each of those tests
/// goes red when its own poll is deleted.
///
/// A CANCELLED PROBE IS NEVER A CLEAN PROBE. It is INCOMPLETE with the
/// OBSTRUCTION cause — deliberately not `.entryBudget`, which is the
/// ESCALATABLE one: a cancelled walk reported as budget-exhausted would be
/// re-run at twice the bound up to sixteen times by
/// `ValuablesProbeBudget.escalating`, which is the exact opposite of winding
/// down. Being incomplete it is tokenless on every surface and forces its item
/// to review, so "we stopped looking" can never be read as "we looked and
/// found nothing", and `preDeleteValuablesProbe` also skips the census
/// enumeration it would otherwise pay for an entry-budget stop.
///
/// BOTH FACES POLL, because there is one core. Their CONSEQUENCES differ and
/// both are fail-closed: at scan time the item is denied, unselected and
/// tokenless (and a cancelled session adopts nothing anyway); at delete time
/// the revalidator refuses that item and deletes nothing. A cancelled clean
/// refusing to delete is the correct reading of cancellation, not a
/// regression.
///
/// ## Determinism contract (deliberately NARROW under truncation)
/// For a COMPLETE probe the output is fully deterministic: every directory
/// was read whole, siblings are visited byte-wise ascending, and the disclosed
/// list is sorted byte-wise by canonical identity path.
/// For an INCOMPLETE probe, WHICH entries were seen is deliberately
/// UNSPECIFIED — a directory larger than the remaining entry budget is read in
/// filesystem `readdir` order, because selecting the byte-wise smallest N
/// would require enumerating the whole directory, which is precisely the
/// unbounded read the budget exists to prevent. Nothing downstream may depend
/// on that membership: an incomplete probe is unauthorizable and TOKENLESS on
/// every surface, and its item is forced to review regardless of what was
/// found. What IS disclosed is still shown (hiding a real DMG because the
/// walk ran out of budget would be strictly worse) — it is a floor on the
/// warning, never a basis for authorization.
///
/// ## DISCLOSURE IS NEVER CONSENT
/// `ValuablesDisclosure` records what the scan SAW. It is never read as
/// acknowledgement: both a GUI clean and an unacknowledged CLI clean hand the
/// revalidator the same scanned item, and only the per-clean
/// `[ItemKey: acknowledgement]` authorization context (built by fn-4.6/fn-4.9,
/// consumed at fn-4.8's chokepoint) distinguishes them. Nothing in this file
/// grants anything.
///
/// ## No `Date` in the identity path
/// `ValuableIdentity` is five INTEGERS. Identity + modification metadata come
/// from ONE no-follow `lstat` of the valuable's root; `allocatedBytes` is the
/// leaf allocation for regular files and the BOUNDED SUBTREE allocation for
/// directory bundles (a bundle root's own inode is tiny — sourcing its size
/// from its own lstat would exempt every 5MB+ bundle from the floor). The
/// token preimage, the wire row, and the delete-time recomputation all consume
/// the SAME integers, so scan, JSON, GUI, and revalidation can never drift on
/// precision. Display dates DERIVE from the integers (fn-4.6).

import CryptoKit
import Foundation

// MARK: - ValuableIdentity

/// The ALL-INTEGER identity of one detected valuable (R17). Five integers,
/// no `Date`, no formatting — the exact values the wire serializes, the token
/// preimage consumes, and the delete-time probe recomputes.
///
/// `device`/`inode` are `UInt64` matching the as-built
/// `FileSystemIdentityProvider.Identity` convention (`device` is the bit
/// pattern of Darwin's signed `dev_t`, `inode` is `ino_t` verbatim) and
/// serialize as UNSIGNED decimal integers.
///
/// PINNED VALUE DOMAINS (checked by `SpaceScannerRuntime`'s value-domain
/// family, and by construction at every production source):
/// - `allocatedBytes >= 0`;
/// - `0 <= modifiedNanoseconds < 1_000_000_000`;
/// - `modifiedSeconds` inside the range where
///   `modifiedSeconds * 1_000_000_000 + modifiedNanoseconds` still fits
///   `Int64` — checked with overflow-REPORTING arithmetic and REJECTED when
///   violated, never saturated (a saturated timestamp is a lie).
struct ValuableIdentity: Equatable, Sendable {
    /// Leaf allocation (regular files) or BOUNDED SUBTREE allocation
    /// (directory bundles) — the SAME figure the wire and the token use.
    let allocatedBytes: Int64
    /// `st_dev` of the valuable's ROOT, bit pattern as `UInt64`.
    let device: UInt64
    /// `st_ino` of the valuable's ROOT.
    let inode: UInt64
    /// `st_mtimespec.tv_sec` of the valuable's ROOT.
    let modifiedSeconds: Int64
    /// `st_mtimespec.tv_nsec` of the valuable's ROOT, in `[0, 1e9)`.
    let modifiedNanoseconds: Int64

    /// One nanosecond of the epoch — the PINNED wire field `modified_at_ns`,
    /// DERIVED (never stored) from the two integers.
    ///
    /// `nil` exactly when the pinned value domains are violated, computed
    /// with overflow-reporting arithmetic so it can NEVER trap and never
    /// saturates. Unreachable for anything a production probe emits (the
    /// source rejects out-of-domain `lstat` metadata outright) and
    /// unreachable for any item that passed the validator (the value-domain
    /// family malforms the whole outcome first) — the optionality exists so
    /// the derivation is total, not so callers invent numbers.
    var modifiedAtNanoseconds: Int64? {
        guard modifiedNanoseconds >= 0,
              modifiedNanoseconds < ValuableIdentity.nanosecondsPerSecond
        else { return nil }
        let (scaled, scaleOverflow) = modifiedSeconds
            .multipliedReportingOverflow(by: ValuableIdentity.nanosecondsPerSecond)
        guard !scaleOverflow else { return nil }
        let (total, sumOverflow) = scaled
            .addingReportingOverflow(modifiedNanoseconds)
        guard !sumOverflow else { return nil }
        return total
    }

    /// The pinned scale factor, named once so the domain check, the wire
    /// derivation, and the validator cannot disagree.
    static let nanosecondsPerSecond: Int64 = 1_000_000_000
}

// MARK: - DetectedValuable

/// One release artifact found inside a matched artifact dir.
///
/// `canonicalIdentityPath` is THE one stored identity path: the house identity
/// doctrine's value (canonical parent chain + UNRESOLVED leaf), COMPOSED by the
/// probe from its anchored root plus the basenames it actually traversed —
/// never re-resolved from the discovered spelling, because an ancestor swapped
/// after the walk opened it would then redirect this value (see the
/// `ValuablesDetector` header). It drives the canonical ORDERING, the token
/// PREIMAGE, and the wire `path` field — one value, three consumers, so an
/// alias-spelled root and the canonical root produce identical ordering and
/// identical tokens.
///
/// `displayURL` is the UNRESOLVED discovered spelling, for the confirmation
/// sheet and reveal-in-Finder ONLY. It NEVER reaches the wire.
struct DetectedValuable: Equatable, Sendable {
    /// Basename as discovered (`Murmur_0.1.7_aarch64.dmg`).
    let name: String
    /// Sheet/reveal spelling. Never serialized, never a token input.
    let displayURL: URL
    /// The one stored identity path: canonical parent + unresolved leaf.
    let canonicalIdentityPath: String
    /// The all-integer identity (see `ValuableIdentity`).
    let identity: ValuableIdentity
}

// MARK: - ValuablesDisclosure

/// What ONE probe of ONE artifact dir saw: the valuables (already in the ONE
/// canonical order — byte-wise ascending `canonicalIdentityPath`, sorted once
/// at detection time so evidence, the model field, the wire array, and
/// fn-4.6's sheet all consume the SAME order with no downstream re-sort) plus
/// the fail-closed completeness flag.
///
/// **DISCLOSURE IS NEVER CONSENT.** Riding an item, this is the structural
/// record of what the user was SHOWN — never an authorization. Acknowledgement
/// lives exclusively in the per-clean `[ItemKey: acknowledgement]` context.
struct ValuablesDisclosure: Equatable, Sendable {
    /// Canonical order, sorted ONCE at detection time.
    let valuables: [DetectedValuable]
    /// False when the bounded inspection could not finish — see the file
    /// header's fail-closed rule.
    let probeComplete: Bool
    /// WHY it could not finish — nil exactly when it did.
    ///
    /// Two causes with two different remedies, and flattening them into one
    /// message (or one class) is what made "re-scan and retry" the printed
    /// advice for a condition no retry could ever change. See
    /// `ProbeIncompleteness`.
    let incompleteness: ProbeIncompleteness?

    /// The BYTE length of the longest descendant path this walk composed
    /// under the subject's OWN spelling, reported only when at least one is
    /// longer than `ValuablesDetector.removablePathByteLimit`. `nil` means
    /// every path this walk saw is one the cleaner's removal can name.
    ///
    /// NOT an incompleteness — the walk finished; it read the whole tree and
    /// found a FACT about it. Kept as its own field precisely so it can never
    /// be flattened into `.entryBudget` (which the budget policy would
    /// re-walk sixteen times at doubled bounds, for a condition no bound can
    /// change) or into `.obstruction` (whose printed remedy is "re-scan",
    /// which cannot change it either). Its remedy is specific and it works:
    /// shorten or restructure the tree.
    ///
    /// FAIL-CLOSED ASYMMETRY, deliberate: a COMPLETE probe reporting `nil`
    /// has PROVEN there is no such descendant, because a complete probe read
    /// every entry. An INCOMPLETE probe reporting `nil` has proven nothing —
    /// and needs to prove nothing, because an incomplete probe is already
    /// tokenless on every surface and refused whole by the delete-time
    /// revalidator.
    ///
    /// This field is NOT part of the acknowledgement-token preimage and must
    /// never become part of it: the token authorizes deletion of a tree whose
    /// valuables the user acknowledged, and an over-long tree is refused
    /// BEFORE any token is consulted. Adding it would rotate tokens for a
    /// reason acknowledgement has nothing to do with.
    let overlongDescendantPathBytes: Int?

    /// Why a bounded inspection stopped short. The question that separates
    /// them is the house one: *can a retry, unaided, change this?*
    enum ProbeIncompleteness: Equatable, Sendable {
        /// The ENTRY BUDGET ran out, and nothing else went wrong. The tree is
        /// bigger than the bound it was granted, so a bigger bound — which
        /// the census-proportionate policy grants automatically, starting at
        /// the subject's own count and doubling from there — is exactly what
        /// changes it. Surviving every one of those doublings is what a tree
        /// that is still GROWING does; a static one cannot.
        case entryBudget
        /// Something the probe could not read, characterise, decode, or
        /// cross: an unreadable branch, a mount boundary, an undecodable
        /// basename, a descriptor that could not be re-anchored, metadata
        /// outside the pinned value domains. A bigger budget cannot help;
        /// fixing the impediment can.
        ///
        /// A CANCELLED walk lands here too, and deliberately: the alternative
        /// cause is the escalatable one, and re-walking a cancelled tree at
        /// twice the bound is the opposite of winding down. The remedy the
        /// message names ("re-scan") is exactly the one that clears it.
        case obstruction
    }

    /// The memberwise init, made TOTAL: an unfinished probe ALWAYS names a
    /// cause, and the default is the conservative one (an obstruction never
    /// escalates a budget), so no caller can construct a disclosure that is
    /// incomplete for no stated reason.
    init(
        valuables: [DetectedValuable],
        probeComplete: Bool,
        incompleteness: ProbeIncompleteness? = nil,
        overlongDescendantPathBytes: Int? = nil
    ) {
        self.valuables = valuables
        self.probeComplete = probeComplete
        self.incompleteness = probeComplete
            ? nil : (incompleteness ?? .obstruction)
        self.overlongDescendantPathBytes = overlongDescendantPathBytes
    }

    /// The probe result that forces nothing: nothing found, inspection
    /// finished.
    static let clean = ValuablesDisclosure(valuables: [], probeComplete: true)

    /// The fail-closed result of an inspection that could not even begin:
    /// nothing disclosed, and nothing PROVEN — unauthorizable and tokenless.
    /// An OBSTRUCTION by construction: an inspection that never started did
    /// not run out of budget.
    static let incomplete = ValuablesDisclosure(
        valuables: [], probeComplete: false, incompleteness: .obstruction
    )

    /// Does this disclosure force the item off safe, force selection false,
    /// and add warning evidence? Any hit OR an incomplete probe — the two
    /// have the SAME consequence. (Already-review rows keep their risk; the
    /// gate only ever NARROWS.)
    var forcesReview: Bool { !valuables.isEmpty || !probeComplete }

    // MARK: Acknowledgement token (R17)

    /// The PURE token derivation both authorization paths use — the full
    /// lowercase-hex SHA-256 over the UTF-8 bytes of
    ///
    ///     scannerID "\0" itemID "\0"
    ///     ( canonicalIdentityPath "\0" allocatedBytes "\0" device "\0"
    ///       inode "\0" modifiedSeconds "\0" modifiedNanoseconds "\0" )*
    ///
    /// with the valuables in CANONICAL ORDER and every numeric written as the
    /// `ValuableIdentity` integer verbatim (decimal; `device`/`inode`
    /// unsigned). The leading pair is the canonical ItemKey serialization,
    /// matching the frozen `stableID` preimage convention
    /// (`SpaceScanner.swift:262`): item ids are scanner-scoped, so only the
    /// FULL ItemKey makes a token item-bound — a token applied to another
    /// item, even the same item id under a different scanner id, can never
    /// match.
    ///
    /// PRECONDITION — the uniform R17 rule: a token exists ONLY for a
    /// NON-EMPTY set from a COMPLETE probe. `nil` otherwise, on every surface
    /// (scan plan, GUI confirm, refusal rows, delete-time recompute). There is
    /// no empty-set token and no partial-probe token ANYWHERE.
    ///
    /// HONEST INVALIDATION CONTRACT: the token rotates on set membership,
    /// path, allocated size, no-follow identity (dev/inode), or mtime change —
    /// so an IN-PLACE REPLACEMENT (same path, same size, new inode or new
    /// mtime) invalidates a held token. It does NOT guard content mutation
    /// that preserves ALL of those; that is the documented accepted residual
    /// (fn-4.7).
    static func acknowledgementToken(
        scannerID: String,
        itemID: String,
        valuables: [DetectedValuable],
        probeComplete: Bool
    ) -> String? {
        guard probeComplete, !valuables.isEmpty else { return nil }
        var preimage = scannerID + "\0" + itemID + "\0"
        for valuable in valuables {
            let identity = valuable.identity
            preimage += valuable.canonicalIdentityPath + "\0"
                + String(identity.allocatedBytes) + "\0"
                + String(identity.device) + "\0"
                + String(identity.inode) + "\0"
                + String(identity.modifiedSeconds) + "\0"
                + String(identity.modifiedNanoseconds) + "\0"
        }
        return SHA256.hash(data: Data(preimage.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Item-bound convenience over the pure derivation above.
    func acknowledgementToken(for key: ItemKey) -> String? {
        Self.acknowledgementToken(
            scannerID: key.scannerID, itemID: key.itemID,
            valuables: valuables, probeComplete: probeComplete
        )
    }
}

// MARK: - ValuablesProbeBudget

/// The probe's ENTRY BOUND POLICY — ONE value per scanner, consumed by BOTH
/// of its faces, so the scan-time and delete-time bounds cannot drift.
///
/// ## Why a policy and not a constant (PR #457 review r7)
/// A FIXED entry cap is deterministic, and a deterministic bound that makes a
/// probe incomplete strands its item FOREVER: an incomplete probe is tokenless
/// on every surface, the GUI filters it out of the confirmation clean set, the
/// CLI can never obtain the token the identical bounded revalidation demands,
/// and re-scanning an unchanged tree exhausts in exactly the same place. That
/// is the defect the retired depth cap had; the 20,000-entry cap that survived
/// it had the same shape, and MEASURED ON THIS MACHINE it fired on exactly the
/// trees this scanner exists to reclaim — `node_modules` up to 44,468 entries,
/// `.build` up to 53,924, a `venv` at 33,552, with five of twenty-five sampled
/// `node_modules` and three of thirteen `.build` trees over the cap.
///
/// So the bound stops being a constant and becomes PROPORTIONATE to its
/// subject: the probe starts at twice the entries an enumeration of that very
/// tree just cost (`SizeReport.enumeratedEntries`), and — when even that runs
/// out — DOUBLES until the walk finishes. For a static tree the budget
/// therefore cannot run out: budget exhaustion stops being an event at all,
/// which is the honest end state for a bound nothing could clear. What CAN
/// still exhaust it is a tree that keeps growing faster than the bound
/// doubles, and that is the clearable case by construction: it is not
/// deterministic, and a retry over a tree that stopped growing completes.
///
/// ## Why the census is a HINT and the DOUBLING is the guarantee (review r8)
/// The census comes from `DirectorySizer`, which is a PATH-BASED walk
/// (`FileManager.enumerator`, per-item absolute-path `lstat`), while the probe
/// is DESCRIPTOR-ANCHORED (`openat` one component at a time). The two truncate
/// in DIFFERENT PLACES, so a census is only a sound BOUND for the probe if
/// both walks stop together — and they measurably do not. A 120-deep chain of
/// 20-character components puts the deepest path past `PATH_MAX` (measured:
/// 2634 bytes against 1024): the sizer dies there with ENAMETOOLONG after 44
/// entries and one recorded denial, while the probe walks the whole 151-entry
/// tree — and at the production floor the same shape with 21,000 files at the
/// bottom counted 43 of 21,121 entries, for a budget of 20,000 against a need
/// of 21,121. Twice a truncated census is not a bound, it is an undercount, and
/// deriving the probe's ONLY bound from it made a STATIC tree deterministically
/// incomplete — tokenless on every surface, dropped from the GUI clean set,
/// and told it was "changing faster than it can be inspected" when nothing
/// about it was changing.
///
/// So the census keeps only the job it is honest for: a STARTING HINT that
/// saves rounds when it is right (an exhaustive census finishes the probe in
/// ONE pass; on real trees it is exact to within a rounding of 1 — measured:
/// `.build` 13021 → 13022, `node_modules` 19265 → 19265). The GUARANTEE is
/// progress-driven and needs no census at all: a pass that exhausted its bound
/// is retried at TWICE that bound, which no walk's truncation can undercount.
///
/// The bound still exists, and still guarantees termination: at most
/// `escalationRounds` doublings, and the total work of all passes is under
/// twice the final bound. Raising it costs nothing that pass was not already
/// paying — `DirectorySizer.measure` walks the identical tree with
/// `FileManager.enumerator` and NO cap (and at strictly higher cost per entry),
/// and the deletion that follows unlinks every entry — so the probe was never
/// the pass's cost driver at any cap.
enum ValuablesProbeBudget: Equatable, Sendable {
    /// PRODUCTION. At least `floor` entries, raised to `slackFactor ×` the
    /// subject's own exhaustive census whenever that is larger.
    case censusProportionate(floor: Int)
    /// A FIXED bound, never escalated. The delete-time first pass runs at the
    /// floor this way, and the fail-closed truncation cells are proven with
    /// it — an explicitly pinned bound is honored verbatim.
    case fixed(Int)

    /// Twice the census, and the factor every escalation round multiplies by.
    /// The census is exact for a static tree the sizer can walk WHOLE, so the
    /// factor is pure slack there: it covers entries created between the two
    /// walks and the small census differences two enumerators can have at a
    /// boundary.
    static let slackFactor = 2

    /// How many DOUBLINGS a probe may take beyond its starting bound.
    ///
    /// Sized so that no static tree can ever reach it and no growing one is
    /// stopped early by anything else: from the production floor of 20,000 the
    /// ceiling is `20_000 << 16` = 1,310,720,000 entries — three orders of
    /// magnitude past the largest tree this scanner has ever been pointed at
    /// (measured on this machine: `.build` 53,924 entries, `node_modules`
    /// 44,468). Reaching it therefore means exactly one thing, and it is the
    /// thing the "still changing" guidance says: the subject outgrew every
    /// bound a doubling could grant it.
    ///
    /// It is a ROUND count and not an entry ceiling on purpose: rounds bound
    /// the number of re-walks (the cost the user waits on), while the entry
    /// ceiling they imply scales with whatever bound the subject's own census
    /// started at.
    static let escalationRounds = 16

    /// The bound to spend when no census is available yet (the delete-time
    /// first pass).
    var firstPass: Int {
        switch self {
        case .censusProportionate(let floor): return floor
        case .fixed(let limit): return limit
        }
    }

    /// The bound to spend for a subject whose exhaustive census is `census`.
    /// Never below `firstPass`; SATURATING rather than trapping, because the
    /// census is filesystem-supplied.
    func limit(census: Int) -> Int {
        switch self {
        case .fixed(let limit):
            return limit
        case .censusProportionate(let floor):
            let (scaled, overflow) = census
                .multipliedReportingOverflow(by: Self.slackFactor)
            return max(floor, overflow ? Int.max : scaled)
        }
    }

    /// The bound a SECOND pass should spend, or nil when a second pass could
    /// not read one entry more than the first already did.
    func escalation(census: Int) -> Int? {
        let escalated = limit(census: census)
        return escalated > firstPass ? escalated : nil
    }

    /// The bound to retry a pass that EXHAUSTED `bound` at — DOUBLING, and
    /// derived from nothing but the bound that was actually spent, so no
    /// walk's truncation can hold it down. `nil` when it cannot grow: a
    /// `.fixed` policy is honored verbatim and never escalates, and a bound
    /// already at `Int.max` has nowhere left to go.
    ///
    /// `max(1, bound)` so a floor of 0 (or a nonsense negative one) still
    /// escalates instead of doubling zero forever.
    func escalated(beyond bound: Int) -> Int? {
        switch self {
        case .fixed:
            return nil
        case .censusProportionate:
            let (doubled, overflow) = max(1, bound)
                .multipliedReportingOverflow(by: Self.slackFactor)
            let next = overflow ? Int.max : doubled
            return next > bound ? next : nil
        }
    }

    /// THE ONE ESCALATION DRIVER, consumed by BOTH faces of the scanner (the
    /// scan-time probe and `preDeleteValuablesProbe`), so the two can neither
    /// drift nor disagree about when a probe is finished.
    ///
    /// `result` is what a probe ALREADY run at `bound` produced. While — and
    /// only while — the ENTRY BUDGET is what stopped it, the probe is re-run
    /// at a doubled bound. An OBSTRUCTION is never escalated: no bound can
    /// read an unreadable branch, and `ValuablesProbeWalk.incompleteness`
    /// already reports the obstruction whenever both causes fired.
    ///
    /// Termination: `rounds` is a hard round count, `escalated(beyond:)`
    /// saturates, and each pass is itself bounded — so the driver performs at
    /// most `rounds` extra walks and the sum of every pass's bound is under
    /// twice the last one's.
    ///
    /// - Parameter rounds: TEST SEAM. Production takes the default; a test
    ///   pins it small to prove the ceiling arm without a billion-entry
    ///   fixture.
    func escalating(
        _ result: ValuablesDisclosure,
        spent bound: Int,
        rounds: Int = ValuablesProbeBudget.escalationRounds,
        _ probe: (Int) -> ValuablesDisclosure
    ) -> ValuablesDisclosure {
        var result = result
        var bound = bound
        var remaining = rounds
        while result.incompleteness == .entryBudget, remaining > 0,
              let next = escalated(beyond: bound) {
            bound = next
            result = probe(bound)
            remaining -= 1
        }
        return result
    }
}

// MARK: - ValuablesDetector

/// The detection rules and the ONE bounded probe core.
enum ValuablesDetector {

    // MARK: Pinned rules (epic-pinned — data, not conditionals)

    /// Regular-file valuables, matched on the basename's EXTENSION,
    /// case-INSENSITIVELY (a `.DMG` is the same artifact as a `.dmg`; the
    /// rest of the name is never interpreted).
    static let fileExtensions: Set<String> = ["dmg", "pkg", "ipa"]

    /// Directory-BUNDLE valuables. A bundle is a DIRECTORY: its size is the
    /// BOUNDED SUBTREE allocation (its own inode is tiny), while its IDENTITY
    /// is the bundle ROOT's no-follow lstat. Lowercased for the same
    /// case-insensitive compare (`.DSYM` == `.dSYM`).
    static let bundleExtensions: Set<String> = ["app", "xcarchive", "dsym"]

    /// FALSE-POSITIVE MAGNETS the epic's research explicitly excludes —
    /// deliberately absent from both tables above and asserted disjoint from
    /// them, so no future edit can quietly enrol them. A cache `.db`, a
    /// `.sqlite`, or a generic `.zip` inside a build dir is build output.
    static let deliberatelyNotFlaggedExtensions: Set<String> =
        ["db", "sqlite", "zip"]

    /// The allocated FLOOR (decimal MB, the house convention): below this a
    /// hit is an icon-sized `.app` stub or an installer fragment, not a
    /// release artifact worth guarding. Named once and shared by both shapes.
    static let minimumAllocatedBytes: Int64 = 5_000_000

    // MARK: The pinned cap (shared by scan time AND delete time)

    /// The PRODUCTION probe FLOOR — ONE definition, consumed by the scanner's
    /// init default AND by the delete-time entry point
    /// (`BuildArtifactsScanner.preDeleteValuablesProbe`), so the two
    /// inspections' bounds can never drift apart (the
    /// `OrphanedCachesScanner.swift:193` doctrine).
    ///
    /// A FLOOR, not a cap (review r7): the production policy raises it to
    /// twice the subject's own exhaustive census whenever that is larger, so
    /// this value only decides how much work a probe may do BEFORE anyone has
    /// counted the tree. It is sized to cover an ordinary artifact dir
    /// outright — measured on this machine, 20 of 25 sampled `node_modules`
    /// and 10 of 13 `.build` trees finish inside it — so the escalation is
    /// the exception, not the path.
    ///
    /// Whatever bound is in force is GLOBAL to one probe and is the sole
    /// guarantee that it terminates: it is shared across the outer walk and
    /// every bundle's subtree sizing, so the whole probe visits at most that
    /// many directory entries however deep the tree runs (see the file header
    /// on why there is no second, depth-shaped bound).
    static let defaultProbeEntryLimit = 20_000

    // MARK: The path-length limit a PATH-BASED removal can name (review r10)

    /// The longest absolute path, IN BYTES, that the cleaner's removal can
    /// actually name — and therefore the longest one this scanner may OFFER
    /// a tree containing.
    ///
    /// ## Why a walk that does not need it measures it anyway
    /// This walk is descriptor-anchored and runs past `PATH_MAX` happily. The
    /// REMOVAL does not: `CacheCleaner`'s permanent arm is
    /// `FileManager.removeItem` → `removefile(3)`, which composes and
    /// RESOLVES an absolute path for every entry it recurses into. Handed a
    /// tree with one over-long descendant it unlinks everything it reaches
    /// FIRST and then fails with ENAMETOOLONG — measured on this machine over
    /// a 200-sibling `target/`: 38 of 521 entries destroyed, deterministically,
    /// the target left standing, and the caller handed nothing but Cocoa 514.
    /// No cleanup entry, zero bytes reported freed, and a half-deleted build
    /// directory. Offering a row whose removal can only end that way is the
    /// worst outcome this codebase can produce, so the probe — the one walk
    /// that CAN see past the limit — is where the fact is surfaced, and the
    /// scanner refuses the item outright (`BuildArtifactsScanner`'s
    /// `pathLimitScanError`, and the delete-time revalidator's matching
    /// refusal).
    ///
    /// ## Why this number
    /// `PATH_MAX - 1`: `PATH_MAX` (1024 on Darwin) counts the terminating
    /// NUL. MEASURED rather than reasoned, with a chain built fd-relatively
    /// and removed with `FileManager.removeItem`: deepest paths of 1020, 1021,
    /// 1022 and 1023 bytes all remove cleanly; 1024, 1025 and 1026 all fail
    /// with Cocoa 514. `testTheRefusalBoundaryIsExactlyWhereTheRemovalStarts‐
    /// Failing` pins both sides of that edge against the real filesystem, so
    /// the constant cannot drift off the behaviour it encodes.
    ///
    /// NOT a bound on this walk, and deliberately not spelled as one: nothing
    /// here stops reading at the limit. The probe still reads the whole tree
    /// (that is what makes the refusal COMPLETE and therefore trustworthy);
    /// it just records that the tree cannot be removed whole.
    static let removablePathByteLimit = Int(PATH_MAX) - 1

    // MARK: The ONE bounded probe core

    /// Bounded, no-follow inspection of ONE matched artifact dir.
    ///
    /// NO-FOLLOW rule (safety — mirrors the sizer's `.deletionTarget` mode and
    /// fn-3's probe): every descent is lstat-gated, symlinks are never
    /// traversed and never count as valuables (deleting the artifact dir
    /// removes the link, never its target, so no deletable content went
    /// uninspected). Matched bundles are NOT descended by the outer walk —
    /// they are sized as ONE subject; a valuable nested inside a flagged
    /// bundle is already covered by the bundle itself.
    ///
    /// NO-CROSS rule (safety — the same two signals as the sizer and the
    /// project walker): mount boundaries are never crossed, at the root or
    /// anywhere beneath it, and an uncrossed boundary makes the probe
    /// INCOMPLETE. A boundary-bearing artifact dir is denied and refused
    /// whole anyway, so nothing past a mount could change an outcome — and
    /// reading it would spend the entry budget on a network/removable/FUSE
    /// volume outside the configured dev root (see the file header).
    ///
    /// ROOT KIND GATE (PR #457 review r3), applied HERE in the shared core
    /// rather than on one face: `opendir` FOLLOWS a symlink leaf, so a
    /// supplied root that is a symlink would have the probe read — and
    /// disclose — a tree the deletion never touches (deleting the leaf
    /// removes the link only). The delete-time face already gated this and
    /// the scan-time face did not; a check on one face of a two-faced walk is
    /// exactly the scan/delete drift the one-core rule exists to prevent, so
    /// the gate lives in the core and both faces inherit it:
    /// - real directory → the bounded walk below;
    /// - symlink / regular file / special → `.clean`: no contents OF THEIR
    ///   OWN are removed by deleting the leaf, so nothing went uninspected;
    /// - absent → `.clean` (nothing to disclose; the deletion path surfaces
    ///   its own ENOENT and the probe must not preempt it);
    /// - unprobeable → `.incomplete`, fail closed.
    ///
    /// Determinism: within every directory the budget could read WHOLE,
    /// siblings are visited in byte-wise basename order — files as they come,
    /// directories descended in that same ascending order — and the result is
    /// sorted ONCE into the canonical order before returning. Membership
    /// under TRUNCATION is deliberately unspecified; see the file header.
    ///
    /// - Parameter descriptorWindow: TEST SEAM ONLY — the live-descriptor
    ///   window (see `ValuablesProbeWalk`). Production leaves it nil and the
    ///   window derives from `RLIMIT_NOFILE`. It is a PERFORMANCE knob, never
    ///   a policy: the walk completes correctly at a window of 2, so there is
    ///   no tree depth and no descriptor-pressure condition at which it
    ///   reports something it would not report at depth 1.
    static func probe(
        at directory: URL,
        provider: FileSystemIdentityProvider,
        entryLimit: Int = defaultProbeEntryLimit,
        descriptorWindow: Int? = nil
    ) -> ValuablesDisclosure {
        // THE ROOT KIND GATE, no-follow. Retained beside the root open below
        // because it is the ONLY place the probe can tell "not a directory"
        // (→ `.clean`: deleting a symlink or file leaf removes no contents of
        // its own, so nothing went uninspected) apart from "unverifiable"
        // (→ `.incomplete`). The open cannot draw that distinction: it
        // reports ENOTDIR for both a symlink leaf and a leaf swapped for one.
        switch provider.probeKind(of: directory) {
        case .kind(.directory): break
        case .kind, .absent: return .clean
        case .failed: return .incomplete
        }

        // THE ROOT OPEN — the ONE path-based open of the whole walk, and the
        // gate that actually ENFORCES the kind decision above. The `lstat`
        // gate and the open are two separate resolutions of the same path, so
        // a root swapped for a symlink BETWEEN them passes the gate; only
        // `O_NOFOLLOW | O_DIRECTORY` on the open itself refuses it, and it
        // refuses with ENOTDIR (measured; `O_DIRECTORY` is checked before the
        // link, so ELOOP is unreachable here).
        //
        // From here on NOTHING below the root is reached by path: every child
        // is discovered by `fstatat` and opened by `openat` relative to a
        // descriptor this walk already holds and has already vetted. That is
        // what closes the ANCESTOR-swap race, which no amount of re-`lstat`ing
        // or identity re-proof can: if the ancestor is replaced before the
        // vetting stat, the "vetted" identity is ALREADY the foreign object's.
        // Safety here is proof by CONTAINMENT in a held parent inode, and the
        // identity comparison survives only as a cheap corroborator.
        guard let root = SecureDirectory(
            fd: provider.openDirectoryNoFollow(at: directory),
            provider: provider
        ) else { return .incomplete }

        return probe(
            at: directory, root: root, provider: provider,
            entryLimit: entryLimit, descriptorWindow: descriptorWindow
        )
    }

    /// The SAME bounded core, entered with the root ALREADY OPEN and ALREADY
    /// VETTED by the caller — no path-based kind gate and no path-based root
    /// open, because there is no path left to race.
    ///
    /// This is the entry point for a caller that reached `directory` by
    /// CONTAINMENT: it descended to it component by component from a
    /// descriptor it has held continuously since admission, so the object
    /// under `root` is provably the one that chain names. Re-deriving it from
    /// `directory.path` here would throw that proof away and re-resolve every
    /// ancestor — the exact hole `BuildArtifactsScanner`'s post-walk pass had,
    /// and the one that mattered most, since what this probe returns enters
    /// the acknowledgement-token preimage that AUTHORIZES A DELETION.
    ///
    /// `directory` is still required, and still only for what it was always
    /// for: the UNRESOLVED display/identity spelling. It is never opened here.
    ///
    /// The mount checks are unchanged and all of them still run, including the
    /// path-based arms: they can only ever push the answer toward INCOMPLETE.
    static func probe(
        at directory: URL,
        root: SecureDirectory,
        provider: FileSystemIdentityProvider,
        entryLimit: Int = defaultProbeEntryLimit,
        descriptorWindow: Int? = nil
    ) -> ValuablesDisclosure {
        // MOUNT BOUNDARY AT THE ROOT. The sizer applies these signals to its
        // OWN root (`DirectorySizer.swift:202`) and declines to enumerate; the
        // probe must decline identically, or the delete-time face — which has
        // no size report to consult — would read a whole mounted volume.
        // Nothing beneath is opened: not one entry of a foreign filesystem is
        // read, and the verdict is INCOMPLETE because we did not look.
        let rootDevice = provider.deviceID(of: directory)
        let parentDevice = provider.deviceID(
            of: directory.deletingLastPathComponent()
        )
        // THE IDENTITY ANCHOR (PR #457 review, P2 #1). Resolved ONCE, here,
        // BEFORE the walk holds anything — and then never again: every
        // valuable's identity path is this value plus the exact basenames
        // `readdir` handed the walk, so no ancestor is ever re-resolved after
        // its descriptor was opened. See `ValuablesProbeWalk.Frame`.
        // It is the value this mount check already needed, so the anchoring
        // costs the probe not one extra path resolution.
        let identityRoot = provider.canonicalize(directory)
        if (rootDevice != nil && parentDevice != nil
                && rootDevice != parentDevice)
            || provider.isMountPoint(identityRoot) {
            return .incomplete
        }
        // …plus the descriptor-relative arm, which is the one that actually
        // carries the check on modern macOS: `st_dev` is identical for EVERY
        // path on an APFS volume group (measured: `/` and
        // `/System/Volumes/Data` both report 16777230), so only `f_fsid`
        // separates a firmlink mount from its host. `..` of the ROOT is the
        // real parent directory, whatever spelling was handed in.
        switch rootIsMountRoot(root, provider: provider) {
        case .some(true), .none: return .incomplete
        case .some(false): break
        }

        var walk = ValuablesProbeWalk(
            provider: provider, entryLimit: entryLimit,
            window: max(2, descriptorWindow ?? defaultDescriptorWindow()),
            rootURL: directory, identityRootURL: identityRoot,
            rootDevice: rootDevice, root: root
        )
        walk.run()

        // THE ONE canonical order, applied ONCE here: byte-wise ascending by
        // the stored CANONICAL IDENTITY PATH (never a display spelling), so
        // evidence, the model field, the wire array, and the sheet all read
        // the SAME order and nothing downstream re-sorts. Identity paths are
        // unique within one artifact dir, so this is a strict total order.
        return ValuablesDisclosure(
            valuables: walk.found.sorted {
                $0.canonicalIdentityPath.utf8
                    .lexicographicallyPrecedes($1.canonicalIdentityPath.utf8)
            },
            probeComplete: walk.complete,
            incompleteness: walk.incompleteness,
            overlongDescendantPathBytes: walk.overlongDescendantPathBytes
        )
    }

    /// Is the walk root itself the root of a mounted filesystem? `nil` when
    /// that could not be established (fail closed — the caller treats `nil`
    /// exactly like `true`).
    ///
    /// `/`'s `..` is `/` itself, so the identity-equality arm comes first;
    /// otherwise a different `f_fsid` across the `..` step means the root sits
    /// at a mount boundary. Verified against the real firmlinks on this
    /// machine: `/System/Volumes/Data` YES, `/Volumes` YES, `/private/tmp` no,
    /// `~/Library/Caches` no.
    private static func rootIsMountRoot(
        _ root: SecureDirectory, provider: FileSystemIdentityProvider
    ) -> Bool? {
        guard let up = SecureDirectory(
            fd: provider.openParentDirectory(of: root.fd), provider: provider
        ) else { return nil }
        if up.identity == root.identity { return true }
        return up.mount.fsidMajor != root.mount.fsidMajor
            || up.mount.fsidMinor != root.mount.fsidMinor
    }

    /// The live-descriptor window, derived ONCE per probe from the process's
    /// soft descriptor limit.
    ///
    /// `clamp((rlim_cur - 64) / 4, 4, 64)`. The scanner NEVER calls
    /// `setrlimit`: a library must not mutate a process-global limit it shares
    /// with AppKit, `DirectorySizer`, and the privileged helper. Measured on
    /// this machine, a genuinely launchd-spawned process sees a soft limit of
    /// **256** (a dev shell sees 1048576), so the shipped `.app` gets a window
    /// of 48 and a peak of 50 live descriptors, against 64/66 under test —
    /// which is why the window may never become a policy decision.
    private static func defaultDescriptorWindow() -> Int {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return 4 }
        let soft = Int(clamping: limit.rlim_cur)
        return max(4, min(64, (soft - 64) / 4))
    }

    /// Assemble one detected valuable: the SPLIT sourcing made explicit —
    /// `device`/`inode`/`mtime` from the root's ONE lstat (`metadata`),
    /// `allocatedBytes` from the caller (leaf allocation for files, bounded
    /// subtree allocation for bundles).
    ///
    /// `identityPath` is COMPOSED by the walk (anchored root + the basenames
    /// it actually traversed), never re-derived here: a
    /// `resolveTargetKeepingLeaf` of the discovered spelling would resolve
    /// ancestors the walk already holds open, and that value feeds the
    /// acknowledgement token. See `ValuablesProbeWalk.Frame.identityURL`.
    private static func valuable(
        name: String,
        at url: URL,
        identityPath: String,
        metadata: FileSystemIdentityProvider.LeafMetadata,
        allocatedBytes: Int64
    ) -> DetectedValuable {
        DetectedValuable(
            name: name,
            // UNRESOLVED discovered spelling — sheet/reveal only.
            displayURL: url,
            // Canonical parent + UNRESOLVED leaf: ordering, token preimage,
            // and the wire `path` all read THIS.
            canonicalIdentityPath: identityPath,
            identity: ValuableIdentity(
                allocatedBytes: allocatedBytes,
                device: metadata.device,
                inode: metadata.inode,
                modifiedSeconds: metadata.modifiedSeconds,
                modifiedNanoseconds: metadata.modifiedNanoseconds
            )
        )
    }

    // MARK: The descriptor-anchored DFS

    /// TEST-ONLY synchronous observation points, so a test can perform a REAL
    /// `rename`/`symlink` at the EXACT instant the race lives in and let the
    /// real kernel decide the outcome. Single-threaded, no sleeps, no threads,
    /// zero timing dependence. Never set in production.
    enum WalkEvent: Equatable {
        /// A directory's basenames have been READ but NOT yet vetted. This
        /// is the precise instant the ancestor-swap defect lived in: the
        /// pre-fix walk read the real directory's names here and then vetted
        /// each of them by ABSOLUTE PATH, so a swap performed now made both
        /// the vetting stat and the open resolve to the foreign object —
        /// which is why the identity re-proof passed.
        case didReadNames(logical: URL)
        /// A directory's children have been read and vetted; the walk is
        /// about to start descending them.
        case didEnumerate(logical: URL)
        /// A named child is about to be `openat`-ed from its parent.
        case willDescend(name: String, logical: URL)
        /// The frame at `depth` is about to be popped.
        case willPop(depth: Int)
    }

    /// Not concurrency-safe and not meant to be: tests set it, run one probe
    /// synchronously, and clear it.
    nonisolated(unsafe) static var testHook: ((WalkEvent) -> Void)?

    /// The DFS state machine. One frame per level of the CURRENT PATH — never
    /// one per pending sibling, which is the misreading that made
    /// descriptor-relative traversal look like it needed `entryLimit` live
    /// descriptors. Both the outer walk and every bundle's subtree sizing run
    /// on this ONE frame stack and spend from this ONE entry budget, so the
    /// two can neither drift nor compose their bounds.
    ///
    /// ## Invariants (asserted in debug)
    /// - **I1** the DEEPEST frame always holds a live descriptor.
    /// - **I2** live frames are `{0} ∪ [k, count)` — frame 0 plus a
    ///   contiguous suffix. That is what makes restoring a released frame
    ///   exactly one `..` step from the frame below it.
    /// - **I3** `frames[0]` is NEVER released. It is the continuously held
    ///   anchor the whole walk's containment argument rests on, and the frame
    ///   the `..` climb terminates at.
    /// - **I4** `liveCount <= window`.
    ///
    /// ## The descriptor bound
    /// `peak = min(depth + 1, window) + 2`. The `+2` covers the mutually
    /// exclusive transients: the `openat(fd, ".")` handed to `fdopendir`, the
    /// child descriptor between `openat` and `append`, and the `..`
    /// descriptor during a re-anchor.
    ///
    /// ## Why exceeding the window is NOT an event
    /// When the window is full, the SHALLOWEST live frame below the root is
    /// released; when the walk pops back to it, one `openat(child, "..")`
    /// restores it, identity-verified. Exceeding the window costs syscalls and
    /// nothing else — no obstruction, no budget spend, no incompleteness. A
    /// descriptor limit must never resurrect the deterministic, permanently
    /// unclearable refusals the retired depth cap produced.
    private struct ValuablesProbeWalk {
        struct Frame {
            /// `nil` ⇒ released; re-acquirable in one `..` step.
            var dir: SecureDirectory?
            /// Proven when this frame's descriptor was FIRST opened; the
            /// value a re-anchor must reproduce.
            let identity: FileSystemIdentityProvider.Identity
            /// The UNRESOLVED spelling. Display ONLY — it is never opened,
            /// stat'd, or resolved below the root.
            let logicalURL: URL
            /// The ANCHORED IDENTITY spelling: the root's canonical path
            /// (resolved ONCE, before this walk opened anything) plus the
            /// exact basenames `readdir` handed us on the way down. It is
            /// COMPOSED, never resolved — which is what makes it immune to an
            /// ancestor swapped after its descriptor was opened, exactly as
            /// the traversal itself is. This is the value that reaches the
            /// acknowledgement-token preimage.
            let identityURL: URL
            var pending: [String] = []
            var cursor = 0
            /// `fstatat` identity of each pending name, for the corroborator.
            var vetted: [String: FileSystemIdentityProvider.Identity] = [:]
            /// Pending names that are matched BUNDLES (outer mode only).
            var bundles: [String: FileSystemIdentityProvider.LeafMetadata] = [:]
        }

        /// The one in-flight bundle sizing. Bundles never nest — the bundle
        /// rule applies in outer mode only, so a `.app` inside a `.app` is
        /// just another directory being summed — which is why one optional
        /// suffices and no second stack (and no second bound) exists.
        struct BundleSizing {
            let frameIndex: Int
            let name: String
            let logicalURL: URL
            /// Composed exactly like `Frame.identityURL`.
            let identityURL: URL
            let metadata: FileSystemIdentityProvider.LeafMetadata
            var total: Int64 = 0
            var complete = true
        }

        let provider: FileSystemIdentityProvider
        let entryLimit: Int
        let window: Int
        let rootURL: URL
        let rootDevice: UInt64?
        let rootMount: FileSystemIdentityProvider.MountIdentity

        var frames: [Frame] = []
        var liveCount = 0
        var visited = 0
        var complete = true
        var found: [DetectedValuable] = []
        var sizing: BundleSizing?
        var aborted = false
        /// Did the ENTRY BUDGET stop this walk anywhere?
        var budgetExhausted = false
        /// Did anything OTHER than the budget stop it anywhere?
        var obstructed = false

        /// The LONGEST over-limit descendant path this walk composed, or nil
        /// when every one of them fits (review r10).
        ///
        /// Recorded, never acted on: nothing here stops, skips, or shortens
        /// anything because of it. This walk is descriptor-anchored and reads
        /// past the limit perfectly well — it is the CLEANER's path-based
        /// removal that cannot, and the scanner's refusal is what that fact
        /// feeds. Keeping the walk exhaustive is what makes the refusal
        /// COMPLETE, and therefore trustworthy.
        var overlongDescendantPathBytes: Int?

        /// The ONE incompleteness verdict, or nil for a finished walk.
        ///
        /// An obstruction WINS over budget exhaustion whenever both happened:
        /// the causes differ in what clears them, and a bigger budget cannot
        /// clear an unreadable branch. Reporting the escalatable cause while
        /// an unescalatable one is also present would send a caller (and the
        /// user) chasing a second pass that must fail identically.
        var incompleteness: ValuablesDisclosure.ProbeIncompleteness? {
            if complete { return nil }
            if obstructed { return .obstruction }
            return budgetExhausted ? .entryBudget : .obstruction
        }

        /// Record an incompleteness with its CAUSE. Every `complete = false`
        /// in this walk goes through here, so no arm can add a cause-less
        /// refusal.
        mutating func fail(_ cause: ValuablesDisclosure.ProbeIncompleteness) {
            complete = false
            switch cause {
            case .entryBudget: budgetExhausted = true
            case .obstruction: obstructed = true
            }
        }

        /// THE ONE COOPERATIVE-CANCELLATION POINT (PR #457 review, P2 #2).
        /// `true` once the walk has been told to wind down; the walk is
        /// INCOMPLETE from that moment and stops everywhere.
        ///
        /// Classed as an OBSTRUCTION, never `.entryBudget`, and that is the
        /// safety-critical half: `.entryBudget` is the ESCALATABLE cause, so
        /// a cancelled probe reported that way would be re-walked at twice
        /// the bound, sixteen times over, by the very escalation driver the
        /// cancellation is trying to wind down. An obstruction escalates
        /// nothing and — the uniform rule — is tokenless and forces review, so
        /// "we stopped looking" can never be read as "we looked and it was
        /// clean".
        mutating func windingDown() -> Bool {
            guard Task.isCancelled else { return false }
            fail(.obstruction)
            aborted = true
            return true
        }

        init(
            provider: FileSystemIdentityProvider,
            entryLimit: Int,
            window: Int,
            rootURL: URL,
            identityRootURL: URL,
            rootDevice: UInt64?,
            root: SecureDirectory
        ) {
            self.provider = provider
            self.entryLimit = entryLimit
            self.window = window
            self.rootURL = rootURL
            self.rootDevice = rootDevice
            self.rootMount = root.mount
            self.frames = [Frame(
                dir: root, identity: root.identity, logicalURL: rootURL,
                identityURL: identityRootURL
            )]
            self.liveCount = 1
        }

        /// Whether the walk is currently summing a bundle's subtree.
        var isSizing: Bool { sizing != nil }

        mutating func run() {
            enumerate(index: 0)
            walk: while !frames.isEmpty && !aborted {
                if windingDown() { break walk }
                let i = frames.count - 1
                assert(frames[i].dir != nil, "I1")
                assert(liveCount <= window, "I4")
                assert(frames[0].dir != nil, "I3")

                if frames[i].cursor == frames[i].pending.count {
                    ValuablesDetector.testHook?(.willPop(depth: i))
                    if sizing?.frameIndex == i { finishBundle() }
                    // Re-anchor BEFORE the descriptor that makes `..`
                    // reachable is dropped. A failure here is terminal: we
                    // can never get back above this level, and continuing
                    // would be a silent truncation.
                    if i >= 1, frames[i - 1].dir == nil {
                        guard reacquire(index: i - 1, from: frames[i].dir!)
                        else {
                            fail(.obstruction)
                            aborted = true
                            break walk
                        }
                    }
                    if frames[i].dir != nil { liveCount -= 1 }
                    frames.removeLast()
                    continue
                }

                let name = frames[i].pending[frames[i].cursor]
                frames[i].cursor += 1
                descend(name: name, from: i)
            }
            // A bundle still in flight when the budget ran out is finalized
            // here: what WAS summed is a floor, and disclosing a floor is
            // strictly better than hiding a real bundle (the probe is
            // incomplete and therefore tokenless either way).
            if sizing != nil { finishBundle() }
            // Dropping every frame closes every descriptor on EVERY exit
            // path — `SecureDirectory.deinit`, not review vigilance.
            frames.removeAll()
            liveCount = 0
        }

        // MARK: Enumeration

        /// Read + vet one directory's children, descriptor-relative.
        ///
        /// No cancellation check on ENTRY, deliberately: the very next thing
        /// this does is the `readdir` loop, which polls before its first
        /// entry, and the walk loop polls before it gets here — a third check
        /// between them would bound nothing either of those does not, and an
        /// unevidenced guard is one a later refactor keeps for the wrong
        /// reason.
        mutating func enumerate(index: Int) {
            let remaining = entryLimit - visited
            guard remaining > 0 else {
                fail(.entryBudget)
                aborted = true
                return
            }
            guard let dir = frames[index].dir else {
                fail(.obstruction)
                return
            }
            guard let read = ValuablesDetector.boundedChildNames(
                parentFD: dir.fd, limit: remaining, provider: provider
            ) else {
                // Unreadable branch: absence of valuables is UNPROVEN.
                fail(.obstruction)
                return
            }
            // The two ways ONE directory read can come up short, kept apart:
            // entries left unread because the budget ended, versus a read that
            // FAILED or produced a name that could not be decoded.
            if read.budgetTruncated { fail(.entryBudget) }
            if read.obstructed { fail(.obstruction) }
            // Sorting a slice bounded by the REMAINING budget, never a whole
            // million-entry build directory.
            let names = read.names
                .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            ValuablesDetector.testHook?(
                .didReadNames(logical: frames[index].logicalURL)
            )

            for name in names {
                // The VETTING loop runs one `fstatat` per name, up to the
                // whole granted budget — it winds down per name, like the read
                // that fed it.
                if windingDown() { return }
                guard visited < entryLimit else {
                    fail(.entryBudget)
                    aborted = true
                    return
                }
                visited += 1
                // MANDATORY: a multi-component name defeats `O_NOFOLLOW`
                // entirely (measured). `readdir` cannot produce one; this
                // makes a future refactor a refusal instead of a hole.
                guard FileSystemIdentityProvider.isSafeComponent(name) else {
                    fail(.obstruction)
                    continue
                }
                let logical = frames[index].logicalURL
                    .appendingPathComponent(name)
                // THE REMOVAL'S LIMIT, measured on the removal's OWN spelling
                // (review r10). `logicalURL` is rooted at the exact
                // UNRESOLVED URL the cleaner passes to `FileManager
                // .removeItem`, so a length composed here is the length
                // `removefile(3)` would compose there — the two cannot drift.
                // Every entry is checked, files included: an over-long FILE is
                // as fatal to the removal as an over-long directory.
                //
                // Cost: `URL.path` on an already-built URL, measured at
                // 258.6 ns/entry against the 567.4 ns `fstatat` and the
                // ~1971 ns `appendingPathComponent` this loop already pays per
                // entry — ~10% of the per-entry cost, and zero syscalls. The
                // alternative (carrying a running byte count on each frame)
                // would re-implement path composition beside Foundation's and
                // could silently disagree with it; this reads the very string
                // whose length is the question.
                if logical.path.utf8.count
                    > ValuablesDetector.removablePathByteLimit {
                    overlongDescendantPathBytes = max(
                        overlongDescendantPathBytes ?? 0,
                        logical.path.utf8.count
                    )
                }
                // COMPOSED, never resolved (see `Frame.identityURL`).
                let identityURL = frames[index].identityURL
                    .appendingPathComponent(name)
                // ONE atomic no-follow stat, relative to the HELD parent:
                // kind, identity, allocation and mtime together. This
                // replaces the `probeKind(of:)` + `leafMetadata(of:)` PAIR,
                // whose second path lstat was an independent re-resolution
                // whose output fed the acknowledgement-token preimage.
                switch provider.probeKind(
                    inDirectory: dir.fd, named: name, logical: logical
                ) {
                case .kind(.regularFile, _, let metadata):
                    record(
                        file: name, logical: logical, identity: identityURL,
                        metadata: metadata
                    )
                case .kind(.directory, let identity, let metadata):
                    record(
                        directory: name, logical: logical, index: index,
                        identity: identity, metadata: metadata
                    )
                case .kind:
                    // Symlink / special: never followed, never a valuable.
                    break
                case .absent:
                    // Vanished mid-probe — the ordinary benign race.
                    break
                case .failed:
                    fail(.obstruction)
                }
            }
            ValuablesDetector.testHook?(
                .didEnumerate(logical: frames[index].logicalURL)
            )
        }

        private mutating func record(
            file name: String, logical: URL, identity identityURL: URL,
            metadata: FileSystemIdentityProvider.LeafMetadata?
        ) {
            if isSizing {
                guard let metadata else {
                    sizing?.complete = false
                    return
                }
                let (sum, overflow) = (sizing?.total ?? 0)
                    .addingReportingOverflow(metadata.allocatedBytes)
                guard !overflow else {
                    // Physically unreachable; still never saturated — an
                    // unrepresentable sum is an incomplete sizing.
                    sizing?.complete = false
                    aborted = true
                    return
                }
                sizing?.total = sum
                return
            }
            guard fileExtensions.contains(logical.pathExtension.lowercased())
            else { return }
            guard let metadata else {
                // Metadata we cannot describe is a valuable we cannot
                // describe — fail closed rather than skip silently.
                fail(.obstruction)
                return
            }
            guard metadata.allocatedBytes >= minimumAllocatedBytes else {
                return
            }
            found.append(ValuablesDetector.valuable(
                name: name, at: logical, identityPath: identityURL.path,
                metadata: metadata, allocatedBytes: metadata.allocatedBytes
            ))
        }

        private mutating func record(
            directory name: String, logical: URL, index: Int,
            identity: FileSystemIdentityProvider.Identity,
            metadata: FileSystemIdentityProvider.LeafMetadata?
        ) {
            frames[index].pending.append(name)
            frames[index].vetted[name] = identity
            guard !isSizing else { return }
            guard bundleExtensions
                .contains(logical.pathExtension.lowercased())
            else { return }
            guard let metadata else {
                // A bundle we cannot describe is never disclosed and never
                // sized: its size would enter a token preimage.
                fail(.obstruction)
                frames[index].pending.removeLast()
                return
            }
            frames[index].bundles[name] = metadata
        }

        // MARK: Descent

        mutating func descend(name: String, from index: Int) {
            guard let parent = frames[index].dir else {
                fail(.obstruction)
                aborted = true
                return
            }
            let logical = frames[index].logicalURL
                .appendingPathComponent(name)
            ValuablesDetector.testHook?(
                .willDescend(name: name, logical: logical)
            )

            let fd = provider.openChildDirectory(
                inDirectory: parent.fd, named: name, logical: logical
            )
            guard fd >= 0 else {
                let code = errno
                // ENOENT is the ordinary eviction race and stays BENIGN:
                // classing it as a failure would make almost every probe of a
                // live build directory incomplete. Everything else — ENOTDIR
                // (the name is no longer a directory: swapped for a symlink,
                // swapped for a file, or raced), EACCES, EMFILE — is unproven.
                if code != ENOENT { fail(.obstruction) }
                return
            }
            guard let child = SecureDirectory(fd: fd, provider: provider)
            else {
                fail(.obstruction)
                return
            }
            // The corroborator. Sound now in a way it never was before: the
            // vetted value came from an `fstatat` on THIS SAME held parent
            // descriptor, so it cannot itself be a foreign object's identity.
            // It catches the one swap `O_NOFOLLOW` cannot see — a directory
            // re-bound to a DIFFERENT real directory.
            guard let vetted = frames[index].vetted[name],
                  child.identity == vetted
            else {
                fail(.obstruction)
                return
            }
            guard !crossesMountBoundary(child: child, logical: logical) else {
                // We did not look past it: unproven, exactly like an
                // unreadable branch.
                fail(.obstruction)
                return
            }

            let bundle = isSizing ? nil : frames[index].bundles[name]
            // COMPOSED from the parent frame's anchored identity — the same
            // basename `readdir` produced and `openat` just descended, so the
            // identity path names exactly the inode this frame holds.
            let identityURL = frames[index].identityURL
                .appendingPathComponent(name)
            makeRoom()
            frames.append(Frame(
                dir: child, identity: child.identity, logicalURL: logical,
                identityURL: identityURL
            ))
            liveCount += 1
            if let bundle {
                sizing = BundleSizing(
                    frameIndex: frames.count - 1, name: name,
                    logicalURL: logical, identityURL: identityURL,
                    metadata: bundle
                )
            }
            enumerate(index: frames.count - 1)
        }

        /// A finished bundle: identity from the bundle ROOT's own `fstatat`,
        /// size from the subtree just summed. A truncated sizing makes the
        /// WHOLE probe incomplete — a token must never derive from a partial
        /// size — while what WAS summed is still disclosed if it clears the
        /// floor (hiding a real bundle because the budget ran out is strictly
        /// worse; it is a floor on the warning, never a basis to authorize).
        private mutating func finishBundle() {
            guard let bundle = sizing else { return }
            sizing = nil
            // A bundle sizing that failed on METADATA (or an
            // unrepresentable sum) is an obstruction; a bundle the BUDGET cut
            // short never sets this flag — that arm already recorded the
            // budget as the cause where it happened.
            if !bundle.complete { fail(.obstruction) }
            guard bundle.total >= minimumAllocatedBytes else { return }
            found.append(ValuablesDetector.valuable(
                name: bundle.name, at: bundle.logicalURL,
                identityPath: bundle.identityURL.path,
                metadata: bundle.metadata, allocatedBytes: bundle.total
            ))
        }

        // MARK: The descriptor window

        /// Free a slot before a push, if the window is full. NEVER a refusal
        /// and never charged to the entry budget.
        private mutating func makeRoom() {
            guard liveCount >= window else { return }
            // The shallowest live frame BELOW the root — releasing it is what
            // keeps the live set `{0} ∪ [k, count)` (I2), so restoring it is
            // always exactly one `..` from the frame directly beneath it.
            guard let shallowest = (1..<frames.count)
                .first(where: { frames[$0].dir != nil })
            else { return }
            frames[shallowest].dir = nil          // deinit closes the fd
            liveCount -= 1
        }

        /// Restore a released frame from the frame directly BELOW it.
        ///
        /// `..` is never a symlink, so no `O_NOFOLLOW` is needed; the identity
        /// check is what makes the step safe — it detects the subtree having
        /// been MOVED under a foreign parent, which is the one way a `..` can
        /// land somewhere we never vetted.
        private mutating func reacquire(
            index: Int, from deeper: SecureDirectory
        ) -> Bool {
            guard let restored = SecureDirectory(
                fd: provider.openParentDirectory(of: deeper.fd),
                provider: provider
            ) else { return false }
            guard restored.identity == frames[index].identity else {
                return false
            }
            frames[index].dir = restored
            liveCount += 1
            return true
        }

        // MARK: Mount boundary

        /// Does descending into an ALREADY-OPEN child cross a mount boundary?
        ///
        /// Two families of signal, and the descriptor family is the one that
        /// carries the check:
        ///
        /// - `f_fsid` and `st_dev` of the CHILD'S OWN DESCRIPTOR against the
        ///   root's. Immune to every path race, and `f_fsid` is the only
        ///   discriminator that sees an APFS firmlink mount at all: measured
        ///   on this machine `st_dev` is 16777230 for literally every path
        ///   INCLUDING `/`, so the device arm alone is blind to exactly the
        ///   system/Data split it was partly meant to catch.
        /// - The two PATH arms this probe has always had. They are retained
        ///   deliberately, not by oversight: they are the seam hermetic tests
        ///   inject synthetic devices and mount points through, and they can
        ///   only ever push the answer toward REFUSAL, so a path resolved
        ///   through a hostile ancestor can make this walk stop early but can
        ///   never make it descend something the descriptor arms refused. The
        ///   alias-blindness that used to make `isMountPoint` answer `false`
        ///   for an aliased spelling is no longer load-bearing, because
        ///   `f_fsid` now catches that case first.
        ///
        /// Declared ORDERING shift: the check now runs AFTER the child is
        /// opened rather than during its parent's enumeration, so under
        /// truncation a boundary below the cut is no longer in the refusal
        /// set. Truncation membership is already unspecified by contract and
        /// a truncated probe is incomplete regardless.
        private func crossesMountBoundary(
            child: SecureDirectory, logical: URL
        ) -> Bool {
            if child.mount.device != rootMount.device { return true }
            if child.mount.fsidMajor != rootMount.fsidMajor
                || child.mount.fsidMinor != rootMount.fsidMinor {
                return true
            }
            if let rootDevice, let childDevice = provider.deviceID(of: logical),
               childDevice != rootDevice {
                return true
            }
            return provider.isMountPoint(provider.canonicalize(logical))
        }
    }

    /// BOUNDED directory read: at most `limit` basenames, plus whether MORE
    /// entries remained unread. `nil` when the directory could not be opened
    /// (the caller's fail-closed "unreadable branch" arm).
    ///
    /// `opendir`/`readdir` rather than `FileManager` on purpose — BOTH
    /// Foundation overloads materialize the WHOLE directory before any cap
    /// can apply, which would let a build directory with a million entries
    /// spike memory and CPU inside the very probe whose contract is to stay
    /// bounded (`contentsOfDirectory(at:)` additionally returns fully
    /// RESOLVED child URLs, while `displayURL` must keep the walk's own
    /// unresolved spelling for reveal-in-Finder). Reading basenames also
    /// keeps the spelling question moot: the caller appends them to ITS OWN
    /// directory URL. `.` and `..` are skipped; hidden entries are INCLUDED
    /// (a `.dmg` in a dot-directory is still a release artifact).
    ///
    /// The enumeration is NOT PROVEN EXHAUSTED in two SEPARATELY REPORTED
    /// ways, because they have different remedies (the caller maps them to
    /// `ProbeIncompleteness` verbatim): `budgetTruncated` means entries
    /// remained that the granted budget could not read — a bigger budget
    /// reads them — while `obstructed` means a `readdir` FAILED or an entry's
    /// name could not be decoded, which no budget can fix. Either one makes
    /// the probe incomplete.
    ///
    /// UNDECODABLE NAMES FAIL CLOSED: `String(validatingCString:)`, never
    /// `String(cString:)`. A repairing decode would substitute U+FFFD, and
    /// the URL rebuilt from that lie names a DIFFERENT path — `probeKind`
    /// would report it absent and the probe could return "complete, nothing
    /// found" while the real entry (a `.dmg`, say) was never inspected. APFS
    /// and HFS+ reject non-UTF-8 basenames outright (EILSEQ), but a mounted
    /// exFAT/SMB/FUSE volume can deliver them. The read STOPS at the first
    /// undecodable entry: the directory is already unproven, and continuing
    /// would let a hostile directory full of such names defeat the budget.
    ///
    /// DESCRIPTOR-RELATIVE (PR #457 review r5): the enumeration handle comes
    /// from `openat(parentFD, ".")` — never a path, never `dup`, never
    /// `fcntl(F_DUPFD_CLOEXEC)`. `dup` clears `FD_CLOEXEC` (leaking directory
    /// descriptors into every `posix_spawn`, and this app spawns a privileged
    /// helper) and BOTH duplication forms share the anchor's file offset, so a
    /// second enumeration through them silently returns zero entries.
    /// `closedir` closes only this handle; the caller's anchor survives.
    ///
    /// COOPERATIVELY CANCELLABLE (PR #457 review, P2 #2), and this is the loop
    /// that most needed it: the bound it runs to is the WHOLE probe's entry
    /// budget, which is no longer a flat 20,000 but proportionate to the
    /// subject and escalating to `20_000 << 16` — so ONE directory read can be
    /// three orders of magnitude longer than anything this code used to
    /// perform between cancellation checks. The view model deliberately awaits
    /// the producer's ACTUAL completion after cancelling
    /// (`CacheoutViewModel.untilProducerFinishes`), so every entry read after
    /// the cancel is time the UI spends unresponsive and a pending runtime
    /// replacement spends queued.
    ///
    /// A cancelled read reports itself `obstructed` — the SAME channel an
    /// unreadable branch uses, and deliberately so: both mean "this directory
    /// was not proven empty of valuables and no bigger budget changes that",
    /// which is exactly the verdict cancellation deserves. Reporting it as
    /// `budgetTruncated` would send `ValuablesProbeBudget.escalating` off to
    /// re-walk a cancelled tree at twice the bound, sixteen times over. One
    /// mapping, no second cancellation vocabulary to drift.
    ///
    /// NOT `private`: the cancellation policy is proven by calling this
    /// directly on a real directory of thousands of entries, in the same
    /// spirit as `decodedBasename` — the returned `names` are the WORK
    /// ACTUALLY DONE, so the test measures the loop instead of asking it.
    static func boundedChildNames(
        parentFD: Int32, limit: Int, provider: FileSystemIdentityProvider
    ) -> (names: [String], budgetTruncated: Bool, obstructed: Bool)? {
        let enumerationFD = provider.openSelfForEnumeration(parentFD)
        guard enumerationFD >= 0 else { return nil }
        guard let handle = fdopendir(enumerationFD) else {
            close(enumerationFD)
            return nil
        }
        // Closes the description `fdopendir` took ownership of; the anchor
        // `parentFD` is a DIFFERENT description and is untouched.
        defer { closedir(handle) }
        var names: [String] = []
        var budgetTruncated = false
        var obstructed = false
        while true {
            // Checked EVERY entry, not every N. Measured on this machine
            // inside a real `Task` (where the check takes its atomic-load
            // path) over a 50,000-entry directory: 11.55 ns for the poll
            // against 513.50 ns per `readdir` entry — 2.2%. An interval would
            // buy that back by putting a directory's own size into the
            // wind-down latency this exists to bound.
            if Task.isCancelled {
                obstructed = true
                break
            }
            // `readdir` returns nil for BOTH end-of-stream and error; errno
            // is the only discriminator, so it is cleared before each call.
            errno = 0
            guard let entry = readdir(handle) else {
                if errno != 0 { obstructed = true }
                break
            }
            let decoded = withUnsafeBytes(of: entry.pointee.d_name) {
                raw -> String? in
                guard let base = raw.bindMemory(to: CChar.self).baseAddress
                else { return nil }
                return decodedBasename(fromCString: base)
            }
            guard let name = decoded, !name.isEmpty else {
                obstructed = true
                break
            }
            if name == "." || name == ".." { continue }
            guard names.count < limit else {
                budgetTruncated = true
                break
            }
            names.append(name)
        }
        return (names, budgetTruncated, obstructed)
    }

    /// The VALIDATING basename decode, factored out so the fail-closed policy
    /// is testable without a non-UTF-8-capable volume (APFS/HFS+ refuse to
    /// create such names at all). `nil` for ANY byte sequence that is not
    /// valid UTF-8 — never a U+FFFD-repaired string, which would name a
    /// different path than the entry it came from.
    static func decodedBasename(
        fromCString pointer: UnsafePointer<CChar>
    ) -> String? {
        String(validatingCString: pointer)
    }
}
