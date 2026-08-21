/// # EphemeralTempRoots — Runtime Temp-Root Resolution & Sweep Config (fn-6.1, R2/R3/R7/R14)
///
/// The declaration and RUNTIME RESOLUTION of the three ephemeral temp roots
/// the `ephemeral_tmp` scanner works over, plus that scanner's two-knob
/// config surface. Pure declaration + resolution: no enumeration, no
/// staleness, no sizing, no deletion — fn-6.2 consumes the roots, fn-6.4
/// consumes the config for CLI overrides.
///
/// ## The three roots (exactly — the set is closed)
///
/// - `/private/tmp` — the shared, world-writable (sticky, 1777) temp dir.
/// - `confstr(_CS_DARWIN_USER_CACHE_DIR)` — the per-user `…/C` container.
/// - `confstr(_CS_DARWIN_USER_TEMP_DIR)` — the per-user `…/T` container.
///
/// `_CS_DARWIN_USER_DIR` (`…/0`) is deliberately NOT resolved and NOT in the
/// set (epic Boundaries; negative assertion in tests). Declaration order is
/// the epic's yield/risk priority (D7): durable payload (`/private/tmp`, `C`)
/// ahead of the OS-reaped, live-app-state container (`T`).
///
/// ## confstr(3), and why not a hardcoded `/var/folders/<bucket>`
///
/// The per-user bucket names are machine-specific, so they can only be
/// resolved at runtime. `confstrPath(_:)` uses the two-call sizing idiom
/// (authoritative Swift precedent: swift-nio `Sources/NIOFS/FileSystem.swift`
/// :708-723). Failure taxonomy, all treated identically: a return of 0 means
/// either a real error (`errno` `EIO` — dirhelper communication failure — or
/// `EINVAL` for a bad name) or "no defined value" (0 with `errno` untouched),
/// and a second-call return GREATER than the buffer means truncation. ANY of
/// these ⇒ that root is silently ABSENT from the resolved set. There is no
/// hardcoded substitute: a guessed `/var/folders/…` path would be a fiction.
///
/// SIDE EFFECT, documented: `confstr` on these names asks `dirhelper` for the
/// container and CREATES it when absent — so this app's own `T`/`C` always
/// exist right after resolution. The live output also carries a TRAILING
/// SLASH, normalized away here before any URL is built.
///
/// ## Canonical-spelling discipline (R3), and why the LEAF stays unresolved
///
/// Every root is resolved EXACTLY ONCE, here, via
/// `FileSystemIdentityProvider.resolveTargetKeepingLeaf(_:)`: the PARENT
/// CHAIN is canonicalized (`/var/folders/…` becomes `/private/var/folders/…`)
/// and the LEAF — the container's own name — is appended UNRESOLVED. That ONE
/// spelling is what fn-6.2 declares as `trustedContainerRoots`, stamps into
/// every item's `originContainer`, and uses as the canonical PARENT chain of
/// item identity. A second spelling anywhere downstream makes the outcome
/// validator-rejected or deletion structurally unreachable, because
/// `ContainerSnapshot.capture` keys by the DECLARED spelling
/// (`PathGuard.swift:124-155`).
///
/// The leaf is left unresolved because this URL becomes a TRUSTED CONTAINER
/// ROOT, not a comparison value. `realpath(3)` resolves the leaf too, so a
/// symlink standing where `C`/`T` should be would silently register its
/// DESTINATION as a temp root — and the container-root policy only refuses
/// `/`, volume roots and `$HOME` itself (`PathGuard.swift:344-355` says so in
/// as many words: "`~/Documents` can be a container while `admitDeletionRoot`
/// refuses it"), so an arbitrary directory would be admitted, walked, listed
/// as cache-container payload and deleted. Keeping the leaf means the
/// declared spelling IS the link, so fn-6.2's no-follow root gate (an `lstat`
/// `probeKind`) sees a symlink and refuses the root with a VISIBLE
/// `.symlinkRoot` issue, and `ContainerSnapshot.capture` binds the LINK's own
/// identity at delete time.
///
/// On stock macOS this is a NO-OP: the symlink on the way to these containers
/// is `/var` → `private/var`, an ANCESTOR, which the parent chain still
/// resolves; `/private/tmp` is declared canonically for the same reason. Both
/// live-Mac cells below assert the resulting spellings.
///
/// Roots are de-duped by INODE identity (`sameLocation`) of a fully canonical
/// comparison KEY — never string equality, and the key never reaches the kept
/// set (the `DevRootsStore.swift:315-324` pattern). `$TMPDIR`,
/// `NSTemporaryDirectory()` and confstr `T` are one directory under three
/// spellings; because `sameLocation` is `lstat`-based, an alias spelling only
/// collapses onto its target through the leaf-resolving key.
///
/// ## Resolution time vs SCAN time — two distinct layers, deliberately
///
/// This file is the RESOLUTION layer only: a root that cannot be resolved
/// (confstr failure, non-absolute or `/` output) never enters the set, and
/// nothing here probes existence, permissions or mode bits. What happens to a
/// resolved root that is MISSING or UNREADABLE when a scan actually runs is
/// fn-6.2's contract (epic R11): scan-time absence — including the
/// construction-to-scan disappearance race — is a SILENT skip, while a
/// present-but-denied root is a VISIBLE `ScanIssue`. Do not fold the two
/// layers together: a spurious issue for a root that legitimately vanished
/// trains users to ignore issues, and a silent zero for a denied root is the
/// fn-1 TCC-silent-zero defect class.
///
/// ## Declared writability class (R14, D12 — never probed)
///
/// Each root carries a STATIC, DECLARED writability class. It scopes exactly
/// one thing: fn-6.2's D12 ownership gate, which applies under the
/// world-writable root (sticky `/private/tmp`, where another user's entry is
/// undeletable) and is vacuous under the 0700 per-user containers. It does
/// NOT drive trigger behavior — since epic D11 (revised) the ENTIRE scanner
/// runs only on `.userInitiated` triggers. The class is a property of the
/// fixed 3-root definition, so probing mode bits would add failure modes for
/// zero information.
///
/// ## Evidence wording (D7 revised — non-contractual)
///
/// Per-root cleanup evidence is deliberately non-contractual about OS
/// behavior AND factually consistent with the engineering census: nothing
/// here promises what macOS will or will not delete. The observed reaping
/// mechanics of the per-user temp container (a shorter clock, aged by access
/// time) are ENGINEERING NOTES ONLY — Apple disclaims those values as
/// non-API, so a shipped string stating them as behavior becomes false the
/// release Apple changes them.
///
/// ## No own-process exclusion surface (D9)
///
/// There is deliberately NO own-temp identity/exclusion set here. This app is
/// not sandboxed, so `NSTemporaryDirectory()` IS the `T` root: a first-level
/// candidate can never share its parent container's inode, so such a set
/// could never fire — it would be false safety. The AGE gate (fn-6.2) is the
/// sole and sufficient own-process shield: anything this app or the current
/// session writes is fresh by construction.

