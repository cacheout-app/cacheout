/// # Cacheout — Application Entry Point
///
/// This file serves as the top-level entry point for the Cacheout application.
/// It routes execution to CLI mode, daemon mode, or GUI mode based on command-line flags.
///
/// ## Execution Modes
///
/// - **GUI mode** (default): Launches the full SwiftUI application with main window,
///   menubar extra, and settings. Invoked by simply running the binary or double-clicking
///   the app bundle.
///
/// - **CLI mode** (`--cli`): Runs headlessly without any UI. Outputs structured JSON
///   to stdout. Useful for scripting, MCP server integration, and automation.
///   Uses a `DispatchSemaphore` to keep the process alive until the async CLI handler
///   completes, since there's no run loop in headless mode.
///
/// - **Daemon mode** (`--daemon`): Runs as a long-lived headless daemon that monitors
///   memory and exposes a Unix domain socket for status queries. State files are stored
///   in `--state-dir` (default: `~/.cacheout/`). Requires the privileged helper to be
///   pre-installed via the GUI app for autopilot actions.
///
/// ## Usage
///
/// ```bash
/// # GUI mode
/// open Cacheout.app
///
/// # CLI mode
/// Cacheout --cli scan
/// Cacheout --cli clean xcode_derived_data npm_cache --dry-run
/// Cacheout --cli smart-clean 5.0
/// Cacheout --cli disk-info
///
/// # Daemon mode
/// Cacheout --daemon
/// Cacheout --daemon --state-dir /var/lib/cacheout
/// ```

import SwiftUI
import CacheoutShared

if CommandLine.arguments.contains("--daemon") {
    // Daemon mode: long-lived headless process with Unix socket server,
    // autopilot policy engine, and webhook alerting.
    //
    // Prerequisites:
    //   - Privileged helper must be pre-installed via the GUI app (SMAppService)
    //     for autopilot actions to function. Without it, the daemon starts in
    //     degraded mode with helper_available=false and a HELPER_UNAVAILABLE
    //     warning alert is set when autopilot is enabled.
    //
    // Config:
    //   - Autopilot rules: <state-dir>/autopilot.json
    //   - Reload config: send SIGHUP to the daemon process
    //   - Validate config: use the validate_config socket command

    // Handle --daemon --help
    if CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h") {
        print("""
        Usage: Cacheout --daemon [--state-dir <path>]

        Run CacheOut as a headless daemon with memory monitoring, autopilot
        policy engine, and webhook alerting.

        Options:
          --state-dir <path>  State directory (default: ~/.cacheout/)
          --help, -h          Show this help message

        State files:
          daemon.pid          PID lock file (flock-based)
          status.sock         Unix domain socket for commands
          autopilot.json      Autopilot policy configuration (v1 schema)
          restart.marker      Written on self-monitor restart

        Socket commands:
          stats               Current system memory stats
          processes           Top processes by memory (accepts top_n)
          compressor          Compressor stats
          health              Alerts + health score + helper status
          config_status       Config generation and load status
          validate_config     Dry-run validation (accepts path)

        Config reload:
          Send SIGHUP to reload autopilot.json. Config is applied atomically
          to both the autopilot policy engine and webhook alerter.

        Prerequisites:
          The privileged XPC helper must be pre-installed via the GUI app
          (SMAppService registration) before running --daemon. Without it,
          autopilot actions will return xpc_not_available errors and a
          HELPER_UNAVAILABLE warning alert will be set.
        """)
        Foundation.exit(0)
    }

    let args = CommandLine.arguments
    let stateDir: URL
    if let idx = args.firstIndex(of: "--state-dir"), idx + 1 < args.count {
        stateDir = URL(fileURLWithPath: args[idx + 1])
    } else {
        stateDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cacheout")
    }
    let config = DaemonConfig(stateDir: stateDir)
    // Use dispatchMain() instead of semaphore to keep the main thread's
    // run loop active. This is required for GCD signal DispatchSources
    // (which are dispatched on queues that need the main run loop running)
    // and for proper shutdown via Foundation.exit().
    Task {
        await DaemonMode.runWithAutopilot(config: config)
    }
    dispatchMain()
} else if CLIHandler.shouldHandleCLI() {
    // CLI mode: run headless without a SwiftUI app or run loop.
    // The semaphore blocks the main thread until the async handler finishes,
    // preventing the process from exiting prematurely.
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        await CLIHandler.run()
        semaphore.signal()
    }
    semaphore.wait()
} else {
    // GUI mode: launch the full SwiftUI application lifecycle.
    CacheoutApp.main()
}
