// CacheoutHelper — Privileged LaunchDaemon entry point.
//
// Starts the helper process, configures the XPC listener on the
// com.cacheout.memhelper Mach service, and keeps the RunLoop alive
// to service XPC connections.
//
// On startup the sysctl journal is loaded and checked for unclean
// shutdown; on SIGTERM, all modified sysctls are rolled back before
// the process exits cleanly.
//
// This process runs as root, registered via SMAppService with the
// com.cacheout.memhelper LaunchDaemon plist.

import Foundation
import os
import CacheoutHelperLib

private let logger = Logger(
    subsystem: "com.cacheout.memhelper",
    category: "lifecycle"
)

logger.info("CacheoutHelper daemon starting")

// Initialize sysctl journal — detects unclean shutdown and rolls back if needed.
// This clears the shutdownClean marker before we serve any XPC requests.
let journal = SysctlJournal()
journal.startup()

// Install SIGTERM handler for graceful shutdown.
// Step 1: Ignore the default SIGTERM handler so the process isn't killed
// before the dispatch source is installed.
signal(SIGTERM, SIG_IGN)

// Step 2: Create a dispatch source to handle SIGTERM asynchronously.
let sigSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigSource.setEventHandler {
    logger.info("SIGTERM received — initiating graceful shutdown")
    let allReverted = journal.rollbackAll()
    if allReverted {
        journal.markCleanShutdown()
        logger.info("Graceful shutdown complete (all sysctls reverted), exiting")
    } else {
        // Do NOT mark clean — next startup will detect unclean state and retry rollback.
        logger.warning("Graceful shutdown with partial rollback failure — leaving dirty marker for retry on next startup")
    }
    exit(0)
}
sigSource.resume()

// Set up XPC listener on the Mach service registered in the LaunchDaemon plist.
let delegate = XPCDelegate()
delegate.journal = journal
let listener = NSXPCListener(machServiceName: "com.cacheout.memhelper")
listener.delegate = delegate
listener.resume()

logger.info("XPC listener active on com.cacheout.memhelper")

// Keep the process alive to service XPC connections.
RunLoop.current.run()
