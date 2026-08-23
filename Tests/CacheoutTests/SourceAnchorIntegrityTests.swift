import XCTest

/// # Anchors rot silently, and this branch shipped that three times
///
/// A comment that cites `Some.swift` at lines 1452-1456 is a claim about a
/// LINE NUMBER, and a line number is invalidated by any edit ABOVE it in the
/// cited file — an edit that touches neither the comment nor anything it
/// is about. Nothing then reads wrong: the anchor still names a real file
/// and a real line, and the reader lands on plausible neighbouring text.
///
/// MEASURED on this branch (PR #460 codex r8, D2). `2d2ad5e` ("repoint 17
/// anchors") set 16 anchors against `SpaceScanner.swift` as it stood there;
/// `26c880b` then added a net +12 lines above them and nothing re-verified.
/// By `git show <commit>:Sources/Cacheout/Scanner/SpaceScanner.swift`:
/// `static func stableID` 784 → 796, `static func production(` 1589 → 1601,
/// `private static func suppressingAliasShadows` 1447 → 1459. One of them,
/// the one at 1462-1465, had drifted onto DIFFERENT prose that still reads
/// like a citation — the failure mode this file exists to make impossible.
///
/// Auditing the rest at r8 found the same rot in anchors this PR never
/// touched. In `DirectorySizer`, lines 202 and 205 were cited by 5 sites
/// between them and are BLANK LINES. In `CacheoutViewModel`, the range
/// 483-499 was cited as `CacheoutViewModel.production`, which sits at 533,
/// and line 489 was cited as a non-optional `DevRootsResolution` and is the
/// doc line `///   source.`. In `ProjectTreeWalker`, line 376 is a bare `}`;
/// in `PathGuard`, line 357 is a bare `)`. And one anchor named
/// `NodeModulesScanner`, a file that no longer exists — its predicate now
/// lives in `BuildArtifactsScanner.publishedLogicalBytes`. All are repointed
/// in the same commit as this file.
///
/// ## The check
///
/// Every `<Name>.swift` followed by `:N` or `:N-M`, written inside a comment
/// anywhere under `Sources/` or `Tests/`, must:
///
/// 1. name a file that exists, exactly once, under `Sources/` or `Tests/`;
/// 2. cite a line range that file actually has;
/// 3. appear in `anchorExpectations` — DEFAULT-DENY, so a new anchor is a
///    build-out-of-the-box failure until its author states what it points at;
/// 4. and the pinned excerpt must appear somewhere inside the cited range.
///
/// The excerpt is the point. Pinning only "the file has that many lines"
/// would have passed every one of the shifted anchors above.
///
/// ## Two counts in the commit that introduced this check are off by one
///
/// Recorded here because a commit message cannot be corrected in place
/// (PR #460 codex r9, D5). Both were re-derived over `git archive 27782c0`
/// with this file's OWN regex and comment rule.
///
/// - "(52 distinct anchors, 73 citing sites)" — `27782c0` has 52 anchors and
///   **72** citing sites. 73 is the site count at its PARENT `aaf9c03`,
///   where the distinct count is 57, so the parenthetical pairs a post-fix
///   number with a pre-fix one.
/// - "naming all seven affected anchors and all fifteen citing sites" —
///   reproducing that exact mutation (12 blank lines inserted at
///   `SpaceScanner.swift` line 701 in a `27782c0` checkout) the check reports
///   7 anchors and **14** citing sites. Seven was right.
///
/// Neither figure is restated for HEAD, and deliberately: the cells below
/// are DEFAULT-DENY on a table, so nothing here needs a count to be correct,
/// and a count in this header would be one more number to go stale.
///
/// ## What this does NOT cover, stated rather than implied
///
/// - **Only comments.** The scanner requires a `//` earlier on the line, so
///   an anchor inside a string literal is invisible. None exists.
/// - **The excerpt, not the MEANING.** It proves the cited range still holds
///   the text r8 verified it held; it cannot prove that text is what the
///   citing sentence claims. That judgement was made once, by hand, at r8 —
///   and pinning it is what makes a future drift a failing cell instead of a
///   reader's wrong turn.
/// - **A moved anchor is a FAILING cell, not an auto-fix.** Repointing means
///   re-reading the citing sentence, which is the work the three shipped
///   shifts skipped.
/// - **Markdown line-anchors are not checked AGAINST HEAD, and the reason is
///   not that there are none** (PR #460 codex r9, D3). r8 wrote that
///   `SCANNERS-ROADMAP.md` and `CHANGELOG.md` "cite by SYMBOL, not by line";
///   `CHANGELOG.md` does, `SCANNERS-ROADMAP.md` does not — six rows of its
///   D1-D8 defect table cite lines, which
///   `grep -rnE '([A-Za-z][A-Za-z0-9_]*\.swift):([0-9]+)' --include='*.md' .`
///   prints. Checking them against HEAD would be a CATEGORY ERROR: that
///   document is a dated snapshot, "Anchored to v2.1.9, commit `d747412`",
///   and it says so in its own third line — its line numbers are `d747412`'s
///   and are MEANT to be read with `git show d747412:<path>`. One of them
///   names `NodeModulesScanner.swift`, which existed at `d747412`
///   (`git ls-tree -r --name-only d747412 | grep -i nodemodules` prints it)
///   and does not exist now.
///
///   So the rule Markdown gets is the one that fits it, and it is CHECKED
///   rather than described: `testMarkdownLineAnchorsAreDatedAndTheirFilesAccountedFor`
///   requires every `.md` that cites a Swift LINE to declare the commit those
///   lines were verified at in its opening lines, and requires every
///   `.swift` file it cites by line either to exist today or to be listed in
///   `retiredMarkdownAnchorTargets` with where it went.
final class SourceAnchorIntegrityTests: XCTestCase {