import Foundation

// MARK: - Root model (R2/R3/R14)

/// One RESOLVED ephemeral temp root: the canonical URL plus the three
/// declared facts fn-6.2 needs — a human label, the truthful per-root
/// OS-cleanup evidence line, and the static writability class.
struct EphemeralTempRoot: Equatable, Sendable {

    /// The DECLARED write scope of a temp root — static, never probed
    /// (D12 scoping only; it does not drive triggers, D11 revised).
    enum Writability: Equatable, Sendable {
        /// Sticky, multi-writer (`/private/tmp`, mode 1777): another user's
        /// entry is readable but undeletable, so fn-6.2 applies the D12
        /// ownership gate here.
        case worldWritable
        /// Mode 0700, single-writer (`…/T`, `…/C`): every entry is the
        /// current user's by construction, so the ownership gate is vacuous.
        case perUser
    }

    /// The ONE canonical spelling (R3): `trustedContainerRoots`,
    /// `originContainer`, root records and item identity parent chains all
    /// derive from exactly this URL.
    let url: URL
    /// Short human label — disambiguates the two per-user containers in
    /// item evidence and root records.
    let label: String
    /// The per-root OS-cleanup evidence line (D7 revised, non-contractual).
    /// fn-6.2 appends the per-item age to this; it never mutates it.
    let cleanupEvidence: String
    /// Declared writability class (R14/D12).
    let writability: EphemeralTempRoot.Writability
}

// MARK: - Declaration + resolution (R2/R3)

/// The closed 3-root declaration and its runtime resolution.
enum EphemeralTempRoots {

    /// Injection seam for the confstr(3) lookup: a name → path resolver.
    /// Production is `confstrPath(_:)`; tests inject failures, alternative
    /// spellings and trailing slashes hermetically.
    typealias ConfstrResolver = (Int32) -> String?

