// SysctlJournal.swift
// Crash-safe sysctl rollback journal using atomic persistence.
//
// Before any sysctl modification, the current value is recorded in a plist
// journal at /var/run/com.cacheout.memhelper.journal.plist. On unclean
// shutdown (crash / kill -9), the next startup detects the missing
// `shutdownClean` marker + stale heartbeat and rolls back all un-reverted
// entries.
//
// Persistence uses atomic temp-file + rename(2) — never writes in-place.

import Darwin
import Foundation
import os

// MARK: - SysctlProvider Protocol

/// Abstraction over sysctl read/write for testability.
/// Production uses the real kernel sysctl; tests can inject a mock.
public protocol SysctlProvider {
    func read(_ name: String) -> Int32?
    func write(_ name: String, value: Int32) -> Bool
}

/// Real sysctl provider using the kernel sysctl(3) API.
public struct SystemSysctlProvider: SysctlProvider {
    public init() {}

    public func read(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let rc = sysctlbyname(name, &value, &size, nil, 0)
        guard rc == 0 else { return nil }
        return value
    }

    public func write(_ name: String, value: Int32) -> Bool {
        var val = value
        let rc = sysctlbyname(name, nil, nil, &val, MemoryLayout<Int32>.size)
        return rc == 0
    }
}

// MARK: - Journal Entry

/// A single journaled sysctl value that can be rolled back.
public struct JournalEntry: Codable {
    /// Opaque token for entry-specific abort.
    public let id: UUID
    public let name: String
    public let originalValue: Int32
    public var rolledBack: Bool
    public let timestamp: Date
}

// MARK: - Journal State

/// Top-level plist structure persisted to disk.
///
/// `lastHeartbeat` stores monotonic system uptime (seconds since boot via
/// `ProcessInfo.processInfo.systemUptime`). Because the journal lives in
/// `/var/run/` (cleared on reboot) and sysctls also reset on reboot,
/// cross-boot comparisons never occur.
public struct JournalState: Codable {
    public var entries: [JournalEntry]
    public var shutdownClean: Bool
    /// Monotonic uptime in seconds (via ProcessInfo.systemUptime).
    public var lastHeartbeat: TimeInterval
}

// MARK: - SysctlJournal

/// Crash-safe sysctl rollback journal.
///
/// Thread-safety: all public methods serialize on an internal queue.
public final class SysctlJournal {

    private let logger = Logger(
        subsystem: "com.cacheout.memhelper",
        category: "journal"
    )

    public static let journalPath = "/var/run/com.cacheout.memhelper.journal.plist"

    private let path: String
    private let provider: SysctlProvider
    private let queue = DispatchQueue(label: "com.cacheout.memhelper.journal")

    /// Heartbeat timer — updates `lastHeartbeat` every second.
    private var heartbeatTimer: DispatchSourceTimer?

    /// In-memory journal state, flushed to disk on every mutation.
    private var state: JournalState

    /// Stale heartbeat threshold in seconds.
    /// 30s tolerates system sleep and launchd throttle windows.
    private static let staleThreshold: TimeInterval = 30

    /// Maximum age for journal entries before they are auto-reverted on startup.
    /// Entries older than 1 hour are rolled back regardless of shutdown state.
    private static let maxEntryAge: TimeInterval = 3600

    // MARK: - Init

    /// - Parameters:
    ///   - path: Journal file path. Defaults to the standard `/var/run/` location.
    ///   - provider: Sysctl read/write provider. Defaults to real kernel sysctl.
    public init(path: String = SysctlJournal.journalPath,
                provider: SysctlProvider = SystemSysctlProvider()) {
        self.path = path
        self.provider = provider
        self.state = JournalState(entries: [], shutdownClean: true,
                                  lastHeartbeat: ProcessInfo.processInfo.systemUptime)
    }

    // MARK: - Startup

    /// Called on daemon startup. Detects unclean shutdown and rolls back if needed.
    /// Clears the `shutdownClean` marker so this session starts "dirty".
    public func startup() {
        queue.sync {
            // Load existing journal if present.
            loadState()

            // Primary crash detection: shutdownClean marker absent means the prior
            // session did not call markCleanShutdown() (crash, kill -9, or panic).
            if !state.shutdownClean {
                logger.warning(
                    "Unclean shutdown detected (shutdownClean=false). Rolling back all entries."
                )
                performRollback()
            }

            // Secondary crash detection: heartbeat staleness. If shutdownClean was
            // set but the heartbeat is stale (>30s gap between last heartbeat and
            // current uptime), the process likely crashed after marking clean but
            // before fully shutting down. This catches edge cases like crashes
            // during the shutdown sequence itself.
            let currentUptime = ProcessInfo.processInfo.systemUptime
            let heartbeatAge = currentUptime - state.lastHeartbeat
            if state.shutdownClean && heartbeatAge > Self.staleThreshold
                && !state.entries.isEmpty {
                let hasUnreverted = state.entries.contains { !$0.rolledBack }
                if hasUnreverted {
                    logger.warning(
                        "Stale heartbeat detected (\(Int(heartbeatAge))s > \(Int(Self.staleThreshold))s threshold). Rolling back un-reverted entries."
                    )
                    performRollback()
                }
            }

            // Auto-revert entries older than 1 hour regardless of shutdown state.
            // This ensures no sysctl modification persists indefinitely.
            revertStaleEntries()

            // Clear shutdown marker — this session is now "dirty".
            state.shutdownClean = false
            state.lastHeartbeat = ProcessInfo.processInfo.systemUptime
            flushState()

            logger.info("Journal initialized (\(self.state.entries.count, privacy: .public) entries)")
        }

        startHeartbeat()
    }

