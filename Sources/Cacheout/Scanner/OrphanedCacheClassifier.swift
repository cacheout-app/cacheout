/// # OrphanedCacheClassifier — Sweep Classification Engine (fn-3.2)
///
/// Pure, filesystem-free classification of fn-3.1's `SweptCacheEntry` facts:
/// tier, risk, user-facing evidence strings, selection policy, and the
/// output-set selection. Every rule in the epic's Edge Cases section lives
/// here as a testable function — no filesystem access, no fixtures, no
/// async, no ambient clock construction (`now` is injected).
///
/// ## Tier precedence (category-excluded entries never reach this — fn-3.1
/// filters them out before the facts list is returned)
///
/// 1. **Leak glob** → `knownLeak`, safe. The table is DATA, matched with
///    `fnmatch(3)` against the entry NAME — it is a name glob, not a path
///    (the field machine had TWO distinct `com.apple.SwiftUI.Drag-<UUID>`
///    dirs; FIELD-EVIDENCE-2026-08-06 scenario 4).
/// 2. **Orphan** → review. ONLY for bundle-id-shaped names (≥3 dot-separated
///    non-empty components), ONLY on a POSITIVE `.notInstalled` from the
///    injected resolver predicate. `.unknown` NEVER classifies as orphan —
///    orphan evidence asserts a negative ("no installed app") the census
///    could not establish; the entry falls through with incomplete-resolution
///    evidence instead. Bare names (`pnpm`, `Homebrew`, `go-build`) are tool
///    caches, never orphan — the predicate is not even consulted. Same for
///    `com.apple.*` non-leak entries: system components are not apps, a
///    missing-app match is meaningless — never orphan, never safe (they cap
///    at review by construction: every non-leak tier's base risk is review).
/// 3. **Stale-large** → review: allocated bytes at-or-above the size floor
///    AND newest content STRICTLY older than the stale age against the
///    injected clock. A nil `newestContentDate` (empty or fully denied
///    entry) is never stale-large — staleness cannot be asserted about
///    content that was never dated.
/// 4. **Unclassified** → informational: risk review (keeps it out of any
///    safe-only bulk selection by construction), never selected, evidence
///    notes it is listed for visibility because of its size.
///
/// `SweepTier` stays INTERNAL to the classification layer: fn-2's as-built
/// `ReclaimableItem` has no tier field — "informational" is represented
/// downstream ONLY through risk `.review` + `defaultSelected false` +
/// `automaticCleanEligible false` + the visibility evidence string (fn-3.4
/// maps it; no parallel public tier surface).
///
/// ## Cross-cutting overrides (applied after the tier, in a fixed order)
///
/// - **User-data shapes (R4)**: any `userDataShapeMatches` forces risk to at
///   least review — even on a knownLeak — and appends the verify-the-original
///   caution. Field precedent: the 31G leak WAS a stale Photos-library copy;
///   deletion was approved only after the real library's DB mtime was
///   verified current.
/// - **Incomplete probe (R4, fail-closed)**: `userDataProbeComplete == false`
///   is treated like a caution even with zero matches — absence of matches
///   from a truncated inspection proves nothing.
/// - **Denials (R7)**: never auto-safe; evidence distinguishes TCC from
///   plain permission (the two read very differently to a user fixing them).
/// - **Mount boundaries (R7)**: risk off safe, selection off, and evidence
///   says deletion would be refused — the fn-1 cleaner refuses
///   boundary-bearing targets entirely; the classifier must not promise
///   what delete will refuse.
///
/// ## Output set (R5 + R7, epic rule)
///
/// `output = all classified entries (knownLeak ∪ orphan ∪ staleLarge)
///         ∪ ALL entries with denials or mount boundaries (R7 visibility is
///           UNCONDITIONAL — a zero-byte denied or mount-point entry must
///           never be dropped by the size cut)
///         ∪ top-N of the REMAINING unclassified by allocated bytes`
/// (N = 10, internal constant — deliberately NOT config; the epic's config
/// surface is floor + age only). The ENTIRE returned list has one frozen
/// deterministic order — allocated bytes descending, ties broken by entry
/// name ascending byte-wise — and the SAME comparator drives the top-N cut,
/// so arbitrarily-ordered equivalent inputs produce identical output sets
/// AND order (selection reconciliation keys on stable ids; a flapping
/// output would churn it).

import Foundation
import Darwin

// MARK: - Installed-app resolution contract (tri-state, epic API contract)

/// Whether an app matching a bundle id is installed. TRI-STATE because
/// orphan classification asserts a NEGATIVE: `.notInstalled` must mean the
/// census was complete enough to establish absence; `.unknown` (census
/// incomplete while LaunchServices also had no match) never does.
///
/// Defined here so the classifier and its tests need nothing from fn-3.3's
/// `InstalledAppResolver` implementation — fn-3.4 wires the production
/// resolver's `status(ofBundleID:)` in as this classifier's predicate.
enum InstalledAppStatus: Equatable {
    case installed
    case notInstalled
    case unknown
}

