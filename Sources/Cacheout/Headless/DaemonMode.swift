// DaemonMode.swift
// Headless daemon entry point with PID lock, sampling loop, socket server,
// signal handling, self-monitoring, autopilot policy, and webhook alerting.

import CacheoutShared
import Darwin
import Foundation
import os

/// Headless daemon mode for running CacheOut on servers without a GUI.
///
/// ## Entry points
/// Full daemon with autopilot + webhooks:
/// ```swift
/// await DaemonMode.runWithAutopilot(config: config)
/// ```
/// Minimal (no autopilot/webhooks):
/// ```swift
/// await DaemonMode.run(config: config)
/// ```
///
/// ## Lifecycle
/// `create(config:hooks:)` wires hooks first, then performs all externally-visible
/// setup (state dir, PID lock, socket, signal handlers). `startSamplingLoop()` begins
/// periodic sampling and self-monitoring. This ordering guarantees that `onShutdown`
/// is available even for signals received during early startup.
///
/// ## Features
/// - PID lock file at `<state-dir>/daemon.pid`
/// - Unix domain socket at `<state-dir>/status.sock`
/// - 1Hz memory sampling loop
/// - Alert evaluation from sample history
/// - Autopilot policy engine (T1 interventions from `autopilot.json`)
/// - Webhook alerting with per-code coalescing + cooldown
/// - Self-monitoring (RSS > 50MB for 30s -> restart)
/// - Signal handling (SIGTERM/SIGINT -> graceful shutdown, SIGHUP -> config reload)
/// - HELPER_UNAVAILABLE daemon-owned alert when autopilot enabled + helper not registered
///
/// ## Helper prerequisite
/// The privileged XPC helper must be pre-installed via the GUI app before running
/// `--daemon`. The helper is registered through `SMAppService` which requires the
/// app bundle context. Without it, autopilot actions return `xpc_not_available` errors
/// and a `HELPER_UNAVAILABLE` warning alert is set.
///
/// ## Hooks
/// - `onSnapshot`: called after each sample cycle with alerts
/// - `onShutdown`: called during graceful shutdown for flush/cleanup
/// - `onRestartNeeded`: called when self-monitor triggers restart
/// - `onSIGHUP`: called on SIGHUP for config reload
public actor DaemonMode: StatusSocket.DataSource {

    // MARK: - Constants

    /// Maximum RSS in bytes before triggering restart (50 MB).
    private static let maxRSSBytes: Int = 50 * 1024 * 1024

    /// Duration in seconds RSS must exceed threshold before restart.
    private static let rssExceedDuration: TimeInterval = 30.0

    /// Self-monitoring check interval in seconds.
    private static let selfMonitorInterval: TimeInterval = 10.0

    /// Exit code for self-initiated restart (EX_TEMPFAIL).
    private static let restartExitCode: Int32 = 75

    // MARK: - State

    private let config: DaemonConfig
    private let logger = Logger(subsystem: "com.cacheout", category: "DaemonMode")

    private var _currentSnapshot: DaemonSnapshot?
    private var _sampleHistory: [DaemonSnapshot] = []
    private var _activeAlerts: [DaemonAlert] = []
    private var _daemonOwnedAlerts: [DaemonAlert] = []
    private var _configStatus = ConfigStatus()
    private var _helperAvailable = false

    /// When true, `sampleOnce()` skips the onSnapshot hook to prevent
    /// the sample loop from observing a mid-reload config state.
    /// Set by `loadConfig()` around the multi-step apply sequence.
    private var _reloadInProgress = false

    /// When true, `sampleOnce()` is a no-op. Set during shutdown to
    /// quiesce alert production before the final webhook flush.
    private var _shuttingDown = false

    /// Whether the initial config load has completed. Used by `loadConfig`
    /// to determine generation numbering (initial = gen 0 or 1, reload increments).
    private var _hasCompletedInitialLoad = false

    private var samplingTask: Task<Void, Never>?
    private var selfMonitorTask: Task<Void, Never>?
    private var statusSocket: StatusSocket?

    /// Tracks the currently running onSnapshot hook task so that reload
    /// and shutdown can await its completion before mutating config state.
    private var snapshotHookTask: Task<Void, Never>?

    private let alertEvaluator = AlertEvaluator()

    /// PredictiveEngine for time-to-exhaustion and growth detection.
    /// Owned by DaemonMode; fed availableMB on each sampling tick.
    private let predictiveEngine = PredictiveEngine()

    /// CompressorTracker for compression ratio trend detection.
    /// Owned by DaemonMode; fed directly via `record(_:)` on each sampling tick.
    private let compressorTracker = CompressorTracker()

    /// Maximum sample history size (30 minutes at 1Hz).
    private static let maxHistorySize = 1800

    // MARK: - Hooks

    /// Called after each sample cycle with the current merged alerts.
    /// Set before calling `run()`. Thread-safe via Sendable closure + single-writer pattern.
    nonisolated(unsafe) public var onSnapshot: (@Sendable ([DaemonAlert]) async -> Void)?

    /// Called during graceful shutdown for cleanup (e.g., webhook flush).
    /// Set before calling `run()`. Thread-safe via Sendable closure + single-writer pattern.
    nonisolated(unsafe) public var onShutdown: (@Sendable () async -> Void)?

    /// Called when self-monitor triggers a restart.
    /// Set before calling `run()`. Thread-safe via Sendable closure + single-writer pattern.
    nonisolated(unsafe) public var onRestartNeeded: (@Sendable () async -> Void)?

    /// Called on SIGHUP for config reload.
    /// Set before calling `run()`. Thread-safe via Sendable closure + single-writer pattern.
    nonisolated(unsafe) public var onSIGHUP: (@Sendable () async -> Void)?

    // MARK: - Init

    public init(config: DaemonConfig) {
        self.config = config
    }

    // MARK: - DataSource (StatusSocket.DataSource)

    public func currentSnapshot() -> DaemonSnapshot? {
        _currentSnapshot
    }

    public func sampleHistory() -> [DaemonSnapshot] {
        _sampleHistory
    }

    public func activeAlerts() -> [DaemonAlert] {
        _activeAlerts
    }

    public func configStatus() -> ConfigStatus {
        _configStatus
    }

    public func helperAvailable() -> Bool {
        _helperAvailable
    }

    public func recommendations() async -> RecommendationResult? {
        let stats = _currentSnapshot?.stats
        return await RecommendationEngine.generateRecommendations(
            mode: .daemon,
            predictiveEngine: predictiveEngine,
            compressorTracker: compressorTracker,
            systemStats: stats
        )
    }

    /// Access the predictive engine for recommendations and socket handlers.
    func getPredictiveEngine() -> PredictiveEngine {
        predictiveEngine
    }

    // MARK: - Predictive Access (for StatusSocket handlers in task .2)

    /// Time-to-exhaustion prediction in seconds, or nil if conditions not met.
    func timeToExhaustion() async -> TimeInterval? {
        await predictiveEngine.predictTimeToExhaustion()
    }

    /// Cached/fresh process scan result for recommendations and socket commands.
    func processScanResult() async -> ProcessMemoryScanner.ScanResult {
        await predictiveEngine.getOrRefreshScanResult()
    }

    // MARK: - Config Status Mutation (for task .2)

    /// Update the config status (called by task .2's startup load and SIGHUP handler).
    public func setConfigStatus(_ status: ConfigStatus) {
        _configStatus = status
    }

    /// Update daemon-owned alerts (called by task .2).
    public func setDaemonOwnedAlerts(_ alerts: [DaemonAlert]) {
        _daemonOwnedAlerts = alerts
    }

    // MARK: - Run

    /// Hooks for lifecycle events, accepted upfront so they are set before
    /// any externally-visible startup work (PID lock, socket, signals).
    public struct Hooks: Sendable {
        /// Called after each sample cycle with the current merged alerts.
        public var onSnapshot: (@Sendable ([DaemonAlert]) async -> Void)?
        /// Called during graceful shutdown for cleanup (e.g., webhook flush).
        public var onShutdown: (@Sendable () async -> Void)?
        /// Called when self-monitor triggers a restart.
        public var onRestartNeeded: (@Sendable () async -> Void)?
        /// Called on SIGHUP for config reload.
        public var onSIGHUP: (@Sendable () async -> Void)?

        public init(
            onSnapshot: (@Sendable ([DaemonAlert]) async -> Void)? = nil,
            onShutdown: (@Sendable () async -> Void)? = nil,
            onRestartNeeded: (@Sendable () async -> Void)? = nil,
            onSIGHUP: (@Sendable () async -> Void)? = nil
        ) {
            self.onSnapshot = onSnapshot
            self.onShutdown = onShutdown
            self.onRestartNeeded = onRestartNeeded
            self.onSIGHUP = onSIGHUP
        }
    }

    /// Main daemon entry point. Accepts hooks upfront, then performs all startup
    /// (state dir, PID lock, socket, signal handlers) with hooks already wired.
    /// Finally starts sampling and self-monitoring.
    ///
    /// Usage (task .2):
    /// ```swift
    /// let hooks = DaemonMode.Hooks(
    ///     onSnapshot: { alerts in ... },
    ///     onShutdown: { ... },
    ///     onRestartNeeded: { ... }
    /// )
    /// let daemon = await DaemonMode.create(config: config, hooks: hooks)
    /// await daemon.startSamplingLoop()
    /// ```
    ///
    /// - Parameters:
    ///   - config: Daemon configuration.
    ///   - hooks: Lifecycle hooks. Set before any externally visible work so
    ///     signal handlers can invoke onShutdown even during early startup.
    /// - Returns: The initialized daemon instance (infrastructure running,
    ///   signal handlers installed, but not yet sampling).
    public static func create(config: DaemonConfig, hooks: Hooks = Hooks()) async -> DaemonMode {
        let daemon = DaemonMode(config: config)
        // Wire hooks before any externally visible work
        daemon.onSnapshot = hooks.onSnapshot
        daemon.onShutdown = hooks.onShutdown
        daemon.onRestartNeeded = hooks.onRestartNeeded
        daemon.onSIGHUP = hooks.onSIGHUP
        await daemon.setup()
        return daemon
    }

    /// Convenience entry point that creates and immediately starts the daemon.
    /// No hooks are attached when using this entry point.
    public static func run(config: DaemonConfig) async {
        let daemon = await create(config: config)
        await daemon.startSamplingLoop()
    }

    /// Whether sampling has been started. Guards against accidental re-entry.
    private var hasStartedSampling = false

    /// Start the sampling loop and self-monitor.
    ///
    /// Signal handlers and socket are already running (installed in `setup()`).
    /// This method only starts the periodic sampling and self-monitoring tasks.
    ///
    /// - Precondition: Must only be called once. Subsequent calls are no-ops with a warning.
    public func startSamplingLoop() async {
        guard !hasStartedSampling else {
            logger.warning("DaemonMode.startSamplingLoop() called more than once — ignoring")
            return
        }
        hasStartedSampling = true

        startSampling()
        startSelfMonitor()
        logger.info("Daemon started successfully (PID: \(ProcessInfo.processInfo.processIdentifier))")
    }

    /// Set up daemon infrastructure: state dir, PID lock, socket, signal handlers.
    /// Hooks must be set before calling this method.
    private func setup() async {
        logger.info("Daemon starting with state directory: \(self.config.stateDir.path, privacy: .public)")

        // Ensure state directory exists with 0700 permissions.
        // createDirectory only sets attributes on newly created dirs, so we
        // explicitly chmod afterward to harden pre-existing directories.
        do {
            try FileManager.default.createDirectory(
                at: config.stateDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: config.stateDir.path
            )
        } catch {
            logger.error("Failed to create/secure state directory: \(error.localizedDescription, privacy: .public)")
            Foundation.exit(1)
        }

        // PID lock
        guard acquirePIDLock() else {
            logger.error("Another daemon instance is already running")
            Foundation.exit(1)
        }

        // Check helper availability
        _helperAvailable = HelperInstaller().status == .enabled

        // Start socket server
        let socketPath = config.stateDir.appendingPathComponent("status.sock").path
        let socket = StatusSocket(socketPath: socketPath, dataSource: self)
        do {
            try socket.start()
            statusSocket = socket
        } catch {
            logger.error("Failed to start status socket: \(error.localizedDescription, privacy: .public)")
            cleanupAndExit(code: 1)
        }

        // Install signal handlers. Safe to do here because hooks are set
        // before create() calls setup(), so onShutdown/onRestartNeeded are
        // available even for signals received during early startup.
        installSignalHandlers()

        // The daemon stays alive via dispatchMain() in main.swift.
        // Signal handlers, sampling loop, and self-monitor run as Tasks/DispatchSources.
        // Shutdown occurs via gracefulShutdown() -> Foundation.exit(0) or
        // triggerRestart() -> Foundation.exit(75).
    }

    // MARK: - PID Lock

    private var pidFilePath: String {
        config.stateDir.appendingPathComponent("daemon.pid").path
    }

    /// File descriptor for the PID lock file, held open for the process lifetime.
    /// flock is released automatically when this fd is closed or the process exits.
    private var pidLockFd: Int32 = -1

    /// Acquire an exclusive PID lock using flock(LOCK_EX | LOCK_NB).
    ///
    /// This is atomic: two concurrent launches cannot both acquire the lock.
    /// The lock is held for the process lifetime via the open file descriptor.
    /// If the process crashes, the kernel releases the flock automatically.
    private func acquirePIDLock() -> Bool {
        let pidPath = pidFilePath

        // Open (or create) the PID file with 0600 permissions
        let fd = open(pidPath, O_WRONLY | O_CREAT, 0o600)
        guard fd >= 0 else {
            logger.error("Failed to open PID file: errno \(errno)")
            return false
        }

        // Try non-blocking exclusive lock
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            // Read existing PID for error message
            if let existingPid = readPIDFile(pidPath) {
                logger.error("Daemon already running with PID \(existingPid) (lock held)")
            } else {
                logger.error("Another daemon instance holds the PID lock")
            }
            return false
        }

        // Truncate and write our PID
        ftruncate(fd, 0)
        let pid = ProcessInfo.processInfo.processIdentifier
        let pidStr = "\(pid)\n"
        pidStr.withCString { ptr in
            _ = Darwin.write(fd, ptr, strlen(ptr))
        }

        // Keep fd open — flock is held for process lifetime
        pidLockFd = fd
        return true
    }

    private func readPIDFile(_ path: String) -> pid_t? {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        return pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Release the PID lock by closing the file descriptor.
    ///
    /// The PID file is NOT unlinked on shutdown. This avoids a race where:
    /// 1. Old daemon closes flock fd (releasing lock)
    /// 2. New daemon acquires flock and writes its PID
    /// 3. Old daemon unlinks the file (removing new daemon's identity)
    ///
    /// Instead, flock is the sole source of truth for single-instance.
    /// The next startup overwrites the stale PID after acquiring the lock.
    private func releasePIDLock() {
        if pidLockFd >= 0 {
            close(pidLockFd)
            pidLockFd = -1
        }
    }

    // MARK: - Signal Handling

    /// Dedicated serial queue for signal dispatch sources.
    /// Using a dedicated queue instead of .main avoids dependency on
    /// the main thread's run loop state and ensures signals are handled
    /// even if the main thread is in dispatchMain().
    private let signalQueue = DispatchQueue(label: "com.cacheout.daemon-signals")

    private func installSignalHandlers() {
        // Ignore default signal actions before creating DispatchSources.
        // signal() applies process-wide (not per-thread like sigprocmask),
        // ensuring signals are routed to the dispatch sources on all threads.
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        signal(SIGHUP, SIG_IGN)

        // SIGTERM
        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: signalQueue)
        termSource.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.handleShutdownSignal() }
        }
        termSource.resume()

        // SIGINT
        let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
        intSource.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.handleShutdownSignal() }
        }
        intSource.resume()

        // SIGHUP — hook for config reload (task .2 wires this)
        let hupSource = DispatchSource.makeSignalSource(signal: SIGHUP, queue: signalQueue)
        hupSource.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.handleSIGHUP() }
        }
        hupSource.resume()

        // Prevent sources from being deallocated
        _signalSources = [termSource, intSource, hupSource]
    }

    // Stored to prevent deallocation
    nonisolated(unsafe) private static var _signalSourcesStorage: [Any] = []
    private var _signalSources: [Any] {
        get { Self._signalSourcesStorage }
        set { Self._signalSourcesStorage = newValue }
    }

    private func handleShutdownSignal() async {
        logger.info("Shutdown signal received")
        await gracefulShutdown()
    }

    /// Serialized reload task. Only one reload can be in progress at a time.
    /// Both the initial config load and SIGHUP reloads go through this chain
    /// to guarantee ordered generation increments and prevent overlapping applies.
    private var reloadTask: Task<Void, Never>?

    /// Schedule a config reload through the serial pipeline.
    /// Returns a task that completes when this reload finishes.
    ///
    /// Both initial startup load and SIGHUP use this method to ensure
    /// they share one ordered pipeline. If a SIGHUP fires during the
    /// initial load, it queues behind it.
    @discardableResult
    public func scheduleReload() -> Task<Void, Never> {
        let previousTask = reloadTask
        let task = Task { [weak self] in
            // Wait for any in-progress reload to finish
            await previousTask?.value
            guard let self else { return }
            if let hook = self.onSIGHUP {
                await hook()
            } else {
                self.logger.info("Config reload: no reload hook wired")
            }
        }
        reloadTask = task
        return task
    }

    private func handleSIGHUP() {
        logger.info("SIGHUP received — scheduling config reload")
        scheduleReload()
    }

    // MARK: - Sampling Loop

    private func startSampling() {
        samplingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.sampleOnce()
                try? await Task.sleep(for: .seconds(self.config.pollIntervalSeconds))
            }
        }
    }

    private func sampleOnce() async {
        // Skip if shutting down or mid-reload to avoid mixed config epochs
        guard !_shuttingDown, !_reloadInProgress else { return }

        // Use a lightweight local sample (same approach as MemoryMonitor.sample)
        guard let stats = sampleSystemStats() else {
            return
        }

        let snapshot = DaemonSnapshot(stats: stats)
        _currentSnapshot = snapshot

        // Feed availableMB into PredictiveEngine's sliding window
        let availableMB = Double(stats.freePages + stats.inactivePages) * Double(stats.pageSize) / 1048576.0
        await predictiveEngine.recordAvailableMB(availableMB, at: stats.timestamp)

        // Feed CompressorTracker for compression ratio trend detection
        await compressorTracker.record(stats)

        // Append to history, capping size
        _sampleHistory.append(snapshot)
        if _sampleHistory.count > Self.maxHistorySize {
            _sampleHistory.removeFirst(_sampleHistory.count - Self.maxHistorySize)
        }

        // Evaluate sample-derived alerts
        let sampleAlerts = alertEvaluator.evaluate(
            samples: _sampleHistory,
            currentSnapshot: snapshot
        )

        // Merge with daemon-owned alerts
        _activeAlerts = sampleAlerts + _daemonOwnedAlerts

        // Re-check: reload may have started during the await-free section above
        // (unlikely since we're inside the actor, but defensive)
        guard !_shuttingDown, !_reloadInProgress else { return }

        // Fire onSnapshot hook, tracking the task so reload/shutdown can await it
        if let hook = onSnapshot {
            let alerts = _activeAlerts
            let task = Task { await hook(alerts) }
            snapshotHookTask = task
            await task.value
            snapshotHookTask = nil
        }
    }

    /// Sample system stats locally (mirrors MemoryMonitor.sample but without actor isolation).
    nonisolated private func sampleSystemStats() -> SystemStatsDTO? {
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
        guard vmResult == KERN_SUCCESS else { return nil }

        var compressedBytes: UInt64 = 0
        var compressedSize = MemoryLayout<UInt64>.size
        guard sysctlbyname("vm.compressor_compressed_bytes", &compressedBytes, &compressedSize, nil, 0) == 0 else {
            return nil
        }

        var compressorBytesUsed: UInt64 = 0
        var compressorUsedSize = MemoryLayout<UInt64>.size
        guard sysctlbyname("vm.compressor_bytes_used", &compressorBytesUsed, &compressorUsedSize, nil, 0) == 0 else {
            return nil
        }

        let compressionRatio: Double = compressorBytesUsed > 0
            ? Double(compressedBytes) / Double(compressorBytesUsed)
            : 0.0

        var swapUsage = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &swapUsage, &swapSize, nil, 0) == 0 else {
            return nil
        }

        var pressureLevel: Int32 = 0
        var pressureLevelSize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &pressureLevel, &pressureLevelSize, nil, 0) != 0 {
            pressureLevel = 0
        }

        let pageSize = UInt64(vm_kernel_page_size)

        var memsize: UInt64 = 0
        var memsizeLen = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &memsize, &memsizeLen, nil, 0)

        let memoryTier = MemoryTier.detect()

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
            totalPhysicalMemory: memsize
        )
    }

    // MARK: - Self-Monitoring

    private func startSelfMonitor() {
        selfMonitorTask = Task { [weak self] in
            guard let self else { return }
            var exceedStart: TimeInterval?

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.selfMonitorInterval))

                let rss = self.currentRSSBytes()
                if rss > Self.maxRSSBytes {
                    if exceedStart == nil {
                        exceedStart = ProcessInfo.processInfo.systemUptime
                    }
                    let elapsed = ProcessInfo.processInfo.systemUptime - (exceedStart ?? 0)
                    if elapsed >= Self.rssExceedDuration {
                        await self.triggerRestart()
                        return
                    }
                } else {
                    exceedStart = nil
                }
            }
        }
    }

    /// Get current process RSS in bytes.
    nonisolated private func currentRSSBytes() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int(info.resident_size)
    }

    private func triggerRestart() async {
        logger.warning("Self-monitor: RSS exceeded \(Self.maxRSSBytes / 1024 / 1024)MB for \(Int(Self.rssExceedDuration))s — requesting restart")

        // Fire hook FIRST so urgent webhook delivery completes before the
        // watchdog sees the restart marker and kills the process.
        if let hook = onRestartNeeded {
            await hook()
        }

        // Write restart marker AFTER hook so the watchdog doesn't act prematurely.
        let markerPath = config.stateDir.appendingPathComponent("restart.marker").path
        try? Date().description.write(toFile: markerPath, atomically: true, encoding: .utf8)

        // Cleanup and exit with restart code
        cleanupAndExit(code: Self.restartExitCode)
    }

    // MARK: - Shutdown

    private func gracefulShutdown() async {
        logger.info("Graceful shutdown starting")

        // 1. Quiesce alert production: set shutdown flag and cancel sampling
        //    BEFORE flushing, so no new alerts can be enqueued during flush.
        _shuttingDown = true
        samplingTask?.cancel()
        samplingTask = nil
        selfMonitorTask?.cancel()
        selfMonitorTask = nil

        // 2. Await any in-flight snapshot hook so webhook deliveries from the
        //    last sample cycle complete before we flush.
        await snapshotHookTask?.value
        snapshotHookTask = nil

        // 3. Stop accepting new connections
        statusSocket?.stop()

        // 4. Fire onShutdown hook (e.g., webhook flush with 3s budget)
        //    Safe now: sampling is stopped and in-flight hook is complete.
        if let hook = onShutdown {
            await hook()
        }

        // 4. Release PID lock (file remains for next-start housekeeping)
        releasePIDLock()

        // 5. Exit cleanly
        logger.info("Graceful shutdown complete")
        Foundation.exit(0)
    }

    /// Emergency cleanup and exit (non-graceful).
    /// PID file is NOT removed — flock release (via process exit) is sufficient.
    /// Socket file is unlinked so the next start can bind cleanly.
    private func cleanupAndExit(code: Int32) -> Never {
        let sockPath = config.stateDir.appendingPathComponent("status.sock").path
        unlink(sockPath)
        // pidLockFd is closed automatically by process exit, releasing flock
        Foundation.exit(code)
    }

    // MARK: - Reload Barrier

    /// Set the reload-in-progress flag. While set, `sampleOnce()` skips the
    /// onSnapshot hook to prevent observing a mid-reload config state.
    public func setReloadInProgress(_ inProgress: Bool) {
        _reloadInProgress = inProgress
    }

    /// Await completion of any in-flight onSnapshot hook task.
    /// Called by reload and shutdown to ensure no hook is running before
    /// mutating config state or flushing.
    public func awaitSnapshotHookCompletion() async {
        await snapshotHookTask?.value
    }

    /// Whether the initial config load has completed.
    public var hasCompletedInitialLoad: Bool {
        _hasCompletedInitialLoad
    }

    /// Mark the initial config load as complete.
    public func markInitialLoadComplete() {
        _hasCompletedInitialLoad = true
    }

    // MARK: - Helper Availability Update

    /// Re-check helper availability and update daemon-owned alerts accordingly.
    /// Called during config load/reload to set or clear HELPER_UNAVAILABLE alert.
    ///
    /// Also recomputes `_activeAlerts` immediately so that the `health` socket
    /// command reflects the new daemon-owned alert state without waiting for
    /// the next sample tick.
    public func updateHelperAvailability(autopilotEnabled: Bool) {
        _helperAvailable = HelperInstaller().status == .enabled

        if autopilotEnabled && !_helperAvailable {
            // Set HELPER_UNAVAILABLE daemon-owned alert
            let alert = DaemonAlert(
                code: .helperUnavailable,
                severity: .warning,
                message: "Autopilot is enabled but the privileged helper is not registered. "
                    + "Install the helper via the GUI app before running --daemon."
            )
            _daemonOwnedAlerts = [alert]
            logger.warning("Helper not registered — HELPER_UNAVAILABLE alert set")
        } else {
            // Clear daemon-owned alerts (trigger condition false)
            _daemonOwnedAlerts = []
        }

        // Recompute merged alerts immediately so health reflects the change
        // without waiting for the next sample cycle.
        recomputeActiveAlerts()
    }

    /// Recompute `_activeAlerts` from current sample-derived + daemon-owned alerts.
    private func recomputeActiveAlerts() {
        let sampleAlerts: [DaemonAlert]
        if let currentSnapshot = _currentSnapshot {
            sampleAlerts = alertEvaluator.evaluate(
                samples: _sampleHistory,
                currentSnapshot: currentSnapshot
            )
        } else {
            sampleAlerts = []
        }
        _activeAlerts = sampleAlerts + _daemonOwnedAlerts
    }

    // MARK: - Full Daemon with Autopilot + Webhooks

    /// Main entry point that wires autopilot policy, webhook alerting,
    /// startup config loading, and SIGHUP reload.
    ///
    /// This is the production entry point used by `main.swift`.
    public static func runWithAutopilot(config: DaemonConfig) async {
        let autopilot = AutopilotPolicy()
        let webhookAlerter = WebhookAlerter()
        let configPath = config.stateDir.appendingPathComponent("autopilot.json").path
        let logger = Logger(subsystem: "com.cacheout", category: "DaemonMode")

        // Create daemon with hooks wired
        // We need to capture daemon as a variable for SIGHUP to reference it,
        // but hooks need to be defined first. Use the create/startSamplingLoop pattern.
        // The daemon reference is captured weakly in closures via nonisolated(unsafe).
        nonisolated(unsafe) var daemonRef: DaemonMode?

        let hooks = DaemonMode.Hooks(
            onSnapshot: { @Sendable alerts in
                // Evaluate autopilot rules
                if let daemon = daemonRef {
                    let samples = await daemon.sampleHistory()
                    if let current = await daemon.currentSnapshot() {
                        await autopilot.evaluate(samples: samples, currentSnapshot: current)
                    }
                }
                // Process alerts through webhook alerter
                await webhookAlerter.processAlerts(alerts)
            },
            onShutdown: { @Sendable in
                // Flush webhook deliveries (3s budget)
                await webhookAlerter.flush()
                // Invalidate current XPC connection
                await autopilot.invalidateXPC()
            },
            onRestartNeeded: { @Sendable in
                // Deliver urgent DAEMON_RESTART alert
                let restartAlert = DaemonAlert(
                    code: .daemonRestart,
                    severity: .emergency,
                    message: "Daemon self-monitor triggered restart (RSS exceeded threshold)"
                )
                await webhookAlerter.deliverUrgent(alert: restartAlert)
            },
            onSIGHUP: { @Sendable in
                guard let daemon = daemonRef else { return }
                let isInitial = !(await daemon.hasCompletedInitialLoad)
                await loadConfig(
                    path: configPath,
                    daemon: daemon,
                    autopilot: autopilot,
                    webhookAlerter: webhookAlerter,
                    isInitialLoad: isInitial,
                    logger: logger
                )
                if isInitial {
                    await daemon.markInitialLoadComplete()
                }
            }
        )

        let daemon = await DaemonMode.create(config: config, hooks: hooks)
        daemonRef = daemon

        // Startup config load — goes through the same serial reload pipeline
        // as SIGHUP, so a SIGHUP arriving during startup queues behind it.
        let initialLoadTask = await daemon.scheduleReload()
        await initialLoadTask.value

        // Start sampling
        await daemon.startSamplingLoop()
    }

    // MARK: - XPC Connection Management

    /// Open a new XPC connection to the helper daemon if registered.
    /// Returns nil if the helper is not installed.
    private static func openHelperConnection() -> NSXPCConnection? {
        guard HelperInstaller().status == .enabled else { return nil }
        let conn = NSXPCConnection(machServiceName: "com.cacheout.memhelper", options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: MemoryHelperProtocol.self)
        conn.resume()
        return conn
    }

    // MARK: - Config Loading

    /// Load and apply autopilot configuration from the given path.
    ///
    /// Used by both startup and SIGHUP reload. On reload (non-initial), every
    /// call increments the config generation counter. Helper availability and
    /// XPC connection are refreshed on every attempt, even when the config is
    /// rejected, so the daemon never holds stale helper state.
    ///
    /// - Parameters:
    ///   - path: Path to autopilot.json
    ///   - daemon: The daemon instance to update
    ///   - autopilot: The autopilot policy to configure
    ///   - webhookAlerter: The webhook alerter to configure
    ///   - isInitialLoad: True for startup, false for SIGHUP reload
    ///   - logger: Logger for status messages
    private static func loadConfig(
        path: String,
        daemon: DaemonMode,
        autopilot: AutopilotPolicy,
        webhookAlerter: WebhookAlerter,
        isInitialLoad: Bool,
        logger: Logger
    ) async {
        let currentStatus = await daemon.configStatus()
        let nextGeneration = isInitialLoad ? 1 : currentStatus.generation + 1

        // Refresh XPC connection on every load attempt (helper may have been
        // installed or removed since last check).
        let xpcConnection = openHelperConnection()
        await autopilot.setXPCConnection(xpcConnection)

        // Helper function: refresh helper availability using the currently
        // applied autopilot-enabled state (not the candidate config).
        // Called on every exit path so helper state is never stale.
        func refreshHelperState(autopilotEnabled: Bool?) async {
            let enabled: Bool
            if let explicit = autopilotEnabled {
                enabled = explicit
            } else {
                enabled = await autopilot.isEnabled
            }
            await daemon.updateHelperAvailability(autopilotEnabled: enabled)
        }

        // Check if file exists
        guard FileManager.default.fileExists(atPath: path) else {
            if isInitialLoad {
                // First load, file missing → gen 0, no_config
                let status = ConfigStatus(generation: 0, status: .noConfig)
                await daemon.setConfigStatus(status)
                await refreshHelperState(autopilotEnabled: false)
                logger.info("No autopilot config file found at \(path, privacy: .public)")
            } else {
                // SIGHUP but file removed — increment gen, set no_config
                let status = ConfigStatus(
                    generation: nextGeneration,
                    lastReload: Date(),
                    status: .noConfig
                )
                await daemon.setConfigStatus(status)
                // Disable autopilot + webhooks
                await autopilot.applyConfig(.empty)
                await webhookAlerter.applyConfig(webhook: nil)
                await refreshHelperState(autopilotEnabled: false)
                logger.info("Autopilot config file removed — disabled (gen \(nextGeneration))")
            }
            return
        }

        // Enforce 0600 permissions
        chmod(path, 0o600)

        // Read file
        guard let data = FileManager.default.contents(atPath: path) else {
            let status = ConfigStatus(
                generation: nextGeneration,
                lastReload: Date(),
                status: .error,
                error: "Failed to read config file"
            )
            await daemon.setConfigStatus(status)
            await refreshHelperState(autopilotEnabled: nil)
            logger.error("Failed to read autopilot config at \(path, privacy: .public)")
            return
        }

        // Validate
        let errors = AutopilotConfigValidator.validate(data: data)
        if !errors.isEmpty {
            let status = ConfigStatus(
                generation: nextGeneration,
                lastReload: Date(),
                status: .error,
                error: errors.joined(separator: "; ")
            )
            await daemon.setConfigStatus(status)
            await refreshHelperState(autopilotEnabled: nil)
            logger.error("Autopilot config validation failed: \(errors.joined(separator: "; "), privacy: .public)")
            return
        }

        // Parse
        guard let parsedConfig = AutopilotPolicy.parseConfig(from: data) else {
            let status = ConfigStatus(
                generation: nextGeneration,
                lastReload: Date(),
                status: .error,
                error: "Failed to parse validated config"
            )
            await daemon.setConfigStatus(status)
            await refreshHelperState(autopilotEnabled: nil)
            logger.error("Failed to parse autopilot config despite validation passing")
            return
        }

        // Parse webhook config
        let webhookConfig: WebhookAlerter.WebhookConfig?
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           json["webhook"] != nil {
            webhookConfig = WebhookAlerter.WebhookConfig.parse(from: json)
            // If webhook section exists but failed to parse, treat as config error
            if webhookConfig == nil {
                let status = ConfigStatus(
                    generation: nextGeneration,
                    lastReload: Date(),
                    status: .error,
                    error: "webhook section present but URL is invalid or unparseable"
                )
                await daemon.setConfigStatus(status)
                await refreshHelperState(autopilotEnabled: nil)
                logger.error("Autopilot config: webhook section present but URL is invalid")
                return
            }
        } else {
            webhookConfig = nil
        }

        // Gate the sample loop during the multi-step apply so onSnapshot
        // cannot observe a mixed config epoch (e.g., new autopilot + old webhook).
        await daemon.setReloadInProgress(true)

        // Await any in-flight snapshot hook to ensure no hook is running
        // against the old config while we apply the new one.
        await daemon.awaitSnapshotHookCompletion()

        // Apply atomically to BOTH autopilot + webhook
        await autopilot.applyConfig(parsedConfig)
        await webhookAlerter.applyConfig(webhook: webhookConfig)

        // Update helper availability and daemon-owned alerts
        await refreshHelperState(autopilotEnabled: parsedConfig.enabled)

        // Update config status
        let status = ConfigStatus(
            generation: nextGeneration,
            lastReload: Date(),
            status: .ok
        )
        await daemon.setConfigStatus(status)

        // Release the reload barrier — sampling can resume with the new config
        await daemon.setReloadInProgress(false)

        logger.info("Autopilot config loaded successfully (gen \(nextGeneration), enabled: \(parsedConfig.enabled))")
    }
}