    // MARK: - Record & Rollback

    /// Record the current sysctl value before modification.
    /// MUST be called before every sysctl write. Returns the entry's opaque token
    /// on success, or `nil` on failure. Callers must abort the sysctl write on
    /// `nil` to preserve the crash-safe rollback guarantee. Pass the returned
    /// token to `abort(_:)` if the subsequent write fails.
    ///
    /// - Parameter name: The sysctl name to journal.
    /// - Returns: An opaque entry token if the value was successfully read and durably persisted; `nil` otherwise.
    public func record(_ name: String) -> UUID? {
        queue.sync {
            guard let currentValue = provider.read(name) else {
                logger.error("Failed to read sysctl \(name, privacy: .public) for journaling")
                return nil
            }

            let token = UUID()
            let entry = JournalEntry(
                id: token,
                name: name,
                originalValue: currentValue,
                rolledBack: false,
                timestamp: Date()
            )
            state.entries.append(entry)
            guard flushState() else {
                // Roll back the in-memory append — flush failed, no durable record.
                state.entries.removeLast()
                logger.error("Journal flush failed for \(name, privacy: .public) — aborting record")
                return nil
            }
            logger.info("Journaled \(name, privacy: .public) = \(currentValue)")
            return token
        }
    }

    /// Abort a specific journal entry by its token.
    /// Called when the sysctl write fails after `record()` succeeded, to avoid
    /// leaving a stale rollback entry for a change that was never applied.
    /// Token-based abort is safe under concurrent writes to the same sysctl —
    /// each caller removes only its own entry.
    ///
    /// - Parameter token: The opaque token returned by `record()`.
    /// - Returns: `true` if the entry was durably removed; `false` if the flush
    ///   failed (the stale entry remains on disk and will be rolled back on next
    ///   startup — safe but wasteful).
    @discardableResult
    public func abort(_ token: UUID) -> Bool {
        queue.sync {
            guard let idx = state.entries.firstIndex(where: { $0.id == token }) else {
                return true // Already absent — nothing to abort.
            }
            let name = state.entries[idx].name
            let removed = state.entries.remove(at: idx)
            guard flushState() else {
                // Restore in-memory state — disk still has the entry.
                state.entries.insert(removed, at: idx)
                logger.error("Abort flush failed for \(token.uuidString, privacy: .public) (\(name, privacy: .public)) — stale entry persists on disk")
                return false
            }
            logger.info("Aborted journal entry \(token.uuidString, privacy: .public) for \(name, privacy: .public) (write failed)")
            return true
        }
    }

    /// Roll back all un-reverted journal entries.
    /// - Returns: `true` if all entries were successfully rolled back (or none needed rollback).
    @discardableResult
    public func rollbackAll() -> Bool {
        queue.sync {
            let allReverted = performRollback()
            flushState()
            return allReverted
        }
    }

    /// Write the `shutdownClean` marker and stop the heartbeat.
    /// Called during graceful SIGTERM shutdown.
    public func markCleanShutdown() {
        queue.sync {
            state.shutdownClean = true
            flushState()
        }
        stopHeartbeat()
        logger.info("Clean shutdown marker written")
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Heartbeat is diagnostic only (crash recovery uses shutdownClean marker,
        // not heartbeat staleness). Run at 60s cadence to avoid unnecessary disk IO.
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.state.lastHeartbeat = ProcessInfo.processInfo.systemUptime
            self.flushState()
        }
        heartbeatTimer = timer
        timer.resume()
    }

