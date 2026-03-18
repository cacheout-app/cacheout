// XPCDelegate.swift
// NSXPCListenerDelegate that validates connecting clients using audit-token-based
// code signature verification (not PID — see CVE-2020-9977).

import Foundation
import os
import Security
import SystemConfiguration
import CacheoutShared
import CacheoutHelperLib
import CKernelPrivate

// MARK: - Audit Token Extraction

/// SPI: `xpc_connection_get_audit_token` is not exposed in public headers but is
/// a stable symbol in libxpc, widely used by system daemons and security tools
/// (including Apple's own SMJobBless helpers) to obtain the peer's audit token.
@_silgen_name("xpc_connection_get_audit_token")
private func xpc_connection_get_audit_token(
    _ connection: xpc_connection_t,
    _ token: UnsafeMutablePointer<audit_token_t>
)

/// Extract the audit token from an NSXPCConnection by accessing the underlying
/// `xpc_connection_t` via KVC, then calling `xpc_connection_get_audit_token`.
///
/// This is the secure way to identify the peer process — audit tokens are
/// tamper-proof kernel credentials, unlike PIDs which can be recycled
/// (see CVE-2020-9977).
private func extractAuditToken(from connection: NSXPCConnection) -> audit_token_t? {
    guard let underlying = connection.value(forKey: "_xpcConnection") else {
        return nil
    }
    guard let xpcConnection = underlying as? xpc_connection_t else {
        return nil
    }
    var token = audit_token_t()
    xpc_connection_get_audit_token(xpcConnection, &token)
    return token
}

/// NSXPCListenerDelegate that validates incoming XPC connections against the
/// caller's code-signing identity using audit tokens.
final class XPCDelegate: NSObject, NSXPCListenerDelegate {

    private let logger = Logger(
        subsystem: "com.cacheout.memhelper",
        category: "xpc"
    )

    /// Shared sysctl journal for rollback support.
    var journal: SysctlJournal?

    /// Team ID derived at launch from the helper's own code signature.
    /// Falls back to empty string (will reject all clients) if extraction fails.
    private static let teamID: String = {
        var selfCode: SecCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess,
              let code = selfCode else {
            return ""
        }
        var staticCodeOpt: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCodeOpt) == errSecSuccess,
              let staticCode = staticCodeOpt else {
            return ""
        }
        var infoOpt: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &infoOpt) == errSecSuccess,
              let info = infoOpt as? [String: Any],
              let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String else {
            return ""
        }
        return teamID
    }()

    /// Production designated requirement: must be signed by our team with the correct bundle ID.
    private static let designatedRequirement: String =
        "anchor apple generic and identifier \"com.cacheout.app\" and certificate leaf[subject.OU] = \"\(teamID)\""

    /// Debug designated requirement: requires correct bundle ID but accepts any signer.
    private static let debugRequirement: String =
        "identifier \"com.cacheout.app\""

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        guard validateClient(connection) else {
            logger.error("Rejected XPC connection: client failed code-signing validation")
            return false
        }

        connection.exportedInterface = NSXPCInterface(with: MemoryHelperProtocol.self)
        connection.exportedObject = HelperService(journal: journal)

        connection.invalidationHandler = { [weak self] in
            self?.logger.info("XPC connection invalidated")
        }

        connection.interruptionHandler = { [weak self] in
            self?.logger.info("XPC connection interrupted")
        }

        connection.resume()
        logger.info("Accepted XPC connection from validated client")
        return true
    }

    // MARK: - Client Validation

    private func validateClient(_ connection: NSXPCConnection) -> Bool {
        guard let auditToken = extractAuditToken(from: connection) else {
            logger.error("Failed to extract audit token from connection")
            return false
        }

        let tokenData = withUnsafeBytes(of: auditToken) { Data($0) }
        let attributes: [String: Any] = [
            kSecGuestAttributeAudit as String: tokenData
        ]

        var codeOpt: SecCode?
        let status = SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &codeOpt)
        guard status == errSecSuccess, let code = codeOpt else {
            logger.error("Failed to obtain SecCode from audit token: \(status)")
            return false
        }

        #if DEBUG
        return validateDebug(code: code)
        #else
        return validateProduction(code: code)
        #endif
    }

    private func validateProduction(code: SecCode) -> Bool {
        guard !Self.teamID.isEmpty else {
            logger.error("Cannot validate client: helper's own Team ID could not be determined")
            return false
        }

        var requirementOpt: SecRequirement?
        let reqStatus = SecRequirementCreateWithString(
            Self.designatedRequirement as CFString,
            [],
            &requirementOpt
        )
        guard reqStatus == errSecSuccess, let requirement = requirementOpt else {
            logger.error("Failed to create SecRequirement: \(reqStatus)")
            return false
        }

        let checkStatus = SecCodeCheckValidity(code, [], requirement)
        if checkStatus != errSecSuccess {
            logger.error("Client failed designated requirement check: \(checkStatus)")
            return false
        }
        return true
    }

    private func validateDebug(code: SecCode) -> Bool {
        // In debug builds, first verify the binary is signed (reject unsigned binaries).
        let basicCheck = SecCodeCheckValidity(
            code,
            SecCSFlags(rawValue: kSecCSBasicValidateOnly),
            nil
        )
        if basicCheck != errSecSuccess {
            logger.error("Client is unsigned or has invalid signature: \(basicCheck)")
            return false
        }

        // Then verify the bundle ID matches (still require com.cacheout.app identity,
        // but relax the team ID / anchor requirement for ad-hoc / locally-signed builds).
        var requirementOpt: SecRequirement?
        let reqStatus = SecRequirementCreateWithString(
            Self.debugRequirement as CFString,
            [],
            &requirementOpt
        )
        guard reqStatus == errSecSuccess, let requirement = requirementOpt else {
            logger.error("Failed to create debug SecRequirement: \(reqStatus)")
            return false
        }

        let identityCheck = SecCodeCheckValidity(code, [], requirement)
        if identityCheck != errSecSuccess {
            logger.error("Client bundle ID does not match com.cacheout.app: \(identityCheck)")
            return false
        }

        logger.warning("XPC connection accepted via DEBUG relaxed validation (ad-hoc/locally-signed)")
        return true
    }
}

