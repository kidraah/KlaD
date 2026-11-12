// StorageHeaderBar.swift — volume capacity + scanned APFS totals
//
// Left: what the volume says (Used · Purgeable · Free now). Right: what the
// scan found (Allocated · Reclaimable · Shared · iCloud), so the gap between
// "purgeable System Data" and space that's free right now is explicit.

import SwiftUI
import KlaDModels

struct StorageHeaderBar: View {
    @Environment(AppState.self) private var app
    @State private var showContainer = false

    var body: some View {
        HStack(alignment: .center, spacing: 22) {
            if let volume = app.volume {
                volumeSection(volume)
                    .frame(minWidth: 320, maxWidth: 520)
            }
            if let root = app.root {
                Divider().frame(height: 38).overlay(Theme.hairline)
                scanSection(root)
            }
            Spacer(minLength: 0)
            if app.phase == .ready {
                savingsSection
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private func volumeSection(_ volume: VolumeSpaceReport) -> some View {
        let total = max(Double(volume.totalCapacity), 1)
        let used = Double(volume.nonPurgeableUsedCapacity) / total
        let purgeable = Double(volume.purgeableCapacity) / total
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: "internaldrive.fill")
                    .foregroundStyle(Theme.textSecondary)
                Text(volume.volumeName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("\(formatBytes(volume.totalCapacity)) \(volume.fileSystemType.uppercased())")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 0)
                Button {
                    showContainer.toggle()
                } label: {
                    Label("Container", systemImage: "square.stack.3d.up")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
                .popover(isPresented: $showContainer, arrowEdge: .bottom) {
                    ContainerPopover(volume: volume)
                }
            }
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    Rectangle()
                        .fill(LinearGradient(colors: [Color(hex: 0x64748B), Color(hex: 0x94A3B8)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(2, proxy.size.width * used))
                    Rectangle()
                        .fill(Theme.warning.opacity(0.75))
                        .overlay(StripePattern().stroke(Color.black.opacity(0.25), lineWidth: 2))
                        .clipped()
                        .frame(width: max(purgeable > 0 ? 2 : 0, proxy.size.width * purgeable))
                    Rectangle().fill(Color.white.opacity(0.06))
                }
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .frame(height: 9)
            HStack(spacing: 14) {
                legend(color: Color(hex: 0x94A3B8), label: "Used", value: volume.nonPurgeableUsedCapacity)
                legend(color: Theme.warning, label: "Purgeable", value: volume.purgeableCapacity)
                    .help("Space macOS reclaims on demand (caches, evictable iCloud files, expiring snapshots). Counted as used by Finder's \"System Data\".")
                legend(color: Theme.positive, label: "Free now", value: volume.availableCapacity)
                    .help("Immediately available — what a large download can use right now.")
            }
        }
    }

    private func legend(color: Color, label: String, value: UInt64) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 7, height: 7)
            Text(label).font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary)
            Text(formatBytes(value)).font(.system(size: 10.5, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.textPrimary)
        }
    }

    private func scanSection(_ root: FileTreeNode) -> some View {
        let m = root.metrics
        return HStack(spacing: 20) {
            MetricReadout(label: "Scanned", value: formatBytes(m.allocatedBytes),
                          help: "Physical APFS allocation under \(abbreviatePath(root.path))")
            MetricReadout(label: "Reclaimable", value: formatBytes(m.privateBytes), tint: Theme.positive,
                          help: "Private bytes — freed immediately if everything here were deleted")
            MetricReadout(label: "Shared", value: formatBytes(m.sharedBytes), tint: Theme.warning,
                          help: "Allocated blocks shared with APFS clones, local snapshots or hard links")
            if m.cloudStubBytes > 0 {
                MetricReadout(label: "In iCloud", value: formatBytes(m.cloudStubBytes), tint: Theme.info,
                              help: "Logical size of iCloud placeholders — 0 B on this SSD")
            }
            MetricReadout(label: "Items", value: formatCount(m.itemCount),
                          help: "\(m.fileCount) files, \(m.directoryCount) folders" + (app.result.map { String(format: " · scanned in %.1fs", $0.duration) } ?? ""))
        }
    }

    private var savingsSection: some View {
        let safe = app.reclaimable(for: .safeToClear)
        let review = app.reclaimable(for: .reviewFirst)
        return Button {
            app.tab = .saveSpace
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.positive)
                VStack(alignment: .leading, spacing: 1) {
                    Text(formatBytes(safe))
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textPrimary)
                    Text("safe to clear · \(formatBytes(review)) after review")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .glassPanel(radius: 9, fill: Theme.positive.opacity(0.08))
        }
        .buttonStyle(.plain)
        .help("Open the Save Space hub")
    }
}

private struct ContainerPopover: View {
    let volume: VolumeSpaceReport

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("APFS CONTAINER \(volume.containerReference ?? "")").eyebrow()
            if let capacity = volume.containerCapacity {
                HStack {
                    Text("Capacity ceiling").foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text(formatBytes(capacity)).monospacedDigit()
                }
                .font(.system(size: 12))
            }
            if let free = volume.containerFree {
                HStack {
                    Text("Not allocated").foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text(formatBytes(free)).monospacedDigit()
                }
                .font(.system(size: 12))
            }
            Divider()
            ForEach(volume.containerVolumes) { item in
                HStack(spacing: 8) {
                    Image(systemName: icon(for: item.roles))
                        .frame(width: 16)
                        .foregroundStyle(Theme.textSecondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name).font(.system(size: 12, weight: .medium))
                        Text(([item.deviceIdentifier] + item.roles).joined(separator: " · "))
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    Text(formatBytes(item.capacityInUse))
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                }
            }
            Text("Preboot, Recovery, VM (swap) and Update volumes share this container and are part of what macOS reports as \"System Data\".")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if !volume.localSnapshotNames.isEmpty {
                Divider()
                Text("LOCAL SNAPSHOTS (\(volume.localSnapshotNames.count))").eyebrow()
                ForEach(volume.localSnapshotNames.prefix(8), id: \.self) { name in
                    Text(name)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private func icon(for roles: [String]) -> String {
        switch roles.first {
        case "Data": return "person.crop.square"
        case "System": return "applelogo"
        case "VM": return "memorychip"
        case "Preboot": return "power"
        case "Recovery": return "cross.case"
        case "Update": return "arrow.down.circle"
        default: return "cylinder"
        }
    }
}

/// Diagonal stripes for "purgeable".
struct StripePattern: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += 6
        }
        return path
    }
}
