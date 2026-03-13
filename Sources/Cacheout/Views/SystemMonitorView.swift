/// # SystemMonitorView — Legacy System Health View
///
/// Preserved for backward compatibility. The memory and process views have been
/// extracted into `MemoryView` and `ProcessesView` respectively, each embedded
/// as separate tabs in `ContentView`.
///
/// This view is no longer used as a tab but remains available as a standalone
/// combined view for other entry points (e.g., menu bar popover).

import CacheoutShared
import SwiftUI

struct SystemMonitorView: View {
    @StateObject private var viewModel = SystemMonitorViewModel()

    var body: some View {
        VStack(spacing: 0) {
            MemoryView(viewModel: viewModel)
            Divider()
            processesSection
        }
        .onAppear { viewModel.startMonitoring() }
        .onDisappear { viewModel.stopMonitoring() }
    }

    // MARK: - Processes (inline for legacy view)

    private var processesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Top Processes")
                    .font(.headline)
                Spacer()
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
        .padding()
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
        }
        .padding(.vertical, 3)
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1048576.0
        if mb >= 1024 {
            return String(format: "%.1f GB", mb / 1024)
        }
        return String(format: "%.0f MB", mb)
    }
}
