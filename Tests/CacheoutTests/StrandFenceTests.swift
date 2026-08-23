import XCTest

/// # The fence against constructs that STRAND the run (PR #460 codex r3/r5/r6)
///
/// A trapping construct in a test does not fail a cell — it kills the PROCESS.
/// `swift test` builds ONE bundle and runs BOTH test targets in ONE process,
/// so every cell that sorts after the trap never runs and the total line never
/// prints. This suite has been stranded that way twice, measured both times.
///
/// ## The four positions, and the order they were closed in
///
/// 1. **CONDITION** — `TestElementAccess.swift` retired the trapping subscript
///    from the condition position and PR #460 codex r3 converted the sites.
/// 2. **MESSAGE** — `XCTAssertTrue(_ expression: @autoclosure () throws ->
///    Bool, _ message: @autoclosure () -> String)` evaluates `message()` on
///    EVERY non-pass, including when `expression()` THROWS. So the shape r3
///    shipped,
///
///    ```swift
///    XCTAssertTrue(
///        try XCTUnwrapElement(outcome.errors, 0).detail.contains("(regular file)"),
///        "detail names the real kind: \(outcome.errors[0].detail)"   // ← traps
///    )
///    ```
///
///    converts the very failure `XCTUnwrapElement` exists to make survivable
///    back into a `SIGILL`. MEASURED on this branch: dropping the issue
///    emission in `EphemeralTempScanner.swift:771-777` killed the runner at
///    `EphemeralTempScannerTests.swift:2973-2975` with `Index out of range` and
///    signal 5; the cells after it never ran and the total line never printed.
/// 3. **STATEMENT** (PR #460 codex r6, D4) — a trap needs no assertion around
///    it at all. `let call = mock.calls[0]` and `let state = try!
///    PropertyListDecoder().decode(…)` strand exactly as hard, and until r6
///    NOTHING looked at them: r3's conversion was a convention, and r5's fence
///    parsed only `XCTAssert*` argument lists.
/// 4. **RANGE CONSTRUCTION** (PR #460 codex r9, D1) — `a..<b` is a
///    constructor with a precondition, and `Range requires lowerBound <=
///    upperBound` is a `Fatal error` like any other. A range whose two bounds
///    come from two INDEPENDENT `range(of:)` searches over a document the
///    tests do not control is ordered only by luck. MEASURED at r9: moving
///    `## Alert Schema` above `#### Exception: NO client-side timeout` in
///    `PROTOCOL.md` — an edit that touches no test — killed
///    `testDocumentedNoClientTimeoutRuleAndItsTriggerAreComplete` with that
///    fatal error and no `Executed N tests` line. Three sites had the shape;
///    `testNoIndependentlyLocatedRangePairCanStrandTheRun` fences it.
///
/// 5. **KEYED-DICTIONARY CONSTRUCTION** (PR #460 codex r10, D3) —
///    `Dictionary(uniqueKeysWithValues:)` traps on a duplicate key:
///    `Fatal error: Duplicate values for key` is a stdlib precondition
///    (Swift's `NativeDictionary.swift`, line 792 — a stdlib path, not a
///    repository anchor), and it kills the process exactly
///    as `xs[0]` does. Eleven sites had the shape and nine of them keyed on a
///    value PRODUCTION decides — an entry's `displayName`, an entry's
///    `itemID`, a scanned item's `id` — which is precisely where a regression
///    puts a second one.
///
///    MEASURED AT THIS COMMIT'S PARENT, by mutating ONE production line —
///    `Sources/Cacheout/Cleaner/CacheCleaner.swift:514`, `if let entry =
///    outcome.entry { entries.append(entry) }`, appended twice, which is the
///    shape of SCANNERS-ROADMAP defect D1. With the old constructor at
///    `CacheCleanerTests:1385` the run died with `Fatal error: Duplicate
///    values for key: 'cat-exact'`, exit 1, **24 of the 95
///    `CacheCleanerTests` cells had started and the `Executed N tests` line
///    never printed** — while the swift-testing footer still printed `✔ Test
///    run … passed`. With every site converted to `XCTUniquelyKeyed`, the
///    IDENTICAL mutation produces **15 failing cells out of 138 executed**,
///    three of which name the duplicated key, and the run finishes.
///    `testNoUniquelyKeyedDictionaryCanStrandTheRun` fences it; the sites and
///    the replacement live in `TestElementAccess.swift`.
///
/// 6. **AN UNBOUNDED PARK** (PR #460 codex r11, D2) — and this one is worse
///    than a trap, because a trap ENDS. A cell that `await`s a hand-built
///    gate nobody will resume prints the name of the cell it entered and then
///    NOTHING: no failure, no total line, no exit status, no signal — the run
///    simply stops, for as long as anyone is willing to wait, and every cell
///    after it never runs.
///
///    MEASURED with ONE production line mutated —
///    `Sources/Cacheout/Scanner/SpaceScanner.swift`, `var
///    includeProtectedRoots: Bool { trigger == .userInitiated }` → `{ true }`
///    — the log ended at `EphemeralTempRegistrationTests`'
///    `testADecliningScannerIsNotPendingWhileTheSessionRuns` started. and
///    stayed there for 120 s until the runner was killed. The cell awaited
///    `ScanRendezvous.waitUntilStarted()`, whose only resumer is a
///    `signalStarted()` inside a fixture scanner PRODUCTION invokes on
///    exactly that flag. FOUR hand-built gates had the shape; all four now
///    park on `BoundedRendezvous` (`TestElementAccess.swift`), which resumes
///    an abandoned waiter after a deadline and fails that ONE cell.
///    `testNoHandBuiltGateCanParkTheRunForever` fences it.
///
/// ## And it reads BOTH TEST TARGETS (PR #460 codex r6, D3)
///
/// Through r5 the scan root was `URL(fileURLWithPath: #filePath)
/// .deletingLastPathComponent()` with a NON-recursive `contentsOfDirectory` —
/// `Tests/CacheoutTests` only. `Tests/CacheoutHelperTests` was invisible, and
/// XCTest sorts classes across both: `SysctlJournalTests` sorts immediately
/// before `WorktreeReclaimPerformerTests` and `WorktreeStalenessAssessorTests`,
/// so a trap in the unfenced target stranded this PR's own evidence. PROVEN by
/// mutation: deleting `state.entries.append(entry)` in
/// `Sources/CacheoutHelperLib/SysctlJournal.swift:192` strands the run. The
/// root is now `Tests/` and the walk is recursive, and
/// `testTheFenceReadsEveryTestTargetInTheBundle` fails if either target stops
/// being read.
///
/// ## And force-unwrap is FORBIDDEN, not merely counted (PR #460 codex r7, D4)
///
/// Through r6 `x!` was only INVENTORIED: `testTheForceUnwrapPopulationDoesNotGrow`
/// pinned the count per file. Pinning a count makes no EXISTING site safe, and
/// the dangerous population is not the big one — it is the one whose optional
/// is decided by PRODUCTION code, where the cell exists precisely to catch
/// production returning nil. PROVEN BY THE r7 REVIEW, whose figures these are
/// and which this file did not re-run: making
/// `Sources/CacheoutHelperLib/MemlimitWorkaround.swift:187` return a nil detail
/// turned `XCTAssertTrue(error!.contains("hwm_failed"))` into
/// `Fatal error: Unexpectedly found nil`, **signal 5, the total line never
/// printed, 493 of the 1471 cells AT COMMIT 26c880b never ran**, and this
/// PR's own `WorktreeReclaimPerformerTests` appeared in the log zero times.
/// (The suite WAS 1486 at r8's head 7e9b2c5, 1496 at 101753b, 1500 at
/// a917447, 1511 at 592eb0a, 1522 at 350fa31, and IS 1528 at e29ffb4; a total
/// is only ever a fact about the commit it was taken at — see
/// `WorktreeReclaimPerformerTests`' class header, D5, and r10's D4.)
///
/// So r7 converted that population — 14 sites in `CategoryScannerTests`,
/// `CompressorTrackerTests`, `PredictiveEngineTests`,
/// `MemlimitWorkaroundTests`, `EphemeralTempRegistrationTests` and
/// `EphemeralTempScannerTests` — and turned the fence around: force-unwrap is
/// an offender UNLESS it matches one of five shapes whose operand cannot be
/// production-decided, listed with their justifications in
/// `forceUnwrapAllowances`, or names an implicitly-unwrapped property declared
/// in the SAME FILE (a `setUp`-assigned fixture, decided by the test).
/// `testTheForceUnwrapAllowlistIsExactlyWhatItClaims` proves both directions on
/// synthetic lines, so the allowlist cannot quietly widen.
///
/// BOTH CELLS ARE MUTATION-TESTED, because a fence that cannot go red is a
/// comment. Restoring ONE converted site —
/// `XCTAssertTrue(error!.contains("hwm_failed"))` in
/// `MemlimitWorkaroundTests` — reddens
/// `testNoForceUnwrapCanBeDecidedByProductionCode` naming that exact line;
/// widening the UTF-8 allowance to `\.data\(using: [^)]*\)!` reddens
/// `testTheForceUnwrapAllowlistIsExactlyWhatItClaims` on
/// `text.data(using: .ascii)!`.
///
/// ## What this fence does NOT cover, stated rather than implied
///
/// - **`statementTraps`' subscript pattern matches a LITERAL integer index
///   only** (PR #460 codex r7, D4), and a variable index is handled by a
///   SEPARATE cell rather than by that pattern (PR #460 codex r8, D1).
///   `statementTraps` cannot widen because a regex cannot tell an ARRAY
///   subscript from a DICTIONARY one, and a dictionary subscript returns an
///   Optional and cannot trap. MEASURED at r7: widening the pattern to any
///   identifier index reports **105** lines across the suite. TWO
///   MEASUREMENTS, NOT ONE, AND r8 PUBLISHED THEM AS ONE (PR #460 codex r9,
///   D2). Re-run at `7e9b2c5`, the r8 head of this branch:
///
///   - the RAW grep — `grep -rnE
///     '[A-Za-z0-9_\)\]]\s*\[\s*[A-Za-z_][A-Za-z0-9_.]*\s*\]' Tests
///     --include='*.swift' | wc -l` — prints **150**;
///   - the same pattern over the sources the CELLS actually see, i.e. after
///     `blankingComments` + `blankingLiteralText`, matches **117** lines.
///
///   The gap is the 33 lines where the only match is comment or
///   string-literal text — including this very bullet, which spells the
///   pattern out. r8's sentence attached the blanked figure (117) to the raw
///   command, which produces neither 150 nor 117 at the commit that wrote it
///   (**140** at `aaf9c03`); the raw grep last printed 117 at `f6a048f`, one
///   commit earlier, which is where the coincidence came from. Both numbers
///   are labelled from here on, and the grep is the one anybody can re-run.
///
///   Of that population the overwhelming majority are dictionary reads
///   (`failures[url.path]`, `paths[scanner.registeredID]`,
///   `environment[key]`) — a fence that is ~90% false positives is a fence
///   that gets suppressed. `testTheIntegerSubscriptPatternMatchesLiteralIndicesOnly`
///   pins this scope so the claim and the regex cannot drift apart again.
///   What r7 did NOT do, and r8 does, is separate the subset where the
///   dictionary ambiguity does not exist: when the index name is bound by a
///   loop over integers the read IS an array read.
///   `testNoLoopBoundIndexSubscriptCanStrandTheRun` covers exactly that
///   subset — **7 hits on 5 lines**, not 117 — and its own header states
///   both its limits and how that figure was taken.
/// - **`as!`, `precondition` and its `…Failure` spelling, `fatalError`,
///   arithmetic overflow, out-of-range `Range` subscripts,
///   `Array(repeating:count:)` with a negative count** — not scanned at all.
///
///   WHAT THIS BULLET USED TO SAY, AND WHY IT WAS WITHDRAWN (PR #460 codex
///   r11, D3). It said "No occurrence of any of them has stranded a run
///   here." That sentence is true of HISTORY — none of them ever has — and
///   it READ as a claim about the POPULATION, i.e. that no occurrence sits
///   anywhere a strand could come from. Two did. `CLIGateFramingTests` and
///   `DocumentedCLIFramingTests` each ended a `productsDirectory` property
///   with a trapping `…Failure`, and `runCLI` reads that property on EVERY
///   CLI-framing cell in both classes: a SwiftPM or Xcode layout change that
///   stopped `Bundle.allBundles` yielding a `.xctest` path would have killed
///   the runner with no total line, for a fact about the build layout rather
///   than about the product. Both are converted to `try XCTUnwrap` in the
///   same commit as this paragraph, so each fails ONE cell.
///
///   WHAT IS LEFT, COUNTED RATHER THAN ASSERTED. At this commit
///
///       grep -rnE '\bprecondition\(|\bpreconditionFailure\(|\bfatalError\(|[^A-Za-z0-9_] as! ' \
///           Tests --include='*.swift'
///
///   prints **3** lines, and ONE OF THEM IS THE COMMAND LINE ITSELF — the
///   last alternative matches its own text, exactly as this file's
///   subscript-population bullet matches its own. Labelled rather than
///   silently netted off, because an unlabelled 2 and an unlabelled 3 are how
///   r8's two subscript figures got published as one.
///
///   The other **2** are both the `!outcomes.isEmpty` assertion in
///   `OutcomeSequenceBox.next()` (`CacheoutViewModelTests`,
///   `OrphanedCachesScannerTests`), whose array is a literal list the CELL
///   writes and which is documented as fixture-controlled at both sites.
///   `as!` and `fatalError` occur ZERO times in code. The claim this bullet
///   now makes is therefore about the population, and it is re-derivable in
///   one command.
///
///   An OUT-OF-ORDER `Range` is no longer in this list: it stranded a run at
///   r9 and has its own cell (position 4 above).
/// - **raw string literals (`#"…"#`)** are blanked WHOLE, so a trap inside a
///   raw-string interpolation would be missed. No test uses one.
///
/// Each hit either cell names is a cell that, when it legitimately goes red,
/// takes the rest of the run with it.
final class StrandFenceTests: XCTestCase {