// MARK: - Classification output model

/// Classification tier. INTERNAL to the classification layer — see the
/// file header; downstream mapping never carries it.
enum SweepTier: Equatable {
    /// Matches an entry in the known-leak glob table. The only tier that
    /// can be safe/bulk-eligible, and only when its facts are clean.
    case knownLeak
    /// Bundle-id-shaped name with a POSITIVE not-installed resolution.
    case orphan
    /// At-or-above the size floor and strictly older than the stale age.
    case staleLarge
    /// Listed (if at all) for visibility only.
    case unclassified
}

/// One entry's classification: the judgments fn-3.4 maps onto
/// `ReclaimableItem` (evidence lines joined there — the item model carries
/// a single string).
struct SweepClassification: Equatable {
    let entry: SweptCacheEntry
    let tier: SweepTier
    let risk: RiskLevel
    /// User-facing evidence lines (fn-2 renders them in the confirmation
    /// sheet). Frozen shapes per the epic's examples (the orphan line
    /// additionally appends its basis parenthetical — PR #456 review P2 —
    /// keeping the epic's prefix intact as a substring); deterministic
    /// order: tier line, incomplete-resolution note, user-data caution,
    /// incomplete-probe caution, denial lines, boundary line.
    let evidence: [String]
    /// Selection policy (epic mapping): BOTH flags are true exactly for a
    /// knownLeak with no user-data match, no denials, no mount boundaries,
    /// and a COMPLETE user-data probe; both false for everything else.
    /// The GUI's Quick Clean/select-all-safe reads
    /// `automaticCleanEligible && risk == .safe`, so only clean, fully
    /// inspected known leaks are ever bulk-selected. CLI smart-clean never
    /// runs this scanner (fn-2 freezes `handleSmartClean` to the
    /// `categories` scanner) — the false values on non-leak tiers are
    /// defense-in-depth.
    let defaultSelected: Bool
    let automaticCleanEligible: Bool
}

// MARK: - Leak-pattern table

/// One known-leak glob (R1). The table is extensible DATA, not
/// conditionals: `pattern` is an `fnmatch(3)` glob applied to the entry
/// NAME; `note` is the human explanation rendered in the evidence line.
struct LeakPattern: Equatable {
    let pattern: String
    let note: String
}

// MARK: - OrphanedCacheClassifier

struct OrphanedCacheClassifier {

    /// Classification thresholds. Values are scanner-construction state —
    /// fn-3.4 layers defaults → UserDefaults → CLI flag at the composition
    /// site (they deliberately do not ride `ScanContext`).
    struct Thresholds: Equatable {
        /// Stale-large size floor: allocated bytes AT-OR-ABOVE this qualify.
        let sizeFloorBytes: Int64
        /// Stale-large age: newest content STRICTLY older than this
        /// (against the injected clock) qualifies.
        let staleAge: TimeInterval
    }

    /// Seeded per the epic spec (field case: two distinct Drag-UUID dirs,
    /// one holding a 31G flatten-copied Photos library).
    static let leakPatterns: [LeakPattern] = [
        LeakPattern(pattern: "com.apple.SwiftUI.Drag-*", note: "drag payload cache")
    ]

    /// Top-N cut for CLEAN unclassified entries (see the file header).
    /// Internal constant, deliberately NOT config.
    static let unclassifiedTopN = 10

    let thresholds: Thresholds
    /// Injected tri-state resolver predicate — a plain function value, so
    /// this layer needs nothing from fn-3.3's implementation. Consulted
    /// ONLY for orphan-eligible names (bundle-id-shaped, non-`com.apple.*`,
    /// non-leak).
    let installedAppStatus: (String) -> InstalledAppStatus
    /// The injected clock every age computation uses — the classifier never
    /// reads the ambient current date.
    let now: Date

    init(
        thresholds: Thresholds,
        installedAppStatus: @escaping (String) -> InstalledAppStatus,
        now: Date
    ) {
        self.thresholds = thresholds
        self.installedAppStatus = installedAppStatus
        self.now = now
    }

    // MARK: - Per-entry classification

