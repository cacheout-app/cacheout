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
/// A probe that could not finish (entry budget exhausted, unreadable branch,
/// a mount boundary left uncrossed, unreadable metadata, an undecodable
/// basename, a bundle whose bounded subtree sizing truncated) is INCOMPLETE.
/// An incomplete probe has the SAME consequence as a hit: risk forced off
/// safe, selection forced false, "couldn't fully inspect" evidence — and,
/// uniformly across every surface, NO acknowledgement token exists. Absence of
/// valuables is only meaningful when the inspection actually finished.
///
/// ## Mount boundaries are NEVER crossed (PR #457 review, R15)
/// The probe stops at every mount boundary, using the SAME two signals the
/// sizer (`DirectorySizer.swift:202,287`) and the project walker
/// (`ProjectTreeWalker.swift:376`) already use — device-id change against the
/// walk root, plus the `statfs` mount-root check that catches same-`st_dev`
/// firmlink mounts. There is exactly ONE notion of "mount boundary" in this
/// codebase and this is it; nothing here re-derives a second one.
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
/// ## ONE budget, and NO depth cap (PR #457 review)
/// The shared ENTRY budget is the probe's only bound, and it alone guarantees
/// termination: every directory the walk descends into cost one entry to
/// discover, so at most `entryLimit` directories are ever popped — true even
/// of a hypothetical directory cycle. A fixed depth cap therefore bounded
/// nothing the budget did not already bound. What it DID do was manufacture
/// INCOMPLETE verdicts on ordinary artifact trees, and those verdicts were
/// unescapable: a depth boundary is DETERMINISTIC, so every re-scan and every
/// delete-time re-probe reproduced it, while an incomplete probe is tokenless
/// — the GUI filtered the item out and the revalidator refused it forever,
/// and the "re-scan and retry" guidance every surface prints could not
/// possibly help. Real trees crossed eight levels constantly (this repo's own
/// `.build` nests thirteen deep, well inside the entry budget), so the cap
/// stranded exactly the build directories this scanner exists to reclaim.
/// Depth is now spent FROM the one budget: a tree the budget can afford is
/// PROVEN, and only a tree it genuinely cannot afford stays unproven.
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
/// `canonicalIdentityPath` is THE one stored identity path: the
/// `resolveTargetKeepingLeaf` derivation (canonical parent chain + UNRESOLVED
/// leaf — the house identity doctrine). It drives the canonical ORDERING, the
/// token PREIMAGE, and the wire `path` field — one value, three consumers, so
/// an alias-spelled root and the canonical root produce identical ordering and
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

    /// The probe result that forces nothing: nothing found, inspection
    /// finished.
    static let clean = ValuablesDisclosure(valuables: [], probeComplete: true)

    /// The fail-closed result of an inspection that could not even begin:
    /// nothing disclosed, and nothing PROVEN — unauthorizable and tokenless.
    static let incomplete = ValuablesDisclosure(
        valuables: [], probeComplete: false
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

    /// The PRODUCTION probe cap — ONE definition, consumed by the scanner's
    /// init default AND by the delete-time entry point
    /// (`BuildArtifactsScanner.preDeleteValuablesProbe`), so the two
    /// inspections' bounds can never drift apart (the
    /// `OrphanedCachesScanner.swift:193` doctrine).
    ///
    /// This is the GLOBAL bound on the probe's total work AND the sole
    /// guarantee that it terminates — it is shared across the outer walk and
    /// every bundle's subtree sizing, so the whole probe visits at most this
    /// many directory entries however deep the tree runs (see the file
    /// header on why there is no second, depth-shaped bound).
    static let defaultProbeEntryLimit = 20_000

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
    /// directories descended in that same ascending order (the stack is
    /// loaded in reverse so `popLast` yields ascending) — and the result is
    /// sorted ONCE into the canonical order before returning. Membership
    /// under TRUNCATION is deliberately unspecified; see the file header.
    static func probe(
        at directory: URL,
        provider: FileSystemIdentityProvider,
        entryLimit: Int = defaultProbeEntryLimit
    ) -> ValuablesDisclosure {
        // THE ROOT KIND GATE, no-follow and BEFORE anything is opened (see
        // the doc comment). One `lstat`, shared by both faces.
        switch provider.probeKind(of: directory) {
        case .kind(.directory): break
        case .kind, .absent: return .clean
        case .failed: return .incomplete
        }

        var found: [DetectedValuable] = []
        var complete = true
        // The GLOBAL entry budget, shared with every bundle subtree walk —
        // and the ONE bound on this walk (see the file header).
        var visited = 0

        // MOUNT BOUNDARY AT THE ROOT. The sizer applies exactly this pair of
        // signals to its OWN root (`DirectorySizer.swift:202`) and declines to
        // enumerate; the probe must decline identically, or the delete-time
        // face — which has no size report to consult — would read a whole
        // mounted volume. Nothing is opened: not one entry of a foreign
        // filesystem is read, and the verdict is INCOMPLETE because we did
        // not look.
        //
        // CANONICAL INPUT for the `statfs` arm (PR #457 review r4): the sizer
        // hands that arm its already-resolved root, and `isMountPoint`
        // REQUIRES it — it compares `f_mntonname`, always canonical, against
        // the path it is given, so an aliased spelling silently answers
        // `false`. This probe is handed the walker's (or the cleaner's frozen
        // target's) deliberately UNRESOLVED spelling, which is what made an
        // artifact dir reached through a symlinked ancestor invisible to this
        // arm. Safe HERE because the ROOT KIND GATE above already proved
        // `directory` a REAL directory, so no symlink leaf can reach this
        // call and a real directory's own name is its canonical name. The
        // canonical value is an ARGUMENT and is discarded: `directory` itself
        // is what gets walked, sorted, and turned into items.
        let rootDevice = provider.deviceID(of: directory)
        let parentDevice = provider.deviceID(
            of: directory.deletingLastPathComponent()
        )
        if (rootDevice != nil && parentDevice != nil
                && rootDevice != parentDevice)
            || provider.isMountPoint(provider.canonicalize(directory)) {
            return .incomplete
        }

        var stack: [URL] = [directory]

        walk: while let dir = stack.popLast() {
            let remaining = entryLimit - visited
            guard remaining > 0 else {
                // Budget exhausted with directories still unexplored.
                complete = false
                break walk
            }
            guard let read = boundedChildNames(of: dir, limit: remaining)
            else {
                // Unreadable branch: absence of valuables is UNPROVEN.
                complete = false
                continue
            }
            if read.truncated {
                // More entries existed than the remaining budget could read.
                complete = false
            }
            // Sorting a slice bounded by the REMAINING budget, never a whole
            // million-entry build directory.
            let names = read.names
                .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            // Descend in ascending order: collected here, pushed reversed.
            var pendingDirectories: [URL] = []

            for name in names {
                guard visited < entryLimit else {
                    // The shared budget can still run out mid-directory —
                    // a bundle's subtree sizing spends from the same pot.
                    complete = false
                    break walk
                }
                visited += 1

                let child = dir.appendingPathComponent(name)
                let ext = child.pathExtension.lowercased()

                switch provider.probeKind(of: child) {
                case .kind(.regularFile):
                    guard fileExtensions.contains(ext) else { break }
                    // ONE no-follow lstat: identity AND the leaf allocation.
                    guard let metadata = provider.leafMetadata(of: child) else {
                        // Metadata we cannot read is a valuable we cannot
                        // describe — fail closed rather than skip silently.
                        complete = false
                        break
                    }
                    guard metadata.allocatedBytes >= minimumAllocatedBytes
                    else { break }
                    found.append(valuable(
                        name: name, at: child, provider: provider,
                        metadata: metadata,
                        allocatedBytes: metadata.allocatedBytes
                    ))

                case .kind(.directory):
                    // MOUNT BOUNDARY: never crossed, whatever is on the far
                    // side. Checked BEFORE the bundle split on purpose — a
                    // mounted `.app` must not be subtree-sized either, and
                    // sizing it would spend the same budget on the same
                    // foreign volume.
                    guard !crossesMountBoundary(
                        child, rootDevice: rootDevice, provider: provider
                    ) else {
                        // We did not look past it: unproven, exactly like an
                        // unreadable branch.
                        complete = false
                        break
                    }
                    guard bundleExtensions.contains(ext) else {
                        // ALWAYS descended: discovering this directory
                        // already cost an entry, and the budget bounds what
                        // follows. Refusing to look at some fixed level is
                        // what stranded deep trees (see the file header).
                        pendingDirectories.append(child)
                        break
                    }
                    // BUNDLE. Identity from the bundle ROOT's ONE lstat;
                    // size from the bounded subtree walk below. The outer
                    // walk deliberately does not descend it.
                    let sized = boundedSubtreeAllocation(
                        at: child, provider: provider,
                        rootDevice: rootDevice,
                        entryLimit: entryLimit, visited: &visited
                    )
                    if !sized.complete {
                        // A truncated bundle sizing makes the whole probe
                        // INCOMPLETE: a token must never derive from a
                        // partial size.
                        complete = false
                    }
                    guard let metadata = provider.leafMetadata(of: child) else {
                        complete = false
                        break
                    }
                    guard sized.allocatedBytes >= minimumAllocatedBytes
                    else { break }
                    found.append(valuable(
                        name: name, at: child, provider: provider,
                        metadata: metadata,
                        allocatedBytes: sized.allocatedBytes
                    ))

                case .kind:
                    // Symlink / special file: never followed, never a
                    // valuable (see the no-follow rule).
                    break
                case .absent:
                    // Vanished mid-probe — a benign race.
                    break
                case .failed:
                    // Could not establish the kind — fail closed.
                    complete = false
                }
            }
            // Reversed, so `popLast` descends siblings in ASCENDING order.
            stack.append(contentsOf: pendingDirectories.reversed())
        }

        // THE ONE canonical order, applied ONCE here: byte-wise ascending by
        // the stored CANONICAL IDENTITY PATH (never a display spelling), so
        // evidence, the model field, the wire array, and the sheet all read
        // the SAME order and nothing downstream re-sorts. Identity paths are
        // unique within one artifact dir, so this is a strict total order.
        return ValuablesDisclosure(
            valuables: found.sorted {
                $0.canonicalIdentityPath.utf8
                    .lexicographicallyPrecedes($1.canonicalIdentityPath.utf8)
            },
            probeComplete: complete
        )
    }

    /// Assemble one detected valuable: the SPLIT sourcing made explicit —
    /// `device`/`inode`/`mtime` from the root's ONE lstat (`metadata`),
    /// `allocatedBytes` from the caller (leaf allocation for files, bounded
    /// subtree allocation for bundles).
    private static func valuable(
        name: String,
        at url: URL,
        provider: FileSystemIdentityProvider,
        metadata: FileSystemIdentityProvider.LeafMetadata,
        allocatedBytes: Int64
    ) -> DetectedValuable {
        DetectedValuable(
            name: name,
            // UNRESOLVED discovered spelling — sheet/reveal only.
            displayURL: url,
            // Canonical parent + UNRESOLVED leaf: ordering, token preimage,
            // and the wire `path` all read THIS.
            canonicalIdentityPath: provider.resolveTargetKeepingLeaf(url).path,
            identity: ValuableIdentity(
                allocatedBytes: allocatedBytes,
                device: metadata.device,
                inode: metadata.inode,
                modifiedSeconds: metadata.modifiedSeconds,
                modifiedNanoseconds: metadata.modifiedNanoseconds
            )
        )
    }

    /// Bounded, no-follow allocation of one directory bundle's subtree.
    ///
    /// Counts REGULAR FILES' allocated bytes only (directory inodes are not
    /// counted — the same stance as the shared `DirectorySizer`), never
    /// follows symlinks, and shares the caller's GLOBAL entry budget — the
    /// one bound here too, so the whole probe stays bounded. Mount boundaries
    /// are not crossed here either — a bundle can hold a mounted subtree just
    /// as an artifact dir can. `complete == false` on an unreadable branch, an
    /// uncrossed mount boundary, unreadable file metadata, the entry cap, or
    /// an allocation sum that would overflow `Int64` — every one of which
    /// makes the returned figure a FLOOR, never a truth, so no token may
    /// derive from it. A deep bundle (`Contents/Frameworks/…
    /// /Versions/A/Resources/…` runs long) is sized WHOLE while the budget
    /// lasts: an under-counted bundle would fall below the floor and vanish
    /// from the disclosure entirely.
    private static func boundedSubtreeAllocation(
        at bundleRoot: URL,
        provider: FileSystemIdentityProvider,
        rootDevice: UInt64?,
        entryLimit: Int,
        visited: inout Int
    ) -> (allocatedBytes: Int64, complete: Bool) {
        var total: Int64 = 0
        var complete = true
        var stack: [URL] = [bundleRoot]

        walk: while let dir = stack.popLast() {
            let remaining = entryLimit - visited
            guard remaining > 0 else {
                complete = false
                break walk
            }
            guard let read = boundedChildNames(of: dir, limit: remaining)
            else {
                complete = false
                continue
            }
            if read.truncated { complete = false }
            let names = read.names
                .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            var pendingDirectories: [URL] = []

            for name in names {
                guard visited < entryLimit else {
                    complete = false
                    break walk
                }
                visited += 1

                let child = dir.appendingPathComponent(name)
                switch provider.probeKind(of: child) {
                case .kind(.regularFile):
                    guard let metadata = provider.leafMetadata(of: child) else {
                        complete = false
                        break
                    }
                    let (sum, overflow) = total
                        .addingReportingOverflow(metadata.allocatedBytes)
                    guard !overflow else {
                        // Physically unreachable; still never saturated —
                        // an unrepresentable sum is an incomplete sizing.
                        complete = false
                        break walk
                    }
                    total = sum
                case .kind(.directory):
                    // The SAME uncrossable boundary, against the SAME walk
                    // root as the outer probe (the bundle was reached from
                    // it, so it shares its device). An uncrossed branch makes
                    // the size a FLOOR, so the sizing is incomplete.
                    guard !crossesMountBoundary(
                        child, rootDevice: rootDevice, provider: provider
                    ) else {
                        complete = false
                        break
                    }
                    pendingDirectories.append(child)
                case .kind:
                    // Symlink / special: 0 bytes, never followed.
                    break
                case .absent:
                    break
                case .failed:
                    complete = false
                }
            }
            stack.append(contentsOf: pendingDirectories.reversed())
        }
        return (total, complete)
    }

    /// Does descending into `child` cross a mount boundary?
    ///
    /// The house rule VERBATIM — both signals, no third notion invented here:
    /// (a) device-id change against the WALK ROOT, which catches foreign
    /// volumes and injected test devices, and (b) the `statfs` mount-root
    /// check, required because a unified APFS volume group presents ONE
    /// `st_dev` across the system/Data pair so a firmlink mount is invisible
    /// to (a). The SAME rule the sizer and the project walker apply
    /// (`DirectorySizer.swift:289`, `ProjectTreeWalker.swift:405`); a `nil`
    /// device on either side disables only arm (a), exactly as it does there.
    /// Arm (b)'s ARGUMENT differs by necessity — see below: the sizer walks
    /// an already-resolved root, this probe and the walker do not.
    ///
    /// `child` is lstat-probed as a real directory by both callers before
    /// this runs, so a symlink pointing AT a volume root never reaches here
    /// (and is never followed regardless — the no-follow rule).
    ///
    /// ## Arm (b) gets a CANONICAL path, and ONLY arm (b) (PR #457 review r4)
    /// `isMountPoint` compares `statfs`'s `f_mntonname` — always canonical —
    /// against the path handed to it, and documents that requirement
    /// (`FileSystemIdentityProvider.swift:143`); the sizer satisfies it by
    /// passing its already-resolved URLs. This probe cannot: it keeps the
    /// UNRESOLVED spelling on purpose, because that is the path a deletion
    /// removes and the one a no-follow `lstat` must land on. So an aliased
    /// spelling — an artifact dir under a dev root declared through a
    /// symlinked ancestor (`/tmp/work`, a symlinked home), or the cleaner's
    /// frozen delete-time target — never equalled `f_mntonname`, and arm (b)
    /// answered `false` for a real mount.
    ///
    /// On its own that is a false negative behind a working arm (a). It is
    /// NOT defense-in-depth, because the two fail TOGETHER on a
    /// firmlink-shaped mount that shares the walk root's `st_dev` — which is
    /// exactly the case arm (b) exists to catch. Both silent means the probe
    /// enumerates the mounted volume and calls the result COMPLETE: a "proven
    /// clean" verdict derived from a filesystem the user never pointed this
    /// scanner at, on the delete-time face that has no size report to back it
    /// up.
    ///
    /// The canonical spelling is therefore computed HERE, as an argument, and
    /// discarded. It is never returned, never stored, never pushed on the
    /// stack, never sorted, and never reaches an item — canonicalizing the
    /// traversal would break the `resolveTargetKeepingLeaf` doctrine
    /// (identity is the canonical PARENT chain plus the UNRESOLVED leaf) and
    /// point the walk at paths the deletion does not touch, which is a worse
    /// bug than the one this fixes. Safe here specifically: `canonicalize`
    /// resolves the leaf too, which the unresolved-leaf rule forbids
    /// elsewhere (a mere LINK to a volume root must report `false`), but both
    /// callers run inside `case .kind(.directory)`, so no symlink leaf can
    /// reach this call and a real directory's own name is its canonical name.
    /// Cost is one `realpath` per DIRECTORY child, on the arm-(a)-silent path
    /// only, inside a walk already bounded to `entryLimit` entries and beside
    /// a `DirectorySizer` pass that enumerates the same tree unbounded.
    private static func crossesMountBoundary(
        _ child: URL,
        rootDevice: UInt64?,
        provider: FileSystemIdentityProvider
    ) -> Bool {
        let childDevice = provider.deviceID(of: child)
        if rootDevice != nil && childDevice != nil
            && childDevice != rootDevice {
            return true
        }
        return provider.isMountPoint(provider.canonicalize(child))
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
    /// `truncated` means the enumeration is NOT PROVEN EXHAUSTED — more
    /// entries remained, a `readdir` failed, or an entry's name could not be
    /// decoded. Every one of those makes the probe incomplete.
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
    private static func boundedChildNames(
        of directory: URL, limit: Int
    ) -> (names: [String], truncated: Bool)? {
        guard let handle = opendir(directory.path) else { return nil }
        defer { closedir(handle) }
        var names: [String] = []
        var truncated = false
        while true {
            // `readdir` returns nil for BOTH end-of-stream and error; errno
            // is the only discriminator, so it is cleared before each call.
            errno = 0
            guard let entry = readdir(handle) else {
                if errno != 0 { truncated = true }
                break
            }
            let decoded = withUnsafeBytes(of: entry.pointee.d_name) {
                raw -> String? in
                guard let base = raw.bindMemory(to: CChar.self).baseAddress
                else { return nil }
                return decodedBasename(fromCString: base)
            }
            guard let name = decoded, !name.isEmpty else {
                truncated = true
                break
            }
            if name == "." || name == ".." { continue }
            guard names.count < limit else {
                truncated = true
                break
            }
            names.append(name)
        }
        return (names, truncated)
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
