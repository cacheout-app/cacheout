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
/// ## What this fence does NOT cover, stated rather than implied
///
/// The forbidden set is `try!` and an integer subscript on a named receiver —
/// the two constructs measured to have stranded THIS suite. Swift has others,
/// and pretending otherwise is the failure mode this file exists to correct:
///
/// - **force-unwrap (`x!`) in statement position** — 86 sites across 17 files
///   at r6 (the inventory below is the measurement), most of them on
///   compile-time-constant expressions
///   (`"…".data(using: .utf8)!`, `TimeZone(identifier: "UTC")!`) or on
///   `setUp`-assigned implicitly-unwrapped fixtures. Converting them is a
///   change to nearly every file in the suite and is NOT in this PR. It is
///   enforced the other way instead: `testTheForceUnwrapPopulationDoesNotGrow`
///   pins the count PER FILE, so a new one fails and a converted one has to be
///   deducted. Force-unwrap in MESSAGE position stays forbidden outright.
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
    /// An INTEGER SUBSCRIPT on a named receiver — the receiver is usually a
    /// collection production filled, so "it cannot be empty" is a claim about
    /// the code under test. A subscript into an array LITERAL (`+ [0]`,
    /// `[20]`) is not one: the regex requires an identifier, `)` or `]`
    /// immediately before the bracket.
    private static let statementTraps: [(name: String, pattern: String)] = [
        ("try!", #"\btry!"#),
        ("integer subscript", #"[A-Za-z0-9_\)\]]\s*\[\s*[0-9]+\s*\]"#),
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

    // MARK: - The population this fence does NOT convert, pinned so it cannot grow

    /// Statement-position force-unwraps, PER FILE, as measured at PR #460
    /// codex r6.
    ///
    /// This is an INVENTORY, not an approval. `x!` strands exactly like the
    /// two constructs above; there are simply too many of them, on too many
    /// provably-constant expressions, to convert inside this PR. Pinning the
    /// per-file count is the enforcement that fits: a NEW one fails this cell,
    /// and a CONVERTED one fails it too until the number is deducted — so the
    /// population can only shrink, and every movement is reviewed.
    ///
    /// Implicitly-unwrapped PROPERTY DECLARATIONS (`private var base: URL!`)
    /// are not force-unwraps and are not counted; the use sites of those
    /// properties are.
    private static let forceUnwrapInventory: [String: Int] = [
        "CacheoutHelperTests/MemlimitWorkaroundTests.swift": 2,
        "CacheoutHelperTests/SysctlJournalTests.swift": 1,
        "CacheoutTests/BuildArtifactsScannerTests.swift": 4,
        "CacheoutTests/CacheoutViewModelTests.swift": 2,
        "CacheoutTests/CategoryScannerTests.swift": 2,
        "CacheoutTests/CompressorTrackerTests.swift": 2,
        "CacheoutTests/DepthSafeRemovalTests.swift": 3,
        "CacheoutTests/DevRootsSettingsTests.swift": 1,
        "CacheoutTests/EphemeralTempRegistrationTests.swift": 1,
        "CacheoutTests/EphemeralTempScannerTests.swift": 3,
        "CacheoutTests/GitWorktreeScannerTests.swift": 1,
        "CacheoutTests/HeadlessTests.swift": 35,
        "CacheoutTests/OrphanedCachesScannerTests.swift": 8,
        "CacheoutTests/PredictiveEngineTests.swift": 6,
        "CacheoutTests/RecommendationEngineTests.swift": 2,
        "CacheoutTests/WorktreeReclaimPerformerTests.swift": 12,
        "CacheoutTests/WorktreeStalenessAssessorTests.swift": 1,
    ]

    func testTheForceUnwrapPopulationDoesNotGrow() throws {
        var counts: [String: Int] = [:]
        for file in try testSources() {
            let source = Self.blankingLiteralText(
                Self.blankingComments(
                    try String(contentsOf: file, encoding: .utf8)
                )
            )
            var found = 0
            for line in source.split(
                separator: "\n", omittingEmptySubsequences: false
            ) {
                if Self.isImplicitlyUnwrappedDeclaration(String(line)) {
                    continue
                }
                var cursor = line.startIndex
                while let hit = line.range(
                    of: #"[A-Za-z0-9_\)\]]!(?!=)"#,
                    options: .regularExpression,
                    range: cursor..<line.endIndex
                ) {
                    found += 1
                    cursor = hit.upperBound
                }
            }
            if found > 0 {
                counts["\(target(of: file))/\(file.lastPathComponent)"] = found
            }
        }
        XCTAssertEqual(
            counts, Self.forceUnwrapInventory,
            "the statement-position force-unwrap inventory moved. A NEW `x!` "
                + "is refused (use `try XCTUnwrap`); a REMOVED one means the "
                + "number here is stale and must be deducted."
        )
    }

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
