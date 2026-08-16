import XCTest
@testable import Cacheout

/// Hermetic tests for the v1 build-artifact rule table and the pure matcher
/// (fn-4.1, R1/R15). Pure value tests — the matcher consumes constructed
/// `ProjectTreeEvent`s, so no filesystem fixture exists here at all (the
/// real-walker cells are fn-4.3's ACs).
final class BuildArtifactRulesTests: XCTestCase {

    // MARK: - Helpers

    private func event(
        directory: String = "/fixture/devroot/project",
        depth: Int = 1,
        originRoot: String = "/fixture/devroot",
        entries: [(String, FileSystemIdentityProvider.FileKind)]
    ) -> ProjectTreeEvent {
        ProjectTreeEvent(
            directory: URL(fileURLWithPath: directory),
            depth: depth,
            originRoot: URL(fileURLWithPath: originRoot),
            entries: entries.map { .init(name: $0.0, kind: $0.1) }
        )
    }

    private func siblingRule(
        _ name: String, in rules: [BuildArtifactRule] = BuildArtifactRules.v1
    ) -> BuildArtifactRule? {
        rules.first {
            if case .markerSibling(let artifact, _) = $0.shape {
                return artifact == name
            }
            return false
        }
    }

    // MARK: - R1: table shape frozen

    /// The v1 table VERBATIM — order, shapes, markers, risks. Any drift in
    /// any row (or any smuggled new row) fails byte-for-byte here.
    func testTableShapeFrozenVerbatim() {
        let gradle = [
            "build.gradle", "build.gradle.kts",
            "settings.gradle", "settings.gradle.kts",
        ]
        let expected: [BuildArtifactRule] = [
            .init(shape: .markerSibling(artifactDirName: "target",
                                        markers: ["Cargo.toml"]),
                  risk: .safe, defaultSelected: false,
                  automaticCleanEligible: false),
            .init(shape: .markerSibling(artifactDirName: "node_modules",
                                        markers: ["package.json"]),
                  risk: .review, defaultSelected: false,
                  automaticCleanEligible: false),
            .init(shape: .markerSibling(artifactDirName: ".build",
                                        markers: ["Package.swift"]),
                  risk: .safe, defaultSelected: false,
                  automaticCleanEligible: false),
            .init(shape: .markerSibling(artifactDirName: "build",
                                        markers: gradle),
                  risk: .review, defaultSelected: false,
                  automaticCleanEligible: false),
            .init(shape: .markerSibling(artifactDirName: ".gradle",
                                        markers: gradle),
                  risk: .review, defaultSelected: false,
                  automaticCleanEligible: false),
            .init(shape: .markerInside(marker: "pyvenv.cfg"),
                  risk: .review, defaultSelected: false,
                  automaticCleanEligible: false),
            .init(shape: .markerSibling(artifactDirName: "Pods",
                                        markers: ["Podfile"]),
                  risk: .review, defaultSelected: false,
                  automaticCleanEligible: false),
            .init(shape: .markerSibling(artifactDirName: "dist",
                                        markers: ["package.json"]),
                  risk: .review, defaultSelected: false,
                  automaticCleanEligible: false),
            .init(shape: .markerSibling(artifactDirName: ".next",
                                        markers: ["package.json"]),
                  risk: .review, defaultSelected: false,
                  automaticCleanEligible: false),
            .init(shape: .markerSibling(artifactDirName: ".turbo",
                                        markers: ["turbo.json"]),
                  risk: .review, defaultSelected: false,
                  automaticCleanEligible: false),
        ]
        XCTAssertEqual(BuildArtifactRules.v1, expected,
                       "the v1 rule table is FROZEN — a changed row is a "
                       + "product decision, not a refactor")
    }

    /// The deliberately dropped rows stay dropped: no `__pycache__` rule in
    /// ANY shape, and no `.venv`-BY-NAME rule (venvs are matched by the
    /// marker-inside `pyvenv.cfg` row only — PEP 405 superseded the name).
    func testDroppedRowsAreAbsent() {
        for rule in BuildArtifactRules.v1 {
            switch rule.shape {
            case .markerSibling(let artifact, let markers):
                XCTAssertNotEqual(artifact, "__pycache__",
                                  "__pycache__ is dropped from v1 (PEP 3147)")
                XCTAssertNotEqual(artifact, ".venv",
                                  ".venv-by-name is superseded by marker-inside")
                XCTAssertFalse(markers.contains("__pycache__"))
            case .markerInside(let marker):
                XCTAssertEqual(marker, "pyvenv.cfg",
                               "the ONLY inside row of v1 is the PEP 405 venv")
            }
        }
    }

    // MARK: - R1 feeds R15: selection triple is data on every row

