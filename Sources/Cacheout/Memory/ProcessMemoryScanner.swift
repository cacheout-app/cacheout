// ProcessMemoryScanner.swift
// Scans per-process memory metrics using proc_pid_rusage V4.

import CacheoutShared
import Darwin
import Foundation
import os

/// Scans all running processes for memory metrics and produces `ProcessEntryDTO` entries.
///
/// ## Data Sources
/// - `proc_listallpids` for PID enumeration
/// - `proc_pid_rusage(RUSAGE_INFO_V4)` for per-process memory metrics
/// - `RosettaDetector` for Rosetta 2 translation detection
///
/// ## Privilege Handling
/// When more than 50% of PIDs fail with EPERM, the scanner routes through
/// the CacheoutHelper privileged XPC service. If the helper is unavailable,
/// partial results are returned.
///
/// ## Concurrency
/// Uses a fixed-width worker pool (max 8 concurrent tasks) to avoid
/// unbounded fanout across hundreds of PIDs.
actor ProcessMemoryScanner {

    /// Result of a process scan, including metadata about data source.
    struct ScanResult: Sendable {
        /// Processes sorted by physical footprint descending.
        let processes: [ProcessEntryDTO]
        /// Data source: "proc_pid_rusage" or "privileged_helper".
        let source: String
        /// Whether results are incomplete due to permission restrictions.
        let partial: Bool
    }

    private let logger = Logger(subsystem: "com.cacheout", category: "ProcessMemoryScanner")

    /// Maximum concurrent proc_pid_rusage calls.
    private let maxConcurrency = 8

    /// EPERM failure threshold (fraction) before attempting privileged helper.
    private let epermThreshold = 0.5

    // MARK: - Public API

    /// Scan all running processes and return sorted by physical footprint.
    ///
    /// - Parameter topN: If non-nil, return only the top N processes by footprint.
    /// - Returns: A `ScanResult` with processes, data source, and partial flag.
    func scan(topN: Int? = nil) async -> ScanResult {
        let pids = listAllPIDs()
        guard !pids.isEmpty else {
            return ScanResult(processes: [], source: "proc_pid_rusage", partial: false)
        }

        let (entries, epermCount) = await scanPIDs(pids)
        let epermFraction = Double(epermCount) / Double(pids.count)

        // If too many EPERM failures, try privileged helper
        if epermFraction > epermThreshold {
            logger.notice("EPERM rate \(String(format: "%.0f%%", epermFraction * 100)) exceeds threshold — attempting privileged helper")
            if let helperEntries = await scanViaHelper() {
                let sorted = sortAndLimit(helperEntries, topN: topN)
                return ScanResult(processes: sorted, source: "privileged_helper", partial: false)
            }
            // Helper unavailable — return partial unprivileged results
            logger.warning("Privileged helper unavailable — returning partial results")
            let sorted = sortAndLimit(entries, topN: topN)
            return ScanResult(processes: sorted, source: "proc_pid_rusage", partial: true)
        }

        let sorted = sortAndLimit(entries, topN: topN)
        return ScanResult(processes: sorted, source: "proc_pid_rusage", partial: epermCount > 0)
    }

    // MARK: - PID Enumeration

    /// List all PIDs on the system via `proc_listallpids`.
    private nonisolated func listAllPIDs() -> [pid_t] {
        // proc_listallpids(nil, 0) returns an estimated PID count (not bytes).
        let estimatedCount = proc_listallpids(nil, 0)
        guard estimatedCount > 0 else { return [] }

        // Allocate with headroom for new processes between the two calls.
        let pidCount = Int(estimatedCount) + 64
        var pids = [pid_t](repeating: 0, count: pidCount)
        let bufferBytes = Int32(pidCount * MemoryLayout<pid_t>.stride)
        let actualCount = proc_listallpids(&pids, bufferBytes)
        guard actualCount > 0 else { return [] }

        return Array(pids.prefix(Int(actualCount)).filter { $0 > 0 })
    }

    // MARK: - Unprivileged Scan

    /// Scan a list of PIDs using proc_pid_rusage with capped concurrency.
    ///
    /// Returns the collected entries and the count of EPERM failures.
    private func scanPIDs(_ pids: [pid_t]) async -> (entries: [ProcessEntryDTO], epermCount: Int) {
        // Chunk PIDs to cap concurrency at maxConcurrency.
        let chunks = stride(from: 0, to: pids.count, by: maxConcurrency).map {
            Array(pids[$0..<min($0 + maxConcurrency, pids.count)])
        }

        var allEntries: [ProcessEntryDTO] = []
        var totalEperm = 0

        for chunk in chunks {
            await withTaskGroup(of: ScanPIDResult.self) { group in
                for pid in chunk {
                    group.addTask { [self] in
                        self.scanSinglePID(pid)
                    }
                }
                for await result in group {
                    switch result {
                    case .success(let entry):
                        allEntries.append(entry)
                    case .eperm:
                        totalEperm += 1
                    case .otherError:
                        break
                    }
                }
            }
        }

        return (allEntries, totalEperm)
    }

    /// Result of scanning a single PID.
    private enum ScanPIDResult: Sendable {
        case success(ProcessEntryDTO)
        case eperm
        case otherError
    }

    /// Scan a single PID using proc_pid_rusage V4.
    private nonisolated func scanSinglePID(_ pid: pid_t) -> ScanPIDResult {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            // Rebind the rusage_info_v4 buffer to the type proc_pid_rusage expects.
            // The function writes the full struct into the buffer at ptr's address.
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rusagePtr in
                proc_pid_rusage(pid, Int32(RUSAGE_INFO_V4), rusagePtr)
            }
        }

        guard result == 0 else {
            if errno == EPERM {
                return .eperm
            }
            return .otherError
        }

        // Get process name
        let name: String
        let pathBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: Int(MAXPATHLEN))
        defer { pathBuffer.deallocate() }
        let pathLen = proc_pidpath(pid, pathBuffer, UInt32(MAXPATHLEN))

        if pathLen > 0 {
            let fullPath = String(cString: pathBuffer)
            name = (fullPath as NSString).lastPathComponent
        } else {
            // Fallback to proc_name
            let nameBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: Int(MAXCOMLEN) + 1)
            defer { nameBuffer.deallocate() }
            let nameLen = proc_name(pid, nameBuffer, UInt32(MAXCOMLEN + 1))
            name = nameLen > 0 ? String(cString: nameBuffer) : "unknown"
        }

        let isRosetta = RosettaDetector.isTranslated(pid: pid)

        // CRITICAL: Use ri_phys_footprint, NOT ru_maxrss (always zero on macOS)
        let physFootprint = info.ri_phys_footprint
        let lifetimeMax = info.ri_lifetime_max_phys_footprint

        let leakIndicator: Double = physFootprint > 0
            ? Double(lifetimeMax) / Double(physFootprint)
            : 0.0

        let entry = ProcessEntryDTO(
            pid: pid,
            name: name,
            physFootprint: physFootprint,
            lifetimeMaxFootprint: lifetimeMax,
            pageins: info.ri_pageins,
            jetsamPriority: -1,  // Deferred to jetsam integration
            jetsamLimit: -1,     // Deferred to jetsam integration
            isRosetta: isRosetta,
            leakIndicator: leakIndicator
        )
        return .success(entry)
    }

    // MARK: - Privileged Helper Fallback

    /// Timeout for the privileged helper XPC call in seconds.
    private let helperTimeoutSeconds: UInt64 = 10

    /// Scan via the CacheoutHelper privileged XPC service.
    ///
    /// Returns `nil` if the helper is not available, the call fails, or the call
    /// does not complete within `helperTimeoutSeconds`.
    private func scanViaHelper() async -> [ProcessEntryDTO]? {
        // Capture logger outside the closure to avoid actor-isolation issues.
        let log = Logger(subsystem: "com.cacheout", category: "ProcessMemoryScanner")

        let connection = NSXPCConnection(machServiceName: "com.cacheout.memhelper", options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: MemoryHelperProtocol.self)
        connection.resume()

        // Use a sendable box to ensure the continuation is resumed exactly once.
        // Both the error handler, reply callback, and timeout can fire; only the first wins.
        final class OnceBox: @unchecked Sendable {
            private var resumed = false
            private let lock = NSLock()
            func tryResume(_ continuation: CheckedContinuation<[ProcessEntryDTO]?, Never>, returning value: [ProcessEntryDTO]?) -> Bool {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return false }
                resumed = true
                continuation.resume(returning: value)
                return true
            }
        }

        let timeoutNanos = helperTimeoutSeconds

        let result = await withCheckedContinuation { (continuation: CheckedContinuation<[ProcessEntryDTO]?, Never>) in
            let once = OnceBox()

            // Start a timeout task that resumes with nil if the helper is too slow.
            Task {
                try? await Task.sleep(nanoseconds: timeoutNanos * 1_000_000_000)
                if once.tryResume(continuation, returning: nil) {
                    log.warning("Privileged helper timed out after \(timeoutNanos)s")
                }
            }

            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                log.error("XPC error: \(error.localizedDescription, privacy: .public)")
                _ = once.tryResume(continuation, returning: nil)
            }

            guard let helper = proxy as? MemoryHelperProtocol else {
                _ = once.tryResume(continuation, returning: nil)
                return
            }

            helper.getProcessList { data in
                guard !data.isEmpty else {
                    _ = once.tryResume(continuation, returning: nil)
                    return
                }
                do {
                    let entries = try JSONDecoder().decode([ProcessEntryDTO].self, from: data)
                    _ = once.tryResume(continuation, returning: entries)
                } catch {
                    log.error("Failed to decode helper process list: \(error.localizedDescription, privacy: .public)")
                    _ = once.tryResume(continuation, returning: nil)
                }
            }
        }

        connection.invalidate()
        return result
    }

    // MARK: - Sorting

    /// Sort by physical footprint descending and optionally limit to top N.
    private nonisolated func sortAndLimit(_ entries: [ProcessEntryDTO], topN: Int?) -> [ProcessEntryDTO] {
        let sorted = entries.sorted { $0.physFootprint > $1.physFootprint }
        if let topN {
            return Array(sorted.prefix(topN))
        }
        return sorted
    }
}
