/// # NodeModulesSection — node_modules Discovery Section
///
/// ## NodeModulesSection
///
/// A collapsible section that displays all discovered `node_modules` directories.
/// Shows a header with count and total size, quick-action buttons for batch selection,
/// and individual `NodeModulesRow` entries.
///
/// ### Quick Actions
/// - **Select Stale (30d+)**: Selects all node_modules older than 30 days
/// - **Select All**: Selects every discovered node_modules
/// - **Deselect All**: Clears all selections
///
/// ### States
/// - Scanning: Shows progress indicator with search message
/// - Empty: Shows "No node_modules directories found"
/// - Populated: Shows list with selection controls
/// - Issues (fn-1.4, R14/D6): classified scan problems render as a warning
///   block — a TCC-denied `~/Documents` search root is VISIBLE information
///   ("access denied", with a System Settings link), never an empty
///   section. GUI-only surfacing: the CLI does not expose node_modules
///   until fn-2.
///
/// ## NodeModulesRow
///
/// Displays a single node_modules directory with:
/// - Selection checkbox (purple when selected)
/// - Project name (derived from parent directory name)
/// - Shortened path (~ prefix for home directory)
/// - Stale badge (orange capsule, e.g., "3mo old")
/// - Size in human-readable format

import SwiftUI

struct NodeModulesSection: View {
    @EnvironmentObject var viewModel: CacheoutViewModel
    @State private var isExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            // Section header
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .frame(width: 16)
                    Image(systemName: "folder.fill.badge.gearshape")
                        .foregroundStyle(.purple)
                    Text("Project node_modules")
                        .font(.headline)
                    Text("(\(viewModel.nodeModulesItems.count) found)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(viewModel.formattedNodeModulesTotal)
                        .font(.body.monospacedDigit().bold())
                        .foregroundStyle(.purple)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded && viewModel.isNodeModulesScanning {
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Searching for node_modules across your projects...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }

            // Classified scan problems (R14/D6): a denied search root is
            // information, never a silent skip.
            if isExpanded && !viewModel.isNodeModulesScanning
                && !viewModel.nodeModulesScanIssues.isEmpty {
                issuesBlock
            }

            if isExpanded && !viewModel.nodeModulesItems.isEmpty {
                // Quick actions
                HStack(spacing: 12) {
                    Button("Select Stale (30d+)") {
                        viewModel.selectStaleNodeModules()
                    }
                    .font(.caption)
                    Button("Select All") {
                        viewModel.selectAllNodeModules()
                    }
                    .font(.caption)
                    Button("Deselect All") {
                        viewModel.deselectAllNodeModules()
                    }
                    .font(.caption)
                    Spacer()
                    if viewModel.selectedNodeModulesSize > 0 {
                        Text("Selected: \(viewModel.formattedSelectedNodeModulesSize)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.purple)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 4)

                // Individual items
                LazyVStack(spacing: 2) {
                    ForEach(viewModel.nodeModulesItems) { item in
                        NodeModulesRow(item: item) {
                            viewModel.toggleNodeModulesSelection(for: item.id)
                        }
                    }
                }
            }

            // "Found none" is claimed only when the scan had no classified
            // problems — a denied root is NOT "nothing there" (R14/D6).
            if isExpanded && !viewModel.isNodeModulesScanning
                && viewModel.nodeModulesItems.isEmpty
                && viewModel.nodeModulesScanIssues.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "shippingbox")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text("No node_modules directories found")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 24)
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: - Scan issues

    private var issuesBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(viewModel.nodeModulesScanIssues.enumerated()), id: \.offset) { _, issue in
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text("\(Self.shortPath(issue.url)) — \(Self.label(for: issue.kind))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if issue.kind == .tccDenied {
                        Link("Grant access…",
                             destination: ScanError.fullDiskAccessSettingsURL)
                            .font(.caption)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
    }

    private static func shortPath(_ url: URL) -> String {
        url.path.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"
        )
    }

    private static func label(for kind: NodeModulesScanIssue.Kind) -> String {
        switch kind {
        case .containerRefused: return "not a configured search root"
        case .symlinkRoot: return "symlinked — not searched"
        case .tccDenied: return "access denied by macOS privacy settings"
        case .permissionDenied: return "permission denied"
        case .unreadable: return "unreadable"
        }
    }
}

struct NodeModulesRow: View {
    let item: NodeModulesItem
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 10) {
                Image(systemName: item.isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.isSelected ? .purple : .secondary)

                Image(systemName: "shippingbox.fill")
                    .foregroundStyle(.purple.opacity(0.7))
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.projectName)
                        .font(.body.weight(.medium))
                    Text(item.projectPath.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                // Stale badge
                if let badge = item.staleBadge {
                    Text(badge)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15), in: Capsule())
                        .foregroundStyle(.orange)
                }

                Text(item.formattedSize)
                    .font(.body.monospacedDigit())
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(item.isSelected ? .isSelected : [])
    }
}
