// RosettaDetector.swift
// Detects Rosetta-translated (x86_64) processes via proc_pidinfo.

import Darwin

/// Detects whether a process is running under Rosetta 2 translation.
///
/// Uses `proc_pidinfo(PROC_PIDTBSDINFO)` to read `pbi_flags` and checks
/// the `P_TRANSLATED` bit (0x00020000).
enum RosettaDetector {

    /// The `P_TRANSLATED` flag indicating Rosetta 2 translation.
    private static let pTranslated: UInt32 = 0x0002_0000

    /// Returns `true` if the process with the given PID is running under Rosetta 2.
    ///
    /// Returns `false` if the process cannot be queried (e.g., EPERM or invalid PID).
    static func isTranslated(pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard result == size else { return false }
        return (info.pbi_flags & pTranslated) != 0
    }
}