    /// Where a declared root's raw path comes from.
    enum Source: Equatable, Sendable {
        /// A fixed absolute path (`/private/tmp`).
        case absolute(String)
        /// A `confstr(3)` name (`_CS_DARWIN_USER_TEMP_DIR` /
        /// `_CS_DARWIN_USER_CACHE_DIR`).
        case confstrName(Int32)
    }

    /// A root BEFORE resolution: its source plus the three declared facts
    /// that survive into `EphemeralTempRoot` verbatim.
    struct Definition: Equatable, Sendable {
        let source: Source
        let label: String
        let cleanupEvidence: String
        let writability: EphemeralTempRoot.Writability
    }

    // MARK: Evidence strings (D7 revised — shipped copy, asserted verbatim)

    /// The BSD `periodic`/`110.clean-tmps` reaper is gone from modern macOS
    /// (verified absent: `/etc/periodic/daily/`,
    /// `/etc/defaults/periodic.conf`, `com.apple.periodic-daily.plist`), and
    /// nothing replaced it for this location.
    static let sharedTempEvidence = "no periodic reaper on modern macOS"

    /// EXACT wording pinned by D7 (r3, F2): "does not routinely prune …
    /// during normal operation" — never a "never prunes" absolute, which
    /// would contradict the container's removal on safe boot (engineering
    /// context, not shipped copy).
    static let userCacheEvidence =
        "macOS does not routinely prune this location during normal operation"

    /// Non-contractual "may", and no behavioral mechanics: the OS's own
    /// reaper for this container ages by ACCESS time on a shorter clock, but
    /// that figure is observed and non-API, so it stays an engineering note
    /// and never appears in shipped copy. The comparison holds at the
    /// shipped 7-day default (fn-6.4's CLI override is invocation-scoped and
    /// the wording stays a "may", never a guarantee about either side).
    static let userTempEvidence =
        "macOS may reap older untouched files here; this age gate is more conservative"

    // MARK: Declarations

    /// `/private/tmp` — declared in its canonical spelling (`/tmp` is a
    /// symlink to `private/tmp`).
    static let sharedTemp = Definition(
        source: .absolute("/private/tmp"),
        label: "Shared temp",
        cleanupEvidence: sharedTempEvidence,
        writability: .worldWritable
    )

    /// The per-user `…/C` container.
    static let userCache = Definition(
        source: .confstrName(_CS_DARWIN_USER_CACHE_DIR),
        label: "Per-user cache container (C)",
        cleanupEvidence: userCacheEvidence,
        writability: .perUser
    )

    /// The per-user `…/T` container.
    static let userTemp = Definition(
        source: .confstrName(_CS_DARWIN_USER_TEMP_DIR),
        label: "Per-user temp container (T)",
        cleanupEvidence: userTempEvidence,
        writability: .perUser
    )

    /// The closed set, in D7 yield/risk priority order. `_CS_DARWIN_USER_DIR`
    /// (`…/0`) is absent ON PURPOSE and must never be added here.
    static let definitions: [Definition] = [sharedTemp, userCache, userTemp]

    // MARK: Resolution

    /// Resolve the declared roots to canonical URLs, in declaration order.
    ///
    /// Per definition: obtain the raw path (constant, or confstr) → drop it
    /// silently if the lookup failed or produced a non-absolute / bare-`/`
    /// value → normalize the trailing slash → resolve ONCE, parent chain only
    /// → drop it if it is the same filesystem object as an already-kept root
    /// (inode identity of a fully canonical comparison KEY, first declaration
    /// wins). Nothing probes existence or permissions: that is scan time, and
    /// fn-6.2's contract (R11).
    static func resolve(
        provider: FileSystemIdentityProvider = FileSystemIdentityProvider(),
        confstrPath: ConfstrResolver = EphemeralTempRoots.confstrPath(_:)
    ) -> [EphemeralTempRoot] {
        var kept: [EphemeralTempRoot] = []
        // Fully canonical (LEAF RESOLVED) de-dupe keys, parallel to `kept`.
        // Comparison values ONLY: a key never reaches the kept set, so the
        // leaf-preserving discipline above is untouched (this is verbatim the
        // `DevRootsStore.swift:315-324` pattern). The leaf MUST be resolved
        // here or an alias spelling stops collapsing onto its target —
        // `sameLocation` is `lstat`-based, so a symlink and its destination
        // are two different inodes.
        var keys: [URL] = []
        for definition in definitions {
            guard let raw = rawPath(for: definition.source, confstrPath: confstrPath),
                  let declared = canonicalRoot(fromRawPath: raw, provider: provider)
            else { continue }
            let key = provider.canonicalize(declared)
            // Inode-identity de-dupe: $TMPDIR / NSTemporaryDirectory() /
            // confstr T are one directory under several spellings, and a
            // string compare would keep both.
            guard !keys.contains(where: { provider.sameLocation($0, key) })
            else { continue }
            keys.append(key)
            kept.append(
                EphemeralTempRoot(
                    url: declared,
                    label: definition.label,
                    cleanupEvidence: definition.cleanupEvidence,
                    writability: definition.writability
                )
            )
        }
        return kept
    }

