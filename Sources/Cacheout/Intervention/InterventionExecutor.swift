// InterventionExecutor.swift
// Capabilities struct that interventions use to access system resources.

import Foundation

/// Capabilities available to interventions during execution.
///
/// Each intervention picks its transport from the executor's capabilities.
/// If `xpcConnection` is nil, XPC-backed interventions return `.error("xpc_not_available")`.
/// If `dryRun` is true, mutations are suppressed but reads still execute.
public struct InterventionExecutor: @unchecked Sendable {
    /// XPC connection to the privileged CacheoutHelper daemon.
    /// Nil when the helper is not installed or not reachable.
    public let xpcConnection: NSXPCConnection?

    /// When true, side-effecting mutations (writes, deletes, signals) are suppressed.
    /// Read-only operations (listing, size queries, state reads) still execute.
    public let dryRun: Bool

    /// When true, the caller has obtained user confirmation for `.confirm`/`.destructive` tiers.
    /// Interventions with `tier != .safe` will refuse to execute without this flag.
    public let confirmed: Bool

    public init(xpcConnection: NSXPCConnection?, dryRun: Bool, confirmed: Bool = false) {
        self.xpcConnection = xpcConnection
        self.dryRun = dryRun
        self.confirmed = confirmed
    }
}
