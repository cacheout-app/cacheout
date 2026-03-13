// HelperInstaller.swift
// Manages registration and unregistration of the CacheoutHelper LaunchDaemon
// via SMAppService (macOS 14+). No SMJobBless fallback needed.

import Foundation
import os
import ServiceManagement

/// Handles installation and removal of the privileged CacheoutHelper daemon.
///
/// The helper plist (`com.cacheout.memhelper.plist`) must be embedded in the host
/// app bundle at `Contents/Library/LaunchDaemons/` via an Xcode "Copy Files" build
/// phase. SwiftPM resource processing alone is insufficient for SMAppService.
///
/// ## Usage
/// ```swift
/// let installer = HelperInstaller()
/// try installer.installIfNeeded()
/// ```
///
/// ## Uninstall note
/// `uninstall()` calls `SMAppService.unregister()`, which removes the registration
/// but does **not** stop a running daemon. Use `launchctl bootout` to stop it:
/// ```bash
/// sudo launchctl bootout system/com.cacheout.memhelper
/// ```
public final class HelperInstaller {

    // MARK: - Types

    /// The current registration status of the helper daemon.
    public enum Status: Equatable, Sendable {
        /// The daemon is registered and enabled.
        case enabled
        /// The daemon is not registered.
        case notRegistered
        /// The daemon registration requires user approval in System Settings.
        case requiresApproval
        /// The daemon plist was not found in the app bundle.
        case notFound
    }

    // MARK: - Properties

    private static let plistName = "com.cacheout.memhelper.plist"

    private let logger = Logger(
        subsystem: "com.cacheout",
        category: "helper-installer"
    )

    private var service: SMAppService {
        SMAppService.daemon(plistName: Self.plistName)
    }

    // MARK: - Init

    public init() {}

    // MARK: - Public API

    /// Returns the current registration status of the helper daemon.
    public var status: Status {
        switch service.status {
        case .enabled:
            return .enabled
        case .notRegistered:
            return .notRegistered
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .notFound
        @unknown default:
            logger.warning("Unknown SMAppService status; treating as notRegistered")
            return .notRegistered
        }
    }

    /// Registers the helper daemon if it is not already enabled.
    ///
    /// Terminal states (no `register()` call): `.enabled`, `.requiresApproval`, `.notFound`.
    /// Only `.notRegistered` triggers a fresh registration attempt.
    ///
    /// - Throws: An error from `SMAppService.register()` if registration fails.
    public func installIfNeeded() throws {
        let currentStatus = status

        switch currentStatus {
        case .enabled:
            logger.info("Helper daemon already registered and enabled")
            return

        case .requiresApproval:
            logger.notice("Helper daemon registered but requires user approval in System Settings")
            return

        case .notRegistered:
            logger.info("Helper daemon not registered; attempting registration")
            break

        case .notFound:
            logger.error("Helper plist not found in app bundle — ensure Copy Files build phase is configured")
            throw HelperInstallerError.plistNotFound
        }

        do {
            try service.register()
            logger.info("Helper daemon registered successfully")
        } catch {
            logger.error("Failed to register helper daemon: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Unregisters the helper daemon.
    ///
    /// This removes the LaunchDaemon registration but does **not** stop a
    /// currently running daemon process. To fully stop the daemon, use:
    /// ```bash
    /// sudo launchctl bootout system/com.cacheout.memhelper
    /// ```
    ///
    /// No-ops when the daemon is already `.notRegistered` or `.notFound`.
    ///
    /// - Throws: An error from `SMAppService.unregister()` if unregistration fails.
    public func uninstall() throws {
        let currentStatus = status

        switch currentStatus {
        case .notRegistered:
            logger.info("Helper daemon already not registered; nothing to uninstall")
            return
        case .notFound:
            logger.info("Helper plist not found in app bundle; nothing to uninstall")
            return
        case .enabled, .requiresApproval:
            break
        }

        do {
            try service.unregister()
            logger.info("Helper daemon unregistered successfully")
        } catch {
            logger.error("Failed to unregister helper daemon: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}

// MARK: - Errors

/// Errors specific to helper installation.
public enum HelperInstallerError: LocalizedError {
    /// The helper plist was not found in the app bundle's
    /// `Contents/Library/LaunchDaemons/` directory.
    case plistNotFound

    public var errorDescription: String? {
        switch self {
        case .plistNotFound:
            return "Helper plist 'com.cacheout.memhelper.plist' not found in app bundle. "
                + "Ensure the Xcode project has a Copy Files build phase targeting "
                + "Contents/Library/LaunchDaemons/."
        }
    }
}
