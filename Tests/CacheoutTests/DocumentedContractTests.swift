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
    /// project.yml). They must describe the scanner that actually walks the
    /// protected roots — after fn-4.7 that is `build_artifacts`, not the
    /// retired node_modules scanner — and the three copies must agree, since
    /// a drifting one ships silently in whichever build path used it.
    func testShippedTCCUsageStringsDescribeTheLiveScannerAndStayInSync()
        throws
    {
        let sources = [
            "Sources/Cacheout/Info.plist",
            "project.yml",
            "scripts/bundle.sh",
        ]
        let documents = "Cacheout looks for developer build-artifact folders "
            + "(target/, node_modules/, .venv/ and similar) in Documents "
            + "during scans you start. Nothing is deleted without your "
            + "confirmation."
        let desktop = "Cacheout looks for developer build-artifact folders "
            + "(target/, node_modules/, .venv/ and similar) on your Desktop "
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
        // HAND-MAINTAINED, not `CaseIterable` (noted PR #459 review r2):
        // `ScanIssue.Kind` carries associated-value-free cases but does not
        // conform, so a kind added without touching THIS array ships
        // undocumented with a green suite. Extend both together. The
        // documented taxonomy is EXTENSIBLE by contract — that is about
        // CONSUMERS tolerating unknown kinds, not about this list being
        // allowed to lag.
        let allKinds: [ScanIssue.Kind] = [
            .containerRefused, .mountedVolumeRoot, .policyRefusedRoot,
            .symlinkRoot, .nonDirectoryRoot, .tccDenied,
            .permissionDenied,
            .unreadable, .enumerationTruncated, .configInvalid,
            .malformedOutcome,
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
        for kind in ["malformed_outcome", "config_invalid"] {
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

    // MARK: - Scanner-threshold flags as documented (fn-6.4, R7/R10)

    /// Both documents publish the `--tmp-*` flag SPELLINGS, their
    /// scan/clean-only gating, and their DEFAULTS. Each claim is checked
    /// against the binary that has to honour it — a doc that names a flag the
    /// gate does not know, or a default the config does not use, fails here.
    func testDocumentedTempThresholdFlagsMatchTheGateAndTheDefaults() throws {
        let flags = [CLIHandler.tmpAgeDaysFlag, CLIHandler.tmpMinSizeMBFlag]
        XCTAssertEqual(flags, ["--tmp-age-days", "--tmp-min-size-mb"],
                       "the documented flag spellings are frozen")

        for (name, text) in [
            ("PROTOCOL.md", try protocolDoc()),
            ("CLI-REFERENCE.md", try cliReference()),
        ] {
            for flag in flags {
                XCTAssertTrue(text.contains("`\(flag) N`"),
                              "\(name) must publish `\(flag) N`")
            }
            XCTAssertTrue(text.contains("cacheout.ephemeralTmp"),
                          "\(name) must name the persisted keys the flags override")
        }

        // The documented gating is the real gating: scan/clean accept, every
        // other command refuses pre-dispatch.
        for command in CLIHandler.Command.allCases {
            for flag in flags {
                let rejected = CLIHandler.rejectedFlag(
                    for: command, in: [flag, "3"]
                )?.flag
                if command == .scan || command == .clean {
                    XCTAssertNil(rejected, "\(command.rawValue) accepts \(flag)")
                } else {
                    XCTAssertEqual(rejected, flag,
                                   "\(command.rawValue) must refuse \(flag)")
                }
            }
        }

        // The documented defaults are the shipped constants.
        XCTAssertEqual(EphemeralTempSweepConfig.defaultAgeDays, 7)
        XCTAssertEqual(EphemeralTempSweepConfig.defaultMinSizeMB, 10)
        let cli = try cliReference()
        XCTAssertTrue(cli.contains("`cacheout.ephemeralTmp.ageDays`, never persisted. Default 7"),
                      "CLI-REFERENCE must publish the 7-day default")
        XCTAssertTrue(cli.contains("`cacheout.ephemeralTmp.minSizeMB`, never persisted. Default 10"),
                      "CLI-REFERENCE must publish the 10 MB default")

        // Both are VALUED flags in the one grammar, exactly as documented in
        // the argument-ordering rule.
        for flag in flags {
            XCTAssertTrue(CLIHandler.valuedFlags.contains(flag))
            for (name, text) in [
                ("PROTOCOL.md", try protocolDoc()),
                ("CLI-REFERENCE.md", try cliReference()),
            ] {
                XCTAssertTrue(text.contains("`\(flag)`"),
                              "\(name) must list \(flag) among the valued flags")
            }
        }
    }

    /// The TRIGGER POLICY is user-visible documentation, not an
    /// implementation note: CATEGORIES tells users background refreshes never
    /// include the temp locations, CLI-REFERENCE tells them a CLI scan always
    /// does. The binary half of the claim (zero enumeration on `.automatic`)
    /// is pinned in the scanner and registration suites.
    func testDocumentedEphemeralTempTriggerPolicyIsUserVisible() throws {
        let categories = try document("docs/v1/CATEGORIES.md")
        XCTAssertTrue(categories.contains("ephemeral_tmp"),
                      "CATEGORIES must name the scanner slug")
        XCTAssertTrue(
            categories.contains("Scanned only when YOU ask"),
            "CATEGORIES must state the trigger policy in the user's terms"
        )
        XCTAssertTrue(
            categories.lowercased().contains("automatic background\nrefreshes")
                || categories.lowercased().contains("automatic background refreshes"),
            "…and say that automatic background refreshes never include it"
        )
        XCTAssertTrue(categories.contains("never include it, for any root"),
                      "…in words a user can act on")

        let cli = try cliReference()
        XCTAssertTrue(cli.contains("always an explicit user act"),
                      "CLI-REFERENCE must state CLI scans are user-initiated")
        XCTAssertTrue(cli.contains("`ephemeral_tmp`"),
                      "…and name the scanner that follows from it")
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

    /// PROTOCOL.md and CLI-REFERENCE both say the scanner-threshold flags are
    /// accepted by `scan`/`clean` ONLY and refused PRE-DISPATCH elsewhere,
    /// naming the flag. Proven at the process boundary on READ-ONLY commands,
    /// so a gate regression stays side-effect-free.
    func testTempThresholdFlagsAreScanCleanOnlyAtTheProcessBoundaryFraming()
        throws
    {
        for command in ["version", "disk-info", "memory-stats", "smart-clean"] {
            for flag in [CLIHandler.tmpAgeDaysFlag, CLIHandler.tmpMinSizeMBFlag] {
                let run = try runCLI(["--cli", command, flag, "3"])
                XCTAssertEqual(run.exitCode, 1, "\(command) must refuse \(flag)")
                XCTAssertEqual(run.stdout, "",
                               "stdout stays EMPTY when refused: \(command)")
                let error = try errorEnvelope(run)
                XCTAssertEqual(error["code"] as? String, "INVALID_ARGUMENTS",
                               "the only code a threshold refusal produces")
                let message = (error["message"] as? String) ?? ""
                XCTAssertTrue(message.contains(flag),
                              "the refusal names the flag: \(message)")
                XCTAssertTrue(message.contains(command),
                              "…the refusing command: \(message)")
                XCTAssertTrue(message.contains("scan or clean"),
                              "…and where the flag belongs: \(message)")
            }
        }
    }

    /// A threshold flag written LAST collects no value. Reading that as an
    /// ABSENT flag would scan with the PERSISTED thresholds the caller meant
    /// to override — so it is refused, and refused BEFORE the runtime is even
    /// composed (which is why this cell can name `scan` without walking a
    /// single temp root).
    func testTrailingTempThresholdFlagIsRefusedBeforeAnyScanFraming() throws {
        for flag in [CLIHandler.tmpAgeDaysFlag, CLIHandler.tmpMinSizeMBFlag] {
            let run = try runCLI(["--cli", "scan", flag])
            XCTAssertEqual(run.exitCode, 1,
                           "a valueless \(flag) must be refused")
            XCTAssertEqual(run.stdout, "",
                           "stdout stays EMPTY — nothing was scanned")
            let error = try errorEnvelope(run)
            XCTAssertEqual(error["code"] as? String, "INVALID_ARGUMENTS")
            let message = (error["message"] as? String) ?? ""
            XCTAssertTrue(message.contains(flag),
                          "names the flag: \(message)")
            XCTAssertTrue(message.contains("positive integer"),
                          "says what was missing: \(message)")
        }
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
