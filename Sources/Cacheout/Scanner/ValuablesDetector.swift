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
/// `probe(at:provider:depthLimit:entryLimit:)` is the ONLY walk. The scan-time
/// face (`BuildArtifactsScanner`, injectable caps) and the delete-time face
/// (`BuildArtifactsScanner.preDeleteValuablesProbe`, PRODUCTION caps) both
/// route through it, exactly as `OrphanedCachesScanner`'s user-data probe does
/// (`OrphanedCachesScanner.swift:193,571`) — scan-time and delete-time bounds
/// CANNOT drift, because there is only one set of bounds.
///
/// ## Fail closed, always
/// A probe that could not finish (entry cap hit, depth boundary left
/// unexpanded, unreadable branch, unreadable metadata, a bundle whose bounded
/// subtree sizing truncated) is INCOMPLETE. An incomplete probe has the SAME
/// consequence as a hit: risk forced off safe, selection forced false,
/// "couldn't fully inspect" evidence — and, uniformly across every surface, NO
/// acknowledgement token exists. Absence of valuables is only meaningful when
/// the inspection actually finished.
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

    // MARK: Pinned caps (shared by scan time AND delete time)

    /// PRODUCTION probe caps — ONE definition, consumed by the scanner's init
    /// defaults AND by the delete-time entry point
    /// (`BuildArtifactsScanner.preDeleteValuablesProbe`), so the two
    /// inspections' bounds can never drift apart (the
    /// `OrphanedCachesScanner.swift:193` doctrine).
    ///
    /// Depth 8 clears the deep real layouts release artifacts actually live
    /// in (`target/release/bundle/dmg/…`, `build/Release-iphoneos/…`); the
    /// entry cap is the GLOBAL bound on the probe's total work — it is shared
    /// across the outer walk and every bundle's subtree sizing, so the whole
    /// probe visits at most this many directory entries no matter how the
    /// depth budget is spent.
    static let defaultProbeDepthLimit = 8
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
    /// Determinism: siblings are visited in byte-wise basename order — files
    /// as they come, directories descended in that same ascending order (the
    /// stack is loaded in reverse so `popLast` yields ascending) — and the
    /// result is sorted ONCE into the canonical order before returning.
    static func probe(
        at directory: URL,
        provider: FileSystemIdentityProvider,
        depthLimit: Int = defaultProbeDepthLimit,
        entryLimit: Int = defaultProbeEntryLimit
    ) -> ValuablesDisclosure {
        var found: [DetectedValuable] = []
        var complete = true
        // The GLOBAL entry budget, shared with every bundle subtree walk.
        var visited = 0
        var stack: [(url: URL, depth: Int)] = [(directory, 0)]

        walk: while let (dir, depth) = stack.popLast() {
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
            var pendingDirectories: [(url: URL, depth: Int)] = []

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
                    guard bundleExtensions.contains(ext) else {
                        let childDepth = depth + 1
                        if childDepth < depthLimit {
                            pendingDirectories.append((child, childDepth))
                        } else {
                            // A directory left unexpanded at the depth
                            // boundary: a valuable could hide just past it.
                            complete = false
                        }
                        break
                    }
                    // BUNDLE. Identity from the bundle ROOT's ONE lstat;
                    // size from the bounded subtree walk below. The outer
                    // walk deliberately does not descend it.
                    let sized = boundedSubtreeAllocation(
                        at: child, provider: provider,
                        depthLimit: depthLimit, entryLimit: entryLimit,
                        visited: &visited
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
    /// follows symlinks, and shares the caller's GLOBAL entry budget so the
    /// whole probe stays bounded. `complete == false` on an unreadable
    /// branch, an unexpanded depth boundary, unreadable file metadata, the
    /// entry cap, or an allocation sum that would overflow `Int64` — every
    /// one of which makes the returned figure a FLOOR, never a truth, so no
    /// token may derive from it.
    private static func boundedSubtreeAllocation(
        at bundleRoot: URL,
        provider: FileSystemIdentityProvider,
        depthLimit: Int,
        entryLimit: Int,
        visited: inout Int
    ) -> (allocatedBytes: Int64, complete: Bool) {
        var total: Int64 = 0
        var complete = true
        var stack: [(url: URL, depth: Int)] = [(bundleRoot, 0)]

        walk: while let (dir, depth) = stack.popLast() {
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
            var pendingDirectories: [(url: URL, depth: Int)] = []

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
                    let childDepth = depth + 1
                    if childDepth < depthLimit {
                        pendingDirectories.append((child, childDepth))
                    } else {
                        complete = false
                    }
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
    /// A mid-read `readdir` FAILURE reports `truncated` — the enumeration is
    /// unproven, which is exactly the incomplete-probe consequence.
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
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw -> String in
                guard let base = raw.bindMemory(to: CChar.self).baseAddress
                else { return "" }
                return String(cString: base)
            }
            if name.isEmpty || name == "." || name == ".." { continue }
            guard names.count < limit else {
                truncated = true
                break
            }
            names.append(name)
        }
        return (names, truncated)
    }
}