    func testEveryRowSelectionTripleIsNeverSelectedNeverEligible() {
        XCTAssertFalse(BuildArtifactRules.v1.isEmpty)
        for (index, rule) in BuildArtifactRules.v1.enumerated() {
            XCTAssertFalse(rule.defaultSelected,
                           "row \(index): defaultSelected must be false (D3)")
            XCTAssertFalse(rule.automaticCleanEligible,
                           "row \(index): automaticCleanEligible must be "
                           + "false (D3 — no Quick Clean enrollment in v1)")
        }
        // Risks per row: exactly target/ and .build/ are safe.
        let safeArtifacts = BuildArtifactRules.v1.compactMap {
            rule -> String? in
            guard rule.risk == .safe,
                  case .markerSibling(let name, _) = rule.shape
            else { return nil }
            return name
        }
        XCTAssertEqual(safeArtifacts, ["target", ".build"])
        XCTAssertFalse(BuildArtifactRules.v1.contains { $0.risk == .caution })
    }

    // MARK: - R1: sibling shape

    func testSiblingMarkerPresentMatchesChildTarget() throws {
        let matches = BuildArtifactRules.matches(in: event(entries: [
            ("src", .directory),
            ("target", .directory),
            ("Cargo.toml", .regularFile),
        ]))
        XCTAssertEqual(matches.count, 1)
        let match = try XCTUnwrap(matches.first)
        XCTAssertEqual(match.target, .child(name: "target"),
                       "sibling rows bind the CHILD, pinned target shape")
        XCTAssertEqual(match.rule, siblingRule("target"))
        XCTAssertEqual(match.rule.risk, .safe)
    }

    func testSiblingMarkerAbsentNoMatch() {
        let matches = BuildArtifactRules.matches(in: event(entries: [
            ("target", .directory),
            ("main.rs", .regularFile),
        ]))
        XCTAssertTrue(matches.isEmpty,
                      "a target/ without Cargo.toml could be anything (D6)")
    }

    func testSiblingMarkerPresentOnlyAsDirectoryNoMatch() {
        let matches = BuildArtifactRules.matches(in: event(entries: [
            ("target", .directory),
            ("Cargo.toml", .directory),
        ]))
        XCTAssertTrue(matches.isEmpty,
                      "a marker must be a REGULAR FILE, never a directory")
    }

    func testSiblingMarkerPresentOnlyAsSymlinkNoMatch() {
        let matches = BuildArtifactRules.matches(in: event(entries: [
            ("target", .directory),
            ("Cargo.toml", .symlink),
        ]))
        XCTAssertTrue(matches.isEmpty,
                      "a symlink marker proves nothing about this directory")
    }

    func testFileNamedLikeArtifactDirNeverMatches() {
        // A FILE named `build` beside a full gradle marker set.
        let buildFile = BuildArtifactRules.matches(in: event(entries: [
            ("build", .regularFile),
            ("build.gradle", .regularFile),
            ("settings.gradle", .regularFile),
        ]))
        XCTAssertTrue(buildFile.isEmpty, "a FILE named build never matches")

        // Same for a file named `target` beside Cargo.toml.
        let targetFile = BuildArtifactRules.matches(in: event(entries: [
            ("target", .regularFile),
            ("Cargo.toml", .regularFile),
        ]))
        XCTAssertTrue(targetFile.isEmpty, "a FILE named target never matches")
    }

    func testSymlinkCandidateNeverMatches() {
        let matches = BuildArtifactRules.matches(in: event(entries: [
            ("target", .symlink),
            ("Cargo.toml", .regularFile),
        ]))
        XCTAssertTrue(matches.isEmpty,
                      "a symlink child never matches — deletion would chase "
                      + "a target outside the tree")
    }

    func testGradleEveryMarkerVariantSuffices() {
        for marker in ["build.gradle", "build.gradle.kts",
                       "settings.gradle", "settings.gradle.kts"] {
            let matches = BuildArtifactRules.matches(in: event(entries: [
                ("build", .directory),
                (marker, .regularFile),
            ]))
            XCTAssertEqual(matches.count, 1, "marker \(marker) must suffice")
            XCTAssertEqual(matches.first?.target, .child(name: "build"))
        }
    }

    // MARK: - R1: inside shape

    func testInsideMarkerMatchesCurrentDirectoryRegardlessOfName() throws {
        let matches = BuildArtifactRules.matches(in: event(
            directory: "/fixture/devroot/some-arbitrary-env-name",
            entries: [
                ("pyvenv.cfg", .regularFile),
                ("bin", .directory),
                ("lib", .directory),
            ]
        ))
        XCTAssertEqual(matches.count, 1)
        let match = try XCTUnwrap(matches.first)
        XCTAssertEqual(match.target, .currentDirectory,
                       "inside rows bind the CURRENT directory, pinned "
                       + "target shape")
        XCTAssertEqual(match.rule.shape, .markerInside(marker: "pyvenv.cfg"))
        XCTAssertEqual(match.rule.risk, .review)
    }