    /// Classify one entry's facts. Pure: same inputs, same output.
    func classify(_ entry: SweptCacheEntry) -> SweepClassification {
        var tier: SweepTier
        var evidence: [String] = []

        // Stage 1 — tier, by frozen precedence.
        if let leak = Self.leakPatterns.first(where: {
            fnmatch($0.pattern, entry.name, 0) == 0
        }) {
            tier = .knownLeak
            evidence.append("matches leak pattern \(leak.pattern) (\(leak.note))")
        } else {
            var resolutionNote: String?
            var isOrphan = false
            if Self.isOrphanEligibleName(entry.name) {
                switch installedAppStatus(entry.name) {
                case .installed:
                    break // Positively present — falls through below.
                case .notInstalled:
                    isOrphan = true
                case .unknown:
                    // NEVER orphan: the evidence would assert a negative
                    // the census could not establish. Falls through, with
                    // the incomplete-resolution note.
                    resolutionNote = "couldn't determine whether an app is installed"
                }
            }
            if isOrphan {
                tier = .orphan
                // The frozen epic prefix ("no installed app for bundle id
                // X" — e2e asserts it as a substring) plus the BASIS of
                // the claim (PR #456 review P2): the production resolver
                // (fn-3.3, wired by fn-3.4) establishes absence from
                // LaunchServices + the app-folder census + a
                // canary-verified Spotlight miss, so the evidence names
                // that search instead of overclaiming bare global absence
                // (an app on a Spotlight-excluded volume, never
                // LS-registered, remains invisible to all three signals).
                evidence.append(
                    "no installed app for bundle id \(entry.name)"
                        + " (checked LaunchServices, Spotlight, and standard app folders)"
                )
            } else if let untouchedDays = staleLargeUntouchedDays(entry) {
                tier = .staleLarge
                evidence.append(
                    "\(Self.formattedSize(entry.allocatedBytes)), untouched \(untouchedDays) days"
                )
            } else {
                tier = .unclassified
                evidence.append(
                    "listed for visibility because of its size (\(Self.formattedSize(entry.allocatedBytes)))"
                )
            }
            if let resolutionNote {
                evidence.append(resolutionNote)
            }
        }

        // Base risk: only a known leak starts safe. Every other tier starts
        // at review — which is also what keeps com.apple.* non-leak entries
        // capped off safe by construction.
        var risk: RiskLevel = (tier == .knownLeak) ? .safe : .review

        // Stage 2 — cross-cutting overrides, fixed order (see file header).
        if !entry.userDataShapeMatches.isEmpty {
            risk = Self.forcedOffSafe(risk)
            let names = entry.userDataShapeMatches.joined(separator: ", ")
            evidence.append(
                "contains user-data-shaped content (\(names)) — verify the original still exists before deleting"
            )
        }
        if !entry.userDataProbeComplete {
            // Fail-closed (epic rule): a truncated inspection proves
            // nothing — treated like a caution even with zero matches.
            risk = Self.forcedOffSafe(risk)
            evidence.append("couldn't fully inspect for user-data content")
        }
        if !entry.denials.isEmpty {
            // A partially-scanned entry is never auto-safe.
            risk = Self.forcedOffSafe(risk)
            evidence.append(contentsOf: Self.denialEvidence(entry.denials))
        }
        let hasMountBoundary = entry.rootMountBoundary || !entry.mountBoundaries.isEmpty
        if hasMountBoundary {
            // The fn-1 cleaner refuses boundary deletions — never promise
            // what delete will refuse.
            risk = Self.forcedOffSafe(risk)
            evidence.append("contains a mount boundary — size incomplete; deletion would be refused")
        }

        // Selection policy (epic mapping): both flags true EXACTLY for a
        // clean known leak. Computed from the facts (not from final risk)
        // so the intent is explicit; the two coincide — every condition
        // below also forces risk off safe.
        let cleanKnownLeak = tier == .knownLeak
            && entry.userDataShapeMatches.isEmpty
            && entry.userDataProbeComplete
            && entry.denials.isEmpty
            && !hasMountBoundary

        return SweepClassification(
            entry: entry,
            tier: tier,
            risk: risk,
            evidence: evidence,
            defaultSelected: cleanKnownLeak,
            automaticCleanEligible: cleanKnownLeak
        )
    }

    // MARK: - Output-set selection (R5 + R7)

    /// Classify all entries and select the output set (see the file
    /// header's frozen rule), returning it in the frozen deterministic
    /// order. Input order never matters.
    func classifyForOutput(_ entries: [SweptCacheEntry]) -> [SweepClassification] {
        var included: [SweepClassification] = []
        var cleanUnclassified: [SweepClassification] = []

        for classification in entries.map(classify) {
            if classification.tier != .unclassified
                || Self.hasVisibilityImpediment(classification.entry) {
                // All classified entries, plus ALL denied/boundary entries
                // regardless of tier or size — R7 visibility is
                // unconditional; the size cut below never applies to them.
                included.append(classification)
            } else {
                cleanUnclassified.append(classification)
            }
        }

        // Top-N cut over the REMAINING (clean) unclassified entries, driven
        // by the SAME comparator as the final ordering. The largest
        // unclassified entry is always present; clean unclassified entries
        // beyond the top N are omitted.
        included.append(contentsOf: cleanUnclassified
            .sorted(by: Self.orderedBefore)
            .prefix(Self.unclassifiedTopN))

        // One frozen order over the ENTIRE list (classified,
        // denied/boundary, and selected unclassified rows alike).
        return included.sorted(by: Self.orderedBefore)
    }

