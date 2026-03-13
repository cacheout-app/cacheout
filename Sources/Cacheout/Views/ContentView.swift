/// # ContentView — Main Application Window
///
/// The primary view displayed in the main `WindowGroup`. Contains a 4-tab layout:
///
/// 1. **Caches** — Disk cache scanning, selection, and cleanup controls.
/// 2. **Memory** — Live system memory stats (pressure, RAM bar, compressor).
/// 3. **Processes** — Top memory-consuming processes with intervention actions.
/// 4. **Settings** — Embedded preferences (same content as Cmd+, window).
///    SPUUpdater is injected from `CacheoutApp` so the embedded Settings tab
///    has access to update checking controls.
///
/// ## Shared ViewModel
///
/// Memory and Processes tabs share a single `SystemMonitorViewModel` to avoid
/// duplicate polling. Monitoring lifecycle is driven by `selectedTab` via
/// `.onChange` — starts when entering the monitor-tab set (Memory, Processes),
/// stops when leaving it. An `.onDisappear` guard on the outer TabView ensures
/// teardown on window close regardless of the current tab.
///
/// ## Sheets
///
/// - **CleanConfirmationSheet**: Presented when "Clean Selected" is tapped.
/// - **CleanupReportSheet**: Presented after cleanup completes.
///
/// ## Auto-Scan
///
/// Triggers an initial scan via `.task` when the Caches tab first appears.

import SwiftUI
import Sparkle

struct ContentView: View {
    @EnvironmentObject var viewModel: CacheoutViewModel
    @StateObject private var monitorViewModel = SystemMonitorViewModel()
    @State private var selectedTab = "caches"

    /// SPUUpdater injected from CacheoutApp for the embedded Settings tab.
    let updater: SPUUpdater

    /// Tabs that require the system monitor to be active.
    private static let monitorTabs: Set<String> = ["memory", "processes"]

    var body: some View {
        TabView(selection: $selectedTab) {
            cachesTab
                .tabItem {
                    Label("Caches", systemImage: "externaldrive")
                }
                .tag("caches")

            MemoryView(viewModel: monitorViewModel)
                .tabItem {
                    Label("Memory", systemImage: "memorychip")
                }
                .tag("memory")

            ProcessesView(viewModel: monitorViewModel)
                .tabItem {
                    Label("Processes", systemImage: "list.bullet.rectangle")
                }
                .tag("processes")

            SettingsContentView(updater: updater)
                .environmentObject(viewModel)
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag("settings")
        }
        .onChange(of: selectedTab) { oldTab, newTab in
            let wasMonitoring = Self.monitorTabs.contains(oldTab)
            let needsMonitoring = Self.monitorTabs.contains(newTab)
            if needsMonitoring && !wasMonitoring {
                monitorViewModel.startMonitoring()
            } else if !needsMonitoring && wasMonitoring {
                monitorViewModel.stopMonitoring()
            }
        }
        .onDisappear {
            monitorViewModel.stopMonitoring()
        }
    }

    // MARK: - Caches Tab

    private var cachesTab: some View {
        VStack(spacing: 0) {
            // Header
            headerSection
                .padding()

            // Disk usage bar
            if let diskInfo = viewModel.diskInfo {
                DiskUsageBar(diskInfo: diskInfo)
                    .padding(.horizontal)
            }

            // Results list
            if viewModel.hasResults {
                resultsList
            } else if !viewModel.isScanning {
                emptyState
            }

            Spacer(minLength: 0)

            // Bottom toolbar
            bottomBar
        }
        .sheet(isPresented: $viewModel.showCleanConfirmation) {
            CleanConfirmationSheet()
        }
        .sheet(isPresented: $viewModel.showCleanupReport) {
            if let report = viewModel.lastReport {
                CleanupReportSheet(report: report)
            }
        }
        .task {
            // Guard against re-scanning when switching tabs.
            // TabView re-runs .task each time a tab reappears.
            // Use hasScanned (not hasResults) so a scan that found zero items
            // is not repeated on every tab switch.
            guard !viewModel.hasScanned && !viewModel.isScanning else { return }
            await viewModel.scan()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Cacheout")
                    .font(.largeTitle.bold())
                Text("Reclaim your disk space")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            if viewModel.isScanning {
                ProgressView()
                    .scaleEffect(0.8)
                    .padding(.trailing, 4)
                Text("Scanning...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Results List

    private var resultsList: some View {
        ScrollView {
            VStack(spacing: 12) {
                // Cache categories
                LazyVStack(spacing: 2) {
                    ForEach(viewModel.scanResults) { result in
                        CategoryRow(result: result) {
                            viewModel.toggleSelection(for: result.id)
                        }
                    }
                }

                // Node modules section
                if !viewModel.nodeModulesItems.isEmpty || viewModel.isNodeModulesScanning {
                    Divider().padding(.horizontal)
                    NodeModulesSection()
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Click Scan to find caches")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Cacheout will search common developer cache locations")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                // Selection controls
                if viewModel.hasResults {
                    Menu {
                        Button("Select All Safe") { viewModel.selectAllSafe() }
                        Button("Deselect All") { viewModel.deselectAll() }
                    } label: {
                        Label("Selection", systemImage: "checklist")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    if viewModel.hasSelection {
                        Text("Selected: \(viewModel.formattedTotalSelectedSize)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // Scan button
                Button {
                    Task { await viewModel.scan() }
                } label: {
                    Label("Scan", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isScanning)

                // Clean button
                Button {
                    viewModel.showCleanConfirmation = true
                } label: {
                    Label("Clean Selected", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!viewModel.hasSelection || viewModel.isCleaning)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
    }
}
