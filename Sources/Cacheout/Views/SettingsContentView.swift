/// # SettingsContentView — Reusable Preferences Content
///
/// Extracts the settings content from `SettingsView` into a reusable component
/// that can be embedded both in the main window's Settings tab and in the
/// macOS Settings scene (Cmd+,).
///
/// The `updater` parameter is optional to support contexts where the updater
/// is not available (e.g. SwiftUI previews or test harnesses).

import SwiftUI
import Sparkle

struct SettingsContentView: View {
    @EnvironmentObject var viewModel: CacheoutViewModel

    /// Optional SPUUpdater — nil in previews/tests; non-nil at runtime via CacheoutApp.
    let updater: SPUUpdater?

    /// The dev-roots editor's typed path field (fn-4.6). View-local: nothing
    /// is persisted until `addDevRoot` accepts it.
    @State private var devRootInput = ""

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            cleaningTab
                .tabItem {
                    Label("Cleaning", systemImage: "trash")
                }

            advancedTab
                .tabItem {
                    Label("Advanced", systemImage: "wrench.and.screwdriver")
                }
        }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section {
                HStack {
                    Text("Scan interval")
                    Spacer()
                    Picker("", selection: $viewModel.scanIntervalMinutes) {
                        Text("15 min").tag(15.0)
                        Text("30 min").tag(30.0)
                        Text("1 hour").tag(60.0)
                        Text("2 hours").tag(120.0)
                        Text("4 hours").tag(240.0)
                    }
                    .pickerStyle(.menu)
                    .frame(width: 120)
                }

                HStack {
                    Text("Low-disk warning threshold")
                    Spacer()
                    Picker("", selection: $viewModel.lowDiskThresholdGB) {
                        Text("5 GB").tag(5.0)
                        Text("10 GB").tag(10.0)
                        Text("15 GB").tag(15.0)
                        Text("20 GB").tag(20.0)
                        Text("25 GB").tag(25.0)
                        Text("50 GB").tag(50.0)
                    }
                    .pickerStyle(.menu)
                    .frame(width: 120)
                }

                Toggle("Launch at login", isOn: $viewModel.launchAtLogin)
            } header: {
                Text("Menubar Behavior")
            }

            Section {
                if let disk = viewModel.diskInfo {
                    LabeledContent("Total disk", value: disk.formattedTotal)
                    LabeledContent("Free space", value: disk.formattedFree)
                    LabeledContent("Used", value: "\(Int(disk.usedPercentage * 100))%")
                } else {
                    Text("Scanning disk...")
                        .foregroundStyle(.tertiary)
                }
            } header: {
                Text("Current Disk Status")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Cleaning Tab

    private var cleaningTab: some View {
        Form {
            Section {
                Toggle("Move to Trash (recoverable)", isOn: $viewModel.moveToTrash)
                Text(viewModel.moveToTrash
                     ? "Files are moved to Trash — you can undo via Finder."
                     : "Files are permanently deleted — this is faster but irreversible.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Deletion Behavior")
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Docker System Prune")
                            .font(.headline)
                        Text("Remove stopped containers, dangling images, unused networks, and build cache.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        Task { await viewModel.dockerPrune() }
                    } label: {
                        if viewModel.isDockerPruning {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .scaleEffect(0.5)
                                    .frame(width: 12, height: 12)
                                Text("Pruning...")
                            }
                        } else {
                            Label("Prune", systemImage: "cube.transparent")
                        }
                    }
                    .disabled(viewModel.isDockerPruning)
                    .help(viewModel.isDockerPruning ? "Pruning in progress" : "Run Docker system prune")
                }

                if let result = viewModel.lastDockerPruneResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(result.contains("reclaimed") || result.contains("successfully")
                                         ? .green : .red)
                }
            } header: {
                Text("Docker")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Advanced Tab

    private var advancedTab: some View {
        Form {
            devRootsSection

            Section {
                LabeledContent("Categories scanned") {
                    Text("\(CacheCategory.allCategories.count)")
                }
                LabeledContent("Cleanup log") {
                    Button("Reveal in Finder") {
                        let logPath = FileManager.default.homeDirectoryForCurrentUser
                            .appendingPathComponent(".cacheout/cleanup.log")
                        NSWorkspace.shared.selectFile(logPath.path, inFileViewerRootedAtPath: "")
                    }
                    .buttonStyle(.link)
                }
                LabeledContent("Config directory") {
                    Button("~/.cacheout/") {
                        let dir = FileManager.default.homeDirectoryForCurrentUser
                            .appendingPathComponent(".cacheout")
                        NSWorkspace.shared.open(dir)
                    }
                    .buttonStyle(.link)
                }
            } header: {
                Text("Data")
            }

            Section {
                LabeledContent("Version") {
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                }
                LabeledContent("Build") {
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-")
                }
                if let updater {
                    LabeledContent("Updates") {
                        CheckForUpdatesButton(updater: updater)
                    }
                }
            } header: {
                Text("About Cacheout")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Dev roots (fn-4.6, R8/R16) — the FIRST scanner-config GUI

    /// The dev-roots list editor: the folders the build-artifacts scanner
    /// walks, with add (folder picker or typed path), remove, and
    /// reset-to-defaults. Every mutation goes through the injected
    /// `DevRootsStore` and then rebuilds the runtime through fn-4.10's
    /// factory seam (`devRootsDidChange()`) — this view never constructs a
    /// runtime and never persists anything itself.
    ///
    /// Add-time validation calls the SHARED container-root admission policy
    /// through the store (R16 — no UI-local duplicate): a dangerous pick
    /// (`/`, a volume root, `$HOME`, or a symlink alias of any of them) is
    /// refused INLINE and changes nothing, while protected children like
    /// `~/Documents` are legal dev roots and are accepted.
    private var devRootsSection: some View {
        Section {
            if viewModel.isDevRootsEditorAvailable {
                ForEach(viewModel.devRootRows) { row in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.displayPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            // A policy-refused persisted root is never
                            // registered and never walked — the row says so
                            // instead of implying it is being scanned.
                            if let detail = row.issueDetail {
                                Label(detail, systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        Button {
                            viewModel.removeDevRoot(row.declaredPath)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove \(row.displayPath)")
                        .accessibilityLabel("Remove \(row.displayPath)")
                    }
                }

                HStack(spacing: 8) {
                    TextField("~/dev or /Volumes/Work/code", text: $devRootInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { submitDevRoot() }
                    Button("Add") { submitDevRoot() }
                        .disabled(devRootInput.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty)
                    Button("Choose…") { chooseDevRoot() }
                    Spacer()
                    Button("Reset") { viewModel.resetDevRootsToDefaults() }
                        .help("Back to the default dev roots")
                }

                // INLINE add-time rejection — the shared policy's own reason.
                if let rejection = viewModel.devRootRejection {
                    Label(rejection, systemImage: "xmark.octagon.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Text("Folders scanned for build artifacts (target/, "
                     + "node_modules/, .build/, …). Changes apply to the next "
                     + "scan.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Dev roots aren't configurable in this window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Project Dev Roots")
        }
    }

    private func submitDevRoot() {
        let input = devRootInput
        viewModel.addDevRoot(input)
        // Keep a REFUSED value in the field so the user can correct it;
        // clear it only when the add actually landed.
        if viewModel.devRootRejection == nil { devRootInput = "" }
    }

    /// Folder picker — an absolute path, which the shared policy validates
    /// exactly like a typed one (the picker is a convenience, never a
    /// bypass).
    private func chooseDevRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Dev Root"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        viewModel.addDevRoot(url.path)
    }
}
