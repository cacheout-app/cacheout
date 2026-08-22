import XCTest
@testable import CacheoutHelperLib
import Foundation

// MARK: - Mock SysctlProvider

final class MockSysctlProvider: SysctlProvider {
    /// Current sysctl values keyed by name.
    var values: [String: Int32] = [:]
    /// Track all writes for assertions.
    var writes: [(name: String, value: Int32)] = []
    /// If true, read() returns nil (simulates failure).
    var failReads = false
    /// If true, write() returns false (simulates failure).
    var failWrites = false

    func read(_ name: String) -> Int32? {
        if failReads { return nil }
        return values[name]
    }

    func write(_ name: String, value: Int32) -> Bool {
        if failWrites { return false }
        writes.append((name: name, value: value))
        values[name] = value
        return true
    }
}

// MARK: - Tests

final class SysctlJournalTests: XCTestCase {

    private var tmpDir: String!
    private var journalPath: String!
    private var provider: MockSysctlProvider!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpDir = NSTemporaryDirectory() + "SysctlJournalTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: tmpDir, withIntermediateDirectories: true
        )
        journalPath = tmpDir + "/journal.plist"
        provider = MockSysctlProvider()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tmpDir)
        super.tearDown()
    }

    private func makeJournal() -> SysctlJournal {
        SysctlJournal(path: journalPath, provider: provider)
    }

    /// The journal as production last wrote it.
    ///
    /// `throws` RATHER THAN `try!` (PR #460 codex r6, D4): what this decodes
    /// is a file PRODUCTION wrote, so a regression in the writer is exactly
    /// what makes it fail — and a `try!` here turns that regression into a
    /// `SIGILL` that takes every cell after this class in the run order with
    /// it. This class sorts immediately before `WorktreeReclaimPerformerTests`
    /// and `WorktreeStalenessAssessorTests` in the single process
    /// `swift test` builds.
    private func decodedJournal() throws -> JournalState {
        let data = try Data(contentsOf: URL(fileURLWithPath: journalPath))
        return try PropertyListDecoder().decode(JournalState.self, from: data)
    }

    /// The journal file's POSIX permission bits.
    private func journalPermissions() throws -> Int {
        let attrs = try FileManager.default
            .attributesOfItem(atPath: journalPath)
        return try XCTUnwrap(
            attrs[.posixPermissions] as? Int,
            "the journal file reported no POSIX permissions: \(attrs)"
        )
    }

    /// Helper: write a journal state with a stale heartbeat (>30s old) to simulate crash.
    private func writeStaleJournal(entries: [JournalEntry]) throws {
        let state = JournalState(
            entries: entries,
            shutdownClean: false,
            lastHeartbeat: ProcessInfo.processInfo.systemUptime - 60 // 60s ago — stale
        )
        let data = try PropertyListEncoder().encode(state)
        try data.write(to: URL(fileURLWithPath: journalPath))
    }

    /// Helper: write a journal state with a fresh heartbeat (shutdownClean=false but recent).
    private func writeFreshDirtyJournal(entries: [JournalEntry]) throws {
        let state = JournalState(
            entries: entries,
            shutdownClean: false,
            lastHeartbeat: ProcessInfo.processInfo.systemUptime // just now
        )
        let data = try PropertyListEncoder().encode(state)
        try data.write(to: URL(fileURLWithPath: journalPath))
    }

    // MARK: - Record Tests

    func testRecordJournalsCurrentValue() throws {
        provider.values["kern.maxfiles"] = 12288
        let journal = makeJournal()
        journal.startup()

        let token = journal.record("kern.maxfiles")
        XCTAssertNotNil(token)

        // Verify journal file exists and has correct permissions.
        let perms = try journalPermissions()
        XCTAssertEqual(perms, 0o600, "Journal file should have 0600 permissions")

        // Verify plist content.
        let state = try decodedJournal()
        XCTAssertEqual(state.entries.count, 1)
        let recorded = try XCTUnwrap(state.entries.first)
        XCTAssertEqual(recorded.name, "kern.maxfiles")
        XCTAssertEqual(recorded.originalValue, 12288)
        XCTAssertFalse(recorded.rolledBack)

        journal.markCleanShutdown()
    }

    func testRecordFailsWhenReadFails() {
        provider.failReads = true
        let journal = makeJournal()
        journal.startup()

        let token = journal.record("kern.maxfiles")
        XCTAssertNil(token)

        journal.markCleanShutdown()
    }

    // MARK: - Rollback Tests

    func testRollbackAllRestoresValues() {
        provider.values["kern.maxfiles"] = 12288
        provider.values["kern.maxproc"] = 2048

        let journal = makeJournal()
        journal.startup()

        _ = journal.record("kern.maxfiles")
        _ = journal.record("kern.maxproc")

        // Simulate external changes.
        provider.values["kern.maxfiles"] = 99999
        provider.values["kern.maxproc"] = 99999

        journal.rollbackAll()

        // Verify writes restored original values.
        let rollbackWrites = provider.writes
        XCTAssertTrue(rollbackWrites.contains(where: { $0.name == "kern.maxfiles" && $0.value == 12288 }))
        XCTAssertTrue(rollbackWrites.contains(where: { $0.name == "kern.maxproc" && $0.value == 2048 }))

        journal.markCleanShutdown()
    }

    func testRollbackSkipsAlreadyRolledBack() {
        provider.values["kern.maxfiles"] = 12288
        let journal = makeJournal()
        journal.startup()

        _ = journal.record("kern.maxfiles")

        journal.rollbackAll()
        let firstCount = provider.writes.count

        // Second rollback should not write again.
        journal.rollbackAll()
        XCTAssertEqual(provider.writes.count, firstCount)

        journal.markCleanShutdown()
    }

    func testRollbackDuplicateSysctlRestoresFirstOriginalValue() throws {
        // Record kern.maxfiles twice with different "original" values.
        // The first record captures the true original (12288).
        // The second record captures an intermediate value (20000).
        // Rollback should restore to 12288, not 20000.
        provider.values["kern.maxfiles"] = 12288
        let journal = makeJournal()
        journal.startup()

        _ = journal.record("kern.maxfiles")  // journals original = 12288

        // Simulate the helper setting kern.maxfiles to 20000.
        provider.values["kern.maxfiles"] = 20000
        _ = journal.record("kern.maxfiles")  // journals original = 20000

        // Simulate another change.
        provider.values["kern.maxfiles"] = 99999
        provider.writes.removeAll()

        journal.rollbackAll()

        // Only the first entry's original value (12288) should be written.
        XCTAssertEqual(provider.values["kern.maxfiles"], 12288,
                       "Rollback should restore the true original value (first recorded)")

        // Should only have written once (the first entry), not twice.
        let maxfilesWrites = provider.writes.filter { $0.name == "kern.maxfiles" }
        XCTAssertEqual(maxfilesWrites.count, 1)
        XCTAssertEqual(try XCTUnwrap(maxfilesWrites.first).value, 12288)

        journal.markCleanShutdown()
    }

    // MARK: - Crash Recovery Tests

    func testCrashRecoveryRollsBackOnStaleHeartbeat() throws {
        provider.values["kern.maxfiles"] = 12288

        // Write a journal with stale heartbeat (>30s old) and shutdownClean=false.
        let entry = JournalEntry(
            id: UUID(),
            name: "kern.maxfiles", originalValue: 12288,
            rolledBack: false, timestamp: Date()
        )
        try writeStaleJournal(entries: [entry])

        // Change the value externally (simulates what the helper set before crash).
        provider.values["kern.maxfiles"] = 99999

        // Session 2: startup should detect unclean shutdown + stale heartbeat → rollback.
        let journal = makeJournal()
        journal.startup()

        XCTAssertTrue(
            provider.writes.contains(where: { $0.name == "kern.maxfiles" && $0.value == 12288 }),
            "Startup should rollback kern.maxfiles to 12288 after unclean shutdown with stale heartbeat"
        )

        journal.markCleanShutdown()
    }

    func testUncleanShutdownRollsBackRegardlessOfHeartbeat() throws {
        provider.values["kern.maxfiles"] = 12288

        // Write a journal with fresh heartbeat but shutdownClean=false.
        // Recovery is shutdown-marker-based, not heartbeat-based:
        // any unclean shutdown triggers rollback regardless of heartbeat age.
        let entry = JournalEntry(
            id: UUID(),
            name: "kern.maxfiles", originalValue: 12288,
            rolledBack: false, timestamp: Date()
        )
        try writeFreshDirtyJournal(entries: [entry])

        provider.values["kern.maxfiles"] = 99999

        let journal = makeJournal()
        journal.startup()

        XCTAssertTrue(
            provider.writes.contains(where: { $0.name == "kern.maxfiles" && $0.value == 12288 }),
            "Should rollback on unclean shutdown (shutdownClean=false) regardless of heartbeat freshness"
        )

        journal.markCleanShutdown()
    }

    func testCleanShutdownPreventsRollbackOnRestart() {
        provider.values["kern.maxfiles"] = 12288

        // Session 1: record value, clean shutdown.
        let journal1 = makeJournal()
        journal1.startup()
        _ = journal1.record("kern.maxfiles")
        journal1.markCleanShutdown()

        provider.writes.removeAll()

        // Session 2: should NOT rollback (clean shutdown marker present).
        let journal2 = makeJournal()
        journal2.startup()

        XCTAssertFalse(
            provider.writes.contains(where: { $0.name == "kern.maxfiles" }),
            "Should not rollback after clean shutdown"
        )

        journal2.markCleanShutdown()
    }

    // MARK: - Corruption Tests

    func testCorruptJournalIsReCreated() throws {
        // Write garbage to the journal file.
        try "not a valid plist".data(using: .utf8)!.write(to: URL(fileURLWithPath: journalPath))

        let journal = makeJournal()
        // Should not crash — corrupt journal is logged and re-created.
        journal.startup()

        // Verify journal is now valid.
        let state = try decodedJournal()
        XCTAssertEqual(state.entries.count, 0)

        journal.markCleanShutdown()
    }

    // MARK: - Atomic Persistence Tests

    func testJournalFilePermissions() throws {
        let journal = makeJournal()
        journal.startup()

        let perms = try journalPermissions()
        XCTAssertEqual(perms, 0o600)

        journal.markCleanShutdown()
    }

    // MARK: - Shutdown Marker Tests

    func testStartupClearsShutdownMarker() throws {
        let journal = makeJournal()
        journal.startup()

        let state = try decodedJournal()
        XCTAssertFalse(state.shutdownClean, "Startup should clear shutdownClean marker")

        journal.markCleanShutdown()
    }

    func testCleanShutdownSetsMarker() throws {
        let journal = makeJournal()
        journal.startup()
        journal.markCleanShutdown()

        let state = try decodedJournal()
        XCTAssertTrue(state.shutdownClean)
    }
}
