/// # ProcessesView — Process List Tab
///
/// Shows the top memory-consuming processes with intervention actions.
/// Shares a single `SystemMonitorViewModel` with `MemoryView` — no duplicate polling.
///
/// Process actions use canonical intervention names from `InterventionRegistry`:
/// - `sigterm-cascade` (Tier 3 — destructive)
/// - `sigstop-freeze` (Tier 3 — destructive)
/// - `jetsam-hwm` (Tier 2 — confirm)

import CacheoutShared
import SwiftUI

struct ProcessesView: View {
    @ObservedObject var viewModel: SystemMonitorViewModel

    /// The pending intervention confirmation shown as a sheet.
    @State private var pendingConfirmation: InterventionConfirmation?

    /// Whether the privileged helper is enabled. When false, intervention
    /// actions are hidden and the tab operates in read-only mode.
    private var helperEnabled: Bool {
        HelperInstaller().status == .enabled
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.latestStats != nil {
                ScrollView {
                    VStack(spacing: 16) {
                        processesSection
                    }
                    .padding()
                }
            } else {
                loadingState
            }
        }
        .sheet(item: $pendingConfirmation) { confirmation in
            InterventionConfirmSheet(confirmation: confirmation) { proceed in
                if proceed {
                    // Intervention execution would be handled here via InterventionEngine.
                    // For now, the confirmation flow is wired up; actual execution requires
                    // an InterventionExecutor with an active XPC connection.
                }
            }
        }
    }

    // MARK: - Processes Section

    private var processesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Top Processes")
                    .font(.headline)
                Spacer()
                if !helperEnabled {
                    Text("Read-only")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .foregroundStyle(.secondary)
                        .clipShape(Capsule())
                        .help("Install the privileged helper to enable process actions")
                }
                if viewModel.processPartial {
                    Text("Partial data")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.yellow.opacity(0.2))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())
                }
            }

            ForEach(Array(viewModel.topProcesses.enumerated()), id: \.element.pid) { index, process in
                processRow(process, rank: index + 1)
            }
        }
    }

    private func processRow(_ process: ProcessEntryDTO, rank: Int) -> some View {
        HStack {
            Text("\(rank)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 20, alignment: .trailing)

            Text(process.name)
                .font(.callout)
                .lineLimit(1)

            if process.isRosetta {
                Text("Rosetta")
                    .font(.caption2.bold())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.blue.opacity(0.15))
                    .foregroundStyle(.blue)
                    .clipShape(Capsule())
            }

            Spacer()

            Text(formatBytes(process.physFootprint))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)

            if helperEnabled {
                processActionMenu(process)
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: - Process Actions

    private func processActionMenu(_ process: ProcessEntryDTO) -> some View {
        Menu {
            Button {
                requestConfirmation(
                    interventionName: "sigterm-cascade",
                    displayName: "Terminate Process",
                    tier: .destructive,
                    estimate: "Frees process memory",
                    risk: "Sends SIGTERM to \(process.name) (PID \(process.pid)). The process will be asked to exit gracefully, followed by SIGKILL if it does not respond.",
                    process: process
                )
            } label: {
                Label("Terminate (SIGTERM)", systemImage: "xmark.circle")
            }

            Button {
                requestConfirmation(
                    interventionName: "sigstop-freeze",
                    displayName: "Freeze Process",
                    tier: .destructive,
                    estimate: "Pauses memory allocation",
                    risk: "Sends SIGSTOP to \(process.name) (PID \(process.pid)). The process will be frozen until manually resumed with SIGCONT.",
                    process: process
                )
            } label: {
                Label("Freeze (SIGSTOP)", systemImage: "pause.circle")
            }

            Divider()

            Button {
                requestConfirmation(
                    interventionName: "jetsam-hwm",
                    displayName: "Set Jetsam Limit",
                    tier: .confirm,
                    estimate: "Limits future allocation",
                    risk: "Sets a jetsam high-water mark on \(process.name) (PID \(process.pid)). The kernel will kill the process if it exceeds this memory limit.",
                    process: process
                )
            } label: {
                Label("Set Jetsam Limit", systemImage: "gauge.with.needle")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func requestConfirmation(
        interventionName: String,
        displayName: String,
        tier: InterventionTier,
        estimate: String,
        risk: String,
        process: ProcessEntryDTO
    ) {
        pendingConfirmation = InterventionConfirmation(
            displayName: displayName,
            name: interventionName,
            tier: tier,
            estimate: estimate,
            risk: risk,
            targetPID: process.pid,
            targetName: process.name
        )
    }

    // MARK: - Loading State

    private var loadingState: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
            Text("Loading process data...")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - Formatting

    private func formatBytes(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1048576.0
        if mb >= 1024 {
            return String(format: "%.1f GB", mb / 1024)
        }
        return String(format: "%.0f MB", mb)
    }
}