    /// The raw, un-normalized path for a source — `nil` when a confstr
    /// lookup failed (the root is then silently absent; never substituted).
    private static func rawPath(
        for source: Source, confstrPath: ConfstrResolver
    ) -> String? {
        switch source {
        case .absolute(let path): return path
        case .confstrName(let name): return confstrPath(name)
        }
    }

    /// Trailing-slash normalization + the ONE resolution (R3): canonical
    /// PARENT CHAIN, leaf appended UNRESOLVED. `nil` for anything that is not
    /// a usable root: an empty or relative path, or `/` itself — a filesystem
    /// root can never be a temp container, and registering it would hand the
    /// deletion layer the widest possible trusted root.
    ///
    /// The leaf is deliberately NOT followed. This URL becomes a trusted
    /// container root, so resolving a symlink leaf here would register the
    /// link's DESTINATION — an attacker-chosen or user-relocated directory —
    /// as a temp root, past every later gate (they all then inspect the real
    /// destination directory, which is genuine and stable). Preserved, the
    /// link is what fn-6.2's no-follow root gate sees, and it refuses it
    /// visibly. Probing nothing is still this layer's contract: this is a
    /// spelling transform, and whether the leaf IS a link is judged at scan
    /// time, where absence and denial are already told apart.
    static func canonicalRoot(
        fromRawPath raw: String,
        provider: FileSystemIdentityProvider = FileSystemIdentityProvider()
    ) -> URL? {
        var trimmed = raw
        // Live confstr output ends in "/" — strip every trailing slash, but
        // never past the leading one.
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard trimmed.hasPrefix("/"), trimmed != "/" else { return nil }
        return provider.resolveTargetKeepingLeaf(URL(fileURLWithPath: trimmed))
    }

    /// `confstr(3)` for a configuration name, two-call sizing idiom
    /// (swift-nio precedent). `nil` on EVERY failure shape — a 0 return
    /// (error `errno` EIO/EINVAL, or "no defined value" with `errno`
    /// untouched) and a truncating second call alike. Never traps, never
    /// guesses a path.
    static func confstrPath(_ name: Int32) -> String? {
        // Call 1: required buffer size, INCLUDING the NUL terminator.
        let sized = confstr(name, nil, 0)
        // A path can be at most PATH_MAX bytes with its terminator; anything
        // larger is not a path this process can use, and refusing to
        // allocate it keeps a syscall result from sizing our heap.
        guard sized > 0, sized <= Int(PATH_MAX) else { return nil }
        var buffer = [CChar](repeating: 0, count: sized)
        // Call 2: fill it. 0 ⇒ failure; > sized ⇒ the value was truncated.
        let written = confstr(name, &buffer, sized)
        guard written > 0, written <= sized else { return nil }
        return String(cString: buffer)
    }
}

// MARK: - Config surface (fn-6.1, R7)

/// The ephemeral-temp sweep's two knobs — minimum size (decimal MB) and age
/// (days) — layered defaults → UserDefaults → CLI override at the
/// COMPOSITION site (`SpaceScannerRuntime.production` / the CLI handlers),
/// exactly like `OrphanedCachesSweepConfig`. Fail-safe by contract:
/// conversions are overflow-checked and never trap; an invalid PERSISTED
/// value (≤ 0, non-numeric, non-integral, boolean, overflow) falls back to
/// the default for that scan and is NEVER rewritten — a value this build
/// cannot read may be meaningful to another build.
///
/// Deliberately a CLONE of the orphaned-caches template rather than a shared
/// generic: the two scanners' config surfaces version independently (their
/// keys, defaults and CLI flag families are separate user-visible contracts).
/// The clone is kept honest by a test that pins
/// `persistedPositiveInteger(_:)` to the template's verdicts input-by-input.
enum EphemeralTempSweepConfig {

