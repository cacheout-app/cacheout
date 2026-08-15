import CryptoKit
import XCTest
@testable import Cacheout

/// fn-4.7 (R17/R14) — DOC-ACCURACY checks for the contracts PROTOCOL.md and
/// `docs/v1/CLI-REFERENCE.md` publish.
///
/// Documentation that drifts from the binary is worse than none: a consumer
/// builds against the words. These tests read the SHIPPED markdown, extract
/// the load-bearing claims, and check each one against the code that has to
/// honour it — the flag spelling and its gating, the wire keys, the token
/// derivation, the retired slug, and the `scanner_errors` kind taxonomy.
/// The house subprocess pattern (`CLIGateFramingTests`) covers the claims
/// that are about the PROCESS boundary; the rest are in-process, so nothing
/// here is a snapshot of prose for its own sake.
///
/// Read-only by construction: the only subprocess invocations are ones the
/// docs themselves describe as refusals, so no test can delete anything.
final class DocumentedContractTests: XCTestCase {

    // MARK: - Documents

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CacheoutTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
    }

    private func document(_ relativePath: String) throws -> String {
        let url = repoRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func protocolDoc() throws -> String { try document("PROTOCOL.md") }
    private func cliReference() throws -> String {
        try document("docs/v1/CLI-REFERENCE.md")
    }

    // MARK: - The acknowledgement flag as documented

    /// The flag SPELLING and its item-bound entry grammar are published in
    /// both documents; the binary must agree letter for letter, and the
    /// documented entry shape must actually parse.
    func testDocumentedAcknowledgementFlagAndEntryGrammarAreTheRealOnes()
        throws
    {
        let flag = CLIHandler.acknowledgeValuablesFlag
        XCTAssertEqual(flag, "--acknowledge-valuables",
                       "the documented flag spelling is frozen")

        let documented = "\(flag) <scanner-slug>:<item-id>:<token>"
        for (name, text) in [
            ("PROTOCOL.md", try protocolDoc()),
            ("CLI-REFERENCE.md", try cliReference()),
        ] {
            XCTAssertTrue(text.contains(documented),
                          "\(name) must publish the exact entry grammar "
                            + "'\(documented)'")
            XCTAssertTrue(text.contains("REPEATABLE"),
                          "\(name) must state the flag is repeatable")
        }

        // The documented shape parses, and the three fields land where the
        // docs say they do.
        let itemID = String(repeating: "a", count: 64)
        let token = String(repeating: "b", count: 64)
        guard case .success(let parsed) = CLIHandler.parseAcknowledgements(
            ["build_artifacts:\(itemID):\(token)"]
        ) else {
            return XCTFail("the documented entry shape must parse")
        }
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].key,
                       ItemKey(scannerID: "build_artifacts", itemID: itemID))
        XCTAssertEqual(parsed[0].token, token)
    }

    /// "64 lowercase hex characters" is a documented, checkable claim.
    func testDocumentedTokenFormMatchesTheValidator() throws {
        for (name, text) in [
            ("PROTOCOL.md", try protocolDoc()),
            ("CLI-REFERENCE.md", try cliReference()),
        ] {
            XCTAssertTrue(text.contains("64"), "\(name) states the length")
            XCTAssertTrue(text.lowercased().contains("lowercase hex"),
                          "\(name) states the alphabet")
        }
        XCTAssertTrue(
            CLIHandler.isAcknowledgementToken(String(repeating: "a", count: 64))
        )
        XCTAssertFalse(
            CLIHandler.isAcknowledgementToken(String(repeating: "A", count: 64)),
            "uppercase is documented as rejected, not folded"
        )
        XCTAssertFalse(
            CLIHandler.isAcknowledgementToken(String(repeating: "a", count: 63))
        )
        XCTAssertFalse(
            CLIHandler.isAcknowledgementToken(String(repeating: "g", count: 64))
        )
    }

    /// The documented token PREIMAGE, recomputed here from the published
    /// field order with an independent SHA-256 spelling — if the docs and
    /// the derivation ever disagree, a consumer that follows the docs would
    /// compute an unusable token.
    func testDocumentedTokenPreimageReproducesTheProductionToken() throws {
        let text = try protocolDoc()
        for fragment in [
            "scannerID NUL itemID NUL",
            "path NUL allocated_bytes NUL device NUL inode NUL",
            "modified_seconds NUL modified_nanoseconds NUL",
        ] {
            XCTAssertTrue(text.contains(fragment),
                          "PROTOCOL.md must publish '\(fragment)'")
        }

        let valuables = [
            DetectedValuable(
                name: "A.dmg",
                displayURL: URL(fileURLWithPath: "/alias/A.dmg"),
                canonicalIdentityPath: "/canonical/A.dmg",
                identity: ValuableIdentity(
                    allocatedBytes: 44_040_192, device: 16_777_232,
                    inode: 12_345_678, modifiedSeconds: 1_755_057_600,
                    modifiedNanoseconds: 123_456_789
                )
            ),
            DetectedValuable(
                name: "B.pkg",
                displayURL: URL(fileURLWithPath: "/alias/B.pkg"),
                canonicalIdentityPath: "/canonical/B.pkg",
                identity: ValuableIdentity(
                    allocatedBytes: 8_388_608, device: 16_777_232,
                    inode: 999, modifiedSeconds: 1_700_000_000,
                    modifiedNanoseconds: 0
                )
            ),
        ]
        // Built strictly from the documented recipe.
        var preimage = "build_artifacts" + "\0" + "item-1" + "\0"
        for valuable in valuables {
            let identity = valuable.identity
            preimage += valuable.canonicalIdentityPath + "\0"
                + String(identity.allocatedBytes) + "\0"
                + String(identity.device) + "\0"
                + String(identity.inode) + "\0"
                + String(identity.modifiedSeconds) + "\0"
                + String(identity.modifiedNanoseconds) + "\0"
        }
        let fromDocs = DocumentedToken.hex(of: preimage)

        let produced = try XCTUnwrap(ValuablesDisclosure.acknowledgementToken(
            scannerID: "build_artifacts", itemID: "item-1",
            valuables: valuables, probeComplete: true
        ))
        XCTAssertEqual(produced, fromDocs,
                       "the documented preimage recipe must reproduce the "
                        + "token byte for byte")
        XCTAssertEqual(produced.count, 64)
        XCTAssertTrue(CLIHandler.isAcknowledgementToken(produced))

        // And the documented `modified_at_ns` derivation, verbatim.
        XCTAssertTrue(
            text.contains(
                "`modifiedSeconds * 1_000_000_000 + modifiedNanoseconds`"
            ),
            "PROTOCOL.md must publish the nanosecond derivation"
        )
        XCTAssertEqual(valuables[0].identity.modifiedAtNanoseconds,
                       1_755_057_600_123_456_789,
                       "…and the derivation the binary performs matches it")
    }

    // MARK: - The documented wire keys

    /// The three ADDITIVE plan-row keys the docs name must be exactly the
    /// keys the plan builder emits, under exactly the documented absence
    /// rules (complete + non-empty → token; incomplete → note, no token;
    /// empty → neither).
    func testDocumentedPlanRowKeysMatchTheBuilderAndItsAbsenceRules() throws {
        let text = try protocolDoc()
        for key in ["`plan[].valuables`",
                    "`plan[].acknowledgement_token`",
                    "`plan[].acknowledgement_note`"] {
            XCTAssertTrue(text.contains(key),
                          "PROTOCOL.md must document \(key)")
        }

        let valuable = DetectedValuable(
            name: "A.dmg",
            displayURL: URL(fileURLWithPath: "/alias/A.dmg"),
            canonicalIdentityPath: "/canonical/A.dmg",
            identity: ValuableIdentity(
                allocatedBytes: 44_040_192, device: 16_777_232,
                inode: 12_345_678, modifiedSeconds: 1_755_057_600,
                modifiedNanoseconds: 123_456_789
            )
        )

        // (a) complete probe, non-empty set → valuables + token, no note.
        let disclosing = CLIHandler.cleanPlanItemJSON(for: planItem(
            disclosure: ValuablesDisclosure(
                valuables: [valuable], probeComplete: true
            )
        ))
        XCTAssertNotNil(disclosing["valuables"])
        let token = try XCTUnwrap(disclosing["acknowledgement_token"] as? String)
        XCTAssertTrue(CLIHandler.isAcknowledgementToken(token))
        XCTAssertNil(disclosing["acknowledgement_note"])

        // (b) INCOMPLETE probe → note, and NO token (the uniform rule).
        let incomplete = CLIHandler.cleanPlanItemJSON(for: planItem(
            disclosure: ValuablesDisclosure(
                valuables: [valuable], probeComplete: false
            )
        ))
        XCTAssertNotNil(incomplete["valuables"])
        XCTAssertNil(incomplete["acknowledgement_token"],
                     "an unfinished inspection is documented as TOKENLESS")
        XCTAssertNotNil(incomplete["acknowledgement_note"])

        // (c) complete probe, EMPTY set → none of the three.
        let clean = CLIHandler.cleanPlanItemJSON(
            for: planItem(disclosure: .clean)
        )
        XCTAssertNil(clean["valuables"])
        XCTAssertNil(clean["acknowledgement_token"],
                     "no empty-set token exists anywhere")
        XCTAssertNil(clean["acknowledgement_note"])
    }

    /// The documented valuables ELEMENT is a six-field object with exactly
    /// the published keys — and the display spelling never appears.
    func testDocumentedValuablesElementKeysAreExactlyWhatSerializes() throws {
        let text = try protocolDoc()
        let documentedKeys = [
            "name", "path", "allocated_bytes", "device", "inode",
            "modified_at_ns",
        ]
        for key in documentedKeys {
            XCTAssertTrue(text.contains("| `\(key)` |"),
                          "PROTOCOL.md's element table must document `\(key)`")
        }

        let row = CLIHandler.valuableRowJSON(for: DetectedValuable(
            name: "A.dmg",
            displayURL: URL(fileURLWithPath: "/alias/spelling/A.dmg"),
            canonicalIdentityPath: "/canonical/A.dmg",
            identity: ValuableIdentity(
                allocatedBytes: 44_040_192, device: 16_777_232,
                inode: 12_345_678, modifiedSeconds: 1_755_057_600,
                modifiedNanoseconds: 123_456_789
            )
        ))
        XCTAssertEqual(Set(row.keys), Set(documentedKeys),
                       "the wire element carries exactly the documented keys")
        XCTAssertEqual(row["path"] as? String, "/canonical/A.dmg",
                       "the documented `path` is the CANONICAL identity path")
        XCTAssertFalse(
            row.values.contains { ($0 as? String)?.contains("alias") == true },
            "the display spelling is documented as never serializing"
        )
    }

    // MARK: - The documented tokenless rules

    /// The docs promise two TOKENLESS refusals. Both are produced by the
    /// real revalidator, so both are checked against it rather than against
    /// prose.
    func testDocumentedTokenlessRefusalsAreTokenlessInTheRevalidator() throws {
        let text = try cliReference()
        XCTAssertTrue(text.contains("TOKENLESS"),
                      "CLI-REFERENCE must name the tokenless rule")

        // No token exists for an empty set, on ANY surface — the derivation
        // itself refuses to mint one (the vanished-set case bottoms out
        // here), and an incomplete probe is refused the same way.
        XCTAssertNil(ValuablesDisclosure.acknowledgementToken(
            scannerID: "build_artifacts", itemID: "x",
            valuables: [], probeComplete: true
        ), "no empty-set token exists")
        XCTAssertNil(ValuablesDisclosure.acknowledgementToken(
            scannerID: "build_artifacts", itemID: "x",
            valuables: [DetectedValuable(
                name: "A.dmg",
                displayURL: URL(fileURLWithPath: "/alias/A.dmg"),
                canonicalIdentityPath: "/canonical/A.dmg",
                identity: ValuableIdentity(
                    allocatedBytes: 1, device: 1, inode: 1,
                    modifiedSeconds: 1, modifiedNanoseconds: 0
                )
            )],
            probeComplete: false
        ), "no partial-inspection token exists")
    }

    /// The documented fail-fast rule covers a valueless occurrence too: the
    /// pure guard rejects on the OCCURRENCE count, so a trailing flag can
    /// never read as an absent one.
    func testDocumentedFailFastCoversAValuelessAcknowledgementOccurrence()
        throws
    {
        // One occurrence, no value → refused, naming the flag.
        guard case .failure(let error) = CLIHandler.acknowledgementValues(
            from: [], occurrences: 1
        ) else {
            return XCTFail("a valueless occurrence must be refused")
        }
        XCTAssertTrue(
            error.message.contains(CLIHandler.acknowledgeValuablesFlag),
            error.message
        )
        XCTAssertTrue(error.message.contains("Nothing was cleaned"),
                      error.message)

        // A mix: two occurrences, one value → still refused (the caller
        // authorized less than they think).
        guard case .failure = CLIHandler.acknowledgementValues(
            from: ["build_artifacts:a:b"], occurrences: 2
        ) else {
            return XCTFail("a partially-valued flag list must be refused")
        }

        // The honest cases pass through untouched.
        guard case .success(let none) = CLIHandler.acknowledgementValues(
            from: [], occurrences: 0
        ) else { return XCTFail("an absent flag is not an error") }
        XCTAssertTrue(none.isEmpty)
        guard case .success(let both) = CLIHandler.acknowledgementValues(
            from: ["a:b:c", "d:e:f"], occurrences: 2
        ) else { return XCTFail("well-formed occurrences pass through") }
        XCTAssertEqual(both, ["a:b:c", "d:e:f"])
    }

    // MARK: - The recorded cross-repo release gate (R6)

    /// The CHANGELOG records the RETIREMENT of the `node_modules` slug and,
    /// with it, the semantic gate the unreleased `cacheout-mcp` consumer must
    /// pass before the next release ships. That gate is a release-blocking
    /// promise, so its recorded form has to be one whose zero-state is
    /// REACHABLE and STABLE:
    ///
    /// - semantic, not a raw `grep node_modules` — the artifact RULE keeps
    ///   that directory name, so a raw search can never reach zero;
    /// - SOURCE-scoped — without `-I` / `--exclude-dir=__pycache__` a stale
    ///   or freshly written `.pyc` decides the verdict, and the gate reports
    ///   on build artifacts instead of on the code (review r2).
    ///
    /// The sibling checkout is not assumed to exist, so this checks the
    /// PROMISE's shape, which is what regressed.
    func testRecordedCrossRepoGateIsSemanticAndSourceScoped() throws {
        let changelog = try document("CHANGELOG.md")
        guard let unreleased = changelog.range(of: "## [Unreleased]"),
              let released = changelog.range(of: "## [2.2.0]") else {
            return XCTFail("CHANGELOG must carry an [Unreleased] section")
        }
        let section = String(changelog[unreleased.lowerBound..<released.lowerBound])

        XCTAssertTrue(section.contains("PRE-RELEASE RENAME"),
                      "the slug retirement must be recorded under [Unreleased]")
        for fragment in [
            #""node_modules"|"#,          // scanner_id values
            "node_modules:",              // address prefixes
            "-I",                         // binaries never decide the verdict
            "--exclude-dir=__pycache__",  // build artifacts never do either
            "src tests",                  // the consumer's source roots
        ] {
            XCTAssertTrue(section.contains(fragment),
                          "the recorded gate must contain '\(fragment)'")
        }
        XCTAssertTrue(section.contains("zero"),
                      "the recorded gate must state its passing state")
    }

    // MARK: - Shipped TCC usage strings (R9/R14)

    /// The macOS privacy prompts are PRODUCT copy, generated from three
    /// synchronized sources (the bundle.sh heredoc, Info.plist, and
    /// project.yml). They must describe the scanners that actually walk the
    /// protected roots — after fn-4.7 that is `build_artifacts`, not the
    /// retired node_modules scanner, and after fn-5.6's registration
    /// `git_worktrees` walks the SAME dev roots through the same gate — and
    /// the three copies must agree, since a drifting one ships silently in
    /// whichever build path used it.
    func testShippedTCCUsageStringsDescribeTheLiveScannerAndStayInSync()
        throws
    {
        let sources = [
            "Sources/Cacheout/Info.plist",
            "project.yml",
            "scripts/bundle.sh",
            // The GENERATED fourth copy, checked in and shipped by the Xcode
            // build path. It drifted silently when project.yml changed
            // (found in fn-5.6): a generated artifact still ships, so it is
            // held to the same sync rule — a failure here means the checked-in
            // project is stale and `xcodegen generate` was not re-run.
            "Cacheout.xcodeproj/project.pbxproj",
        ]
        let documents = "Cacheout looks for developer build-artifact folders "
            + "(target/, node_modules/, .venv/ and similar) and stale git "
            + "worktrees in Documents "
            + "during scans you start. Nothing is deleted without your "
            + "confirmation."
        let desktop = "Cacheout looks for developer build-artifact folders "
            + "(target/, node_modules/, .venv/ and similar) and stale git "
            + "worktrees on your Desktop "
            + "during scans you start. Nothing is deleted without your "
            + "confirmation."

        for source in sources {
            let text = try document(source)
            XCTAssertTrue(text.contains(documents),
                          "\(source) must carry the Documents usage string")
            XCTAssertTrue(text.contains(desktop),
                          "\(source) must carry the Desktop usage string")
            XCTAssertFalse(
                text.contains("project node_modules folders"),
                "\(source) still describes the RETIRED scanner"
            )
            XCTAssertFalse(
                text.contains("NodeModulesScanner"),
                "\(source) still points at a deleted type"
            )
            // Every prompting root the walker gates is covered by a key.
            for name in ProjectTreeWalker.tccProtectedAncestorNames {
                XCTAssertTrue(
                    text.contains("NS\(name)FolderUsageDescription"),
                    "\(source) is missing the \(name) usage key"
                )
            }
        }
    }

    // MARK: - `scanner_errors` taxonomy (R14/R16)

    /// The documented kind list must contain every wire string the enum can
    /// produce — a kind the binary can emit but the docs never mention is
    /// exactly the drift these tests exist for — and the path-conditional
    /// rule must name every NON-filesystem kind.
    func testDocumentedScannerErrorKindsCoverTheWireTaxonomy() throws {
        let text = try protocolDoc()
        let allKinds: [ScanIssue.Kind] = [
            .containerRefused, .symlinkRoot, .tccDenied, .permissionDenied,
            .unreadable, .configInvalid, .toolUnavailable, .malformedOutcome,
        ]
        for kind in allKinds {
            XCTAssertTrue(text.contains("`\"\(kind.wireString)\"`"),
                          "PROTOCOL.md must list the `\(kind.wireString)` kind")
        }

        // The path-conditional rule, in the COMPOSABLE form: it names the
        // non-filesystem kinds as a set, so a later epic adding one extends
        // this sentence instead of restating the rule.
        let pathRow = try XCTUnwrap(
            text.split(separator: "\n").first {
                $0.hasPrefix("| `path` |") && $0.contains("conditional")
            },
            "PROTOCOL.md must carry the conditional `path` rule"
        )
        XCTAssertTrue(pathRow.contains("NON-FILESYSTEM"),
                      "the rule is stated over a KIND CLASS: \(pathRow)")
        // fn-5.6 EXTENDS the named set rather than restating the rule.
        for kind in ["malformed_outcome", "config_invalid", "tool_unavailable"] {
            XCTAssertTrue(pathRow.contains(kind),
                          "the rule must name `\(kind)`: \(pathRow)")
        }

        // And the binary agrees: `config_invalid` really carries no path.
        let issue = ScanIssue(
            url: nil, kind: .configInvalid,
            detail: "\(DevRootsStore.devRootsKey) is not an array of strings"
        )
        XCTAssertNil(issue.url)
        XCTAssertEqual(issue.kind.wireString, "config_invalid")

        // …and so does the one the scanner actually publishes: the shipped
        // issue is path-less and its detail carries the pinned prefix the
        // documentation quotes.
        XCTAssertNil(GitWorktreeScanner.toolUnavailableIssue.url)
        XCTAssertEqual(
            GitWorktreeScanner.toolUnavailableIssue.kind.wireString,
            "tool_unavailable"
        )
        XCTAssertTrue(
            GitWorktreeScanner.toolUnavailableIssue.detail
                .hasPrefix("git unavailable")
        )
        XCTAssertTrue(text.contains("the detail begins `git unavailable`"),
                      "PROTOCOL.md must quote the pinned detail prefix")
    }

    // MARK: - The documented reclaim actions (fn-5.6, R11)

    /// The `action` row must cover EVERY wire string the enum can produce —
    /// a consumer branching on `action` is branching on this list — and must
    /// keep the non-exposure rule for the two payload-carrying cases.
    func testDocumentedActionWireStringsCoverTheEnum() throws {
        let text = try protocolDoc()
        let actionRow = try XCTUnwrap(
            text.split(separator: "\n").first {
                $0.hasPrefix("| `action` |") && $0.contains("wire string")
            },
            "PROTOCOL.md must carry the `action` row"
        )
        // Built from the ENUM, so a new case fails here until documented.
        let allActions: [ReclaimAction] = [
            .removeContents, .removeItem, .commands([["true"]]),
            .gitWorktreeReclaim(.pruneOrphanedAdmin(
                parentRepoWorkingDir: URL(fileURLWithPath: "/dev/repo"),
                adminContainer: URL(fileURLWithPath: "/dev/repo/admin"),
                disclosedAdminDirectories: []
            )),
        ]
        for action in allActions {
            XCTAssertTrue(
                actionRow.contains("`\"\(action.wireString)\"`"),
                "the row must list `\(action.wireString)`: \(actionRow)"
            )
        }
        XCTAssertTrue(actionRow.contains("NEVER exposed"),
                      "the payload non-exposure rule survives: \(actionRow)")
        XCTAssertEqual(
            ReclaimAction.gitWorktreeReclaim(.removeStaleWorktree(
                worktreePath: URL(fileURLWithPath: "/dev/wt"),
                worktreeAdminEntry: URL(fileURLWithPath: "/dev/repo/admin/wt"),
                parentRepoWorkingDir: URL(fileURLWithPath: "/dev/repo"),
                adminContainer: URL(fileURLWithPath: "/dev/repo/admin")
            )).wireString,
            "git_worktree_reclaim",
            "the FROZEN wire string, both modes"
        )
    }

    // MARK: - The D18 external timeout contract (fn-5.6, R11)

    /// The rule MCP callers implement, and the reason there is nothing
    /// numeric to keep in sync: a worktree removal is unbounded work, so any
    /// published client-side formula could kill a valid clean. This test
    /// therefore pins the RULE and its TRIGGER, and asserts that no numeric
    /// client-side formula crept back in.
    func testDocumentedNoClientTimeoutRuleAndItsTriggerAreComplete() throws {
        let text = try protocolDoc()
        let start = try XCTUnwrap(
            text.range(of: "#### Exception: NO client-side timeout"),
            "PROTOCOL.md must carry the composite-clean timeout exception"
        )
        let end = try XCTUnwrap(text.range(of: "## Alert Schema"))
        let section = String(text[start.lowerBound..<end.lowerBound])

        // THE RULE.
        XCTAssertTrue(section.contains("NO client-side timeout"), section)
        XCTAssertTrue(section.contains("`git_worktree_reclaim`"), section)
        XCTAssertTrue(section.contains("Not a longer timeout — none."), section)
        // THE TRIGGER, all four clauses — a caller must be able to decide
        // BEFORE running anything.
        for clause in [
            "equals the scanner slug `git_worktrees`",
            "starts with `git_worktrees:`",
            "`\"action\": \"git_worktree_reclaim\"`",
            "scanner-ambiguous",
            "Treat it as composite",
            "Over-waiting is safe",
        ] {
            XCTAssertTrue(section.contains(clause),
                          "the trigger rule must state '\(clause)'")
        }
        // Everything else is unchanged.
        XCTAssertTrue(section.contains("keeps the 30-second rule"), section)
        // THE HONEST CAVEAT — the outer kill is possible and is named.
        XCTAssertTrue(section.contains("ORPHANED mid-removal"), section)
        // Substrings that never span a line break: the caveat must survive a
        // prose reflow, since what is pinned is the CLAIM, not the wrapping.
        XCTAssertTrue(section.contains("tree state is possible"), section)
        XCTAssertTrue(section.contains("next scan handles"), section)

        // NO client-side FORMULA — the round-8 shape is gone for good. The
        // only numbers here are the CLI's OWN budget and the unchanged
        // 30-second default.
        for formula in [
            "per GB", "per gigabyte", "×", "timeout =", "base timeout",
            "scaled", "multiplied",
        ] {
            XCTAssertFalse(
                section.contains(formula),
                "a client-side timeout formula reappeared ('\(formula)') — "
                    + "any finite guess can kill a valid clean"
            )
        }
        // …and the budget the doc DOES quote is the real one.
        XCTAssertTrue(
            section.contains("300 s"),
            "the CLI's own per-invocation budget is what actually bounds this"
        )
        XCTAssertEqual(WorktreeReclaimPerformer.deleteTimeGitTimeout, 300,
                       "the documented budget is the shipped constant")
    }

    /// The release-blocking consumer gate, recorded where a release engineer
    /// will see it. Same discipline as the slug-retirement gate above: a
    /// named owner, and a verification whose passing state is stated and
    /// reachable. The sibling checkout is not assumed to exist, so this
    /// checks the PROMISE's shape.
    func testRecordedTimeoutGateIsBlockingNamedAndVerifiable() throws {
        let changelog = try document("CHANGELOG.md")
        guard let unreleased = changelog.range(of: "## [Unreleased]"),
              let released = changelog.range(of: "## [2.2.0]") else {
            return XCTFail("CHANGELOG must carry an [Unreleased] section")
        }
        let section = String(changelog[unreleased.lowerBound..<released.lowerBound])

        for fragment in [
            "RELEASE-BLOCKING",           // it blocks, it is not advisory
            "cacheout-mcp",               // the named consumer
            "Owner:",                     // a person, not "someone"
            "Baseline verified at",        // the defect was observed, not assumed
            "Required change:",           // what closing it actually means
            "git_worktrees",              // the trigger the consumer implements
            "-I",                         // binaries never decide the verdict
            "--exclude-dir=__pycache__",  // build artifacts never do either
            "src tests",                  // the consumer's source roots
            "NON-ZERO",                   // the adoption half's passing state
            "must be ZERO",               // the defect half's passing state
        ] {
            XCTAssertTrue(section.contains(fragment),
                          "the recorded gate must contain '\(fragment)'")
        }
        // …and its CURRENT state is stated, in one of the two admissible
        // spellings. Asserting the literal open marker would pin a transient
        // condition: the gate is MEANT to close, and closing it must not turn
        // this test red. What must never happen is a gate whose status is
        // absent or unparseable — that is the unverifiable case the release
        // script refuses, so it is what this asserts against.
        let statusPattern =
            #"(?m)^[ \t]*Status: \*\*(NOT SATISFIED|SATISFIED at [0-9a-f]{7,40})\*\*"#
        XCTAssertNotNil(
            section.range(of: statusPattern, options: .regularExpression),
            "the recorded gate must state its status in an admissible spelling: \(section)"
        )
        // The rule the consumer has to adopt is stated here too, not just
        // referenced — a release engineer reading the CHANGELOG alone must be
        // able to tell whether the gate is met.
        XCTAssertTrue(section.contains("NO client-side timeout"), section)
    }

    /// The gate is DEFERRED to the release path — so EVERY mode that produces
    /// a distributable artifact has to enforce it. `--direct` builds and signs
    /// a DMG just as `--release` does (it only skips notarization), so a gate
    /// wired into the release arm alone would be bypassable by the shorter
    /// command (review r3).
    func testEveryDistributionModeRunsTheReleaseGateFirst() throws {
        let script = try document("scripts/bundle.sh")
        XCTAssertTrue(script.contains("check_release_gates() {"),
                      "bundle.sh must define the release-gate check")

        for (arm, steps) in [
            ("--direct)", ["build_release", "create_bundle", "create_dmg"]),
            ("--notarize|--release)",
             ["build_release", "create_bundle", "create_dmg", "notarize_dmg"]),
        ] {
            let start = try XCTUnwrap(script.range(of: arm),
                                      "bundle.sh must have the \(arm) arm")
            let body = String(script[start.lowerBound...].prefix(1_200))
            let gate = try XCTUnwrap(
                body.range(of: "check_release_gates"),
                "the \(arm) arm must RUN the gate: \(body)"
            )
            for step in steps {
                let stepRange = try XCTUnwrap(
                    body.range(of: step), "\(arm) arm missing '\(step)'"
                )
                XCTAssertLessThan(gate.lowerBound, stepRange.lowerBound,
                                  "the gate must precede \(step) in \(arm)")
            }
        }
    }

    /// The gate, EXECUTED — string presence proves wiring, not behavior.
    /// Three states over fixture CHANGELOGs, plus the one that matters most:
    /// applying the CHANGELOG's own documented close instruction really does
    /// unblock the build. A close instruction that does not match what the
    /// script keys on would leave the release permanently blocked (review r3).
    func testTheReleaseGateOpensAndClosesExactlyAsDocumented() throws {
        let script = try document("scripts/bundle.sh")
        let changelog = try document("CHANGELOG.md")

        // The DOCUMENTED transition, quoted from the CHANGELOG itself.
        let openMarker = "Status: **NOT SATISFIED**"
        let closedMarker = "Status: **SATISFIED at 63edbfc**"
        XCTAssertTrue(
            changelog.contains("`**SATISFIED at <commit-hash>**`"),
            "the CHANGELOG must publish the exact closing edit"
        )

        // The live gate may be OPEN or CLOSED — a gate exists to be closed,
        // and closing it must not turn this test red. So the real document is
        // normalized to the open state and the transition is driven from
        // there: every fixture below stays anchored to the SHIPPED changelog's
        // structure (its real markers, sections and prose) while none of them
        // depends on today's status. Pinning the live state instead would make
        // this test assert "nobody has done the work yet", which is not a
        // property of the gate machinery.
        let liveStatus = try XCTUnwrap(
            changelog.range(
                of: #"(?m)^[ \t]*Status: \*\*(NOT SATISFIED|SATISFIED at [0-9a-f]{7,40})\*\*.*$"#,
                options: .regularExpression
            ),
            "the gate's status line must be one of the two admissible spellings"
        )
        let indent = changelog[liveStatus].prefix { $0 == " " || $0 == "\t" }
        let changelogOpen = changelog.replacingCharacters(
            in: liveStatus, with: indent + openMarker
        )
        XCTAssertTrue(changelogOpen.contains(openMarker),
                      "normalizing to the open state must produce the open marker")

        // Extract the function so the REAL shell runs, not a paraphrase.
        let start = try XCTUnwrap(script.range(of: "check_release_gates() {"))
        let end = try XCTUnwrap(
            script.range(of: "\n}\n", range: start.upperBound..<script.endIndex)
        )
        let function = String(script[start.lowerBound..<end.upperBound])

        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReleaseGate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: sandbox, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let functionFile = sandbox.appendingPathComponent("gate.sh")
        try function.write(to: functionFile, atomically: true, encoding: .utf8)

        // NO HEREDOC in the gate (review r7): a `while read` fed by a
        // heredoc needs a writable temp file, and a shell that cannot create
        // one SKIPS the loop silently — every status would go unchecked and
        // the function would fall through to "satisfied". The behavioural
        // half of this is the unwritable-TMPDIR run below; this is the
        // structural guard that keeps the construct from coming back.
        XCTAssertFalse(function.contains("<<"),
                       "the gate must not depend on temporary files: \(function)")

        /// Runs the extracted gate against a fixture project directory.
        /// `temporaryDirectory` is injected so the caller can prove the gate
        /// behaves identically when the shell cannot create temp files.
        func runGate(projectDir: URL, temporaryDirectory: String? = nil) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [
                "-c",
                "source \"$1\"; PROJECT_DIR=\"$2\"; check_release_gates",
                "bash", functionFile.path, projectDir.path,
            ]
            if let temporaryDirectory {
                var environment = ProcessInfo.processInfo.environment
                environment["TMPDIR"] = temporaryDirectory
                process.environment = environment
            }
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            XCTAssertTrue(process.waitForExit(within: 30), "the gate hung")
            return process.terminationStatus
        }

        func fixture(_ name: String, changelog contents: String?) throws -> URL {
            let dir = sandbox.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true
            )
            if let contents {
                try contents.write(
                    to: dir.appendingPathComponent("CHANGELOG.md"),
                    atomically: true, encoding: .utf8
                )
            }
            return dir
        }

        // THE CLOSED CASE, from the documented edit applied verbatim: the
        // instruction must actually unblock the pipeline, and prose that
        // still MENTIONS the phrase must not keep it shut.
        let closed = changelogOpen.replacingOccurrences(
            of: openMarker, with: closedMarker
        )
        XCTAssertNotEqual(closed, changelogOpen, "the documented edit must apply")

        // Every state the checker can face, and the ONLY one that may pass is
        // a provably-satisfied gate. Searching for the open marker alone
        // would FAIL OPEN on rows 3-6: deleting the status line would read as
        // "closed" (review r4).
        let cases: [(name: String, changelog: String?, passes: Bool)] = [
            ("open", changelogOpen, false),
            ("closed", closed, true),
            ("live", changelog, true),
            ("missing-file", nil, false),
            ("status-deleted",
             changelogOpen.replacingOccurrences(of: openMarker, with: ""), false),
            ("section-renamed",
             changelogOpen.replacingOccurrences(
                of: "## [Unreleased]", with: "## [Whatever]"
             ), false),
            ("satisfied-without-a-commit",
             changelogOpen.replacingOccurrences(
                of: openMarker, with: "Status: **SATISFIED**"
             ), false),
            ("satisfied-with-a-non-hex-commit",
             changelogOpen.replacingOccurrences(
                of: openMarker, with: "Status: **SATISFIED at zzzzzzz**"
             ), false),
            // An orphan status with no gate marker: the recorded form is
            // broken, so the gate it belonged to cannot be verified.
            ("status-without-a-gate", """
             # Changelog

             ## [Unreleased]

               Status: **SATISFIED at 63edbfc**

             ## [2.2.0] - 2026-08-06
             """, false),
            // MULTI-GATE PAIRING (review r5). Counting markers against
            // statuses is NOT equivalent to pairing them: this layout
            // balances (two of each, both spellings valid) while gate B has
            // no status at all — a fail-open the count check waved through.
            ("two-gates-one-carrying-both-statuses", """
             # Changelog

             ## [Unreleased]

               **RELEASE-BLOCKING gate A**
               Status: **SATISFIED at 63edbfc**
               Status: **SATISFIED at abcdef1**

               **RELEASE-BLOCKING gate B**

             ## [2.2.0] - 2026-08-06
             """, false),
            ("two-gates-the-first-unstated", """
             # Changelog

             ## [Unreleased]

               **RELEASE-BLOCKING gate A**

               **RELEASE-BLOCKING gate B**
               Status: **SATISFIED at abcdef1**

             ## [2.2.0] - 2026-08-06
             """, false),
            ("two-gates-the-last-unstated", """
             # Changelog

             ## [Unreleased]

               **RELEASE-BLOCKING gate A**
               Status: **SATISFIED at 63edbfc**

               **RELEASE-BLOCKING gate B**

             ## [2.2.0] - 2026-08-06
             """, false),
            ("two-gates-one-still-open", """
             # Changelog

             ## [Unreleased]

               **RELEASE-BLOCKING gate A**
               Status: **SATISFIED at 63edbfc**

               **RELEASE-BLOCKING gate B**
               Status: **NOT SATISFIED** — still waiting

             ## [2.2.0] - 2026-08-06
             """, false),
            ("two-gates-both-satisfied", """
             # Changelog

             ## [Unreleased]

               **RELEASE-BLOCKING gate A**
               Status: **SATISFIED at 63edbfc**

               **RELEASE-BLOCKING gate B**
               Status: **SATISFIED at abcdef1**

             ## [2.2.0] - 2026-08-06
             """, true),
            // A MALFORMED status must not be skipped as prose (review r6):
            // if the parser only saw well-formed lines, the typo'd open
            // status would be ignored and the valid one below it would close
            // a gate that was meant to stay shut.
            ("a-typo-open-status-above-a-valid-one", """
             # Changelog

             ## [Unreleased]

               **RELEASE-BLOCKING gate A**
               Status: *NOT SATISFIED*
               Status: **SATISFIED at 63edbfc**

             ## [2.2.0] - 2026-08-06
             """, false),
            ("a-status-in-neither-admissible-spelling", """
             # Changelog

             ## [Unreleased]

               **RELEASE-BLOCKING gate A**
               Status: pending

             ## [2.2.0] - 2026-08-06
             """, false),
            // The satisfied form is matched to its END, not by prefix
            // (reviews r7-r8): a regex that stopped at the first closing
            // `**` accepts both of these. After the token the line must STOP
            // or continue with WHITESPACE — anything attached means the
            // token is something else.
            ("satisfied-with-a-mangled-closing-token", """
             # Changelog

             ## [Unreleased]

               **RELEASE-BLOCKING gate A**
               Status: **SATISFIED at 63edbfc***

             ## [2.2.0] - 2026-08-06
             """, false),
            ("satisfied-with-a-character-attached-to-the-token", """
             # Changelog

             ## [Unreleased]

               **RELEASE-BLOCKING gate A**
               Status: **SATISFIED at 63edbfc**x

             ## [2.2.0] - 2026-08-06
             """, false),
            ("satisfied-with-too-short-a-commit", """
             # Changelog

             ## [Unreleased]

               **RELEASE-BLOCKING gate A**
               Status: **SATISFIED at 63ed**

             ## [2.2.0] - 2026-08-06
             """, false),
            // …while ordinary trailing prose after the bold token is fine —
            // the documented one-line edit leaves the sentence's tail behind.
            ("satisfied-with-trailing-prose", """
             # Changelog

             ## [Unreleased]

               **RELEASE-BLOCKING gate A**
               Status: **SATISFIED at 63edbfc** — adopted 2026-08-15

             ## [2.2.0] - 2026-08-06
             """, true),
            // Nothing recorded at all is the ordinary, releasable state.
            ("no-gates-recorded", """
             # Changelog

             ## [Unreleased]

             - nothing pending

             ## [2.2.0] - 2026-08-06
             """, true),
            // A gate in a SHIPPED section is history, never a blocker.
            ("historical-gate-only", """
             # Changelog

             ## [Unreleased]

             - nothing pending

             ## [2.2.0] - 2026-08-06

               **RELEASE-BLOCKING cross-repo gate.**
               Status: **NOT SATISFIED** — this shipped long ago.
             """, true),
        ]

        // Every class, run TWICE: once normally, once with TMPDIR pointing
        // nowhere writable. The verdicts must be identical — a gate whose
        // answer depends on whether the shell could open a temp file is a
        // gate that passes when the disk is full (review r7).
        for testCase in cases {
            let directory = try fixture(
                testCase.name, changelog: testCase.changelog
            )
            for temporaryDirectory in [nil, "/nonexistent-tmpdir"] as [String?] {
                let status = try runGate(
                    projectDir: directory, temporaryDirectory: temporaryDirectory
                )
                let context = temporaryDirectory == nil
                    ? "'\(testCase.name)'"
                    : "'\(testCase.name)' with no usable TMPDIR"
                if testCase.passes {
                    XCTAssertEqual(status, 0,
                                   "\(context) must let the build proceed")
                } else {
                    XCTAssertNotEqual(status, 0,
                                      "\(context) must STOP the build — an "
                                          + "unverifiable gate is never a passed one")
                }
            }
        }
    }

    /// PROTOCOL.md's `risk_level` note must no longer claim a per-SCANNER
    /// constant — the rule table publishes mixed risks.
    func testDocumentedRiskLevelIsThePerRuleModelNotAScannerConstant() throws {
        let text = try protocolDoc()
        XCTAssertFalse(
            text.contains("`node_modules` rows are always"),
            "the stale per-scanner risk claim must be gone"
        )
        let risks = Set(BuildArtifactRules.v1.map(\.risk))
        XCTAssertGreaterThan(risks.count, 1,
                             "the rule table really is mixed-risk: \(risks)")
        for row in text.split(separator: "\n")
        where row.hasPrefix("| `risk_level` |") && row.contains("build_artifacts") {
            XCTAssertTrue(row.contains("RULE ROW"),
                          "the note states the per-rule model: \(row)")
            return
        }
        XCTFail("PROTOCOL.md must carry a per-rule `risk_level` note")
    }

    // MARK: - Additive scanner_items fields

    /// `logical_bytes` and `valuables` are documented as ADDITIVE and
    /// OMITTED (never null) when they do not apply.
    func testDocumentedAdditiveScannerItemFieldsAreOmittedNotNull() throws {
        let text = try protocolDoc()
        XCTAssertTrue(text.contains("| `logical_bytes` | integer | no |"),
                      "PROTOCOL.md documents logical_bytes as optional")
        XCTAssertTrue(text.contains("| `valuables` | object[] | no |"),
                      "PROTOCOL.md documents valuables as optional")

        let plain = CLIHandler.scannerItemRowJSON(for: planItem(disclosure: nil))
        XCTAssertNil(plain["logical_bytes"])
        XCTAssertNil(plain["valuables"])
        XCTAssertEqual(
            Set(plain.keys),
            ["scanner_id", "item_id", "path", "name", "state", "exact_bytes",
             "estimated_up_to_bytes", "size_bytes", "item_count",
             "risk_level", "evidence", "action"],
            "an item with neither field keeps the documented base row shape"
        )
    }

    // MARK: - Fixtures

    /// A minimal, validator-coherent per-item row for the JSON builders.
    private func planItem(
        id: String = "item-1",
        disclosure: ValuablesDisclosure?
    ) -> ReclaimableItem {
        let target = URL(fileURLWithPath: "/canonical/dev/proj/target")
        return ReclaimableItem(
            id: id,
            scannerID: BuildArtifactsScanner.registeredID,
            displayName: "target",
            exactBytes: 4_096,
            estimatedUpToBytes: 0,
            logicalBytes: nil,
            itemCount: 1,
            url: target,
            declaredDisplayPath: target.path,
            rootRecords: [RootScanRecord(
                requestedURL: target, resolvedURL: target, status: .measured
            )],
            state: .measured,
            scanError: nil,
            risk: .review,
            evidence: "target/ beside Cargo.toml",
            rebuildNote: nil,
            action: .removeItem,
            admission: .containerItem(
                originContainer: URL(fileURLWithPath: "/canonical/dev"),
                requestedTargetURL: target
            ),
            defaultSelected: false,
            automaticCleanEligible: false,
            isStale: nil,
            valuablesDisclosure: disclosure,
            requiresPreDeleteRevalidation: true
        )
    }
}

