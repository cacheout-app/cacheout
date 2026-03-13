/// # DiskUsageBar — Disk Space Visualization
///
/// A horizontal progress bar showing current disk utilization. Displays the
/// volume name, free space, used/total, and percentage. Color-coded:
/// - Blue: < 85% used (normal)
/// - Orange: 85-95% used (warning)
/// - Red: > 95% used (critical)
///
/// Uses `GeometryReader` to calculate the filled width proportionally.
/// Wrapped in a `regularMaterial` rounded rectangle for visual depth.

import SwiftUI

struct DiskUsageBar: View {
    let diskInfo: DiskInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Macintosh HD")
                    .font(.headline)
                Spacer()
                Text("\(diskInfo.formattedFree) free")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(.separatorColor))
                    RoundedRectangle(cornerRadius: 6)
                        .fill(barColor)
                        .frame(width: geo.size.width * diskInfo.usedPercentage)
                }
            }
            .frame(height: 20)

            HStack {
                Text("\(diskInfo.formattedUsed) of \(diskInfo.formattedTotal) used")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(diskInfo.usedPercentage * 100))%")
                    .font(.caption.bold())
                    .foregroundStyle(diskInfo.usedPercentage > 0.9 ? .red : .secondary)
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var barColor: Color {
        if diskInfo.usedPercentage > 0.95 { return .red }
        if diskInfo.usedPercentage > 0.85 { return .orange }
        return .blue
    }
}