    /// The resolved knobs handed to the scanner at construction (never
    /// context state — thresholds are construction state, `ScanContext`
    /// carries none).
    struct Thresholds: Equatable, Sendable {
        /// Candidate size floor: allocated bytes AT-OR-ABOVE this qualify.
        let sizeFloorBytes: Int64
        /// Staleness age: newest content STRICTLY older than this (against
        /// the scanner's injected clock) qualifies.
        let staleAge: TimeInterval
    }

    /// UserDefaults keys, per the `cacheout.<scanner>.<knob>` template.
    static let ageDaysKey = "cacheout.ephemeralTmp.ageDays"
    static let minSizeMBKey = "cacheout.ephemeralTmp.minSizeMB"

    /// 7 days: longer than any OS reaper's own clock for these locations,
    /// and long enough that a paused-but-live workspace stays untouched.
    static let defaultAgeDays: Int64 = 7
    /// 10 MB: small enough to surface real scratchpads, large enough that
    /// ordinary temp files never appear.
    static let defaultMinSizeMB: Int64 = 10

    /// 10 MB / 7 days, through the same checked conversions as every other
    /// value (the force-unwraps are compile-time constants proven finite).
    static let defaultThresholds = Thresholds(
        sizeFloorBytes: sizeFloorBytes(fromMB: defaultMinSizeMB)!,
        staleAge: staleAge(fromDays: defaultAgeDays)!
    )

    /// MB → bytes at ×1,000,000 — DECIMAL, matching the app's base-10
    /// `ByteCountFormatter` display convention. `nil` on non-positive or
    /// overflowing input (never traps).
    static func sizeFloorBytes(fromMB megabytes: Int64) -> Int64? {
        guard megabytes > 0 else { return nil }
        let (bytes, overflow) = megabytes
            .multipliedReportingOverflow(by: 1_000_000)
        return overflow ? nil : bytes
    }

    /// Days → seconds at ×86,400, overflow-checked in integer space before
    /// the `TimeInterval` conversion. `nil` on non-positive or overflowing
    /// input (never traps).
    static func staleAge(fromDays days: Int64) -> TimeInterval? {
        guard days > 0 else { return nil }
        let (seconds, overflow) = days.multipliedReportingOverflow(by: 86_400)
        return overflow ? nil : TimeInterval(seconds)
    }

    /// The layered resolution: an invocation-scoped OVERRIDE (CLI flag —
    /// already validated by the CLI's invalid-arguments gate) wins; else a
    /// VALID persisted value; else the default. Each half resolves
    /// independently, and nothing is ever written back to UserDefaults.
    static func resolvedThresholds(
        defaults: UserDefaults = .standard,
        minSizeMBOverride: Int64? = nil,
        ageDaysOverride: Int64? = nil
    ) -> Thresholds {
        let minSizeMB = minSizeMBOverride
            ?? persistedPositiveInteger(defaults.object(forKey: minSizeMBKey))
        let ageDays = ageDaysOverride
            ?? persistedPositiveInteger(defaults.object(forKey: ageDaysKey))
        // A value that parses but overflows its conversion is INVALID too —
        // same fallback, still no rewrite.
        return Thresholds(
            sizeFloorBytes: minSizeMB.flatMap(sizeFloorBytes(fromMB:))
                ?? defaultThresholds.sizeFloorBytes,
            staleAge: ageDays.flatMap(staleAge(fromDays:))
                ?? defaultThresholds.staleAge
        )
    }

    /// A persisted value read as a positive INTEGER, or nil when it is
    /// absent or invalid (non-numeric, non-integral, boolean, zero,
    /// negative, or past Int64). Both NSNumber (the normal
    /// `set(_:forKey:)` shapes) and numeric strings are accepted —
    /// nothing else.
    static func persistedPositiveInteger(_ stored: Any?) -> Int64? {
        if let number = stored as? NSNumber {
            // A persisted Bool bridges to NSNumber (`true` → 1) — a
            // boolean is not a positive-integer threshold, so it is
            // invalid like any other non-numeric value (falls back to the
            // default, never rewritten). CFBoolean is the toll-free type
            // a bridged Bool actually carries.
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else {
                return nil
            }
            let value = number.doubleValue
            guard value.isFinite, value > 0,
                  value == value.rounded(),
                  let integer = Int64(exactly: value.rounded())
            else { return nil }
            return integer
        }
        if let string = stored as? String {
            guard let integer = Int64(string), integer > 0 else { return nil }
            return integer
        }
        return nil
    }
}
