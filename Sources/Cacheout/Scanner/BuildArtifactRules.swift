/// # BuildArtifactRules — Rule Table + Pure Matcher (fn-4.1, R1/R15)
///
/// The v1 build-artifact rule table and the pure matcher over
/// `ProjectTreeEvent`s. Data, not conditionals: every row carries its full
/// selection TRIPLE `(risk, defaultSelected, automaticCleanEligible)` so the
/// emission task (fn-4.3) and the R15 tests read policy OFF THE ROW, never
/// out of code.
///
/// Two rule SHAPES exist (epic Architecture; PEP 405 forces the second):
///
/// 1. **Marker-sibling** — artifact dir name + required sibling marker(s).
///    The sibling IS the safety property (D6): a dir named `target/` without
///    a `Cargo.toml` beside it could be anything.
/// 2. **Marker-inside** — a directory of ANY name containing a definitive
///    interior marker. v1 has exactly one row: venv via interior
///    `pyvenv.cfg` (PEP 405, D5).
///
/// DROPPED from v1 (asserted absent by the table-shape test): `__pycache__`
/// (PEP 3147 self-marking at every package level — the per-project roll-up
/// the one-item-per-dir model cannot express is logged future work) and
/// `.venv`-by-name (superseded by the marker-inside rule).
///
/// No Quick Clean enrollment in v1 (D3/R15): ALL rows ship
/// `defaultSelected: false` and `automaticCleanEligible: false`. `safe` RISK
/// still communicates evidence confidence; eligibility is a separate,
/// deliberate future decision. `node_modules/` stays at `.review` — the
/// doctrine inherited verbatim from the retired node_modules scanner —
/// because flipping it to safe would be a product change smuggled into a
/// refactor.

import Foundation

// MARK: - Rule

/// One row of the build-artifact table. Name comparison is exact byte-wise
/// (APFS case-insensitivity is a non-goal, epic contract).
struct BuildArtifactRule: Equatable, Sendable {

    /// The two rule shapes — they bind to DIFFERENT subjects of the same
    /// walker event (see `BuildArtifactMatch.Target`).
    enum Shape: Equatable, Sendable {
        /// A CHILD of the event's directory matches iff its name equals
        /// `artifactDirName`, the child is a real DIRECTORY (a FILE named
        /// `build` never matches; a symlink never matches), and at least
        /// one of `markers` exists among its SIBLINGS (the event's other
        /// entries) as a regular file — never a descendant, never an
        /// ancestor.
        case markerSibling(artifactDirName: String, markers: [String])
        /// The event's CURRENT directory itself matches iff its OWN entries
        /// contain `marker` as a regular file — any directory name. Gated
        /// structurally on `depth > 0`: a dev root is NEVER eligible to
        /// match (D6 — a stray marker must not convert a broad root into an
        /// artifact).
        case markerInside(marker: String)
    }

    let shape: Shape
    /// The selection TRIPLE — data on the row, read verbatim by emission
    /// (fn-4.3) and frozen by the R15 tests.
    let risk: RiskLevel
    let defaultSelected: Bool
    let automaticCleanEligible: Bool
}

// MARK: - Match

/// One rule match produced from one walker event. The two shapes bind to
/// DISTINCT MATCH TARGETS — different subjects of the same event.
struct BuildArtifactMatch: Equatable, Sendable {

    enum Target: Equatable, Sendable {
        /// Sibling shape: the matched CHILD of the event's directory —
        /// what fn-4.3 records and prunes.
        case child(name: String)
        /// Inside shape: the event's current directory itself — what
        /// fn-4.3 records; its descent is pruned via consumer verdicts for
        /// ALL its children.
        case currentDirectory
    }

    let rule: BuildArtifactRule
    let target: Target
}

// MARK: - Structural proof (PR #457 review r3, thread A)

/// The STRUCTURAL SAFETY PROPERTY one matched artifact directory rests on,
/// preserved VERBATIM on the emitted item so the delete-time revalidator can
/// RE-PROVE it instead of trusting the scan.
///
/// This exists because the artifact-dir NAMES are ambiguous by themselves —
/// `target/`, `build/`, `dist/` are whatever their owner put there — and the
/// sibling/interior MARKER is the only thing that distinguishes build output
/// from someone's data (D6). Scan-time inspection alone cannot carry that: a
/// `Cargo.toml` deleted (or a whole project repurposed) between the scan and
/// the clean voids the proof, and the valuables probe cannot see it happen —
/// ordinary files carry no flagged extension, so a repurposed `target/` full
/// of documents probes CLEAN and COMPLETE.
///
/// Carried STRUCTURALLY (never re-derived from the evidence prose, never
/// guessed from the directory name at delete time): the shape that claimed
/// this directory is the shape that must claim it again.
struct BuildArtifactProof: Equatable, Sendable {
    /// The rule SHAPE that claimed the directory. The re-proof runs THIS
    /// shape's own predicate — the same one the scan applied — so scan time
    /// and delete time agree by construction: a Gradle project that swapped
    /// `build.gradle` for `build.gradle.kts` between the two still matches,
    /// exactly as a re-scan would match it.
    let shape: BuildArtifactRule.Shape
    /// The marker the SCAN named in its evidence ("target/ beside
    /// Cargo.toml"). Names the loss in a refusal so the message matches what
    /// the user was shown; the PREDICATE is the shape's whole marker set,
    /// never this one name.
    let marker: String

