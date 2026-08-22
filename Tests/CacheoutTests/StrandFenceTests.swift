import XCTest

/// # The fence against constructs that STRAND the run (PR #460 codex r3/r5/r6)
///
/// A trapping construct in a test does not fail a cell — it kills the PROCESS.
/// `swift test` builds ONE bundle and runs BOTH test targets in ONE process,
/// so every cell that sorts after the trap never runs and the total line never
/// prints. This suite has been stranded that way twice, measured both times.
///
/// ## The three positions, and the order they were closed in
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
///    `EphemeralTempScannerTests.swift:2971` with `Index out of range` and
///    signal 5; the cells after it never ran and the total line never printed.
/// 3. **STATEMENT** (PR #460 codex r6, D4) — a trap needs no assertion around
///    it at all. `let call = mock.calls[0]` and `let state = try!
///    PropertyListDecoder().decode(…)` strand exactly as hard, and until r6
///    NOTHING looked at them: r3's conversion was a convention, and r5's fence
///    parsed only `XCTAssert*` argument lists.
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
/// (The suite is 1480 at r7; the figure belongs to the commit it was taken
/// at — see `WorktreeReclaimPerformerTests`' class header, D5.)
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
/// - **A subscript with a VARIABLE index (`xs[i]`) is NOT matched, and the
///   forbidden set is a LITERAL integer index only** (PR #460 codex r7, D4).
///   The r6 wording said "an integer subscript on a named receiver" and
///   explained the regex only in terms of the receiver, which reads as though
///   `xs[i]` were covered; it is not, and it traps identically. It is not
///   matched because a regex cannot tell an ARRAY subscript from a DICTIONARY
///   one, and a dictionary subscript returns an Optional and cannot trap.
///   MEASURED at r7: widening the pattern to any identifier index reports
///   **105** lines across the suite, of which the overwhelming majority are
///   dictionary reads (`failures[url.path]`, `paths[scanner.registeredID]`,
///   `environment[key]`) — a fence that is ~90% false positives is a fence
///   that gets suppressed. `testTheIntegerSubscriptPatternMatchesLiteralIndicesOnly`
///   pins this scope so the claim and the regex cannot drift apart again.
/// - **`as!`, `precondition`, `fatalError`, arithmetic overflow, out-of-range
///   `Range` subscripts, `Array(repeating:count:)` with a negative count** —
///   not scanned at all. No occurrence of any of them has stranded a run here.
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
    /// before the bracket; and a VARIABLE index (`xs[i]`) is not matched at
    /// all, because no regex can separate it from a dictionary read, which
    /// cannot trap (see the header, D4).
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
            // A VARIABLE index traps identically and is NOT reported — the
            // exclusion this cell exists to make visible rather than imply.
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