    /// The one-argument forms take the condition first; these take two.
    private static let binaryAssertions: Set<String> = [
        "XCTAssertEqual", "XCTAssertNotEqual", "XCTAssertIdentical",
        "XCTAssertNotIdentical", "XCTAssertGreaterThan",
        "XCTAssertGreaterThanOrEqual", "XCTAssertLessThan",
        "XCTAssertLessThanOrEqual",
    ]

    /// `Tests/` — the PARENT of this file's own target directory, so every
    /// test target in the bundle is read (D3). Both cells walk it recursively.
    private var testsRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/CacheoutTests
            .deletingLastPathComponent()   // Tests
    }

    /// Every `.swift` file under `Tests/`, in a stable order.
    private func testSources() throws -> [URL] {
        var files: [URL] = []
        let walker = try XCTUnwrap(
            FileManager.default.enumerator(
                at: testsRoot, includingPropertiesForKeys: nil
            ),
            "Tests/ could not be enumerated at \(testsRoot.path)"
        )
        for case let url as URL in walker where url.pathExtension == "swift" {
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    /// The target directory a test source belongs to.
    private func target(of file: URL) -> String {
        file.deletingLastPathComponent().lastPathComponent
    }

    func testTheFenceReadsEveryTestTargetInTheBundle() throws {
        // The D3 rot check: the fence's reach is asserted, never assumed. A
        // target added to Package.swift and not to Tests/ — or a scan root
        // narrowed back to one directory — fails HERE rather than silently
        // leaving a whole target unfenced.
        let targets = Set(try testSources().map(target(of:)))
        XCTAssertEqual(
            targets, ["CacheoutTests", "CacheoutHelperTests"],
            "the fence must read every test target `swift test` links into "
                + "the one process it runs: \(targets.sorted())"
        )
    }

    func testNoAssertionMessageCanTrapAndStrandTheRun() throws {
        var offenders: [String] = []
        var scannedFiles = 0
        var scannedCalls = 0

        for file in try testSources() {
            // Comments and string-literal TEXT are BLANKED rather than
            // deleted, so the reported line numbers stay the file's own — and
            // so a doc comment quoting the very shape this fence forbids (this
            // file does, twice) and a message that merely SPELLS `try!` are not
            // themselves reported. `\( … )` interpolations survive, which is
            // the whole population this cell is about.
            let source = Self.blankingLiteralText(
                Self.blankingComments(
                    try String(contentsOf: file, encoding: .utf8)
                )
            )
            scannedFiles += 1
            for call in Self.assertionCalls(in: source) {
                scannedCalls += 1
                let skip = call.name == "XCTFail"
                    ? 0
                    : (Self.binaryAssertions.contains(call.name) ? 2 : 1)
                let arguments = Self.splitTopLevel(call.body)
                guard arguments.count > skip else { continue }
                for argument in arguments[skip...] {
                    // `file:`/`line:` are always `#filePath`/`#line`.
                    if argument.contains("file:") || argument.contains("line:") {
                        continue
                    }
                    guard let trap = Self.trap(in: argument) else { continue }
                    let line = source[source.startIndex..<call.start]
                        .filter { $0 == "\n" }.count + 1
                    offenders.append(
                        "\(target(of: file))/\(file.lastPathComponent):"
                            + "\(line): \(call.name) message can trap "
                            + "(\(trap))"
                    )
                    break
                }
            }
        }

        XCTAssertGreaterThan(
            scannedFiles, 40,
            "the fence must actually have read the suite, not an empty listing"
        )
        XCTAssertGreaterThan(
            scannedCalls, 2000,
            "the fence must actually have parsed assertions, not zero of them"
        )
        XCTAssertEqual(
            offenders, [],
            "an assertion MESSAGE that subscripts or force-unwraps traps the "
                + "whole run when that assertion fails — which is precisely "
                + "when it is evaluated. Print the WHOLE collection instead "
                + "(`\\(xs)`, `\\(xs.map(\\.field))`)."
        )
    }

    // MARK: - Statement position (PR #460 codex r6, D4)

    /// The constructs forbidden ANYWHERE in a test source, with the name the
    /// failure reports.
    ///
    /// `try!` — the throw is usually decided by production code, which is the
    /// regression the cell exists to catch, converted into a process kill.
    /// A LITERAL-INTEGER SUBSCRIPT on a named receiver — the receiver is
    /// usually a collection production filled, so "it cannot be empty" is a
    /// claim about the code under test. TWO exclusions, both deliberate and
    /// both pinned by `testTheIntegerSubscriptPatternMatchesLiteralIndicesOnly`:
    /// a subscript into an array LITERAL (`+ [0]`, `[20]`) is not a claim about
    /// production, so the regex requires an identifier, `)` or `]` immediately
    /// before the bracket; and a VARIABLE index (`xs[i]`) is not matched by
    /// THIS pattern, because no regex can separate it from a dictionary read,
    /// which cannot trap (see the header, D4). The subset of variable indices
    /// that provably ARE array reads — the index name is loop-bound to an
    /// integer — is fenced by
    /// `testNoLoopBoundIndexSubscriptCanStrandTheRun` (r8, D1).
    private static let statementTraps: [(name: String, pattern: String)] = [
        ("try!", #"\btry!"#),
        ("literal-integer subscript",
         #"[A-Za-z0-9_\)\]]\s*\[\s*[0-9]+\s*\]"#),
    ]

    func testNoTrappingConstructAnywhereInATestSourceCanStrandTheRun() throws {
        var offenders: [String] = []
        var scannedFiles = 0

        for file in try testSources() {
            // Comments AND string-literal TEXT are blanked; `\( … )`
            // interpolations survive, because those ARE code and a `\(xs[0])`
            // inside a message traps like any other subscript.
            let source = Self.blankingLiteralText(
                Self.blankingComments(
                    try String(contentsOf: file, encoding: .utf8)
                )
            )
            scannedFiles += 1
            for (number, line) in source.split(
                separator: "\n", omittingEmptySubsequences: false
            ).enumerated() {
                for trap in Self.statementTraps
                where line.range(
                    of: trap.pattern, options: .regularExpression
                ) != nil {
                    offenders.append(
                        "\(target(of: file))/\(file.lastPathComponent):"
                            + "\(number + 1): \(trap.name)"
                    )
                }
            }
        }

        XCTAssertGreaterThan(
            scannedFiles, 40,
            "the fence must actually have read the suite, not an empty listing"
        )
        XCTAssertEqual(
            offenders, [],
            "a `try!` or an integer subscript in a test source does not fail "
                + "a cell — it kills the PROCESS, and every cell sorting after "
                + "it never runs. Use `try` in a throwing cell, "
                + "`XCTUnwrapElement(xs, 0)`, or `xs.first`."
        )
    }


    // MARK: - Force-unwrap: forbidden unless provably not production-decided

    /// The five shapes a force-unwrap may take, each with the reason its
    /// operand cannot be decided by the code under test (PR #460 codex r7,
    /// D4). Anything else is an offender; there is no per-file quota and no
    /// way to add a site without adding a JUSTIFICATION here.
    ///
    /// A sixth allowance is computed per file rather than listed: a name
    /// declared in the SAME FILE as an implicitly-unwrapped property
    /// (`private var home: URL!`) is a `setUp`-assigned fixture. If it is nil
    /// the FIXTURE failed, which `setUpWithError` already reports, and no
    /// production return value is involved.
    static let forceUnwrapAllowances: [(reason: String, pattern: String)] = [
        ("a UTF-8 encoding of a Swift String, which cannot fail",
         #"\.data\(using: \.utf8\)!"#),
        // NOT a raw literal: this pattern needs `"` inside it, and a raw
        // literal spelling it carries FIVE quote characters on one line, which
        // leaves `blankingComments`' string tracker open and silently unblanks
        // every comment below it (measured — it reported this file's own
        // `/// private var base: URL!` doc line as an offender). Escaped
        // quotes in an ordinary literal are balanced and are handled.
        ("a TimeZone from a literal identifier",
         "TimeZone\\(identifier: \"[^\"]*\"\\)!"),
        ("the base address of a buffer the cell itself allocated",
         #"baseAddress!"#),
        ("the last element of a collection the cell itself filled",
         #"\.last!"#),
        ("the pointer `withUnsafe…` hands its own closure",
         #"\$0!"#),
    ]

    /// Every implicitly-unwrapped property name declared in `source`.
    static func implicitlyUnwrappedNames(in source: String) -> Set<String> {
        var names: Set<String> = []
        for line in source.split(
            separator: "\n", omittingEmptySubsequences: false
        ) where isImplicitlyUnwrappedDeclaration(String(line)) {
            guard let match = String(line).range(
                of: #"(var|let)\s+\w+"#, options: .regularExpression
            ) else { continue }
            let declaration = String(line)[match]
            if let name = declaration.split(separator: " ").last {
                names.insert(String(name))
            }
        }
        return names
    }

    /// The character ranges on one line that an allowed force-unwrap may end
    /// inside.
    private static func allowedRanges(
        in line: String, fixtures: Set<String>
    ) -> [Range<String.Index>] {
        var patterns = forceUnwrapAllowances.map(\.pattern)
        for name in fixtures.sorted() {
            patterns.append(#"\b(self\.)?"# + NSRegularExpression.escapedPattern(for: name) + "!")
        }
        var ranges: [Range<String.Index>] = []
        for pattern in patterns {
            var cursor = line.startIndex
            while let hit = line.range(
                of: pattern, options: .regularExpression,
                range: cursor..<line.endIndex
            ) {
                ranges.append(hit)
                cursor = hit.upperBound
            }
        }
        return ranges
    }

    /// The force-unwraps on one line that no allowance covers.
    static func unjustifiedForceUnwraps(
        in line: String, fixtures: Set<String>
    ) -> Int {
        if isImplicitlyUnwrappedDeclaration(line) { return 0 }
        let allowed = allowedRanges(in: line, fixtures: fixtures)
        var offenders = 0
        var cursor = line.startIndex
        while let hit = line.range(
            of: #"[A-Za-z0-9_\)\]]!(?!=)"#, options: .regularExpression,
            range: cursor..<line.endIndex
        ) {
            let bang = line.index(before: hit.upperBound)
            if !allowed.contains(where: { $0.contains(bang) }) { offenders += 1 }
            cursor = hit.upperBound
        }
        return offenders
    }

    func testNoForceUnwrapCanBeDecidedByProductionCode() throws {
        var offenders: [String] = []
        var scannedFiles = 0

        for file in try testSources() {
            let source = Self.blankingLiteralText(
                Self.blankingComments(
                    try String(contentsOf: file, encoding: .utf8)
                )
            )
            scannedFiles += 1
            let fixtures = Self.implicitlyUnwrappedNames(in: source)
            for (number, line) in source.split(
                separator: "\n", omittingEmptySubsequences: false
            ).enumerated() {
                let count = Self.unjustifiedForceUnwraps(
                    in: String(line), fixtures: fixtures
                )
                if count > 0 {
                    offenders.append(
                        "\(target(of: file))/\(file.lastPathComponent):"
                            + "\(number + 1)"
                    )
                }
            }
        }

        XCTAssertGreaterThan(
            scannedFiles, 40,
            "the fence must actually have read the suite, not an empty listing"
        )
        XCTAssertEqual(
            offenders, [],
            "a force-unwrap whose optional is decided by PRODUCTION code turns "
                + "the regression it exists to catch into a process kill — "
                + "measured: 493 of 1471 cells never ran. Use "
                + "`try XCTUnwrap(x)`, or add the shape to "
                + "`forceUnwrapAllowances` with the reason it cannot be "
                + "production-decided."
        )
    }

    /// The allowlist's own regression guard: both directions, on synthetic
    /// lines, so a widened pattern is caught by this cell rather than by a
    /// stranded run six months from now.
    func testTheForceUnwrapAllowlistIsExactlyWhatItClaims() {
        let fixtures: Set<String> = ["home", "container"]
        for allowed in [
            #"let data = "x".data(using: .utf8)!"#,
            #"private static let utc = TimeZone(identifier: "UTC")!"#,
            "String(cString: buffer.baseAddress!)",
            "let fd = fds.last!",
            "mkfifo($0!, 0o644)",
            "let root = home!",
            "let root = self.home!",
            "for url in [home!, container!] { _ = url }",
        ] {
            XCTAssertEqual(
                Self.unjustifiedForceUnwraps(in: allowed, fixtures: fixtures),
                0, "must be allowed: \(allowed)"
            )
        }
        for refused in [
            #"XCTAssertTrue(error!.contains("hwm_failed"))"#,
            "XCTAssertEqual(prediction!, 61.0)",
            "let events = outcome(of: categoryEvents!)",
            "let value = try JSONSerialization.jsonObject(with: payload)!",
            #"let data = text.data(using: .ascii)!"#,
            #"let zone = TimeZone(identifier: identifier)!"#,
            "let root = homeDirectory!",
        ] {
            XCTAssertEqual(
                Self.unjustifiedForceUnwraps(in: refused, fixtures: fixtures),
                1, "must be refused: \(refused)"
            )
        }
    }

    /// D4(b): the literal-integer subscript pattern's REACH, pinned in both
    /// directions. The r6 wording implied a variable index was covered; it is
    /// not, and the reason is in the header. This cell makes the documented
    /// scope and the regex one fact.
    func testTheIntegerSubscriptPatternMatchesLiteralIndicesOnly() throws {
        let pattern = try XCTUnwrap(
            Self.statementTraps.first { $0.name == "literal-integer subscript" }
        ).pattern
        func matches(_ line: String) -> Bool {
            line.range(of: pattern, options: .regularExpression) != nil
        }
        for trapping in [
            "let call = mock.calls[0]",
            "let first = outcome.errors[ 12 ]",
            "let nested = report.entries[0].warning",
        ] {
            XCTAssertTrue(matches(trapping), "must be reported: \(trapping)")
        }
        for notReported in [
            // A VARIABLE index traps identically and is NOT reported BY THIS
            // PATTERN — the exclusion this cell exists to make visible rather
            // than imply. Both of these lines ARE read by
            // `testNoLoopBoundIndexSubscriptCanStrandTheRun`, which allows
            // them because both receivers are pointers (r8, D1).
            "let entry = buffer[index]",
            "unlinkat(fds[index], segment, AT_REMOVEDIR)",
            // A dictionary read, which is why the exclusion above exists.
            "if let code = failures[url.path] { return code }",
            // An array LITERAL is not a subscript at all, and the regex's
            // requirement of an identifier, `)` or `]` before the bracket is
            // what keeps it out.
            "let padded = suffixes + [0]",
            "let bounds = [20]",
        ] {
            XCTAssertFalse(
                matches(notReported), "must NOT be reported: \(notReported)"
            )
        }
    }

    // MARK: - Variable index, LOOP-BOUND to an integer (PR #460 codex r8, D1)

    /// The r7 header said a variable index "is NOT matched", gave the reason
    /// (a regex cannot separate an array read from a dictionary read, and a
    /// dictionary read returns an Optional and cannot trap), and stopped
    /// there. That reason does not hold for the whole population: when the
    /// index name is BOUND BY A LOOP over integers — `.enumerated()`,
    /// `.indices`, an integer range, `stride` — the subscript is an INTEGER
    /// subscript, so the receiver is a collection indexed by `Int` and the
    /// read traps exactly like `xs[0]`. MEASURED at r8: the live site was
    /// `clauses[index].hasPrefix(…)` in `WorktreeStalenessAssessorTests`
    /// (lines 974-975 as they stood at `f6a048f`, the commit before the fix),
    /// with `clauses` composed by
    /// `WorktreeStalenessAssessor.evidence` — the exact shape
    /// `TestElementAccess.swift` calls out, sitting one line under its
    /// `XCTAssertEqual(clauses.count, 4, …)`.
    ///
    /// ## What this cell covers, stated so it cannot drift
    ///
    /// - The index must be a BARE identifier bound in the same file by one of
    ///   `integerIndexBindings`. `xs[i + 1]`, `xs[someCall()]` and an index
    ///   bound any other way (a `var` counter, a function parameter) are NOT
    ///   matched. Over the whole suite the loop-bound population is **7 hits
    ///   on 5 lines** against 117 blanked lines (150 raw grep hits) for "any
    ///   identifier index" — the ~90%-dictionary noise r7 measured is exactly
    ///   what the loop-bound requirement removes.
    ///
    ///   HOW THAT FIGURE WAS TAKEN, since it is not one command (PR #460
    ///   codex r9, D6). At `7e9b2c5`: drive THIS cell's own
    ///   `blankingComments` + `blankingLiteralText`, `integerIndexNames` and
    ///   `unfencedLoopBoundSubscripts` over every `Tests/**/*.swift` with the
    ///   allowances DISABLED (`inRange: [:]`, `pointers: []`) and count what
    ///   comes back. It is 7 hits on 5 lines — two lines carry two hits each
    ///   — in `DepthSafeRemovalTests`, `HeadlessTests`,
    ///   `OrphanedCachesScannerTests` (twice) and `RecommendationEngineTests`.
    ///   "7 lines" is what r8 published; the unit was wrong, not the reach.
    /// - The receiver must be a bare identifier: `xs[i]` and `report.rows[i]`
    ///   are read, `f()[i]` and `xs[0][i]` are not.
    /// - Two allowances, both PROVABLE from the same line rather than
    ///   asserted: the index came from THIS receiver's own `.indices` or from
    ///   a `stride` over THIS receiver's own `.count` (it cannot be out of
    ///   range), or the receiver is a POINTER — a name declared
    ///   `Unsafe…Pointer` or bound by a `withUnsafe…` closure in the same
    ///   file — whose extent is the test's own allocation and which has no
    ///   `Array` bounds check to trap on.
    /// - Both allowances are FILE-WIDE on the name, as the force-unwrap
    ///   fixture allowance already is: a second array that happens to reuse
    ///   the name `buffer` in a file that also declares a `buffer` pointer is
    ///   waved through. Narrowing that needs a scope analysis this file does
    ///   not have, and the coarseness is here rather than implied.
    ///
    /// `testTheLoopBoundIndexFenceIsExactlyWhatItClaims` pins every clause
    /// above on synthetic lines, in both directions.
    struct IntegerIndexBinding {
        let label: String
        let pattern: String
        /// The capture holding the INDEX name.
        let indexGroup: Int
        /// The capture holding a receiver the bound proves the index in range
        /// for, or 0 when the bound proves nothing about any receiver.
        let receiverGroup: Int
    }

    static let integerIndexBindings: [IntegerIndexBinding] = [
        IntegerIndexBinding(
            label: "`.enumerated()`",
            pattern: #"for\s*\(\s*(\w+)\s*,\s*\w+\s*\)\s+in[^\n]*\.enumerated\(\)"#,
            indexGroup: 1, receiverGroup: 0
        ),
        IntegerIndexBinding(
            label: "`for … in x.indices`",
            pattern: #"for\s+(\w+)\s+in\s+(\w+)\.indices\b"#,
            indexGroup: 1, receiverGroup: 2
        ),
        IntegerIndexBinding(
            label: "`x.indices.…  { i in`",
            pattern: #"(\w+)\.indices\.\w+\s*\{\s*(\w+)\s+in\b"#,
            indexGroup: 2, receiverGroup: 1
        ),
        IntegerIndexBinding(
            label: "an integer range",
            pattern: #"for\s+(\w+)\s+in\s+-?\d+\s*\.\.[.<]"#,
            indexGroup: 1, receiverGroup: 0
        ),
        IntegerIndexBinding(
            label: "`stride(from: x.count`",
            pattern: #"for\s+(\w+)\s+in\s+stride\(from:\s*(\w+)\.count"#,
            indexGroup: 1, receiverGroup: 2
        ),
    ]

    /// Names a `withUnsafe…` closure binds, plus names declared with an
    /// `Unsafe…Pointer` type — an unchecked receiver whose extent the test
    /// itself allocated.
    static let pointerBindings: [String] = [
        #"(\w+)\s*:\s*Unsafe\w*Pointer"#,
        #"withUnsafe\w*[^\n{]*\{\s*(\w+)\s+in\b"#,
    ]

    /// `(indexNames, provablyInRange)` for one source file.
    static func integerIndexNames(
        in source: String
    ) -> (names: Set<String>, inRange: [String: Set<String>]) {
        var names: Set<String> = []
        var inRange: [String: Set<String>] = [:]
        let full = NSRange(source.startIndex..., in: source)
        for binding in integerIndexBindings {
            guard let regex = try? NSRegularExpression(pattern: binding.pattern)
            else { continue }
            for match in regex.matches(in: source, range: full) {
                guard binding.indexGroup < match.numberOfRanges,
                      let indexRange = Range(
                        match.range(at: binding.indexGroup), in: source
                      )
                else { continue }
                let name = String(source[indexRange])
                names.insert(name)
                guard binding.receiverGroup > 0,
                      binding.receiverGroup < match.numberOfRanges,
                      let receiverRange = Range(
                        match.range(at: binding.receiverGroup), in: source
                      )
                else { continue }
                inRange[name, default: []].insert(String(source[receiverRange]))
            }
        }
        return (names, inRange)
    }

    /// Every pointer-bound name in one source file.
    static func pointerNames(in source: String) -> Set<String> {
        var names: Set<String> = []
        let full = NSRange(source.startIndex..., in: source)
        for pattern in pointerBindings {
            guard let regex = try? NSRegularExpression(pattern: pattern)
            else { continue }
            for match in regex.matches(in: source, range: full) {
                guard match.numberOfRanges > 1,
                      let range = Range(match.range(at: 1), in: source)
                else { continue }
                names.insert(String(source[range]))
            }
        }
        return names
    }

    /// The `receiver[index]` reads on one line that no allowance covers.
    static func unfencedLoopBoundSubscripts(
        in line: String,
        names: Set<String>,
        inRange: [String: Set<String>],
        pointers: Set<String>
    ) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"([A-Za-z_]\w*)\s*\[\s*([A-Za-z_]\w*)\s*\]"#
        ) else { return [] }
        let full = NSRange(line.startIndex..., in: line)
        var hits: [String] = []
        for match in regex.matches(in: line, range: full) {
            guard let receiverRange = Range(match.range(at: 1), in: line),
                  let indexRange = Range(match.range(at: 2), in: line)
            else { continue }
            let receiver = String(line[receiverRange])
            // NOT named `index`: a dictionary read `inRange[index]` in THIS
            // file would then be a live offender of this very cell the moment
            // anyone bound `index` in an `.enumerated()` loop here.
            let indexName = String(line[indexRange])
            guard names.contains(indexName) else { continue }
            if inRange[indexName]?.contains(receiver) == true { continue }
            if pointers.contains(receiver) { continue }
            hits.append("\(receiver)[\(indexName)]")
        }
        return hits
    }

    func testNoLoopBoundIndexSubscriptCanStrandTheRun() throws {
        var offenders: [String] = []
        var scannedFiles = 0

        for file in try testSources() {
            let source = Self.blankingLiteralText(
                Self.blankingComments(
                    try String(contentsOf: file, encoding: .utf8)
                )
            )
            scannedFiles += 1
            let (names, inRange) = Self.integerIndexNames(in: source)
            let pointers = Self.pointerNames(in: source)
            for (number, line) in source.split(
                separator: "\n", omittingEmptySubsequences: false
            ).enumerated() {
                for hit in Self.unfencedLoopBoundSubscripts(
                    in: String(line), names: names, inRange: inRange,
                    pointers: pointers
                ) {
                    offenders.append(
                        "\(target(of: file))/\(file.lastPathComponent):"
                            + "\(number + 1): \(hit)"
                    )
                }
            }
        }

        XCTAssertGreaterThan(
            scannedFiles, 40,
            "the fence must actually have read the suite, not an empty listing"
        )
        XCTAssertEqual(
            offenders, [],
            "an integer subscript with a LOOP-BOUND index traps exactly like "
                + "`xs[0]` and kills the PROCESS, not the cell — measured at "
                + "r3 and r7: 985 and 493 cells never ran. Use "
                + "`try XCTUnwrapElement(xs, i)`."
        )
    }

    /// The widened fence's own regression guard: every clause of the doc
    /// comment above, on synthetic sources, in both directions.
    func testTheLoopBoundIndexFenceIsExactlyWhatItClaims() {
        func offenders(_ source: String) -> [String] {
            let (names, inRange) = Self.integerIndexNames(in: source)
            let pointers = Self.pointerNames(in: source)
            return source.split(
                separator: "\n", omittingEmptySubsequences: false
            ).flatMap {
                Self.unfencedLoopBoundSubscripts(
                    in: String($0), names: names, inRange: inRange,
                    pointers: pointers
                )
            }
        }

        // Reported: the index is loop-bound to an integer and nothing proves
        // the receiver long enough. The first is the r8 live site.
        XCTAssertEqual(
            offenders("""
                for (index, gate) in gates.enumerated() {
                    XCTAssertTrue(clauses[index].hasPrefix(gate))
                }
                """),
            ["clauses[index]"]
        )
        XCTAssertEqual(
            offenders("""
                for i in components.indices {
                    XCTAssertEqual(rows[i], expected[i])
                }
                """),
            ["rows[i]", "expected[i]"],
            "a `.indices` bound proves nothing about a DIFFERENT receiver"
        )
        XCTAssertEqual(
            offenders("""
                for slot in 0..<4 { print(report.entries[slot]) }
                """),
            ["entries[slot]"],
            "a dotted receiver is read as its last component"
        )

        // Not reported, each for the reason the header states.
        for quiet in [
            // The index came from THIS receiver.
            "for i in rows.indices { print(rows[i]) }",
            "let hits = seq.indices.filter { i in seq[i] == \"pop\" }",
            "for i in stride(from: fds.count - 2, through: 0, by: -1) "
                + "{ close(fds[i]) }",
            // A pointer receiver: unchecked, and the test allocated it.
            "var buffer: UnsafeMutablePointer<statfs>?\n"
                + "for index in 0..<count { var e = buffer[index] }",
            "withUnsafeMutableBytes(of: &addr) { ptr in\n"
                + "for i in 0..<n { ptr[i] = 0 } }",
            // Not loop-bound to an integer at all — a dictionary read, which
            // returns an Optional and cannot trap. This is the exclusion that
            // keeps the fence off the 117-blanked-line (150 raw grep)
            // identifier-index population.
            "for (key, value) in extra { environment[key] = value }",
            "if let code = failures[path] { return code }",
            // Not a BARE identifier index, so out of scope by construction.
            "for i in rows.indices { print(other[i + 1]) }",
        ] {
            XCTAssertEqual(
                offenders(quiet), [], "must NOT be reported: \(quiet)"
            )
        }
    }

    // MARK: - A Range built from two INDEPENDENT searches (r9, D1)

    /// `a..<b` is not a slice — it is a CONSTRUCTOR with a precondition, and
    /// `Range requires lowerBound <= upperBound` is a `Fatal error`, so it
    /// kills the PROCESS exactly like `xs[0]` does. The population that can
    /// reach it: a range whose two bounds come from two SEPARATE
    /// `range(of:)` searches over a document the tests do not control.
    /// Neither search knows about the other, so the moment an ordinary
    /// reorganisation puts the second marker above the first, the `..<`
    /// traps.
    ///
    /// MEASURED at r9 on this branch: lifting `## Alert Schema` above
    /// `#### Exception: NO client-side timeout` in `PROTOCOL.md` — an edit
    /// that touches no test — turned
    /// `testDocumentedNoClientTimeoutRuleAndItsTriggerAreComplete` into
    /// `Fatal error: Range requires lowerBound <= upperBound` and xctest died
    /// on a signal. Three sites had the shape (two over `CHANGELOG.md`, one
    /// over `PROTOCOL.md`); all three are now anchored.
    ///
    /// ## What this cell covers, stated so it cannot drift
    ///
    /// - The shape is `A.<bound> ..< B.<bound>` (or `...`) with A and B
    ///   DIFFERENT bare identifiers. The same name on both sides is one
    ///   `Range`'s own two ends, ordered by construction, and is not
    ///   reported.
    /// - One ALLOWANCE, proved from the source rather than asserted: the
    ///   BINDING OF `B` THAT THIS USE SEES — the nearest `let`/`var` of that
    ///   name ABOVE the range construction — searches inside the tail `A`
    ///   opens, `let B = …range(of: …, range: A.upperBound..<…)`. Then
    ///   `B.lowerBound >= A.upperBound >= A.lowerBound` for every pairing of
    ///   bounds, and a document that does not carry the second marker after
    ///   the first yields nil, which is a FAILING cell rather than a signal.
    /// - The allowance is POSITIONAL, not file-wide, and that is load-bearing
    ///   rather than tidiness: `DocumentedContractTests` binds `start`/`end`
    ///   in two different cells, one anchored and one not. MEASURED at r9 —
    ///   with a file-wide allowance (the first shape written here) reverting
    ///   the `PROTOCOL.md` fix left this cell GREEN, because the OTHER cell's
    ///   anchored `end` laundered it. The nearest-binding rule reports it.
    /// - An anchor is attributed to the binding it sits in — the last
    ///   `let`/`var` above it — so an `A.upperBound` anchor belonging to a
    ///   LATER statement cannot launder an earlier construction.
    /// - Only a `.lowerBound`/`.upperBound` pair is read. `a..<b` over two
    ///   plain `String.Index` values is not matched; no test builds one.
    /// - Scope is `Tests/`, as every cell here: this fence is about what
    ///   strands the RUN.
    ///
    /// `testTheIndependentRangePairFenceIsExactlyWhatItClaims` pins every
    /// clause above on synthetic sources, in both directions.
    static let independentRangePairPattern =
        #"([A-Za-z_]\w*)\.(?:lower|upper)Bound\s*\.\.[.<]\s*([A-Za-z_]\w*)\.(?:lower|upper)Bound"#

    /// One `let`/`var` binding, with the names whose `upperBound` its own
    /// statement searches from.
    struct RangeBinding {
        let name: String
        /// UTF-16 offset of the binding, comparable with every other offset
        /// this file takes from `NSRegularExpression`.
        let offset: Int
        var anchors: Set<String>
    }

    /// Every `let`/`var` binding in `source`, in order, each carrying the
    /// anchors that occur between it and the NEXT binding.
    static func rangeBindings(in source: String) -> [RangeBinding] {
        guard let binding = try? NSRegularExpression(
            pattern: #"\b(?:let|var)\s+(\w+)\s*="#
        ), let anchor = try? NSRegularExpression(
            pattern: #"range:\s*(\w+)\.upperBound"#
        ) else { return [] }
        let full = NSRange(source.startIndex..., in: source)
        var bindings: [RangeBinding] = []
        for match in binding.matches(in: source, range: full) {
            guard match.numberOfRanges > 1,
                  let nameRange = Range(match.range(at: 1), in: source)
            else { continue }
            bindings.append(RangeBinding(
                name: String(source[nameRange]),
                offset: match.range.location,
                anchors: []
            ))
        }
        for match in anchor.matches(in: source, range: full) {
            guard match.numberOfRanges > 1,
                  let nameRange = Range(match.range(at: 1), in: source),
                  let owner = bindings.lastIndex(
                    where: { $0.offset < match.range.location }
                  )
            else { continue }
            bindings[owner].anchors.insert(String(source[nameRange]))
        }
        return bindings
    }

    /// `(utf16Offset, description)` for every out-of-order-capable range
    /// construction in one source.
    static func unorderedRangePairs(in source: String) -> [(offset: Int, hit: String)] {
        guard let regex = try? NSRegularExpression(
            pattern: independentRangePairPattern
        ) else { return [] }
        let bindings = rangeBindings(in: source)
        let full = NSRange(source.startIndex..., in: source)
        var hits: [(offset: Int, hit: String)] = []
        for match in regex.matches(in: source, range: full) {
            guard match.numberOfRanges > 2,
                  let firstRange = Range(match.range(at: 1), in: source),
                  let secondRange = Range(match.range(at: 2), in: source)
            else { continue }
            let first = String(source[firstRange])
            let second = String(source[secondRange])
            if first == second { continue }
            // The binding of `second` THIS use sees, not any binding of that
            // name anywhere in the file.
            let visible = bindings.last {
                $0.name == second && $0.offset < match.range.location
            }
            if visible?.anchors.contains(first) == true { continue }
            hits.append((match.range.location, "\(first) … \(second)"))
        }
        return hits
    }

    func testNoIndependentlyLocatedRangePairCanStrandTheRun() throws {
        var offenders: [String] = []
        var scannedFiles = 0

        for file in try testSources() {
            let source = Self.blankingLiteralText(
                Self.blankingComments(
                    try String(contentsOf: file, encoding: .utf8)
                )
            )
            scannedFiles += 1
            for hit in Self.unorderedRangePairs(in: source) {
                guard let index = Range(
                    NSRange(location: hit.offset, length: 0), in: source
                )?.lowerBound else { continue }
                let line = source[source.startIndex..<index]
                    .filter { $0 == "\n" }.count + 1
                offenders.append(
                    "\(target(of: file))/\(file.lastPathComponent):"
                        + "\(line): \(hit.hit)"
                )
            }
        }

        XCTAssertGreaterThan(
            scannedFiles, 40,
            "the fence must actually have read the suite, not an empty listing"
        )
        XCTAssertEqual(
            offenders, [],
            "a range whose two bounds come from two INDEPENDENT searches "
                + "traps — `Range requires lowerBound <= upperBound` — the "
                + "moment the document puts the second marker first, and that "
                + "kills the PROCESS, not the cell. Search for the second "
                + "marker inside the first's tail: "
                + "`range(of: b, range: a.upperBound..<doc.endIndex)`."
        )
    }

    /// The new fence's own regression guard: every clause of the doc comment
    /// above, on synthetic sources, in both directions.
    func testTheIndependentRangePairFenceIsExactlyWhatItClaims() {
        func offenders(_ source: String) -> [String] {
            Self.unorderedRangePairs(in: source).map(\.hit)
        }

        // Reported: the r9 live sites, both range spellings.
        XCTAssertEqual(
            offenders("""
                let unreleased = changelog.range(of: a)
                let released = changelog.range(of: b)
                let section = String(changelog[unreleased.lowerBound..<released.lowerBound])
                """),
            ["unreleased … released"]
        )
        XCTAssertEqual(
            offenders("""
                let start = try XCTUnwrap(text.range(of: a))
                let end = try XCTUnwrap(text.range(of: b))
                let section = String(text[start.lowerBound...end.upperBound])
                """),
            ["start … end"],
            "a closed range traps on the same precondition"
        )
        XCTAssertEqual(
            offenders("""
                let start = doc.range(of: a)
                let end = doc.range(of: b, range: start.upperBound..<doc.endIndex)
                let bad = String(doc[end.lowerBound..<start.lowerBound])
                """),
            ["end … start"],
            "the anchor orders start BEFORE end, so the REVERSED pair is "
                + "still an offender"
        )
        // The r9 measurement, as a cell: a SECOND, anchored binding of the
        // same names elsewhere in the file must not launder this one.
        XCTAssertEqual(
            offenders("""
                func first() {
                    let start = try XCTUnwrap(text.range(of: a))
                    let end = try XCTUnwrap(text.range(of: b))
                    let section = String(text[start.lowerBound..<end.lowerBound])
                }
                func second() {
                    let start = try XCTUnwrap(script.range(of: c))
                    let end = try XCTUnwrap(
                        script.range(of: d, range: start.upperBound..<script.endIndex)
                    )
                    let function = String(script[start.lowerBound..<end.upperBound])
                }
                """),
            ["start … end"],
            "the allowance is the NEAREST binding above the use, not any "
                + "binding of that name in the file"
        )

        // Not reported, each for the reason the header states.
        for quiet in [
            // The later search is anchored inside the earlier one's tail.
            "let start = try XCTUnwrap(script.range(of: a))\n"
                + "let end = try XCTUnwrap(\n"
                + "    script.range(of: b, range: start.upperBound..<script.endIndex)\n"
                + ")\n"
                + "let function = String(script[start.lowerBound..<end.upperBound])",
            // One Range's own two ends.
            "let text = String(line[hit.lowerBound..<hit.upperBound])",
            // One-sided: no second bound to be out of order with.
            "let text = String(line[comment.lowerBound...])",
            // The second operand is not a Range bound at all.
            "body: String(source[range.upperBound..<bodyEnd])",
        ] {
            XCTAssertEqual(
                offenders(quiet), [], "must NOT be reported: \(quiet)"
            )
        }

        // The anchor belongs to the binding it sits in: one written in a
        // LATER statement does not reach back.
        XCTAssertEqual(
            offenders("""
                let start = doc.range(of: a)
                let end = doc.range(of: b)
                let other = doc.range(of: c, range: start.upperBound..<doc.endIndex)
                let bad = String(doc[start.lowerBound..<end.lowerBound])
                """),
            ["start … end"]
        )
    }

    // MARK: - Position 5: a KEYED-DICTIONARY constructor (r10, D3)

    /// `Dictionary(uniqueKeysWithValues:)` — the label alone is the offence,
    /// because it is the only thing that spells this constructor.
    ///
    /// The scan runs over sources with comments AND string-literal text
    /// blanked, which is what lets this fence — and the doc comments that
    /// explain it — spell the needle without reporting themselves.
    static let uniquelyKeyedDictionaryNeedle = "uniqueKeysWithValues"

    /// Line numbers (1-based) of every `uniqueKeysWithValues:` in one already
    /// blanked source.
    static func uniquelyKeyedDictionaries(in source: String) -> [Int] {
        var lines: [Int] = []
        for (offset, line) in source.split(
            separator: "\n", omittingEmptySubsequences: false
        ).enumerated() where line.contains(uniquelyKeyedDictionaryNeedle) {
            lines.append(offset + 1)
        }
        return lines
    }

    func testNoUniquelyKeyedDictionaryCanStrandTheRun() throws {
        var offenders: [String] = []
        var scannedFiles = 0

        for file in try testSources() {
            let source = Self.blankingLiteralText(
                Self.blankingComments(
                    try String(contentsOf: file, encoding: .utf8)
                )
            )
            scannedFiles += 1
            for line in Self.uniquelyKeyedDictionaries(in: source) {
                offenders.append(
                    "\(target(of: file))/\(file.lastPathComponent):\(line)"
                )
            }
        }

        XCTAssertGreaterThan(
            scannedFiles, 40,
            "the fence must actually have read the suite, not an empty listing"
        )
        XCTAssertEqual(
            offenders, [],
            "`Dictionary(uniqueKeysWithValues:)` traps on a duplicate key — "
                + "`Fatal error: Duplicate values for key` is a stdlib "
                + "precondition — and every site of it in this suite keyed on "
                + "a value PRODUCTION decides, which is exactly where a "
                + "regression puts a second one. Use `XCTUniquelyKeyed`, "
                + "which fails one cell and lets the run finish."
        )
    }

    /// The new fence's own regression guard, in both directions.
    func testTheUniquelyKeyedDictionaryFenceIsExactlyWhatItClaims() {
        func offenders(_ source: String) -> [Int] {
            Self.uniquelyKeyedDictionaries(
                in: Self.blankingLiteralText(Self.blankingComments(source))
            )
        }

        // Reported: the live shapes r10 converted, on one line and split.
        XCTAssertEqual(
            offenders(
                "let byID = Dictionary(uniqueKeysWithValues: "
                    + "report.entries.map { ($0.itemID, $0) })"
            ),
            [1]
        )
        XCTAssertEqual(
            offenders(
                "let bySlug = Dictionary(\n"
                    + "    uniqueKeysWithValues: outcome.items.map { ($0.id, $0) }\n"
                    + ")"
            ),
            [2],
            "the label is what is matched, so the multi-line spelling is "
                + "reported on the line that carries it"
        )

        // Not reported, each for the reason the header states.
        for quiet in [
            // A comment that explains the rule is not a breach of it.
            "// never Dictionary(uniqueKeysWithValues: pairs)",
            "/// `Dictionary(uniqueKeysWithValues:)` traps on a duplicate.",
            // The needle inside string-literal text — a failure message, or
            // this fence's own scan.
            "XCTFail(\"do not use uniqueKeysWithValues: here\")",
            // The non-trapping constructor, which is not this defect.
            "let byID = Dictionary(pairs, uniquingKeysWith: { first, _ in first })",
            // The replacement.
            "let byID = XCTUniquelyKeyed(report.entries.map { ($0.itemID, $0) })",
        ] {
            XCTAssertEqual(offenders(quiet), [], "must NOT be reported: \(quiet)")
        }
    }

    // MARK: - Position 6: an UNBOUNDED PARK (r11, D2)

    /// The one construct here that does not kill the process — it stops it.
    ///
    /// `Continuation` is the whole needle: it is what
    /// `withCheckedContinuation`, `withUnsafeContinuation`, their throwing
    /// spellings and a stored `CheckedContinuation<…>` property all have in
    /// common, and a hand-built gate cannot be written without one.
    static let continuationNeedle = "Continuation"

    /// The ONE file allowed to spell it: the file that declares
    /// `BoundedRendezvous`, the bounded park every gate in the suite now
    /// uses. Asserted to actually declare it, so moving the type without
    /// moving this constant fails HERE instead of opening a silent hole.
    static let boundedParkFile = "TestElementAccess.swift"

    /// Line numbers (1-based) of every `Continuation` in one already blanked
    /// source.
    static func continuationParks(in source: String) -> [Int] {
        var lines: [Int] = []
        for (offset, line) in source.split(
            separator: "\n", omittingEmptySubsequences: false
        ).enumerated() where line.contains(continuationNeedle) {
            lines.append(offset + 1)
        }
        return lines
    }

    /// **NOTHING IN THE SUITE MAY PARK ON A CONTINUATION IT BUILT ITSELF**
    /// (PR #460 codex r11, D2).
    ///
    /// A trap ENDS the run: the shell gets a signal, the total line is
    /// missing, and anybody looking at the log can see it. A park on a
    /// continuation nobody resumes does not end. MEASURED, with ONE
    /// production line mutated —
    /// `Sources/Cacheout/Scanner/SpaceScanner.swift`, `var
    /// includeProtectedRoots: Bool { trigger == .userInitiated }` → `{ true
    /// }`:
    ///
    ///     Test Suite 'EphemeralTempRegistrationTests' started at 17:14:20.935
    ///     Test Case '…testADecliningScannerIsNotPendingWhileTheSessionRuns' started.
    ///     <nothing at all, for 120 s, until the runner was killed>
    ///
    /// no failure, no total line, no exit code. The cell awaited
    /// `ScanRendezvous.waitUntilStarted()`, whose only resumer is a
    /// `signalStarted()` that PRODUCTION reaches only on that flag.
    ///
    /// FOUR hand-built gates had the shape — `ScanRendezvous`
    /// (`EphemeralTempRegistrationTests`), `ScanGate`
    /// (`CacheoutViewModelTests`), `ScanHoldGate`
    /// (`OrphanedCachesScannerTests`) and `AsyncGate`
    /// (`CategoryScannerTests`) — and all four now park on
    /// `BoundedRendezvous`, which resumes an abandoned waiter after a
    /// deadline and FAILS that one cell.
    ///
    /// WHAT THIS CELL DOES NOT COVER, counted rather than implied. Three
    /// Dispatch parks with no timeout remain: `group.wait()` in
    /// `DocumentedContractTests` and `CLIGateTests` (both wait for two pipe
    /// readers of a subprocess that has already exited under a
    /// `DispatchWorkItem` watchdog) and `flipperDone.wait()` in
    /// `EphemeralTempScannerTests` (waits for a detached thread whose loop
    /// exits on a flag the same `defer` just set). All three are resumed by
    /// something the TEST controls, which is the property that makes the
    /// continuation population dangerous and these three not. They are not
    /// scanned; if a future one waits on a production decision, it belongs
    /// here.
    func testNoHandBuiltGateCanParkTheRunForever() throws {
        var offenders: [String] = []
        var scannedFiles = 0
        var sanctionedSeen = 0

        for file in try testSources() {
            let source = Self.blankingLiteralText(
                Self.blankingComments(
                    try String(contentsOf: file, encoding: .utf8)
                )
            )
            scannedFiles += 1
            let lines = Self.continuationParks(in: source)
            guard file.lastPathComponent != Self.boundedParkFile else {
                sanctionedSeen = lines.count
                XCTAssertTrue(
                    source.contains("final class BoundedRendezvous"),
                    "\(Self.boundedParkFile) is the sanctioned home of the "
                        + "bounded park and no longer declares it — move the "
                        + "constant with the type"
                )
                continue
            }
            for line in lines {
                offenders.append(
                    "\(target(of: file))/\(file.lastPathComponent):\(line)"
                )
            }
        }

        XCTAssertGreaterThan(
            scannedFiles, 40,
            "the fence must actually have read the suite, not an empty listing"
        )
        XCTAssertGreaterThan(
            sanctionedSeen, 0,
            "the sanctioned file must still contain the park this fence "
                + "points every other file at — otherwise the fence is "
                + "vacuously green"
        )
        XCTAssertEqual(
            offenders, [],
            "a park on a hand-built continuation does not fail the cell and "
                + "does not kill the process — it STOPS the run, with no "
                + "failure and no total line, for as long as anybody waits "
                + "(measured: 120 s and counting, from one mutated production "
                + "line). Park on `BoundedRendezvous` instead: it fails one "
                + "cell after a deadline and lets the rest of the run finish."
        )
    }

    /// The new fence's own regression guard, in both directions.
    func testTheUnboundedParkFenceIsExactlyWhatItClaims() {
        func offenders(_ source: String) -> [Int] {
            Self.continuationParks(
                in: Self.blankingLiteralText(Self.blankingComments(source))
            )
        }

        // Reported: every spelling a hand-built gate can use.
        for shape in [
            "private var startWaiter: CheckedContinuation<Void, Never>?",
            "await withCheckedContinuation { waiters.append($0) }",
            "await withUnsafeContinuation { continuation in park(continuation) }",
            "try await withCheckedThrowingContinuation { self.store($0) }",
        ] {
            XCTAssertEqual(offenders(shape), [1], "must be reported: \(shape)")
        }

        // Not reported, each for the reason the header states.
        for quiet in [
            // A comment that explains the rule is not a breach of it.
            "// never store a CheckedContinuation in a test",
            "/// `withCheckedContinuation` parks with no deadline.",
            // The needle inside string-literal text — a failure message.
            "XCTFail(\"do not build a CheckedContinuation here\")",
            // The replacement, which spells no continuation at all.
            "await gate.park(\"a staggered scan gate\")",
        ] {
            XCTAssertEqual(offenders(quiet), [], "must NOT be reported: \(quiet)")
        }
    }

    // MARK: - The inventory this fence REPLACED

    // `forceUnwrapInventory` + `testTheForceUnwrapPopulationDoesNotGrow` stood
    // here from r6 to r7: a per-file COUNT of statement-position force-unwraps,
    // pinned so the population could only shrink. It is deleted rather than
    // kept alongside `testNoForceUnwrapCanBeDecidedByProductionCode`, for the
    // reason the review gave when it filed D4 — pinning a count makes no
    // EXISTING site safe — and for a second one this branch has been fixing
    // all round: a pinned per-file table is seventeen numbers that go stale on
    // any edit, which is the D5 class of defect, and the default-deny fence
    // needs no numbers at all. Every shape the inventory tolerated is now
    // either converted or listed in `forceUnwrapAllowances` with the reason it
    // cannot be production-decided.

    /// `private var base: URL!` and friends — a TYPE annotation, not an
    /// unwrap.
    static func isImplicitlyUnwrappedDeclaration(_ line: String) -> Bool {
        line.range(
            of: #"^\s*(@\w+\s+)*((private|fileprivate|internal|public|open)\s+)?((static|lazy|weak|unowned)\s+)*(var|let)\s+\w+\s*:\s*[^=]+!\s*$"#,
            options: .regularExpression
        ) != nil
    }

    // MARK: - A minimal Swift-call scanner (enough for assertion call sites)

    /// Replace every `//` line comment and `/* … */` block comment with
    /// spaces, preserving newlines and offsets. String literals are tracked so
    /// a `//` inside one (a URL, a path) is never mistaken for a comment.
    static func blankingComments(_ source: String) -> String {
        var output = ""
        output.reserveCapacity(source.count)
        var characters = Array(source)
        var index = 0
        var inString = false
        var inMultiline = false
        var escaped = false
        var blockDepth = 0
        func isTripleQuote(_ at: Int) -> Bool {
            at + 2 < characters.count && characters[at] == "\""
                && characters[at + 1] == "\"" && characters[at + 2] == "\""
        }
        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : "\0"
            if inMultiline {
                if isTripleQuote(index) {
                    inMultiline = false
                    output += "\"\"\""; index += 3; continue
                }
                output.append(character)
                index += 1
                continue
            }
            if blockDepth > 0 {
                if character == "/" && next == "*" {
                    blockDepth += 1
                    output += "  "; index += 2; continue
                }
                if character == "*" && next == "/" {
                    blockDepth -= 1
                    output += "  "; index += 2; continue
                }
                output.append(character == "\n" ? "\n" : " ")
                index += 1
                continue
            }
            if inString {
                output.append(character)
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                index += 1
                continue
            }
            if isTripleQuote(index) {
                inMultiline = true
                output += "\"\"\""; index += 3; continue
            }
            if character == "\"" {
                inString = true; output.append(character); index += 1; continue
            }
            if character == "/" && next == "/" {
                while index < characters.count, characters[index] != "\n" {
                    output.append(" "); index += 1
                }
                continue
            }
            if character == "/" && next == "*" {
                blockDepth = 1
                output += "  "; index += 2; continue
            }
            output.append(character)
            index += 1
        }
        return output
    }

    /// Blank every string literal's TEXT, keeping `\( … )` interpolations —
    /// they are code, and a subscript inside one traps like any other.
    ///
    /// Run AFTER `blankingComments`. Newlines are preserved so line numbers
    /// stay the file's own. RAW strings (`#"…"#`) are blanked WHOLE, escapes
    /// and interpolations included: no test uses a raw-string interpolation,
    /// and blanking them keeps this scanner from having to model `\#(`.
    static func blankingLiteralText(_ source: String) -> String {
        enum Context {
            case code
            case single
            case multi
            case raw(hashes: Int)
            /// Inside `\( … )`; the payload is the nesting depth of `(`.
            case interpolation(depth: Int)
        }
        let characters = Array(source)
        var output: [Character] = []
        output.reserveCapacity(characters.count)
        var stack: [Context] = [.code]
        var index = 0

        func blank(_ character: Character) {
            output.append(character == "\n" ? "\n" : " ")
        }
        func matches(_ at: Int, _ literal: [Character]) -> Bool {
            guard at + literal.count <= characters.count else { return false }
            for (offset, expected) in literal.enumerated()
            where characters[at + offset] != expected {
                return false
            }
            return true
        }

        while index < characters.count {
            let character = characters[index]
            switch stack[stack.count - 1] {
            case .code, .interpolation:
                if character == "#" {
                    var hashes = 0
                    var cursor = index
                    while cursor < characters.count, characters[cursor] == "#" {
                        hashes += 1
                        cursor += 1
                    }
                    if cursor < characters.count, characters[cursor] == "\"" {
                        for position in index...cursor {
                            output.append(characters[position])
                        }
                        index = cursor + 1
                        stack.append(.raw(hashes: hashes))
                        continue
                    }
                }
                if matches(index, ["\"", "\"", "\""]) {
                    output.append(contentsOf: ["\"", "\"", "\""])
                    index += 3
                    stack.append(.multi)
                    continue
                }
                if character == "\"" {
                    output.append(character)
                    index += 1
                    stack.append(.single)
                    continue
                }
                if case .interpolation(let depth) = stack[stack.count - 1] {
                    if character == "(" {
                        stack[stack.count - 1] = .interpolation(depth: depth + 1)
                    } else if character == ")" {
                        if depth == 0 {
                            stack.removeLast()
                        } else {
                            stack[stack.count - 1] =
                                .interpolation(depth: depth - 1)
                        }
                    }
                }
                output.append(character)
                index += 1
            case .single, .multi:
                let isMulti: Bool
                if case .multi = stack[stack.count - 1] { isMulti = true }
                else { isMulti = false }
                if character == "\\" {
                    if index + 1 < characters.count,
                       characters[index + 1] == "(" {
                        output.append("\\")
                        output.append("(")
                        index += 2
                        stack.append(.interpolation(depth: 0))
                        continue
                    }
                    blank(character)
                    if index + 1 < characters.count { blank(characters[index + 1]) }
                    index += 2
                    continue
                }
                if isMulti, matches(index, ["\"", "\"", "\""]) {
                    output.append(contentsOf: ["\"", "\"", "\""])
                    index += 3
                    stack.removeLast()
                    continue
                }
                if !isMulti, character == "\"" {
                    output.append(character)
                    index += 1
                    stack.removeLast()
                    continue
                }
                blank(character)
                index += 1
            case .raw(let hashes):
                if character == "\"" {
                    var cursor = index + 1
                    var seen = 0
                    while cursor < characters.count, characters[cursor] == "#",
                          seen < hashes {
                        seen += 1
                        cursor += 1
                    }
                    if seen == hashes {
                        for position in index..<cursor {
                            output.append(characters[position])
                        }
                        index = cursor
                        stack.removeLast()
                        continue
                    }
                }
                blank(character)
                index += 1
            }
        }
        return String(output)
    }

    private struct AssertionCall {
        let name: String
        let start: String.Index
        let body: String
    }

    /// Every `XCTAssert*` / `XCTFail` / `XCTUnwrap` call, with the text
    /// between its parentheses. String literals and nesting are tracked so a
    /// `)` inside a message never closes the call early.
    private static func assertionCalls(in source: String) -> [AssertionCall] {
        var calls: [AssertionCall] = []
        var index = source.startIndex
        while index < source.endIndex {
            guard let range = source.range(
                of: #"\b(XCTAssert[A-Za-z]*|XCTFail|XCTUnwrap)\s*\("#,
                options: .regularExpression, range: index..<source.endIndex
            ) else { break }
            let name = source[range].prefix { $0 != "(" && !$0.isWhitespace }
            var cursor = range.upperBound
            var depth = 1
            var inString = false
            var escaped = false
            while cursor < source.endIndex, depth > 0 {
                let character = source[cursor]
                if inString {
                    if escaped { escaped = false }
                    else if character == "\\" { escaped = true }
                    else if character == "\"" { inString = false }
                } else if character == "\"" {
                    inString = true
                } else if character == "(" {
                    depth += 1
                } else if character == ")" {
                    depth -= 1
                }
                cursor = source.index(after: cursor)
            }
            guard depth == 0 else { break }
            let bodyEnd = source.index(before: cursor)
            calls.append(AssertionCall(
                name: String(name), start: range.lowerBound,
                body: String(source[range.upperBound..<bodyEnd])
            ))
            index = range.upperBound
        }
        return calls
    }

    /// Split an argument list on TOP-LEVEL commas — never one inside a
    /// literal, a nested call, a closure, a collection, or a `\(…)`
    /// interpolation.
    private static func splitTopLevel(_ body: String) -> [String] {
        var arguments: [String] = []
        var current = ""
        var depth = 0
        var inString = false
        var escaped = false
        var interpolation = 0
        for character in body {
            if inString {
                current.append(character)
                if escaped {
                    if character == "(" { interpolation += 1 }
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if interpolation > 0 {
                    if character == "(" { interpolation += 1 }
                    if character == ")" { interpolation -= 1 }
                } else if character == "\"" {
                    inString = false
                }
                continue
            }
            switch character {
            case "\"": inString = true; current.append(character)
            case "(", "[", "{": depth += 1; current.append(character)
            case ")", "]", "}": depth -= 1; current.append(character)
            case "," where depth == 0:
                arguments.append(current); current = ""
            default: current.append(character)
            }
        }
        arguments.append(current)
        return arguments
    }

    /// The trapping constructs, named so the failure says WHICH one.
    /// A force-unwrap is `x!`; `!=`, `!x` and `!!` are not.
    private static func trap(in argument: String) -> String? {
        if argument.range(
            of: #"\[\s*[0-9]+\s*\]"#, options: .regularExpression
        ) != nil {
            return "integer subscript"
        }
        if argument.range(of: "try!") != nil { return "try!" }
        if argument.range(
            of: #"[A-Za-z0-9_\)\]]!(?!=)"#, options: .regularExpression
        ) != nil {
            return "force-unwrap"
        }
        return nil
    }
}