    func testInsideMarkerAsDirectoryOrSymlinkNoMatch() {
        let asDirectory = BuildArtifactRules.matches(in: event(entries: [
            ("pyvenv.cfg", .directory),
        ]))
        XCTAssertTrue(asDirectory.isEmpty,
                      "pyvenv.cfg as a DIRECTORY is not the PEP 405 marker")

        let asSymlink = BuildArtifactRules.matches(in: event(entries: [
            ("pyvenv.cfg", .symlink),
        ]))
        XCTAssertTrue(asSymlink.isEmpty,
                      "pyvenv.cfg as a SYMLINK is not the PEP 405 marker")
    }

    // MARK: - R1: dev root never eligible (structural, not caller discipline)

    func testDepthZeroEventWithInteriorMarkerProducesNoCandidate() {
        // The dev root ITSELF contains pyvenv.cfg — the matcher's own
        // depth gate must refuse (a stray marker must not convert a broad
        // root into an artifact, D6). Constructed EVENT values, exactly as
        // the AC pins — the real-walker cell is fn-4.3's.
        let root = BuildArtifactRules.matches(in: event(
            directory: "/fixture/devroot",
            depth: 0,
            originRoot: "/fixture/devroot",
            entries: [("pyvenv.cfg", .regularFile), ("projects", .directory)]
        ))
        XCTAssertTrue(root.isEmpty,
                      "a depth-0 event must NEVER produce a currentDirectory "
                      + "candidate")

        // The EQUIVALENT depth-1 child event IS a candidate.
        let child = BuildArtifactRules.matches(in: event(
            directory: "/fixture/devroot/venv",
            depth: 1,
            originRoot: "/fixture/devroot",
            entries: [("pyvenv.cfg", .regularFile), ("projects", .directory)]
        ))
        XCTAssertEqual(child.map(\.target), [.currentDirectory])
    }

    func testSiblingMatchesAtDepthZeroAreChildrenAndThereforeLegal() {
        // Sibling-shape targets are SUBDIRECTORIES of the event's directory
        // by construction — a depth-0 event may still yield child matches
        // (the child is depth 1, not the root).
        let matches = BuildArtifactRules.matches(in: event(
            directory: "/fixture/devroot",
            depth: 0,
            originRoot: "/fixture/devroot",
            entries: [("target", .directory), ("Cargo.toml", .regularFile)]
        ))
        XCTAssertEqual(matches.map(\.target), [.child(name: "target")])
    }

    // MARK: - R1: first-rule-wins

    func testFirstRuleWinsOnCraftedNameCollision() throws {
        // Two rules claim the same artifact name with different markers and
        // risks — the FIRST fully matching row takes the subject.
        let first = BuildArtifactRule(
            shape: .markerSibling(artifactDirName: "collide",
                                  markers: ["marker-a"]),
            risk: .safe, defaultSelected: false, automaticCleanEligible: false
        )
        let second = BuildArtifactRule(
            shape: .markerSibling(artifactDirName: "collide",
                                  markers: ["marker-b"]),
            risk: .review, defaultSelected: false, automaticCleanEligible: false
        )

        // Both markers present → the first row wins.
        let both = BuildArtifactRules.matches(
            in: event(entries: [
                ("collide", .directory),
                ("marker-a", .regularFile),
                ("marker-b", .regularFile),
            ]),
            rules: [first, second]
        )
        XCTAssertEqual(both.count, 1)
        XCTAssertEqual(try XCTUnwrap(both.first).rule, first)

        // Only the SECOND row's marker present → a name-only hit on the
        // first row is NOT a match; the second row takes it.
        let secondOnly = BuildArtifactRules.matches(
            in: event(entries: [
                ("collide", .directory),
                ("marker-b", .regularFile),
            ]),
            rules: [first, second]
        )
        XCTAssertEqual(secondOnly.count, 1)
        XCTAssertEqual(try XCTUnwrap(secondOnly.first).rule, second)
    }

    // MARK: - Determinism: multiple matches in one event

    func testMultipleMatchesInOneEventInEntryOrder() {
        let matches = BuildArtifactRules.matches(in: event(entries: [
            ("node_modules", .directory),
            ("dist", .directory),
            (".next", .directory),
            ("package.json", .regularFile),
            ("pyvenv.cfg", .regularFile),
        ]))
        // Child matches in entry order, then the currentDirectory match.
        XCTAssertEqual(matches.map(\.target), [
            .child(name: "node_modules"),
            .child(name: "dist"),
            .child(name: ".next"),
            .currentDirectory,
        ])
        XCTAssertEqual(matches[0].rule, siblingRule("node_modules"))
        XCTAssertEqual(matches[0].rule.risk, .review,
                       "node_modules stays .review — the as-built doctrine")
    }
}
