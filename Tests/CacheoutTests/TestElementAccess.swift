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
/// The rule covers a VARIABLE index too — `xs[i]` traps exactly like
/// `xs[0]`. `StrandFenceTests` reads the literal-index shape everywhere and
/// the variable-index shape wherever the index name is loop-bound to an
/// integer; PR #460 codex r8 found one live site of the latter
/// (`clauses[index]` in `WorktreeStalenessAssessorTests`, under its own
/// `XCTAssertEqual(clauses.count, 4, …)`) and measured the strand: 25 cells
/// never ran and the total line never printed.
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

// MARK: - The same rule, one constructor further

/// # `Dictionary(uniqueKeysWithValues:)` is `xs[0]` in a different hat
///
/// `Fatal error: Duplicate values for key` is a stdlib PRECONDITION
/// (`Swift/NativeDictionary.swift`), so a duplicate key kills the PROCESS
/// exactly as an out-of-range subscript does — and every site that mattered
/// was keying a dictionary by a value PRODUCTION decides (an entry's
/// `displayName`, an item's `itemID`, a scanned item's `id`), which is
/// precisely where a regression puts a second one.
///
/// PROVEN BY MUTATION (PR #460 codex r9's review, D3): appending the entry
/// twice at `CacheCleaner.swift:514` — `if let entry = outcome.entry {
/// entries.append(entry) }`, the shape of SCANNERS-ROADMAP defect D1 — let
/// the correct cell fire and survive, and then trapped a LATER cell and took
/// the rest of the run with it.
///
/// So: **in tests, never build a dictionary with `uniqueKeysWithValues:`.**
/// `XCTUniquelyKeyed` reports the duplicate, fails exactly one cell, and
/// hands back a last-wins dictionary so the rest of that cell's assertions
/// still say something. `StrandFenceTests` enforces it.

/// `Dictionary(uniqueKeysWithValues: pairs)` that FAILS THE CELL on a
/// duplicate key instead of trapping the process.
///
/// - Note: the failure is attributed to the caller's file and line, so it
///   reads exactly like the constructor it replaces. The returned dictionary
///   is last-wins, which is what `Dictionary(_:uniquingKeysWith:)` would give
///   — the value is never a licence, because the cell has already failed.
func XCTUniquelyKeyed<Key: Hashable, Value>(
    _ pairs: [(Key, Value)],
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) -> [Key: Value] {
    var result: [Key: Value] = [:]
    var duplicates: [Key] = []
    for (key, value) in pairs where result.updateValue(value, forKey: key) != nil {
        duplicates.append(key)
    }
    if !duplicates.isEmpty {
        let detail = message()
        XCTFail(
            "\(duplicates.count) duplicate key(s) — \(duplicates) — in a "
                + "\(pairs.count)-pair sequence"
                + (detail.isEmpty ? "" : " — \(detail)"),
            file: file, line: line
        )
    }
    return result
}

// MARK: - The same rule, one AWAIT further

/// # A rendezvous PRODUCTION decides, awaited with no bound, is worse than a
/// # trap
///
/// The four constructs above all kill the process, and a killed process at
/// least ENDS: the run stops, the shell gets a non-zero status, and the
/// missing total line is visible to anyone who looks. A test that parks on a
/// continuation nobody will ever resume does not end. It prints the name of
/// the cell it entered and then nothing — no failure, no total, no exit — and
/// every cell after it never runs, for as long as anyone is willing to wait.
///
/// MEASURED (PR #460 codex r11, D2), with ONE production line mutated —
/// `Sources/Cacheout/Scanner/SpaceScanner.swift`, `var includeProtectedRoots:
/// Bool { trigger == .userInitiated }` → `{ true }`, which is an ordinary
/// regression in a derived TCC gate:
///
///     Test Suite 'EphemeralTempRegistrationTests' started at 17:14:20.935
///     Test Case '…testADecliningScannerIsNotPendingWhileTheSessionRuns' started.
///     <nothing, for 120 s, until the runner was killed>
///
/// The cell awaited `ScanRendezvous.waitUntilStarted()`, whose only resumer
/// is a `signalStarted()` inside a fixture scanner that PRODUCTION invokes
/// only when `context.includeProtectedRoots == false`. The mutation removed
/// that call, so nothing was ever going to resume it.
///
/// ## The rule
///
/// **In tests, never `await` a hand-built gate that has no deadline.** Park
/// on `BoundedRendezvous`, which fails exactly one cell and lets the rest of
/// the run finish. `StrandFenceTests.testNoHandBuiltGateCanParkTheRunForever`
/// enforces it: a stored `CheckedContinuation` in the test targets must be
/// stored BY this type.
///
/// The bound is deliberately generous (30 s by default). It costs nothing on
/// the healthy path — a rendezvous that is going to be signalled is signalled
/// in microseconds — and it is not a scheduling assertion: this type never
/// fails a cell for being SLOW, only for being ABANDONED.

