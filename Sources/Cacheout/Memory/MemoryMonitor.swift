/// # MemoryMonitor — System-wide VM Stats Polling
///
/// An actor that polls system-wide memory statistics at 1Hz (foreground) or
/// 0.1Hz (background) and publishes `SystemStatsDTO` snapshots via an
/// `AsyncStream`.
///
/// ## Data Sources
///
/// - `host_statistics64(HOST_VM_INFO64)` for page counts and activity counters
/// - `vm.compressor_compressed_bytes` / `vm.compressor_bytes_used` for compressor stats
/// - `vm.swapusage` for swap usage
/// - `kern.memorystatus_vm_pressure_level` for pressure level
/// - `vm_kernel_page_size` for dynamic page size (16384 on Apple Silicon)
/// - `hw.memsize` for total physical memory
///
/// ## Lifecycle
///
/// Call ``start()`` to begin polling (idempotent). Call ``stop()`` to cancel
/// the background task. Foreground/background mode is determined by
/// `NSApp.isActive` and updated via NotificationCenter observers.

import AppKit
import CacheoutShared
import Darwin
import os

actor MemoryMonitor {

    // MARK: - Public Stream

    /// The latest system stats snapshot. Consumers iterate this to receive
    /// new samples at the current polling rate.
    ///
    /// > Note: `AsyncStream` is single-consumer. For multiple consumers,
    /// > use ``subscribe()`` which creates a dedicated stream per subscriber.
    let stats: AsyncStream<SystemStatsDTO>

    // MARK: - Subscription (Fan-out)

    /// Active subscriber continuations for fan-out broadcasting.
    private var subscribers: [UUID: AsyncStream<SystemStatsDTO>.Continuation] = [:]

    /// Create a new stream that receives all future `SystemStatsDTO` snapshots.
    /// Each call returns an independent stream — multiple consumers can
    /// subscribe without contending for elements.
    ///
    /// The stream finishes when the subscriber is deallocated (via the
    /// `onTermination` handler) or when the monitor is stopped.
    func subscribe() -> AsyncStream<SystemStatsDTO> {
        let id = UUID()
        let stream = AsyncStream<SystemStatsDTO>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            self.subscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in
                    await self?.removeSubscriber(id)
                }
            }
        }
        return stream
    }

    /// Remove a subscriber by ID.
    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    // MARK: - Private State

    private let streamContinuation: AsyncStream<SystemStatsDTO>.Continuation
    private var pollingTask: Task<Void, Never>?
    private var isRunning = false

    /// Monotonically increasing generation counter. Incremented on every
    /// start/stop transition to detect stale resumes after suspension points.
    private var generation: UInt64 = 0

    /// Whether the app is in the foreground. Updated by NotificationCenter observers.
    private var isForeground = true

    /// Signalled when foreground/background mode changes so the polling loop
    /// can wake from its current sleep and apply the new interval immediately.
    private var wakeStream: AsyncStream<Void>?
    private var wakeContinuation: AsyncStream<Void>.Continuation?

    /// Polling interval: 1s foreground, 10s background.
    private var pollingInterval: Duration {
        isForeground ? .seconds(1) : .seconds(10)
    }

    // MARK: - Cached System Constants

    /// Kernel page size, queried once at init. 16384 on Apple Silicon.
    private let kernelPageSize: UInt64

    /// Total installed physical memory in bytes.
    private let totalPhysicalMemory: UInt64

    /// Hardware memory tier (static, never changes).
    private let memoryTier: MemoryTier

    private let logger = Logger(subsystem: "com.cacheout", category: "MemoryMonitor")

    // MARK: - Lifecycle Observer

    /// Wraps NotificationCenter observers for foreground/background transitions.
    /// Must be a class (not actor-isolated) because NotificationCenter delivers
    /// callbacks on arbitrary threads.
    private final class LifecycleObserver: @unchecked Sendable {
        private let monitor: MemoryMonitor
        private var tokens: [NSObjectProtocol] = []

        init(monitor: MemoryMonitor) {
            self.monitor = monitor
        }

        func install() {
            let nc = NotificationCenter.default
            tokens.append(nc.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                Task { await self.monitor.setForeground(true) }
            })
            tokens.append(nc.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                Task { await self.monitor.setForeground(false) }
            })
        }

        func uninstall() {
            let nc = NotificationCenter.default
            for token in tokens {
                nc.removeObserver(token)
            }
            tokens.removeAll()
        }
    }

    /// Retained lifecycle observer — set on start, cleared on stop.
    private var lifecycleObserver: LifecycleObserver?

    // MARK: - Init

    init() {
        // Query kernel page size once (vm_kernel_page_size is a global variable).
        self.kernelPageSize = UInt64(vm_kernel_page_size)

        // Query total physical memory once.
        var memsize: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        if sysctlbyname("hw.memsize", &memsize, &size, nil, 0) == 0 {
            self.totalPhysicalMemory = memsize
        } else {
            self.totalPhysicalMemory = 0
        }

        self.memoryTier = MemoryTier.detect()

        // Create the AsyncStream with a buffer policy that keeps only the latest value.
        var cont: AsyncStream<SystemStatsDTO>.Continuation!
        self.stats = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            cont = continuation
        }
        self.streamContinuation = cont
    }

    // MARK: - Public API

    /// Begin polling. Idempotent — calling multiple times has no effect.
    ///
    /// Uses a generation counter to detect stale resumes: if `stop()` (or
    /// another `start()`) runs while this method is suspended on `MainActor.run`,
    /// the generation will have changed and the stale call bails out.
    func start() async {
        // Fast path: already running — no suspension needed.
        guard !isRunning else { return }

        // Capture generation before suspending so we can detect invalidation.
        generation &+= 1
        let startGeneration = generation

        // Prepare the observer before the await so it's ready to install.
        let observer = LifecycleObserver(monitor: self)

        // Install observers AND read current activation state atomically on
        // the main actor. The observer is installed first so that any
        // activation change after the isActive read is still captured.
        let currentlyActive = await MainActor.run {
            observer.install()
            return NSApp?.isActive ?? true
        }

        // --- Non-suspending critical section ---------------------------------
        // If stop() or another start() ran during the await, our generation
        // is stale — clean up and bail out.
        guard generation == startGeneration, !isRunning else {
            observer.uninstall()
            return
        }
        isRunning = true
        isForeground = currentlyActive
        self.lifecycleObserver = observer

        // Create a wake stream so mode changes interrupt the current sleep.
        var cont: AsyncStream<Void>.Continuation!
        let stream = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { c in
            cont = c
        }
        self.wakeStream = stream
        self.wakeContinuation = cont

        let pollGeneration = generation
        pollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let snapshot = self.sample()
                guard !Task.isCancelled else { break }
                if let snapshot {
                    await self.yieldIfCurrent(snapshot, generation: pollGeneration)
                }
                // Sleep for the current interval, but wake early if the
                // foreground/background mode changes.
                await self.sleepUntilNextPoll()
            }
        }
        // --- End critical section --------------------------------------------
    }

    /// Stop polling. Idempotent — safe to call when already stopped.
    ///
    /// Always bumps the generation counter so that any in-flight `start()`
    /// suspended on `MainActor.run` will detect invalidation on resume,
    /// even if `isRunning` has not yet been set to `true`.
    func stop() {
        // Always bump generation to invalidate any in-flight start() resumes,
        // regardless of whether isRunning is true (start may be mid-await).
        generation &+= 1

        guard isRunning else { return }
        pollingTask?.cancel()
        pollingTask = nil
        isRunning = false

        wakeContinuation?.finish()
        wakeContinuation = nil
        wakeStream = nil

        // Do NOT finish the primary `stats` stream here — it is created once
        // in init and must survive start/stop cycles. Finishing it would make
        // the stream permanently terminated, breaking any restart.

        // Finish all subscriber streams (these are per-subscription and
        // recreated on each subscribe() call).
        for (_, continuation) in subscribers {
            continuation.finish()
        }
        subscribers.removeAll()

        lifecycleObserver?.uninstall()
        lifecycleObserver = nil
    }

    // MARK: - Private Helpers

    private func setForeground(_ value: Bool) {
        guard isForeground != value else { return }
        isForeground = value
        // Wake the polling loop so the new interval applies immediately.
        wakeContinuation?.yield(())
        logger.debug("Polling mode: \(value ? "foreground (1Hz)" : "background (0.1Hz)")")
    }

    /// Sleep for the current polling interval, returning early if a wake
    /// signal arrives (e.g., foreground/background transition).
    private func sleepUntilNextPoll() async {
        let interval = pollingInterval
        guard let wakeStream else {
            try? await Task.sleep(for: interval)
            return
        }
        // Race: sleep vs wake signal. Whichever fires first wins.
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                try? await Task.sleep(for: interval)
            }
            group.addTask {
                var iterator = wakeStream.makeAsyncIterator()
                _ = await iterator.next()
            }
            // Return as soon as either completes.
            _ = await group.next()
            group.cancelAll()
        }
    }

    /// Publish a snapshot only if this polling session is still the current one.
    /// Drops stale snapshots from prior start/stop cycles.
    /// Broadcasts to both the primary `stats` stream and all subscribers.
    private func yieldIfCurrent(_ snapshot: SystemStatsDTO, generation pollGeneration: UInt64) {
        guard isRunning, self.generation == pollGeneration else { return }
        streamContinuation.yield(snapshot)
        for (_, continuation) in subscribers {
            continuation.yield(snapshot)
        }
    }

    /// Collect a single sample of system-wide VM stats.
    /// Returns `nil` on failure (logged but non-fatal).
    nonisolated private func sample() -> SystemStatsDTO? {
        // 1. host_statistics64 for page counts and activity counters
        let hostPort = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, hostPort) }

        var vmStats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let vmResult = withUnsafeMutablePointer(to: &vmStats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(hostPort, HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard vmResult == KERN_SUCCESS else {
            logger.error("host_statistics64 failed: \(vmResult)")
            return nil
        }

        // 2. Compressor stats via sysctl
        var compressedBytes: UInt64 = 0
        var compressedSize = MemoryLayout<UInt64>.size
        guard sysctlbyname("vm.compressor_compressed_bytes", &compressedBytes, &compressedSize, nil, 0) == 0 else {
            logger.error("Failed to query vm.compressor_compressed_bytes")
            return nil
        }

        var compressorBytesUsed: UInt64 = 0
        var compressorUsedSize = MemoryLayout<UInt64>.size
        guard sysctlbyname("vm.compressor_bytes_used", &compressorBytesUsed, &compressorUsedSize, nil, 0) == 0 else {
            logger.error("Failed to query vm.compressor_bytes_used")
            return nil
        }

        // Compression ratio: logical/physical. > 1.0 means effective compression.
        let compressionRatio: Double = compressorBytesUsed > 0
            ? Double(compressedBytes) / Double(compressorBytesUsed)
            : 0.0

        // 3. Swap usage
        var swapUsage = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &swapUsage, &swapSize, nil, 0) == 0 else {
            logger.error("Failed to query vm.swapusage")
            return nil
        }

        // 4. Pressure level
        var pressureLevel: Int32 = 0
        var pressureLevelSize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &pressureLevel, &pressureLevelSize, nil, 0) != 0 {
            logger.warning("Failed to query kern.memorystatus_vm_pressure_level, defaulting to 0")
            pressureLevel = 0
        }

        let pageSize = kernelPageSize

        return SystemStatsDTO(
            timestamp: Date(),
            freePages: UInt64(vmStats.free_count),
            activePages: UInt64(vmStats.active_count),
            inactivePages: UInt64(vmStats.inactive_count),
            wiredPages: UInt64(vmStats.wire_count),
            compressorPageCount: UInt64(vmStats.compressor_page_count),
            compressedBytes: compressedBytes,
            compressorBytesUsed: compressorBytesUsed,
            compressionRatio: compressionRatio,
            pageSize: pageSize,
            purgeableCount: UInt64(vmStats.purgeable_count),
            externalPages: UInt64(vmStats.external_page_count),
            internalPages: UInt64(vmStats.internal_page_count),
            compressions: UInt64(vmStats.compressions),
            decompressions: UInt64(vmStats.decompressions),
            pageins: UInt64(vmStats.pageins),
            pageouts: UInt64(vmStats.pageouts),
            swapUsedBytes: UInt64(swapUsage.xsu_used),
            swapTotalBytes: UInt64(swapUsage.xsu_total),
            pressureLevel: pressureLevel,
            memoryTier: memoryTier.rawValue,
            totalPhysicalMemory: totalPhysicalMemory
        )
    }
}