// MARK: - Helper Service

/// Implementation of `MemoryHelperProtocol` exposed over XPC.
private final class HelperService: NSObject, MemoryHelperProtocol {

    private let logger = Logger(
        subsystem: "com.cacheout.memhelper",
        category: "service"
    )

    /// Shared sysctl journal for rollback support. Nil if not yet initialized.
    private let journal: SysctlJournal?

    /// Allowlist of sysctl names that may be written via setSysctlValue.
    private static let sysctlAllowlist: Set<String> = [
        "vm.compressor_mode",
        "vm.compressor_swaptrigger_pages_scaler",
        "kern.memorypressure_manual_trigger"
    ]

    /// Per-sysctl allowed values. Values not in these sets are rejected.
    private static let sysctlAllowedValues: [String: Set<Int32>] = [
        // compressor_mode: 1=normal, 2=swap-only, 4=frozen-compressed
        "vm.compressor_mode": [1, 2, 4],
        // swaptrigger scaler: 0=disable, reasonable tuning range 1-100
        "vm.compressor_swaptrigger_pages_scaler": Set(0...100),
        // memorypressure_manual_trigger: 0=off, 1=notify, 2=warn, 4=critical
        "kern.memorypressure_manual_trigger": [0, 1, 2, 4]
    ]

    init(journal: SysctlJournal?) {
        self.journal = journal
        super.init()
    }

    func getSystemStats(reply: @escaping (Data) -> Void) {
        logger.info("getSystemStats called")
        let stats = SystemStatsDTO(
            timestamp: Date(),
            freePages: 0,
            activePages: 0,
            inactivePages: 0,
            wiredPages: 0,
            compressorPageCount: 0,
            compressedBytes: 0,
            compressorBytesUsed: 0,
            compressionRatio: 0,
            pageSize: UInt64(vm_page_size),
            purgeableCount: 0,
            externalPages: 0,
            internalPages: 0,
            compressions: 0,
            decompressions: 0,
            pageins: 0,
            pageouts: 0,
            swapUsedBytes: 0,
            swapTotalBytes: 0,
            pressureLevel: 0,
            memoryTier: "unknown",
            totalPhysicalMemory: ProcessInfo.processInfo.physicalMemory
        )
        do {
            let data = try JSONEncoder().encode(stats)
            reply(data)
        } catch {
            logger.error("Failed to encode SystemStatsDTO: \(error)")
            reply(Data())
        }
    }