    /// `File.swift:N` or `File.swift:N-M`.
    static let anchorPattern =
        #"([A-Za-z][A-Za-z0-9_]*\.swift):(\d+)(?:\s*-\s*(\d+))?"#

    /// Every anchor in the tree, with a fragment of the text it cites.
    /// Sorted; one entry per DISTINCT anchor however many places cite it.
    static let anchorExpectations: [(anchor: String, excerpt: String)] = [
        ("BuildArtifactsScanner.swift:1405-1406",
         "deletable && report.logicalBytes > report.measur"),
        ("BuildArtifactsScanner.swift:378-382",
         "this walk's per-root classified issues. Candidat"),
        ("CLIHandler.swift:206",
         "orphanedCachesThresholds: sweepThresholds, devRo"),
        ("CLIHandler.swift:2123",
         "One invocation, one session (R9): the cleaner ho"),
        ("CLIHandler.swift:426-438",
         "orphanedCachesThresholds: OrphanedCacheClassifie"),
        ("CacheCleaner.swift:514",
         "if let entry = outcome.entry { entries.append(en"),
        ("CacheoutApp.swift:58",
         "@StateObject private var viewModel = CacheoutVie"),
        ("CacheoutViewModel.swift:1487-1488",
         "never report (the runtime invokes only the named"),
        ("CacheoutViewModel.swift:264",
         "@MainActor"),
        ("CacheoutViewModel.swift:555-574",
         "static func production("),
        ("CacheoutViewModel.swift:563",
         ".production(home: home, provider: provider, devR"),
        ("CacheoutViewModel.swift:610-614",
         "private func isBlockedFromDestructivePaths(_ sca"),
        ("ContentView.swift:203-208",
         "ForEach(viewModel.perItemSections) { section in"),
        ("DepthSafeRemoval.swift:641-878",
         "private static func removeTree("),
        ("DevRootsStore.swift:28-38",
         "walker's `originRoot` carry these verbatim; vali"),
        ("DevRootsStore.swift:320-324",
         "isDirectory: provider.probeKind(of: declared) =="),
        ("DevRootsStore.swift:322",
         "key: provider.canonicalize(declared).path,"),
        ("DevRootsStore.swift:326-332",
         "of it — and an ACTIVELY HARMFUL one: `PathGuard."),
        ("DevRootsStore.swift:333-335",
         "let coveredByRealDirectory = Set("),
        ("DevRootsStore.swift:349-355",
         "issues.append(ScanIssue("),
        ("DirectorySizer.swift:261-272",
         "provider.isMountPoint(resolved)"),
        ("DirectorySizer.swift:354-359",
         "provider.isMountPoint(itemURL)"),
        ("DirectorySizer.swift:483",
         "case .some(Int(EPERM)):"),
        ("DirectorySizer.swift:50-52",
         "- `.scanRoot`: the root is fully resolved via th"),
        ("EphemeralTempScanner.swift:1579-1583",
         "Never followed; neither carries content of its o"),
        ("EphemeralTempScanner.swift:771-777",
         "kind: kind == .symlink ? .symlinkRoot : .nonDire"),
        ("EphemeralTempScannerTests.swift:2973-2975",
         "detail.contains("),
        ("FileSystemIdentityProvider.swift:143",
         "guard !blocksOverflow, allocated >= 0 else { ret"),
        ("FileSystemIdentityProvider.swift:292-296",
         "case S_IFREG: return .kind(.regularFile)"),
        ("MemlimitWorkaround.swift:187",
         "return (false, \"memorystatus_control_hwm_failed:"),
        ("OrphanedCachesScanner.swift:1387-1691",
         "static func boundedUserDataShapeWalk("),
        ("OrphanedCachesScanner.swift:193",
         "#458 review r9). It is the single IRREDUCIBLE cl"),
        ("OrphanedCachesScanner.swift:230-233",
         "tree is still unmeasurable and still lands at re"),
        ("OrphanedCachesScanner.swift:2397-2403",
         "A failed read mid-directory: the rest is unprove"),
        ("PathGuard.swift:165-176",
         "refuses non-directory containers, so a link iden"),
        ("PathGuard.swift:350-361",
         "throw PathGuardError.outsideCategoryPolicy(path:"),
        ("PathGuard.swift:370",
         "`~/Documents` can be a container while `admitDel"),
        ("PathGuard.swift:400-403",
         "(2) No-follow reality gate on BOTH spellings: th"),
        ("PathGuard.swift:45",
         "compared as `pathComponents` arrays (never `hasP"),
        ("PathGuard.swift:462-469",
         "The filesystem root `/` is exempt from both: it"),
        ("ProjectTreeWalker.swift:529-532",
         "|| provider.isMountPoint(provider.canonicalize(c"),
        ("SpaceScanner.swift:1941-1952",
         "no-follow reality gate to THAT spelling and refu"),
        ("SpaceScanner.swift:143",
         "`[\"git\", \"-C\", <parentRepoWorkingDir>, \"worktree"),
        ("SpaceScanner.swift:1981-1986",
         "Nothing is silently lost: a dropped root is unus"),
        ("SpaceScanner.swift:1987-1989",
         "private static func suppressingAliasShadows("),
        ("SpaceScanner.swift:1964-2004",
         "private static func suppressingAliasShadows("),
        ("SpaceScanner.swift:1992-1996",
         "let probed = roots.map { root in"),
        ("SpaceScanner.swift:2002-2005",
         "Two real-directory spellings of one location are"),
        ("SpaceScanner.swift:2129",
         "static func production("),
        ("SpaceScanner.swift:40-51",
         "(Documents, Desktop, …) are enumerated ONLY for"),
        ("SpaceScanner.swift:796",
         "static func stableID(scannerID: String, canonica"),
        ("SysctlJournal.swift:192",
         "state.entries.append(entry)"),
        ("ValuablesDetector.swift:1754-1756",
         "is the only discriminator, so it is cleared before ea"),
        ("WorktreeReclaimPerformer.swift:832-844",
         "let appeared = ignoredNow.subtracting(ignoredWitne"),
    ]

