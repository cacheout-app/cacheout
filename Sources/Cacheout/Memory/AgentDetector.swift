/// # AgentDetector — Known AI Agent Process Detection
///
/// Simple detection of known AI agent processes by exact `proc_name` match.
/// Uses a fixed set of process names reliably observable via MAXCOMLEN (~16 chars).
///
/// No generic names like `python3` — too unreliable via proc_name truncation.

import CacheoutShared
import Foundation

enum AgentDetector {

    /// Known agent process names (exact proc_name match).
    static let knownAgentNames: Set<String> = [
        "ollama",
        "llama-server",
        "llama-cli",
        "mlx_lm.server",
        "claude",
    ]

    /// Check if a process is a known AI agent.
    static func isAgent(_ process: ProcessEntryDTO) -> Bool {
        knownAgentNames.contains(process.name)
    }

    /// Filter processes to only known AI agents.
    static func agentProcesses(from processes: [ProcessEntryDTO]) -> [ProcessEntryDTO] {
        processes.filter { isAgent($0) }
    }
}