    /// RE-PROOF at delete time. `nil` when the property still holds;
    /// otherwise the fail-closed detail naming what can no longer be proven.
    ///
    /// BOUNDED BY CONSTRUCTION: at most one `lstat` per declared marker name
    /// (four, for the Gradle rows) plus one for the target itself. Nothing is
    /// enumerated, so no budget, no depth, and no truncation verdict exists
    /// here — unlike the valuables probe, this predicate reads only names it
    /// already knows.
    ///
    /// Every arm mirrors the scan-time matcher (`BuildArtifactRules.matches`)
    /// exactly:
    /// - the subject must still be a real DIRECTORY (the matcher's
    ///   `entry.kind == .directory` gate — a symlink never matched, and a
    ///   symlink must never be deleted as though it were the tree it names);
    /// - sibling shape: the leaf name must still equal the rule's artifact
    ///   dir name, and at least one declared marker must sit BESIDE it as a
    ///   regular file (never itself the artifact dir name);
    /// - inside shape: the declared marker must still be a regular file
    ///   INSIDE it.
    ///
    /// ABSENT is deliberately NOT a failure: a target that vanished between
    /// scan and clean has nothing left to prove, and the deletion path owns
    /// that ENOENT (the `preDeleteValuablesProbe` precedent — the re-proof
    /// must not preempt it).
    ///
    /// CLEARABLE, never a permanent strand: restore the marker and the proof
    /// holds again; or re-scan, in which case the item is simply not produced
    /// (the walker's matcher rejects the same subject for the same reason).
    /// Nothing here is deterministic-and-forever.
    func failureDetail(
        target: URL, provider: FileSystemIdentityProvider
    ) -> String? {
        switch provider.probeKind(of: target) {
        case .kind(.directory):
            break
        case .absent:
            // Nothing to prove; the deletion path surfaces its own ENOENT.
            return nil
        case .kind(let kind):
            return "it is \(Self.phrase(for: kind)) now, not the directory "
                + "the scan matched"
        case .failed(let code):
            return "couldn't re-read it (\(String(cString: strerror(code))))"
        }

        switch shape {
        case .markerSibling(let artifactDirName, let markers):
            guard target.lastPathComponent == artifactDirName else {
                return "it is named '\(target.lastPathComponent)' now, not "
                    + "'\(artifactDirName)'"
            }
            let parent = target.deletingLastPathComponent()
            var unreadable: String?
            for name in markers where name != artifactDirName {
                switch provider.probeKind(of: parent.appendingPathComponent(name)) {
                case .kind(.regularFile):
                    return nil
                case .kind, .absent:
                    continue
                case .failed(let code):
                    // Record and keep looking: another declared marker may
                    // still be readable and prove the rule outright.
                    unreadable = unreadable ?? "couldn't re-read '\(name)' "
                        + "beside it (\(String(cString: strerror(code))))"
                }
            }
            if let unreadable { return unreadable }
            return "the \(marker) that proved it is build output is no "
                + "longer beside it"

        case .markerInside(let interior):
            let markerURL = target.appendingPathComponent(interior)
            switch provider.probeKind(of: markerURL) {
            case .kind(.regularFile):
                return nil
            case .kind, .absent:
                return "the \(interior) that proved it is build output is no "
                    + "longer inside it"
            case .failed(let code):
                return "couldn't re-read '\(interior)' inside it "
                    + "(\(String(cString: strerror(code))))"
            }
        }
    }

    private static func phrase(
        for kind: FileSystemIdentityProvider.FileKind
    ) -> String {
        switch kind {
        case .directory: return "a directory"
        case .regularFile: return "a regular file"
        case .symlink: return "a symlink"
        case .other: return "a special file"
        }
    }
}

// MARK: - Table + matcher

enum BuildArtifactRules {