/// The documented recipe, hashed. The INDEPENDENCE that matters is the
/// PREIMAGE — built here from PROTOCOL.md's published field order and NUL
/// separators rather than from the production string-builder — so a doc that
/// misstates the order or the separators fails the comparison. SHA-256
/// itself is a standard and is deliberately not reimplemented.
private enum DocumentedToken {
    static func hex(of preimage: String) -> String {
        SHA256.hash(data: Data(preimage.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

// MARK: - The worked retry example, executed

/// fn-4.7 (R17) — the WORKED RETRY EXAMPLE both documents print, executed
/// against the real pipeline: refusal → copy the token out of the SAME
/// envelope → re-run with the documented entry → success. Plus the same
/// keys on the other arm (partial success), because the docs promise ONE
/// row shape on both.
///
/// Hermetic and fixture-contained: a real `BuildArtifactsScanner` over a
/// temp dev root, driven through the injected `CLIRuntimeDependencies` seam.
final class DocumentedRetryExampleTests: XCTestCase {

    private var base: URL!
    private var fixtureHome: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private let fm = FileManager.default
    private let scannerID = BuildArtifactsScanner.registeredID

    override func setUpWithError() throws {
        base = fm.temporaryDirectory
            .appendingPathComponent("DocRetryTests-\(UUID().uuidString)")
        fixtureHome = base.appendingPathComponent("home")
        try fm.createDirectory(at: fixtureHome, withIntermediateDirectories: true)
        suiteName = "DocRetryTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        if let suiteName { defaults?.removePersistentDomain(forName: suiteName) }
        if let base { try? fm.removeItem(at: base) }
    }

    // MARK: Fixtures

    /// `<dev>/<name>/Cargo.toml` beside `<dev>/<name>/target/`, optionally
    /// with a release artifact inside — the shape the documentation uses.
    @discardableResult
    private func makeRustProject(
        _ name: String, in dev: URL, valuable: String? = nil
    ) throws -> URL {
        let project = dev.appendingPathComponent(name)
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        try Data(repeating: 0xC3, count: 32)
            .write(to: project.appendingPathComponent("Cargo.toml"))
        let artifact = project.appendingPathComponent("target")
        try fm.createDirectory(at: artifact, withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: 8_192)
            .write(to: artifact.appendingPathComponent("payload.bin"))
        if let valuable {
            let url = artifact.appendingPathComponent("release/bundle/\(valuable)")
            try fm.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(
                repeating: 0xAB,
                count: Int(ValuablesDetector.minimumAllocatedBytes) + 100_000
            ).write(to: url)
        }
        return artifact
    }

    private func makeDeps(devRoots roots: [URL]) throws
        -> CLIHandler.CLIRuntimeDependencies
    {
        let scanner = BuildArtifactsScanner(
            home: fixtureHome,
            devRoots: DevRootsStore(defaults: defaults)
                .effectiveRoots(replacing: roots, home: fixtureHome)
        )
        return CLIHandler.CLIRuntimeDependencies(
            runtime: try SpaceScannerRuntime(
                scanners: [scanner], categories: [], home: fixtureHome,
                provider: FileSystemIdentityProvider()
            ),
            categorySlugs: []
        )
    }

    /// The documented address form: `<scanner-slug>:<item-id>`.
    private func address(for artifact: URL) -> String {
        "\(scannerID):" + ReclaimableItem.stableID(
            scannerID: scannerID,
            canonicalPath: FileSystemIdentityProvider()
                .resolveTargetKeepingLeaf(artifact).path
        )
    }

    private func clean(
        _ deps: CLIHandler.CLIRuntimeDependencies,
        targets: [String], acknowledgements: [String] = []
    ) async -> CLIHandler.CLIOutcome {
        await CLIHandler.cleanCLIOutcome(
            targets: targets, acknowledgements: acknowledgements,
            dryRun: false, confirmed: true, euid: 501, deps: deps
        )
    }

    // MARK: The example

    func testDocumentedRefusalThenAcknowledgedRetryDeletesTheItem()
        async throws
    {
        let dev = base.appendingPathComponent("dev")
        let artifact = try makeRustProject(
            "rustapp", in: dev, valuable: "Murmur_0.1.7_aarch64.dmg"
        )
        let deps = try makeDeps(devRoots: [dev])
        let target = address(for: artifact)

        // STEP 1 — the documented refusal: exit-1 CLEAN_FAILED, nothing
        // deleted, and BOTH documented keys on the row.
        guard case .failure(let code, _, let details) = await clean(
            deps, targets: [target]
        ) else {
            return XCTFail("a confirmed clean of a disclosing item is refused")
        }
        XCTAssertEqual(code, "CLEAN_FAILED",
                       "the documented total-failure envelope")
        let refusedRows = try XCTUnwrap(details?["results"] as? [[String: Any]])
        XCTAssertEqual(refusedRows.count, 1)
        let refused = refusedRows[0]
        XCTAssertEqual(refused["success"] as? Bool, false)
        let valuables = try XCTUnwrap(refused["valuables"] as? [[String: Any]])
        XCTAssertEqual(Set(valuables[0].keys), [
            "name", "path", "allocated_bytes", "device", "inode",
            "modified_at_ns",
        ], "the documented six-field element")
        XCTAssertEqual(valuables[0]["name"] as? String,
                       "Murmur_0.1.7_aarch64.dmg")
        let token = try XCTUnwrap(
            refused["acknowledgement_token"] as? String,
            "the documented token rides the SAME envelope — never parsed "
                + "out of the message"
        )
        XCTAssertTrue(CLIHandler.isAcknowledgementToken(token),
                      "64 lowercase hex, exactly as documented: \(token)")
        XCTAssertTrue(fm.fileExists(atPath: artifact.path),
                      "the refusal deleted NOTHING")

        // STEP 2 — the documented re-run, with the entry composed exactly as
        // the docs spell it: `<scanner-slug>:<item-id>:<token>`.
        let entry = "\(target):\(token)"
        guard case .success(let payload) = await clean(
            deps, targets: [target], acknowledgements: [entry]
        ) else {
            return XCTFail("the acknowledged retry must succeed")
        }
        let rows = try XCTUnwrap(payload["results"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["success"] as? Bool, true)
        XCTAssertNil(rows[0]["acknowledgement_token"],
                     "a success row carries no refusal fields")
        XCTAssertFalse(fm.fileExists(atPath: artifact.path),
                       "the acknowledged retry deletes the artifact dir")
    }

    /// The SAME two keys on the OTHER arm: a mixed run where one item is
    /// refused and another is cleaned stays a process-level success, and the
    /// refusal row on stdout carries exactly what `CLEAN_FAILED` carried.
    func testDocumentedRefusalKeysRideThePartialSuccessArmToo() async throws {
        let dev = base.appendingPathComponent("dev")
        let disclosing = try makeRustProject(
            "rustapp", in: dev, valuable: "Murmur_0.1.7_aarch64.dmg"
        )
        let plain = try makeRustProject("plainapp", in: dev)
        let deps = try makeDeps(devRoots: [dev])

        guard case .success(let payload) = await clean(
            deps, targets: [scannerID]
        ) else {
            return XCTFail("a PARTIAL clean stays a process-level success")
        }
        let rows = try XCTUnwrap(payload["results"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 2, "one row per resolved item")

        // Both artifact dirs are named `target` — rows are keyed by the
        // COMPOSITE address, never the display name.
        let refused = try XCTUnwrap(
            rows.first { $0["category"] as? String == address(for: disclosing) },
            "no row for the disclosing item"
        )
        let cleaned = try XCTUnwrap(
            rows.first { $0["category"] as? String == address(for: plain) },
            "no row for the plain item"
        )
        XCTAssertEqual(cleaned["success"] as? Bool, true)
        XCTAssertEqual(refused["success"] as? Bool, false,
                       "one row per item; the disclosing one is refused")
        XCTAssertNotNil(refused["valuables"])
        XCTAssertNotNil(refused["acknowledgement_token"])
        XCTAssertTrue(fm.fileExists(atPath: disclosing.path))

        // …and the plain item was still cleaned in the same invocation.
        XCTAssertFalse(fm.fileExists(atPath: plain.path),
                       "an unrelated item in the same run still deletes")
    }
}

// MARK: - Documented refusals at the process boundary

/// fn-4.7 (R17/R6) — the documented refusals at the PROCESS boundary, using
/// the house subprocess harness (`CLIGateFramingTests` precedent). Every
/// invocation here is one the documentation describes as a REFUSAL, so the
/// suite is read-only by construction: nothing can be deleted even when
/// `--confirm` is present, because the refusal happens pre-dispatch.
final class DocumentedCLIFramingTests: XCTestCase {

    private struct CLIRun {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private var productsDirectory: URL {
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            return bundle.bundleURL.deletingLastPathComponent()
        }
        preconditionFailure(
            "cannot locate the build-products directory from the XCTest bundles"
        )
    }

    private func runCLI(
        _ arguments: [String], timeout: TimeInterval = 300
    ) throws -> CLIRun {
        let binary = productsDirectory.appendingPathComponent("Cacheout")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            XCTFail("Cacheout executable missing at \(binary.path)")
            throw XCTSkip("executable not built")
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()

        var stdoutData = Data()
        var stderrData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let watchdog = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        process.waitUntilExit()
        watchdog.cancel()
        group.wait()

        return CLIRun(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    private func errorEnvelope(
        _ run: CLIRun, file: StaticString = #filePath, line: UInt = #line
    ) throws -> [String: Any] {
        let data = try XCTUnwrap(run.stderr.data(using: .utf8), file: file, line: line)
        let json = try JSONSerialization.jsonObject(with: data)
        let envelope = try XCTUnwrap(json as? [String: Any],
                                     "stderr is not JSON: \(run.stderr.prefix(400))",
                                     file: file, line: line)
        return try XCTUnwrap(envelope["error"] as? [String: Any],
                             file: file, line: line)
    }

    /// CLI-REFERENCE states the retired `node_modules` slug is an unknown
    /// target. Proven at the process boundary, in every documented address
    /// form.
    func testRetiredNodeModulesSlugIsRefusedAsAnUnknownTargetFraming() throws {
        for target in [
            "node_modules",
            "node_modules:" + String(repeating: "0", count: 64),
        ] {
            let run = try runCLI(["--cli", "clean", target, "--confirm"])
            XCTAssertEqual(run.exitCode, 1, "'\(target)' must be refused")
            XCTAssertEqual(run.stdout, "",
                           "stdout stays EMPTY — no plan, no results")
            let error = try errorEnvelope(run)
            XCTAssertEqual(error["code"] as? String, "INVALID_ARGUMENTS",
                           "the retired slug is an unknown target")
        }
    }

    /// PROTOCOL.md and CLI-REFERENCE both say `--acknowledge-valuables` is
    /// accepted by `clean` ONLY and refused PRE-DISPATCH elsewhere, naming
    /// the flag. Read-only commands only, so a gate regression stays
    /// side-effect-free.
    func testAcknowledgeFlagIsCleanOnlyAtTheProcessBoundaryFraming() throws {
        let entry = "build_artifacts:"
            + String(repeating: "a", count: 64) + ":"
            + String(repeating: "b", count: 64)
        for command in ["version", "disk-info", "memory-stats", "scan"] {
            let run = try runCLI([
                "--cli", command, CLIHandler.acknowledgeValuablesFlag, entry,
            ])
            XCTAssertEqual(run.exitCode, 1, "\(command) must refuse the flag")
            XCTAssertEqual(run.stdout, "",
                           "stdout stays EMPTY when refused: \(command)")
            let error = try errorEnvelope(run)
            XCTAssertEqual(error["code"] as? String, "INVALID_ARGUMENTS")
            let message = (error["message"] as? String) ?? ""
            XCTAssertTrue(message.contains(CLIHandler.acknowledgeValuablesFlag),
                          "the refusal names the flag: \(message)")
            XCTAssertTrue(message.contains(command),
                          "the refusal names the command: \(message)")
            XCTAssertTrue(message.contains("clean"),
                          "it points at the command that accepts it: \(message)")
        }
    }

    /// A trailing `--acknowledge-valuables` collects no value. Treating that
    /// like an ABSENT flag would run an UNACKNOWLEDGED clean while the caller
    /// believes they authorized one — so it is refused BEFORE dispatch,
    /// exactly as a bare `--dev-root` is (review r1). `--confirm` is present
    /// on purpose: the refusal must beat the destructive path.
    func testBareAcknowledgeFlagIsRefusedInsteadOfSilentlyUnacknowledgedFraming()
        throws
    {
        let run = try runCLI([
            "--cli", "clean", "npm_cache", "--confirm",
            CLIHandler.acknowledgeValuablesFlag,
        ])
        XCTAssertEqual(run.exitCode, 1, "a valueless entry must be refused")
        XCTAssertEqual(run.stdout, "",
                       "stdout stays EMPTY — no results, nothing deleted")
        let error = try errorEnvelope(run)
        XCTAssertEqual(error["code"] as? String, "INVALID_ARGUMENTS")
        let message = (error["message"] as? String) ?? ""
        XCTAssertTrue(message.contains(CLIHandler.acknowledgeValuablesFlag),
                      "names the flag: \(message)")
        XCTAssertTrue(message.contains("requires an entry"),
                      "says what is missing: \(message)")
        XCTAssertTrue(message.contains("Nothing was cleaned"),
                      "states the fail-fast outcome: \(message)")
    }

    /// The documented "Argument ordering" rule: targets come BEFORE flags,
    /// and a positional after a flag is a NAMED usage error rather than a
    /// silent drop.
    func testDocumentedArgumentOrderingRuleHoldsAtTheProcessBoundaryFraming()
        throws
    {
        let run = try runCLI(["--cli", "clean", "--confirm", "npm_cache"])
        XCTAssertEqual(run.exitCode, 1, "a positional after a flag is refused")
        XCTAssertEqual(run.stdout, "")
        let error = try errorEnvelope(run)
        XCTAssertEqual(error["code"] as? String, "INVALID_ARGUMENTS")
        let message = (error["message"] as? String) ?? ""
        XCTAssertTrue(message.contains("npm_cache"),
                      "the refusal names the misplaced token: \(message)")
        XCTAssertTrue(message.contains("BEFORE"),
                      "…and states the rule: \(message)")
    }

    /// The documented tolerance the MCP consumer depends on: a trailing
    /// `--format json` is a VALUED flag, so its value is never mistaken for
    /// a positional and the invocation keeps its meaning.
    func testDocumentedTrailingFormatJSONToleranceFraming() throws {
        let run = try runCLI(["--cli", "clean", "npm_cache", "--format", "json"])
        XCTAssertEqual(run.exitCode, 1, "still the ordinary confirm gate")
        XCTAssertEqual(run.stdout, "")
        let error = try errorEnvelope(run)
        XCTAssertEqual(error["code"] as? String, "CONFIRMATION_REQUIRED",
                       "the trailing --format json value is consumed as a "
                        + "flag VALUE, never parsed as a stray target")
    }
}
