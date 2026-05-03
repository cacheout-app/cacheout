/// # MenuBarView — Menubar Popover
///
/// A compact 300px-wide popover displayed from the menubar extra. Provides
/// at-a-glance disk status and one-tap cleanup without opening the full window.
///
/// ## Layout Structure
///
/// ```
/// ┌──────────────────────────┐
/// │ [Gauge] Macintosh HD     │
/// │         XX GB available  │
/// ├──────────────────────────┤
/// │ Recoverable │ Categories │
/// ├──────────────────────────┤
/// │ Top 5 categories by size │
/// ├──────────────────────────┤
/// │ Scanned X min ago        │
/// │ Docker Prune      [Run]  │
/// ├──────────────────────────┤
/// │ [Scan] [Quick Clean] [⊞] │
/// └──────────────────────────┘
/// ```
///
/// ## Gauge Colors
///
/// - Blue: < 85% used (normal)
/// - Orange: 85-95% used (warning)
/// - Red: > 95% used (critical)
///
/// ## Auto-Scan
///
/// Automatically triggers a scan when the popover opens if data is stale
/// (no previous results or older than the scan interval).

import SwiftUI

/// Compact menubar popover showing disk status and quick-clean options.
struct MenuBarView: View {
    @EnvironmentObject var viewModel: CacheoutViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            // Header with disk gauge
            diskHeader
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 10)

            Divider()

            // Quick stats or scan prompt
            if viewModel.hasResults {
                quickStats
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)

                Divider()

                // Top reclaimable categories (max 5)
                topCategories
                    .padding(.vertical, 6)

                Divider()
            }

            // Last scanned timestamp
            if let lastScanned = viewModel.lastScanDate {
                HStack {
                    Text("Scanned \(lastScanned, style: .relative) ago")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
            }

            // Docker prune
            dockerRow
                .padding(.horizontal, 14)
                .padding(.vertical, 6)

            Divider()

            // Action buttons
            actionBar
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .frame(width: 300)
        .task(id: viewModel.scanGeneration) {
            // Refresh disk info every time the popover appears or scan completes
            // scanGeneration increments on each scan, so this re-fires when data changes
        }
        .task {
            // Auto-scan on popover open if stale (no results or >5 min old)
            if viewModel.shouldAutoRescan {
                await viewModel.scan()
            }
        }
    }

    // MARK: - Disk Header

    private var diskHeader: some View {
        HStack(spacing: 12) {
            // Circular gauge
            ZStack {
                Circle()
                    .stroke(Color(.separatorColor), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: viewModel.diskInfo?.usedPercentage ?? 0)
                    .stroke(gaugeColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))

                VStack(spacing: 0) {
                    Text("\(Int((viewModel.diskInfo?.usedPercentage ?? 0) * 100))")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("%")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 3) {
                Text("Macintosh HD")
                    .font(.headline)
                if let disk = viewModel.diskInfo {
                    Text("\(disk.formattedFree) available")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Checking...")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()
        }
    }

    // MARK: - Quick Stats

    private var quickStats: some View {
        HStack {
            statPill(
                label: "Recoverable",
                value: ByteCountFormatter.string(
                    fromByteCount: viewModel.totalRecoverable,
                    countStyle: .file
                ),
                color: .orange
            )
            Spacer()
            statPill(
                label: "Categories",
                value: "\(viewModel.scanResults.filter { !$0.isEmpty }.count)",
                color: .blue
            )
        }
    }

    private func statPill(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.title3, design: .rounded).bold())
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Top Categories

    private var topCategories: some View {
        let top = viewModel.scanResults
            .filter { !$0.isEmpty }
            .sorted { $0.sizeBytes > $1.sizeBytes }
            .prefix(5)

        return VStack(spacing: 0) {
            ForEach(Array(top)) { result in
                HStack(spacing: 8) {
                    Image(systemName: result.category.icon)
                        .font(.caption)
                        .foregroundStyle(riskColor(result.category.riskLevel))
                        .frame(width: 18)

                    Text(result.category.name)
                        .font(.caption)
                        .lineLimit(1)

                    Spacer()

                    Text(result.formattedSize)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
            }
        }
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack(spacing: 8) {
            // Rescan
            Button {
                Task { await viewModel.scan() }
            } label: {
                Label("Scan", systemImage: "arrow.clockwise")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isScanning)

            if viewModel.isScanning {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)
            }

            Spacer()

            // Smart Clean button
            Button {
                Task { await viewModel.smartClean() }
            } label: {
                Label(
                    viewModel.isCleaning ? "Cleaning..." : "Quick Clean",
                    systemImage: "sparkles"
                )
                .font(.caption.weight(.medium))
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0.85, green: 0.45, blue: 0.1)) // burnt orange — readable white text
            .disabled(viewModel.totalRecoverable == 0 || viewModel.isCleaning)

            // Open main window
            Button {
                openWindow(id: "main")
            } label: {
                Image(systemName: "macwindow")
                    .font(.caption)
                    .accessibilityLabel("Open full window")
            }
            .buttonStyle(.bordered)
            .help("Open full window")
        }
    }

    // MARK: - Docker Row

    private var dockerRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "cube.transparent")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 18)

            Text("Docker Prune")
                .font(.caption)

            Spacer()

            if viewModel.isDockerPruning {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 14, height: 14)
            } else if let result = viewModel.lastDockerPruneResult {
                Text(result.contains("reclaimed") ? "✓" : "—")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Button {
                Task { await viewModel.dockerPrune() }
            } label: {
                Text("Run")
                    .font(.caption2.weight(.medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .disabled(viewModel.isDockerPruning)
        }
    }

    // MARK: - Helpers

    private var gaugeColor: Color {
        guard let pct = viewModel.diskInfo?.usedPercentage else { return .blue }
        if pct > 0.95 { return .red }
        if pct > 0.85 { return .orange }
        return .blue
    }

    private func riskColor(_ level: RiskLevel) -> Color {
        switch level {
        case .safe: return .green
        case .review: return .yellow
        case .caution: return .red
        }
    }
}