    // MARK: - The walk

    /// The repository root: this file is `Tests/CacheoutTests/<name>.swift`.
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/CacheoutTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo>
    }

    /// Every `.swift` file under `Sources/` and `Tests/`, in a stable order.
    private func swiftSources() throws -> [URL] {
        var files: [URL] = []
        for directory in ["Sources", "Tests"] {
            let root = repositoryRoot.appendingPathComponent(directory)
            let walker = try XCTUnwrap(
                FileManager.default.enumerator(
                    at: root, includingPropertiesForKeys: nil
                ),
                "\(directory)/ could not be enumerated at \(root.path)"
            )
            for case let url as URL in walker where url.pathExtension == "swift" {
                files.append(url)
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    /// `anchor -> [citing site]`, read from comment text only.
    private func anchorSites() throws -> [String: [String]] {
        guard let regex = try? NSRegularExpression(
            pattern: Self.anchorPattern
        ) else { return [:] }
        var sites: [String: [String]] = [:]
        for file in try swiftSources() {
            let source = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in source.split(
                separator: "\n", omittingEmptySubsequences: false
            ).enumerated() {
                guard let comment = line.range(of: "//") else { continue }
                let text = String(line[comment.lowerBound...])
                let full = NSRange(text.startIndex..., in: text)
                for match in regex.matches(in: text, range: full) {
                    guard let range = Range(match.range, in: text) else {
                        continue
                    }
                    sites[String(text[range]), default: []].append(
                        "\(file.lastPathComponent):\(number + 1)"
                    )
                }
            }
        }
        return sites
    }

    func testEverySourceAnchorStillPointsAtWhatItCites() throws {
        let sources = try swiftSources()
        var byName: [String: [URL]] = [:]
        for file in sources {
            byName[file.lastPathComponent, default: []].append(file)
        }
        let expectations = XCTUniquelyKeyed(
            Self.anchorExpectations.map { ($0.anchor, $0.excerpt) }
        )
        let sites = try anchorSites()
        var offenders: [String] = []

        for anchor in sites.keys.sorted() {
            let where_ = sites[anchor]?.sorted().joined(separator: ", ") ?? ""
            // No subscripts anywhere below: `StrandFenceTests` reads this
            // file too, and it reported this very block at r8 before the
            // rewrite.
            let parts = anchor.split(separator: ":").map(String.init)
            guard parts.count == 2, let name = parts.first,
                  let citedLines = parts.last
            else {
                offenders.append("\(anchor) (\(where_)): unparsable")
                continue
            }
            let numbers = citedLines.split(separator: "-").compactMap {
                Int($0.trimmingCharacters(in: .whitespaces))
            }
            guard let low = numbers.first, let high = numbers.last else {
                offenders.append("\(anchor) (\(where_)): unparsable")
                continue
            }
            guard let targets = byName[name], targets.count == 1,
                  let target = targets.first
            else {
                offenders.append(
                    "\(anchor) (\(where_)): names \(byName[name]?.count ?? 0) "
                        + "files under Sources/ and Tests/"
                )
                continue
            }
            let lines = try String(contentsOf: target, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
            guard low >= 1, high >= low, high <= lines.count else {
                offenders.append(
                    "\(anchor) (\(where_)): the file has \(lines.count) lines"
                )
                continue
            }
            guard let excerpt = expectations[anchor] else {
                offenders.append(
                    "\(anchor) (\(where_)): no entry in anchorExpectations — "
                        + "state what this anchor points at"
                )
                continue
            }
            let cited = lines[(low - 1)..<high].joined(separator: "\n")
            if !cited.contains(excerpt) {
                offenders.append(
                    "\(anchor) (\(where_)): the cited range no longer contains "
                        + "\(excerpt.debugDescription) — it now reads "
                        + "\(cited.prefix(160).debugDescription)"
                )
            }
        }

        XCTAssertGreaterThan(
            sources.count, 80,
            "the check must actually have read the tree, not an empty listing"
        )
        XCTAssertGreaterThan(
            sites.count, 40,
            "the check must actually have found anchors, not zero of them"
        )
        XCTAssertEqual(
            offenders, [],
            "an anchor whose cited line no longer holds what the comment says "
                + "sends every future reader to the wrong place, and nothing "
                + "else in the build looks at it. Re-read the citing sentence, "
                + "repoint the anchor, and update anchorExpectations."
        )
    }

    /// The table's own rot check: an entry for an anchor nobody cites any more
    /// is a pin on text no comment depends on, and it hides the fact that the
    /// citation was deleted.
    func testTheAnchorTableCarriesNoEntryNobodyCites() throws {
        let cited = Set(try anchorSites().keys)
        let listed = Self.anchorExpectations.map(\.anchor)
        XCTAssertEqual(
            listed.count, Set(listed).count,
            "anchorExpectations has a duplicate anchor"
        )
        XCTAssertEqual(
            listed.filter { !cited.contains($0) }, [],
            "anchorExpectations lists anchors no comment cites any more"
        )
    }

    // MARK: - Markdown line-anchors (PR #460 codex r9, D3)

    /// `.swift` files cited BY LINE from Markdown that no longer exist in the
    /// tree. A Markdown line-anchor is read against the commit its document
    /// declares, not against HEAD, so a retired file is not by itself a
    /// defect — an UNACCOUNTED one is, because the reader has no way to tell
    /// "deleted, and here is where it went" from "this citation rotted".
    static let retiredMarkdownAnchorTargets: [(file: String, whereItWent: String)] = [
        ("NodeModulesScanner.swift",
         "retired before this branch, together with the `node_modules` "
             + "scanner slug (CHANGELOG.md, [Unreleased], PRE-RELEASE "
             + "RENAME); per-project node_modules is now scanned by "
             + "`BuildArtifactsScanner`. SCANNERS-ROADMAP.md rows D3 and D6 "
             + "cite it at `d747412`, where it existed: "
             + "`git show d747412:Sources/Cacheout/Scanner/NodeModulesScanner.swift`"),
    ]

    /// Every Markdown file in the repository, excluding build products.
    private func markdownDocuments() throws -> [URL] {
        var files: [URL] = []
        let walker = try XCTUnwrap(
            FileManager.default.enumerator(
                at: repositoryRoot, includingPropertiesForKeys: nil
            ),
            "the repository root could not be enumerated"
        )
        for case let url as URL in walker {
            let name = url.lastPathComponent
            if name == ".build" || name == ".git" {
                walker.skipDescendants()
                continue
            }
            if url.pathExtension == "md" { files.append(url) }
        }
        return files.sorted { $0.path < $1.path }
    }

    func testMarkdownLineAnchorsAreDatedAndTheirFilesAccountedFor() throws {
        guard let anchors = try? NSRegularExpression(
            pattern: Self.anchorPattern
        ) else { return XCTFail("the anchor pattern does not compile") }
        // A DOCUMENT-LEVEL declaration, so it has to sit in the opening
        // lines: `CHANGELOG.md` mentions a commit hundreds of lines down in
        // the body, and that is a sentence about one entry, not a statement
        // about how to read the whole file.
        let pin = #"commit `[0-9a-f]{7,40}`"#
        let retired = Set(Self.retiredMarkdownAnchorTargets.map(\.file))
        let live = Set(try swiftSources().map(\.lastPathComponent))

        var scanned = 0
        var citing = 0
        var offenders: [String] = []
        for document in try markdownDocuments() {
            scanned += 1
            let text = try String(contentsOf: document, encoding: .utf8)
            let lines = text.split(
                separator: "\n", omittingEmptySubsequences: false
            )
            var cited: Set<String> = []
            let full = NSRange(text.startIndex..., in: text)
            for match in anchors.matches(in: text, range: full) {
                guard match.numberOfRanges > 1,
                      let range = Range(match.range(at: 1), in: text)
                else { continue }
                cited.insert(String(text[range]))
            }
            guard !cited.isEmpty else { continue }
            citing += 1
            let opening = lines.prefix(10).joined(separator: "\n")
            if opening.range(of: pin, options: .regularExpression) == nil {
                offenders.append(
                    "\(document.lastPathComponent): cites "
                        + "\(cited.sorted().joined(separator: ", ")) by LINE "
                        + "but its opening lines declare no commit those "
                        + "lines were verified at"
                )
            }
            for name in cited.sorted()
            where !live.contains(name) && !retired.contains(name) {
                offenders.append(
                    "\(document.lastPathComponent): cites \(name) by LINE and "
                        + "no such file exists under Sources/ or Tests/ — say "
                        + "where it went in retiredMarkdownAnchorTargets"
                )
            }
        }

        XCTAssertGreaterThan(
            scanned, 3,
            "the check must actually have read the repository's Markdown"
        )
        XCTAssertGreaterThan(
            citing, 0,
            "the check must actually have found a Markdown line-anchor — if "
                + "the last one is genuinely gone, delete this cell rather "
                + "than leave it passing vacuously"
        )
        XCTAssertEqual(
            offenders, [],
            "a Markdown line-anchor is read against the commit its document "
                + "declares. Undeclared, a reader checks it against HEAD and "
                + "lands on unrelated text; unaccounted, a deleted file reads "
                + "as a rotted citation."
        )
    }

    /// `retiredMarkdownAnchorTargets`' own rot check: a name that exists
    /// again would silently exempt a live file.
    func testTheRetiredMarkdownAnchorListIsExactlyWhatItClaims() throws {
        let live = Set(try swiftSources().map(\.lastPathComponent))
        XCTAssertEqual(
            Self.retiredMarkdownAnchorTargets.map(\.file).filter(live.contains),
            [],
            "a retired anchor target that exists again must leave the list"
        )
    }

    // MARK: - Cited cell names (PR #460 codex r8, D3)

    /// Cell names cited in a comment that no `func` declares — because the
    /// cell was renamed, because it was deleted, or because it NEVER EXISTED
    /// and the citation is this branch's record of that defect. Each carries
    /// the reason the citation is still honest; anything NOT listed here must
    /// be a real `func`.
    ///
    /// The defect this closes: r7's own headline guard
    /// (`WorktreeReclaimPerformer.swift`, the `removeTree` seam) named
    /// `testThePermanentProofAndTheRemovalAreNotSeparatedByTheHop` and
    /// `testThePermanentArmRefusesAWorktreeSwappedInsideTheHop`. Neither has
    /// ever existed — `grep -rn 'func <name>' Tests` returned 0 for both —
    /// and a reader checking the guard's evidence finds nothing, which reads
    /// as evidence that was deleted. Two more of the same shape predate this
    /// PR and are corrected in the same commit: a cell claiming to pin
    /// `.readFailed` "without any seam" in `EphemeralTempScannerTests`, and a
    /// scan-time-token round trip in `ValuablesDetector`.
    static let absentCellNames: [(name: String, reason: String)] = [
        ("testNonZeroExitIsTheOnlyClassThatReachesTheReCheck",
         "renamed at r5 when the second `worktree remove` arm was deleted; "
             + "cited by its successor's doc as history, in the past tense"),
        ("testTheForceUnwrapPopulationDoesNotGrow",
         "deleted at r7 and replaced by "
             + "`testNoForceUnwrapCanBeDecidedByProductionCode`; "
             + "`StrandFenceTests` records what stood there and why it went"),
        ("testThePermanentProofAndTheRemovalAreNotSeparatedByTheHop",
         "never existed; named by r7's `removeTree` guard and cited only in "
             + "this file's record of that defect"),
        ("testThePermanentArmRefusesAWorktreeSwappedInsideTheHop",
         "never existed; named by r7's `removeTree` guard and cited only in "
             + "this file's record of that defect"),
        ("testProductionBoundedReadCarriesTheReaddirErrno",
         "never existed; cited by `EphemeralTempScannerTests` only in the "
             + "correction that retired the false coverage claim naming it"),
    ]

    func testEveryCitedTestCellNameExists() throws {
        var declared: Set<String> = []
        guard let declaration = try? NSRegularExpression(
            pattern: #"func\s+(test[A-Za-z0-9_]+)"#
        ), let citation = try? NSRegularExpression(
            pattern: #"`(test[A-Za-z0-9_]+)`"#
        ) else { return XCTFail("the cell-name patterns do not compile") }

        let sources = try swiftSources()
        for file in sources where file.path.contains("/Tests/") {
            let source = try String(contentsOf: file, encoding: .utf8)
            let full = NSRange(source.startIndex..., in: source)
            for match in declaration.matches(in: source, range: full) {
                guard let range = Range(match.range(at: 1), in: source)
                else { continue }
                declared.insert(String(source[range]))
            }
        }
        let retired = Set(Self.absentCellNames.map(\.name))

        var offenders: [String] = []
        var citations = 0
        for file in sources {
            let source = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in source.split(
                separator: "\n", omittingEmptySubsequences: false
            ).enumerated() {
                guard let comment = line.range(of: "//") else { continue }
                let text = String(line[comment.lowerBound...])
                let full = NSRange(text.startIndex..., in: text)
                for match in citation.matches(in: text, range: full) {
                    guard let range = Range(match.range(at: 1), in: text)
                    else { continue }
                    let name = String(text[range])
                    citations += 1
                    guard !declared.contains(name), !retired.contains(name)
                    else { continue }
                    offenders.append(
                        "\(file.lastPathComponent):\(number + 1): \(name)"
                    )
                }
            }
        }

        XCTAssertGreaterThan(
            citations, 40,
            "the check must actually have found citations, not zero of them"
        )
        XCTAssertGreaterThan(
            declared.count, 1_000,
            "the check must actually have read the cells: \(declared.count)"
        )
        XCTAssertEqual(
            offenders, [],
            "a guard that cites a cell by name is claiming that cell is its "
                + "evidence. When the name is wrong the reader finds nothing "
                + "and reads it as evidence that was deleted. Name the real "
                + "cell, or list it in `absentCellNames` with the reason the "
                + "citation is still honest."
        )
    }

    /// `absentCellNames`' own rot check: an entry for a name that EXISTS
    /// again would silently exempt a live cell from the check.
    func testTheAbsentCellListIsExactlyWhatItClaims() throws {
        var declared: Set<String> = []
        guard let declaration = try? NSRegularExpression(
            pattern: #"func\s+(test[A-Za-z0-9_]+)"#
        ) else { return XCTFail("the declaration pattern does not compile") }
        for file in try swiftSources() where file.path.contains("/Tests/") {
            let source = try String(contentsOf: file, encoding: .utf8)
            let full = NSRange(source.startIndex..., in: source)
            for match in declaration.matches(in: source, range: full) {
                guard let range = Range(match.range(at: 1), in: source)
                else { continue }
                declared.insert(String(source[range]))
            }
        }
        XCTAssertEqual(
            Self.absentCellNames.map(\.name).filter(declared.contains), [],
            "an absent name that exists again must leave the list"
        )
    }
}
