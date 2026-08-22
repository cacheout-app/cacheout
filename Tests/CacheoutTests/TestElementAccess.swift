import XCTest

/// # Why this file exists: a trapping subscript strands the WHOLE run
///
/// The shape it replaces is `XCTAssertEqual(xs.count, 2)` followed by
/// `xs[0]` / `xs[1]`. `XCTAssertEqual` does **not** halt the cell — it
/// records a failure and returns — so when production emits fewer elements
/// than the fixture expects, control reaches the subscript anyway and
/// `Array.subscript` traps. A trap is a `SIGILL` in the **test process**, not
/// a test failure: the runner dies mid-suite, every cell that had not yet run
/// is never run, and nothing in the output says so.
///
/// MEASURED on this branch (PR #460 codex r3): emitting one disclosure
/// instead of two from `CacheoutViewModel.gitWorktreeTrashDisclosures` made
/// `CleanSheetPresentationTests.testBothModesDiscloseSeparatelyAndInOrder`
/// trap at its `disclosures[0]`. The run printed **461 passed, 0 failures**
/// and the swift-testing footer printed `✔ Test run … passed`, while **985 of
/// the 1446 cells never ran** — including every `GitWorktree*` /
/// `Worktree*` cell, i.e. the entire deletion-safety suite this PR's evidence
/// rests on, because `CleanSheet…` sorts ahead of them.
///
/// So a trapping subscript in ANY cell that sorts early is a global
/// false-green: it converts a regression anywhere later in the alphabet into
/// silence.
///
/// ## The rule
///
/// **In tests, never subscript an array whose length is decided by
/// production code.** Use `XCTUnwrapElement`, which fails exactly one cell
/// and lets the other 1445 run.
///
/// Adding a *count* assertion is not a fix, and that is not a hypothesis:
/// the measured strand above happened with `XCTAssertEqual(disclosures.count,
/// 2, "\(disclosures)")` sitting on the line directly above the trap.
///
/// A literal-fixture subscript (`["a", "b"][0]`) cannot trap, but the sites
/// here were converted uniformly anyway: "is this array's length decided by
/// production?" is a question a future edit can silently change the answer
/// to, and a rule with an exception is a rule nobody applies.

/// Returns `array[index]`, or fails **this cell** and throws if the array is
/// too short.
///
/// - Note: the failure is attributed to the caller's file and line, so it
///   reads exactly like the `array[index]` it replaces.
func XCTUnwrapElement<Element>(
    _ array: [Element],
    _ index: Int,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> Element {
    guard array.indices.contains(index) else {
        let detail = message()
        XCTFail(
            "index \(index) is out of range for a \(array.count)-element "
                + "array"
                + (detail.isEmpty ? "" : " — \(detail)")
                + " — the array is: \(array)",
            file: file, line: line
        )
        throw XCTUnwrapElementFailure(index: index, count: array.count)
    }
    return array[index]
}

/// Thrown by `XCTUnwrapElement` after it has already recorded the failure, so
/// the cell unwinds instead of trapping. Never caught, never asserted on.
struct XCTUnwrapElementFailure: Error, CustomStringConvertible {
    let index: Int
    let count: Int

    var description: String {
        "index \(index) out of range for \(count) elements"
    }
}
