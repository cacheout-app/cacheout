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
                            ProgressView()
                                .scaleEffect(0.7)
                                .frame(width: 16, height: 16)
                        } else {
                            Label("Prune", systemImage: "cube.transparent")
                        }
                    }
                    .disabled(viewModel.isDockerPruning)
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
}