    /// R7: denials and mount boundaries make an entry unconditionally
    /// visible — a zero-byte denied entry is NOT a genuinely-empty entry.
    static func hasVisibilityImpediment(_ entry: SweptCacheEntry) -> Bool {
        !entry.denials.isEmpty || entry.rootMountBoundary || !entry.mountBoundaries.isEmpty
    }

    /// The frozen output comparator: allocated bytes DESCENDING, ties
    /// broken by entry name ASCENDING byte-wise (UTF-8 lexicographic —
    /// locale/Unicode-normalization-independent, so equivalent input sets
    /// can never flap across rescans).
    static func orderedBefore(_ a: SweepClassification, _ b: SweepClassification) -> Bool {
        if a.entry.allocatedBytes != b.entry.allocatedBytes {
            return a.entry.allocatedBytes > b.entry.allocatedBytes
        }
        return a.entry.name.utf8.lexicographicallyPrecedes(b.entry.name.utf8)
    }

    // MARK: - Tier rules

    /// Orphan tier applies ONLY to bundle-id-shaped names that are not
    /// Apple system components. For every other name the resolver predicate
    /// is not even consulted — a "no installed app" answer about `pnpm` or
    /// `com.apple.CoreSimulator` is meaningless.
    static func isOrphanEligibleName(_ name: String) -> Bool {
        isBundleIDShapedName(name) && !isAppleSystemName(name)
    }

    /// Heuristic per the task spec: ≥3 dot-separated NON-EMPTY components
    /// (`com.foo.bar` yes; `pnpm`, `go-build`, `com.foo`, `.hidden.thing`
    /// no).
    static func isBundleIDShapedName(_ name: String) -> Bool {
        let components = name.split(separator: ".", omittingEmptySubsequences: false)
        return components.count >= 3 && components.allSatisfy { !$0.isEmpty }
    }

    /// `com.apple.*` detection for the never-orphan/never-safe cap.
    /// Case-insensitive — bundle ids compare case-insensitively, and the
    /// cap only ever makes classification MORE conservative.
    static func isAppleSystemName(_ name: String) -> Bool {
        name.lowercased().hasPrefix("com.apple.")
    }

    /// Stale-large rule: allocated bytes AT-OR-ABOVE the floor AND newest
    /// content STRICTLY older than the stale age against the injected
    /// clock. Returns the whole-day untouched count for the evidence line,
    /// or nil when not stale-large. Entries with nil `newestContentDate`
    /// (empty, or fully denied) are never stale-large.
    private func staleLargeUntouchedDays(_ entry: SweptCacheEntry) -> Int? {
        guard entry.allocatedBytes >= thresholds.sizeFloorBytes,
              let newest = entry.newestContentDate
        else { return nil }
        let age = now.timeIntervalSince(newest)
        guard age > thresholds.staleAge else { return nil }
        return Int(age / 86_400)
    }

    // MARK: - Evidence helpers

    /// Risk floor for every cross-cutting override: at least review. The
    /// classifier never ASSIGNS caution itself, but an existing
    /// higher-than-review risk would pass through untouched.
    static func forcedOffSafe(_ risk: RiskLevel) -> RiskLevel {
        risk == .safe ? .review : risk
    }

    /// Denial evidence, one line per distinct failure class in a fixed
    /// order — TCC and plain permission read very differently to a user
    /// trying to fix them (R7).
    static func denialEvidence(_ denials: [SizeDenial]) -> [String] {
        let kinds = Set(denials.map(\.kind))
        var lines: [String] = []
        if kinds.contains(.tcc) {
            lines.append("couldn't fully scan: TCC denied")
        }
        if kinds.contains(.permission) {
            lines.append("couldn't fully scan: permission denied")
        }
        if kinds.contains(.unaddressablePath) {
            // NAMES THE REAL CAUSE (PR #458 review). "Some content was
            // unreadable" was false: every byte here is readable by anything
            // that walks with descriptors instead of paths — the probe does,
            // and so does the deletion now. What failed is the SIZING, and
            // only the sizing. Saying so is what stops a user hunting for a
            // permission that was never missing, or renaming a file whose
            // name was never the problem.
            lines.append(
                "couldn't measure its size: part of it sits deeper than an "
                    + "absolute path can address — deleting it still works"
            )
        }
        if kinds.contains(.metadata) || kinds.contains(.other) {
            lines.append("couldn't fully scan: some content was unreadable")
        }
        return lines
    }

    /// Evidence size formatting — the app-wide shared formatter (epic
    /// examples use its decimal `.file` style: "2.1 GB").
    static func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.sharedFile.string(fromByteCount: bytes)
    }
}
