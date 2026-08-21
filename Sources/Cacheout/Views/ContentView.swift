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

            // Results list — gated on DISPLAYABLE output, not just items:
            // an issue-only scan (denied roots, malformed outcome) must
            // render its warnings, and a scanner that has NEVER BEEN
            // INSPECTED must reach its own "not yet scanned" row, never the
            // empty state (R14/D6; PR #459 codex r14 for the fourth clause).
            // The whole predicate lives on the view model because this
            // expression is assertion-dead.
            //
            // RESIDUAL, RECORDED AT MEASURED SCOPE. `emptyState` below says
            // "Click Scan to find caches". After a scan in which every
            // per-item scanner published and nothing was found, that is an
            // invitation to do what was just done — it does not say a scan
            // has run and found nothing. Folding the awaiting clause into
            // the gate shrinks the set of machines that see it (a machine
            // with a deferred scanner now reaches the results list instead)
            // but does not make the sentence true for the rest. Left alone
            // deliberately: it is the WINDOW's text, not the disclosure this
            // round is about, and it is not covered by any cell — SwiftUI
            // bodies are assertion-dead and this repo has no view harness.
            if viewModel.hasDisplayableScanOutput {
                resultsList
            } else if !viewModel.isAnyScanInProgress {
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
            // `.automatic`: opening a tab is not consent to a TCC prompt —
            // protected roots wait for an explicit Scan (fn-1.4, R9).
            guard !viewModel.hasScanned && !viewModel.isAnyScanInProgress else { return }
            await viewModel.scan(trigger: .automatic)
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

            if viewModel.isAnyScanInProgress {
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
                // Cache categories — unchanged CategoryRow inputs, list
                // identity by composite ItemKey (fn-2.4).
                LazyVStack(spacing: 2) {
                    ForEach(viewModel.categoryRows) { row in
                        CategoryRow(result: row.result) {
                            viewModel.toggleSelection(for: row.key)
                        }
                    }
                }

                // A malformed category outcome is fail-closed and VISIBLE:
                // previous rows are retained above, the issue renders here.
                if !viewModel.categoryScanIssues.isEmpty {
                    ScanIssuesBlock(issues: viewModel.categoryScanIssues)
                }

                // One generic section per registered per-item scanner —
                // also shown when the scan produced only classified issues
                // (a denied search root must be visible, never an empty
                // section — R14/D6), and when the scanner has NEVER BEEN
                // INSPECTED (PR #459 codex r11: hiding that case made it
                // indistinguishable from "inspected, found nothing").
                //
                // The predicate itself lives on the section model
                // (`isDisplayed`) because this expression is assertion-dead:
                // hoisting it is what lets a cell pin the visibility rule.
                ForEach(viewModel.perItemSections) { section in
                    if section.isDisplayed {
                        Divider().padding(.horizontal)
                        ScannerItemSection(section: section)
                    }
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
        .accessibilityElement(children: .combine)
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

                // Scan button — disabled until BOTH scan phases finish
                // (node_modules keeps running after the cache phase, R11)
                Button {
                    Task { await viewModel.scan(trigger: .userInitiated) }
                } label: {
                    Label(viewModel.isAnyScanInProgress ? "Scanning..." : "Scan", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isAnyScanInProgress || viewModel.isCleaning)
                .help(viewModel.isAnyScanInProgress ? "Scan in progress" : (viewModel.isCleaning ? "Cleanup in progress" : "Scan for caches"))

                // Clean button
                Button {
                    viewModel.showCleanConfirmation = true
                } label: {
                    Label(viewModel.isCleaning ? "Cleaning..." : "Clean Selected", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                // Disabled while ANY scan phase runs (R11): confirming
                // against a half-built result set would clean stale
                // selections (the model guard in clean() backs this up).
                // Gates on the CLEANABLE selection, not bare keys: retained
                // selections under a malformed rescan are display-only and
                // must not enable a destructive control.
                .disabled(!viewModel.hasCleanableSelection || viewModel.isCleaning || viewModel.isAnyScanInProgress)
                .help(viewModel.isCleaning ? "Cleanup in progress" : (viewModel.isAnyScanInProgress ? "Scan in progress" : (!viewModel.hasCleanableSelection ? "Select at least one cleanable item" : "Clean selected items")))
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
    }
}