    /// The v1 table, VERBATIM from the epic spec (order significant —
    /// first-rule-wins). Every row: `defaultSelected: false`,
    /// `automaticCleanEligible: false` (D3).
    static let v1: [BuildArtifactRule] = [
        // target/ beside Cargo.toml — the Rust case the epic exists for.
        BuildArtifactRule(
            shape: .markerSibling(artifactDirName: "target",
                                  markers: ["Cargo.toml"]),
            risk: .safe, defaultSelected: false, automaticCleanEligible: false
        ),
        // node_modules/ — preserves the retired node_modules scanner's
        // doctrine (.review, never auto-eligible).
        BuildArtifactRule(
            shape: .markerSibling(artifactDirName: "node_modules",
                                  markers: ["package.json"]),
            risk: .review, defaultSelected: false, automaticCleanEligible: false
        ),
        // SwiftPM .build/ beside Package.swift.
        BuildArtifactRule(
            shape: .markerSibling(artifactDirName: ".build",
                                  markers: ["Package.swift"]),
            risk: .safe, defaultSelected: false, automaticCleanEligible: false
        ),
        // Gradle build/ — full marker set including BOTH settings variants.
        BuildArtifactRule(
            shape: .markerSibling(artifactDirName: "build",
                                  markers: Self.gradleMarkers),
            risk: .review, defaultSelected: false, automaticCleanEligible: false
        ),
        // Gradle .gradle/ — same marker set.
        BuildArtifactRule(
            shape: .markerSibling(artifactDirName: ".gradle",
                                  markers: Self.gradleMarkers),
            risk: .review, defaultSelected: false, automaticCleanEligible: false
        ),
        // Python venv — ANY directory name with interior pyvenv.cfg
        // (PEP 405, D5). The one marker-inside row of v1.
        BuildArtifactRule(
            shape: .markerInside(marker: "pyvenv.cfg"),
            risk: .review, defaultSelected: false, automaticCleanEligible: false
        ),
        // CocoaPods Pods/ (CocoaPods recommends committing Pods → review).
        BuildArtifactRule(
            shape: .markerSibling(artifactDirName: "Pods",
                                  markers: ["Podfile"]),
            risk: .review, defaultSelected: false, automaticCleanEligible: false
        ),
        // dist/ and .next/ beside package.json — the weakest rows.
        BuildArtifactRule(
            shape: .markerSibling(artifactDirName: "dist",
                                  markers: ["package.json"]),
            risk: .review, defaultSelected: false, automaticCleanEligible: false
        ),
        BuildArtifactRule(
            shape: .markerSibling(artifactDirName: ".next",
                                  markers: ["package.json"]),
            risk: .review, defaultSelected: false, automaticCleanEligible: false
        ),
        // Turborepo .turbo/ beside turbo.json.
        BuildArtifactRule(
            shape: .markerSibling(artifactDirName: ".turbo",
                                  markers: ["turbo.json"]),
            risk: .review, defaultSelected: false, automaticCleanEligible: false
        ),
    ]

    /// The Gradle marker set, shared by the `build/` and `.gradle/` rows —
    /// both `settings.gradle` AND `settings.gradle.kts` included (epic
    /// contract).
    static let gradleMarkers: [String] = [
        "build.gradle", "build.gradle.kts",
        "settings.gradle", "settings.gradle.kts",
    ]

    /// The pure matcher: all rule matches produced by ONE walker event.
    ///
    /// Semantics (epic contract):
    /// - **Subjects.** Each entry of the event is a candidate for the
    ///   sibling shape; the event's current directory is the candidate for
    ///   the inside shape. A child's own interior is a SEPARATE event (the
    ///   walker's descent), never inspected here.
    /// - **First-rule-wins.** Per subject, the first FULLY matching row in
    ///   table order claims it; later rows are not consulted.
    /// - **Root never eligible — structural.** The inside-shape branch
    ///   requires `event.depth > 0` (equivalently `directory != originRoot`)
    ///   before it can produce a `currentDirectory` target: a dev root
    ///   containing `pyvenv.cfg` is not recorded, and sibling-shape
    ///   `child(name:)` targets are subdirectories of the root by
    ///   construction.
    /// - **Order.** Child matches in entry order, then the
    ///   current-directory match (if any) — deterministic given the event.
    static func matches(
        in event: ProjectTreeEvent,
        rules: [BuildArtifactRule] = v1
    ) -> [BuildArtifactMatch] {
        var found: [BuildArtifactMatch] = []

        // Sibling shape: each entry is a candidate child.
        for entry in event.entries {
            guard entry.kind == .directory else { continue }
            for rule in rules {
                guard case .markerSibling(let name, let markers) = rule.shape,
                      entry.name == name
                else { continue }
                let markerPresent = event.entries.contains { sibling in
                    sibling.name != entry.name
                        && sibling.kind == .regularFile
                        && markers.contains(sibling.name)
                }
                if markerPresent {
                    // First-rule-wins: the first FULLY matching row takes
                    // the subject. A name-only hit without its marker is
                    // NOT a match and falls through to later rows.
                    found.append(BuildArtifactMatch(
                        rule: rule, target: .child(name: entry.name)
                    ))
                    break
                }
            }
        }

        // Inside shape: the current directory is the candidate — but NEVER
        // the dev root itself (structural depth gate, D6).
        if event.depth > 0 {
            for rule in rules {
                guard case .markerInside(let marker) = rule.shape else {
                    continue
                }
                let markerPresent = event.entries.contains {
                    $0.name == marker && $0.kind == .regularFile
                }
                if markerPresent {
                    found.append(BuildArtifactMatch(
                        rule: rule, target: .currentDirectory
                    ))
                    break
                }
            }
        }

        return found
    }
}