/// A gate that can be parked on and opened, where parking is BOUNDED: after
/// `seconds` with nothing having opened it, the waiter is resumed anyway and
/// the cell FAILS.
///
/// Lock-guarded rather than an actor so that an actor, a `@unchecked
/// Sendable` class and a plain `struct` fixture can all hold one — the four
/// hand-rolled gates it replaces were two of each.
final class BoundedRendezvous: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    /// Tickets whose deadline fired BEFORE the continuation was stored. The
    /// window is microscopic and the default bound is 30 s, but a park that
    /// resumes nobody is exactly the bug this type exists to remove, so it is
    /// closed rather than reasoned away.
    private var abandoned: Set<Int> = []
    private var nextTicket = 0

    var isOpen: Bool {
        lock.lock(); defer { lock.unlock() }; return opened
    }

    /// Open the gate and resume everyone parked on it. Idempotent.
    func open() {
        lock.lock()
        opened = true
        let waiting = Array(waiters.values)
        waiters.removeAll()
        lock.unlock()
        for waiter in waiting { waiter.resume() }
    }

    /// Shut the gate again for the next park. Never resumes anybody.
    func close() {
        lock.lock(); opened = false; lock.unlock()
    }

    /// Park until `open()`, or fail the cell after `seconds` and return
    /// `false`.
    ///
    /// - Parameter what: what the caller is waiting FOR, in the failure text
    ///   — the whole value of the bound is that the message names the
    ///   rendezvous that was never signalled.
    @discardableResult
    func park(
        _ what: String,
        within seconds: TimeInterval = 30,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Bool {
        lock.lock()
        if opened { lock.unlock(); return true }
        let ticket = nextTicket
        nextTicket += 1
        lock.unlock()

        let deadline = Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(seconds * 1_000_000_000)
            )
            self?.abandon(ticket)
        }
        await withCheckedContinuation {
            (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if opened || abandoned.contains(ticket) {
                abandoned.remove(ticket)
                lock.unlock()
                continuation.resume()
            } else {
                waiters[ticket] = continuation
                lock.unlock()
            }
        }
        deadline.cancel()

        lock.lock()
        let released = opened
        abandoned.remove(ticket)
        lock.unlock()
        if !released {
            XCTFail(
                "\(what): nothing opened this rendezvous within \(seconds)s. "
                    + "The cell fails here rather than parking the process "
                    + "forever — see BoundedRendezvous (PR #460 codex r11, "
                    + "D2). If the signal comes from a closure PRODUCTION "
                    + "invokes, production has stopped invoking it.",
                file: file, line: line
            )
        }
        return released
    }

    /// The deadline's side: resume one abandoned waiter WITHOUT opening the
    /// gate, so `park` can tell "released" from "gave up".
    private func abandon(_ ticket: Int) {
        lock.lock()
        let waiter = waiters.removeValue(forKey: ticket)
        if waiter == nil { abandoned.insert(ticket) }
        lock.unlock()
        waiter?.resume()
    }
}