    private func stopHeartbeat() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }

    // MARK: - Persistence (private, called under queue)

    private func loadState() {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            state = JournalState(entries: [], shutdownClean: true,
                                 lastHeartbeat: ProcessInfo.processInfo.systemUptime)
            return
        }

        do {
            let data = try Data(contentsOf: url)
            state = try PropertyListDecoder().decode(JournalState.self, from: data)
        } catch {
            // Corruption: log and re-create (don't crash).
            logger.error("Journal corrupt, re-creating: \(error.localizedDescription, privacy: .public)")
            state = JournalState(entries: [], shutdownClean: true,
                                 lastHeartbeat: ProcessInfo.processInfo.systemUptime)
        }
    }

    /// Atomically flush state to disk: write temp file, then rename(2).
    /// - Returns: `true` if the state was durably persisted.
    @discardableResult
    private func flushState() -> Bool {
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()
        let tmpURL = dir.appendingPathComponent(
            ".com.cacheout.memhelper.journal.\(ProcessInfo.processInfo.processIdentifier).tmp"
        )

        do {
            let data = try PropertyListEncoder().encode(state)

            // Write to temp file (non-atomic — we control the rename ourselves).
            try data.write(to: tmpURL)

            // Set permissions to 0600 (root-only) on temp file before rename.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: tmpURL.path
            )

            // Atomic rename(2) — atomicity on APFS/HFS+.
            if rename(tmpURL.path, url.path) != 0 {
                let err = String(cString: strerror(errno))
                logger.error("rename(2) failed: \(err, privacy: .public)")
                try? FileManager.default.removeItem(at: tmpURL)
                return false
            }
            return true
        } catch {
            logger.error("Failed to flush journal: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: tmpURL)
            return false
        }
    }

    /// Revert journal entries whose timestamp is older than `maxEntryAge`.
    ///
    /// Only the first entry per sysctl name holds the true original value; if it
    /// is stale, we write it back. After a successful revert, ALL remaining
    /// entries for that sysctl (stale or fresh) are marked rolled back so a later
    /// `rollbackAll()` does not restore an intermediate value.
    private func revertStaleEntries() {
        let now = Date()
        var firstStaleIndex: [String: Int] = [:]

        // Identify stale, un-rolled-back entries.
        for i in state.entries.indices {
            guard !state.entries[i].rolledBack else { continue }
            let age = now.timeIntervalSince(state.entries[i].timestamp)
            guard age > Self.maxEntryAge else { continue }
            if firstStaleIndex[state.entries[i].name] == nil {
                firstStaleIndex[state.entries[i].name] = i
            }
        }

        guard !firstStaleIndex.isEmpty else { return }

        logger.info("Auto-reverting \(firstStaleIndex.count, privacy: .public) stale sysctl entries (> 1h)")

        // Track which sysctls were successfully reverted so we can mark ALL
        // entries (including fresh duplicates) as rolled back.
        var revertedNames: Set<String> = []

        for i in state.entries.indices {
            guard !state.entries[i].rolledBack else { continue }
            let age = now.timeIntervalSince(state.entries[i].timestamp)
            guard age > Self.maxEntryAge else { continue }

            let entry = state.entries[i]
            if firstStaleIndex[entry.name] == i {
                // First entry: write the original value.
                if provider.write(entry.name, value: entry.originalValue) {
                    state.entries[i].rolledBack = true
                    revertedNames.insert(entry.name)
                    logger.info("Auto-reverted stale entry \(entry.name, privacy: .public) to \(entry.originalValue)")
                } else {
                    logger.error("Failed to auto-revert stale entry \(entry.name, privacy: .public)")
                }
            } else {
                // Duplicate stale entry: mark as rolled back.
                state.entries[i].rolledBack = true
            }
        }

        // Mark ALL remaining entries for reverted sysctls as rolled back,
        // including fresh duplicates, to prevent rollbackAll() from restoring
        // an intermediate value.
        if !revertedNames.isEmpty {
            for i in state.entries.indices {
                guard !state.entries[i].rolledBack else { continue }
                if revertedNames.contains(state.entries[i].name) {
                    state.entries[i].rolledBack = true
                    logger.info("Marked fresh duplicate \(self.state.entries[i].name, privacy: .public) as rolled back after stale revert")
                }
            }
        }
    }

    /// Roll back un-reverted entries, restoring the true original value per sysctl.
    ///
    /// When the same sysctl is journaled multiple times (e.g. set kern.maxfiles
    /// twice), only the *first* entry holds the true pre-modification value.
    /// We iterate forward, write only the first entry per name, and mark all
    /// subsequent duplicates as rolled back (they hold intermediate values).
    ///
    /// - Returns: `true` if all entries were successfully rolled back.
    @discardableResult
    private func performRollback() -> Bool {
        // Collect the first un-rolled-back entry per sysctl name.
        var firstEntryIndex: [String: Int] = [:]
        for i in state.entries.indices {
            guard !state.entries[i].rolledBack else { continue }
            if firstEntryIndex[state.entries[i].name] == nil {
                firstEntryIndex[state.entries[i].name] = i
            }
        }

        var allSucceeded = true

        for i in state.entries.indices {
            guard !state.entries[i].rolledBack else { continue }
            let entry = state.entries[i]

            if firstEntryIndex[entry.name] == i {
                // This is the first (true original) entry — write it.
                if provider.write(entry.name, value: entry.originalValue) {
                    state.entries[i].rolledBack = true
                    logger.info("Rolled back \(entry.name, privacy: .public) to \(entry.originalValue)")
                } else {
                    allSucceeded = false
                    logger.error("Failed to rollback \(entry.name, privacy: .public)")
                }
            } else {
                // Duplicate — skip the write, just mark as rolled back.
                state.entries[i].rolledBack = true
            }
        }

        return allSucceeded
    }
}
