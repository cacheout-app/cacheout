import XCTest

/// # The THIRD strand mechanism: a trapping assertion MESSAGE (PR #460 codex r5, D5)
///
/// `TestElementAccess.swift` retired the trapping-subscript shape from the
/// *condition* position, and PR #460 codex r3 converted the sites. This file
/// closes the position that conversion did not look at: the **message**.
///
/// `XCTAssertTrue(_ expression: @autoclosure () throws -> Bool, _ message:
/// @autoclosure () -> String)` evaluates `message()` on EVERY non-pass —
/// including when `expression()` **throws**. So the shape r3 shipped,
///
/// ```swift
/// XCTAssertTrue(
///     try XCTUnwrapElement(outcome.errors, 0).detail.contains("(regular file)"),
///     "detail names the real kind: \(outcome.errors[0].detail)"   // ← traps
/// )
/// ```
///
/// converts the very failure `XCTUnwrapElement` exists to make survivable
/// back into a `SIGILL`: the unwrap records its failure and throws, XCTest
/// catches the throw, and then evaluates the message — whose `errors[0]`
/// traps on the empty array. MEASURED on this branch: dropping the issue
/// emission in `EphemeralTempScanner.swift:771-777` (three lines) killed the
/// runner at `EphemeralTempScannerTests.swift:2971` with `Index out of range`
/// and signal 5; the cells after it in the run order never ran, and the total
/// line never printed.
///
/// The same is true with no `try` in sight: a plain `XCTAssertEqual(xs.count,
/// 2, "\(xs[0])")` traps whenever production emits nothing, which is exactly
/// the regression the assertion was written to catch.
///
/// ## What this fence checks
///
/// Every `XCTAssert*` / `XCTFail` / `XCTUnwrap` call in `Tests/`, argument
/// list split at the top level, every argument in MESSAGE position (after the
/// condition — after BOTH operands for the binary forms; `XCTFail`'s only
/// argument) scanned for a literal integer subscript or a force-unwrap.
///
/// It is a fence, not a style rule: each hit it names is a cell that, when it
/// legitimately goes red, takes the rest of the run with it.
final class AssertionMessageFenceTests: XCTestCase {

    /// The one-argument forms take the condition first; these take two.
    private static let binaryAssertions: Set<String> = [
        "XCTAssertEqual", "XCTAssertNotEqual", "XCTAssertIdentical",
        "XCTAssertNotIdentical", "XCTAssertGreaterThan",
        "XCTAssertGreaterThanOrEqual", "XCTAssertLessThan",
        "XCTAssertLessThanOrEqual",
    ]

    private var testsDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    }

    func testNoAssertionMessageCanTrapAndStrandTheRun() throws {
        var offenders: [String] = []
        var scannedFiles = 0
        var scannedCalls = 0

        let contents = try FileManager.default.contentsOfDirectory(
            at: testsDirectory, includingPropertiesForKeys: nil
        )
        for file in contents.sorted(by: { $0.path < $1.path })
        where file.pathExtension == "swift" {
            // Comments are BLANKED rather than deleted, so the reported line
            // numbers stay the file's own — and so a doc comment quoting the
            // very shape this fence forbids (this file does, twice) is not
            // itself reported.
            let source = Self.blankingComments(
                try String(contentsOf: file, encoding: .utf8)
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
                        "\(file.lastPathComponent):\(line): \(call.name) "
                            + "message can trap (\(trap))"
                    )
                    break
                }
            }
        }

        XCTAssertGreaterThan(
            scannedFiles, 30,
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
