/// # MemoryView — Memory Dashboard Tab
///
/// Extracted from SystemMonitorView to serve as the dedicated Memory tab.
/// Shows live system memory metrics: pressure badge, RAM bar, and stats grid.
///
/// Shares a single `SystemMonitorViewModel` with `ProcessesView` — no duplicate polling.

import CacheoutShared
import SwiftUI

struct MemoryView: View {
    @ObservedObject var viewModel: SystemMonitorViewModel

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.latestStats != nil {
                ScrollView {
                    VStack(spacing: 16) {
                        pressureAndRAMSection
                        statsGrid
                    }
                    .padding()
                }
            } else {
                loadingState
            }
        }
    }

    // MARK: - Pressure + RAM Bar

    private var pressureAndRAMSection: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Memory")
                    .font(.headline)
                Spacer()
                pressureBadge
            }

            ramBar
        }
    }

    private var pressureBadge: some View {
        let tier = viewModel.pressureTier
        let (label, color): (String, Color) = {
            switch tier {
            case .normal: return ("Normal", .green)
            case .elevated: return ("Elevated", .yellow)
            case .warning: return ("Warning", .orange)
            case .critical: return ("Critical", .red)
            }
        }()

        return Text(label)
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var ramBar: some View {
        let total = viewModel.totalPhysicalMB
        guard total > 0 else { return AnyView(EmptyView()) }

        let active = viewModel.activeMB / total
        let wired = viewModel.wiredMB / total
        let compressed = viewModel.compressedMB / total
        let inactive = viewModel.inactiveMB / total

        return AnyView(
            VStack(alignment: .leading, spacing: 4) {
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(Color.red.opacity(0.8))
                            .frame(width: geo.size.width * wired)
                        Rectangle()
                            .fill(Color.orange.opacity(0.8))
                            .frame(width: geo.size.width * active)
                        Rectangle()
                            .fill(Color.purple.opacity(0.7))
                            .frame(width: geo.size.width * compressed)
                        Rectangle()
                            .fill(Color.blue.opacity(0.4))
                            .frame(width: geo.size.width * inactive)
                        Rectangle()
                            .fill(Color.green.opacity(0.3))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .frame(height: 14)

                HStack(spacing: 12) {
                    legendDot(color: .red.opacity(0.8), label: "Wired")
                    legendDot(color: .orange.opacity(0.8), label: "Active")
                    legendDot(color: .purple.opacity(0.7), label: "Compressed")
                    legendDot(color: .blue.opacity(0.4), label: "Inactive")
                    legendDot(color: .green.opacity(0.3), label: "Free")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        )
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
        }
    }

    // MARK: - Stats Grid

    private var statsGrid: some View {
        LazyVGrid(columns: [
            GridItem(.flexible()),
            GridItem(.flexible()),
            GridItem(.flexible()),
        ], spacing: 10) {
            statCard("Active", formatMB(viewModel.activeMB))
            statCard("Wired", formatMB(viewModel.wiredMB))
            statCard("Compressed", formatMB(viewModel.compressedMB))
            statCard("Free", formatMB(viewModel.freeMB))
            statCard("Swap Used", formatMB(viewModel.swapUsedMB))

            VStack(spacing: 2) {
                Text("Compressor")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack(spacing: 2) {
                    Text(String(format: "%.1fx", viewModel.compressionRatio))
                        .font(.callout.monospacedDigit().bold())
                    Text(viewModel.trendArrow)
                        .font(.callout)
                        .foregroundStyle(trendColor)
                }
                if viewModel.isThrashing {
                    Text("Thrashing")
                        .font(.caption2.bold())
                        .foregroundStyle(.red)
                }
            }
            .padding(8)
            .background(.quaternary.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private var trendColor: Color {
        switch viewModel.compressionTrend {
        case .improving: return .green
        case .declining: return .orange
        case .stable: return .secondary
        }
    }

    private func statCard(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospacedDigit().bold())
        }
        .padding(8)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Loading State

    private var loadingState: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
            Text("Loading system stats...")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - Formatting

    private func formatMB(_ mb: Double) -> String {
        if mb >= 1024 {
            return String(format: "%.1f GB", mb / 1024)
        }
        return String(format: "%.0f MB", mb)
    }
}