    func getProcessList(reply: @escaping (Data) -> Void) {
        logger.info("getProcessList called")
        var entries: [ProcessEntryDTO] = []

        // proc_listallpids(nil, 0) returns an estimated PID count (not bytes).
        let estimatedCount = proc_listallpids(nil, 0)
        guard estimatedCount > 0 else { reply(Data()); return }

        let pidCount = Int(estimatedCount) + 64
        var pids = [pid_t](repeating: 0, count: pidCount)
        let rawCount = Int(proc_listallpids(&pids, Int32(pidCount * MemoryLayout<pid_t>.stride)))
        // Clamp to buffer size in case the process table grew between calls.
        let actualCount = min(rawCount, pids.count)

        for i in 0..<actualCount {
            let pid = pids[i]
            guard pid > 0 else { continue }

            var info = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &info) { ptr in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rusagePtr in
                    proc_pid_rusage(pid, Int32(RUSAGE_INFO_V4), rusagePtr)
                }
            }
            guard result == 0 else { continue }

            let name: String
            let pathBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: Int(MAXPATHLEN))
            defer { pathBuffer.deallocate() }
            let pathLen = proc_pidpath(pid, pathBuffer, UInt32(MAXPATHLEN))

            if pathLen > 0 {
                let fullPath = String(cString: pathBuffer)
                name = (fullPath as NSString).lastPathComponent
            } else {
                let nameBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: Int(MAXCOMLEN) + 1)
                defer { nameBuffer.deallocate() }
                let nameLen = proc_name(pid, nameBuffer, UInt32(MAXCOMLEN + 1))
                name = nameLen > 0 ? String(cString: nameBuffer) : "?"
            }

            var bsdInfo = proc_bsdinfo()
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsdInfo,
                         Int32(MemoryLayout<proc_bsdinfo>.size))
            let isRosetta = (bsdInfo.pbi_flags & 0x0002_0000) != 0

            let leakIndicator: Double = info.ri_phys_footprint > 0
                ? Double(info.ri_lifetime_max_phys_footprint) / Double(info.ri_phys_footprint)
                : 0

            entries.append(ProcessEntryDTO(
                pid: pid,
                name: name,
                physFootprint: info.ri_phys_footprint,
                lifetimeMaxFootprint: info.ri_lifetime_max_phys_footprint,
                pageins: info.ri_pageins,
                jetsamPriority: -1,
                jetsamLimit: -1,
                isRosetta: isRosetta,
                leakIndicator: leakIndicator
            ))
        }

        entries.sort { $0.physFootprint > $1.physFootprint }

        do {
            let data = try JSONEncoder().encode(entries)
            reply(data)
        } catch {
            logger.error("Failed to encode process list: \(error)")
            reply(Data())
        }
    }

    func getJetsamSnapshot(reply: @escaping (Data) -> Void) {
        reply(Data())
    }

    func getJetsamPriorityList(reply: @escaping (Data) -> Void) {
        logger.info("getJetsamPriorityList called")

        let cmd = UInt32(MEMORYSTATUS_CMD_GET_PRIORITY_LIST)
        let entrySize = MemoryLayout<memorystatus_priority_entry_t>.stride

        // Guard against vendored header drift: XNU's struct is 24 bytes
        // (pid:4 + priority:4 + user_data:8 + limit:4 + state:4).
        // With alignment padding the stride is 24 on arm64/x86_64.
        // If this assertion fires, CKernelPrivate/memorystatus_private.h is stale.
        assert(entrySize == 24, "memorystatus_priority_entry_t stride mismatch — update CKernelPrivate header")

        // Resize loop: start with 2048 entries and grow if the buffer fills
        // completely, which indicates possible truncation. Cap at 3 attempts
        // to avoid unbounded allocation.
        var capacity = 2048
        let maxAttempts = 3
        var finalBuffer: UnsafeMutableRawPointer?
        var finalReturnedSize: Int = 0

        for attempt in 0..<maxAttempts {
            let bufferSize = entrySize * capacity
            let buffer = UnsafeMutableRawPointer.allocate(
                byteCount: bufferSize,
                alignment: MemoryLayout<memorystatus_priority_entry_t>.alignment
            )

            let returnedSize = memorystatus_control(cmd, 0, 0, buffer, bufferSize)
            if returnedSize <= 0 {
                let err = errno
                buffer.deallocate()
                logger.error("memorystatus_control GET_PRIORITY_LIST failed: errno \(err)")
                reply(Data())
                return
            }

            let returnedEntries = Int(returnedSize) / entrySize

            // If the returned count equals capacity, the buffer may have been
            // truncated. Double capacity and retry.
            if returnedEntries >= capacity {
                buffer.deallocate()
                if attempt < maxAttempts - 1 {
                    capacity *= 2
                    logger.info("Priority list may be truncated (\(returnedEntries) entries), resizing to \(capacity)")
                    continue
                }
                // Final attempt still full — treat as truncation error rather
                // than returning partial data that could cause wrong target selection.
                logger.error("GET_PRIORITY_LIST still truncated after \(maxAttempts) attempts (\(returnedEntries) entries at capacity \(capacity))")
                reply(Data())
                return
            }

            finalBuffer = buffer
            finalReturnedSize = Int(returnedSize)
            break
        }

        guard let buffer = finalBuffer else {
            logger.error("GET_PRIORITY_LIST: failed to obtain non-truncated result")
            reply(Data())
            return
        }
        defer { buffer.deallocate() }

        // Validate that returned bytes are an exact multiple of the entry size.
        guard finalReturnedSize % entrySize == 0 else {
            logger.error("GET_PRIORITY_LIST returned \(finalReturnedSize) bytes, not a multiple of entry size \(entrySize)")
            reply(Data())
            return
        }

        let count = finalReturnedSize / entrySize
        var entries: [JetsamPriorityEntryDTO] = []
        entries.reserveCapacity(count)

        let typedBuffer = buffer.bindMemory(to: memorystatus_priority_entry_t.self, capacity: count)
        for i in 0..<count {
            let entry = typedBuffer[i]
            entries.append(JetsamPriorityEntryDTO(
                pid: entry.pid,
                priority: entry.priority,
                limit: entry.limit
            ))
        }

        do {
            let data = try JSONEncoder().encode(entries)
            reply(data)
        } catch {
            logger.error("Failed to encode jetsam priority list: \(error)")
            reply(Data())
        }
    }

    func getKernelZoneHealth(reply: @escaping (Data) -> Void) {
        reply(Data())
    }

    func getRosettaProcesses(reply: @escaping (Data) -> Void) {
        logger.info("getRosettaProcesses called")
        var entries: [ProcessEntryDTO] = []

        // proc_listallpids(nil, 0) returns an estimated PID count (not bytes).
        let estimatedCount = proc_listallpids(nil, 0)
        guard estimatedCount > 0 else { reply(Data()); return }

        let pidCount = Int(estimatedCount) + 64
        var pids = [pid_t](repeating: 0, count: pidCount)
        let rawCount = Int(proc_listallpids(&pids, Int32(pidCount * MemoryLayout<pid_t>.stride)))
        // Clamp to buffer size in case the process table grew between calls.
        let actualCount = min(rawCount, pids.count)

        for i in 0..<actualCount {
            let pid = pids[i]
            guard pid > 0 else { continue }

            var bsdInfo = proc_bsdinfo()
            let infoResult = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsdInfo,
                                          Int32(MemoryLayout<proc_bsdinfo>.size))
            guard infoResult == Int32(MemoryLayout<proc_bsdinfo>.size) else { continue }
            guard (bsdInfo.pbi_flags & 0x0002_0000) != 0 else { continue }

            var info = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &info) { ptr in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rusagePtr in
                    proc_pid_rusage(pid, Int32(RUSAGE_INFO_V4), rusagePtr)
                }
            }
            guard result == 0 else { continue }

            let name: String
            let pathBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: Int(MAXPATHLEN))
            defer { pathBuffer.deallocate() }
            let pathLen = proc_pidpath(pid, pathBuffer, UInt32(MAXPATHLEN))

            if pathLen > 0 {
                let fullPath = String(cString: pathBuffer)
                name = (fullPath as NSString).lastPathComponent
            } else {
                let nameBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: Int(MAXCOMLEN) + 1)
                defer { nameBuffer.deallocate() }
                let nameLen = proc_name(pid, nameBuffer, UInt32(MAXCOMLEN + 1))
                name = nameLen > 0 ? String(cString: nameBuffer) : "?"
            }

            let leakIndicator: Double = info.ri_phys_footprint > 0
                ? Double(info.ri_lifetime_max_phys_footprint) / Double(info.ri_phys_footprint)
                : 0

            entries.append(ProcessEntryDTO(
                pid: pid,
                name: name,
                physFootprint: info.ri_phys_footprint,
                lifetimeMaxFootprint: info.ri_lifetime_max_phys_footprint,
                pageins: info.ri_pageins,
                jetsamPriority: -1,
                jetsamLimit: -1,
                isRosetta: true,
                leakIndicator: leakIndicator
            ))
        }

        entries.sort { $0.physFootprint > $1.physFootprint }

        do {
            let data = try JSONEncoder().encode(entries)
            reply(data)
        } catch {
            logger.error("Failed to encode Rosetta process list: \(error)")
            reply(Data())
        }
    }

    func setJetsamLimit(pid: pid_t, limitMB: Int32, reply: @escaping (Bool, String?) -> Void) {
        logger.info("setJetsamLimit called: pid=\(pid), limitMB=\(limitMB)")

        // Use MemlimitWorkaround to auto-detect the 128GB bug and choose
        // the appropriate kernel path (HWM vs SET_PRIORITY_PROPERTIES).
        let workaround = MemlimitWorkaround()
        let (success, error) = workaround.setJetsamLimit(pid: pid, limitMB: limitMB)

        if success {
            logger.info("Jetsam limit set to \(limitMB) MB for pid \(pid)")
        } else {
            logger.error("setJetsamLimit failed for pid \(pid): \(error ?? "unknown", privacy: .public)")
        }

        reply(success, error)
    }

    /// Allowed purge levels for memorypressure_manual_trigger.
    private static let allowedPurgeLevels: Set<Int32> = [0, 1, 2, 4]

    func triggerPurge(level: Int32, reply: @escaping (Bool) -> Void) {
        logger.info("triggerPurge called with level \(level)")

        guard Self.allowedPurgeLevels.contains(level) else {
            logger.error("triggerPurge rejected: level \(level) not in allowed set")
            reply(false)
            return
        }

        var value = level
        let result = sysctlbyname("kern.memorypressure_manual_trigger", nil, nil, &value, MemoryLayout<Int32>.size)
        if result == 0 {
            logger.info("Memory pressure trigger succeeded at level \(level)")
            reply(true)
        } else {
            let err = errno
            logger.error("Memory pressure trigger failed: errno \(err)")
            reply(false)
        }
    }

    func getReduceTransparencyState(reply: @escaping (Bool, Bool, String?) -> Void) {
        logger.info("getReduceTransparencyState called")

        // Resolve the console user via SCDynamicStore.
        var uid: uid_t = 0
        guard let consoleUser = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) as String?,
              !consoleUser.isEmpty,
              consoleUser != "loginwindow" else {
            logger.warning("No console user found")
            reply(false, false, "no_console_user")
            return
        }

        // Read reduceTransparency via CFPreferences scoped to the console user.
        let key = "reduceTransparency" as CFString
        let appID = "com.apple.universalaccess" as CFString
        let userName = consoleUser as CFString

        // Synchronize the domain first to ensure we read the latest on-disk state.
        // This distinguishes "key absent" from "domain read failure".
        let synced = CFPreferencesSynchronize(appID, userName, kCFPreferencesAnyHost)
        guard synced else {
            logger.error("CFPreferencesSynchronize failed for console user domain")
            reply(false, false, "defaults_read_failed: synchronize_failed")
            return
        }

        let value = CFPreferencesCopyValue(key, appID, userName, kCFPreferencesAnyHost)

        if let boolValue = value as? Bool {
            logger.info("Reduce transparency state for console user: \(boolValue)")
            reply(true, boolValue, nil)
        } else if value == nil {
            // Key not set — defaults to false (not enabled).
            logger.info("reduceTransparency not set for console user; defaulting to false")
            reply(true, false, nil)
        } else {
            logger.error("reduceTransparency has unexpected type for console user")
            reply(false, false, "defaults_read_failed: unexpected_value_type")
        }
    }

    func setReduceTransparency(_ enabled: Bool, reply: @escaping (Bool) -> Void) {
        logger.info("setReduceTransparency called with enabled=\(enabled)")

        // Resolve the console user.
        var uid: uid_t = 0
        guard let consoleUser = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) as String?,
              !consoleUser.isEmpty,
              consoleUser != "loginwindow" else {
            logger.error("setReduceTransparency: no console user")
            reply(false)
            return
        }

        // Write via CFPreferences scoped to the console user.
        let key = "reduceTransparency" as CFString
        let appID = "com.apple.universalaccess" as CFString
        let userName = consoleUser as CFString

        CFPreferencesSetValue(key, enabled as CFBoolean, appID, userName, kCFPreferencesAnyHost)
        // Use domain-scoped synchronize to flush the write for the correct user,
        // not CFPreferencesAppSynchronize which targets the current user/current host.
        let synced = CFPreferencesSynchronize(appID, userName, kCFPreferencesAnyHost)

        if synced {
            logger.info("Reduce transparency set to \(enabled) for console user")
            reply(true)
        } else {
            logger.error("CFPreferencesSynchronize failed after write for console user")
            reply(false)
        }
    }

    func deleteAPFSSnapshot(uuid: String, reply: @escaping (Bool, String?) -> Void) {
        reply(false, "Not implemented")
    }

    func getSleepImageSize(reply: @escaping (Bool, Bool, UInt64, String?) -> Void) {
        logger.info("getSleepImageSize called")
        let path = "/private/var/vm/sleepimage"
        let fm = FileManager.default

        guard fm.fileExists(atPath: path) else {
            logger.info("Sleep image absent")
            reply(true, false, 0, nil)
            return
        }

        do {
            let attrs = try fm.attributesOfItem(atPath: path)
            let size = (attrs[.size] as? UInt64) ?? 0
            logger.info("Sleep image size: \(size) bytes")
            reply(true, true, size, nil)
        } catch {
            logger.error("Sleep image stat failed: \(error.localizedDescription)")
            reply(false, false, 0, "stat_failed: \(error.localizedDescription)")
        }
    }

    func deleteSleepImage(reply: @escaping (Bool, UInt64) -> Void) {
        logger.info("deleteSleepImage called")
        let path = "/private/var/vm/sleepimage"
        let fm = FileManager.default

        // Check existence and get size before deletion.
        guard fm.fileExists(atPath: path) else {
            logger.info("deleteSleepImage: file absent, nothing to delete")
            reply(true, 0)
            return
        }

        var size: UInt64 = 0
        do {
            let attrs = try fm.attributesOfItem(atPath: path)
            size = (attrs[.size] as? UInt64) ?? 0
        } catch {
            logger.error("deleteSleepImage: stat failed before delete: \(error.localizedDescription)")
            reply(false, 0)
            return
        }

        do {
            try fm.removeItem(atPath: path)
            logger.info("deleteSleepImage: deleted \(size) bytes")
            reply(true, size)
        } catch {
            logger.error("deleteSleepImage: delete failed: \(error.localizedDescription)")
            reply(false, 0)
        }
    }

    func flushWindowServerCaches(reply: @escaping (UInt64) -> Void) {
        reply(0)
    }

    func setSysctlValue(name: String, value: Int32, reply: @escaping (Bool, String?) -> Void) {
        logger.info("setSysctlValue called: name=\(name, privacy: .public), value=\(value)")

        // Validate against allowlist.
        guard Self.sysctlAllowlist.contains(name) else {
            logger.error("setSysctlValue rejected: \(name, privacy: .public) not in allowlist")
            reply(false, "sysctl_not_allowed: \(name)")
            return
        }

        // Validate value against per-sysctl allowed values.
        if let allowed = Self.sysctlAllowedValues[name], !allowed.contains(value) {
            logger.error("setSysctlValue rejected: value \(value) not in allowed set for \(name, privacy: .public)")
            reply(false, "sysctl_value_not_allowed: \(name) does not accept \(value)")
            return
        }

        // Journal the current value before writing (for rollback).
        var journalToken: UUID?
        if let journal {
            guard let token = journal.record(name) else {
                logger.error("Failed to journal sysctl \(name, privacy: .public) before write")
                reply(false, "journal_record_failed")
                return
            }
            journalToken = token
        } else {
            logger.warning("No journal available; sysctl write will not be rollback-safe")
        }

        // Write the new value.
        var val = value
        let rc = sysctlbyname(name, nil, nil, &val, MemoryLayout<Int32>.size)
        if rc == 0 {
            logger.info("sysctl \(name, privacy: .public) set to \(value)")
            reply(true, nil)
        } else {
            let err = errno
            // Abort the journal entry — the write never succeeded, so rolling
            // back this entry later could clobber unrelated external changes.
            if let token = journalToken {
                let aborted = journal?.abort(token) ?? true
                if !aborted {
                    logger.error("journal_abort_failed for \(name, privacy: .public) — stale entry persists on disk")
                    reply(false, "sysctlbyname_failed: errno \(err); journal_abort_failed")
                    return
                }
            }
            logger.error("sysctlbyname write failed for \(name, privacy: .public): errno \(err)")
            reply(false, "sysctlbyname_failed: errno \(err)")
        }
    }

    func detectMemlimitBug(reply: @escaping (Bool) -> Void) {
        let workaround = MemlimitWorkaround()
        reply(workaround.detectBug())
    }

    func getMemoryTier(reply: @escaping (String) -> Void) {
        reply(MemoryTier.detect().rawValue)
    }
}
