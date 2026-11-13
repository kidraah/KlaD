// NativeStyle.swift — system colors, formatting, Finder icons, system actions.
//
// Everything visual comes from the system: semantic NSColors (adapt to light /
// dark / increased contrast automatically), the user's accent color, SF
// Symbols and real Finder icons. No custom theme.

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import KlaDModels

// MARK: - System colors

extension StorageCategory {
    /// System palette color for the category.
    var nsColor: NSColor {
        switch self {
        case .developerBuilds: return .systemTeal
        case .aiModels: return .systemPurple
        case .containersVMs: return .systemIndigo
        case .xcode: return .systemCyan
        case .applications: return .systemBlue
        case .media: return .systemYellow
        case .caches: return .systemBrown
        case .system: return .systemGray
        case .documents: return .systemOrange
        case .other: return .systemGray.withAlphaComponent(0.55)
        }
    }

    var color: Color { Color(nsColor: nsColor) }

    /// Light fills (yellow, cyan…) need dark labels in both appearances.
    var prefersDarkLabel: Bool {
        switch self {
        case .media, .xcode, .developerBuilds: return true
        default: return false
        }
    }
}

extension SafetyLevel {
    var color: Color {
        switch self {
        case .safeToClear: return .green
        case .reviewFirst: return .orange
        case .guidedExternalAction: return .blue
        case .doNotDelete: return .red
        case .unknown: return .secondary
        }
    }
}

/// "Colour by age" buckets — warm for recent activity, cool for old.
enum AgeBucket: Int, CaseIterable, Identifiable {
    case month, halfYear, year, twoYears, fiveYears, older

    var id: Int { rawValue }

    static func bucket(for newest: Int64, now: Date = Date()) -> AgeBucket {
        let days = (now.timeIntervalSince1970 - Double(newest)) / 86_400
        switch days {
        case ..<31: return .month
        case ..<183: return .halfYear
        case ..<366: return .year
        case ..<731: return .twoYears
        case ..<1827: return .fiveYears
        default: return .older
        }
    }

    var title: String {
        switch self {
        case .month: return "This month"
        case .halfYear: return "1–6 months"
        case .year: return "6–12 months"
        case .twoYears: return "1–2 years"
        case .fiveYears: return "2–5 years"
        case .older: return "Older"
        }
    }

    var nsColor: NSColor {
        switch self {
        case .month: return .systemRed
        case .halfYear: return .systemOrange
        case .year: return .systemYellow
        case .twoYears: return .systemGreen
        case .fiveYears: return .systemTeal
        case .older: return .systemBlue
        }
    }

    var color: Color { Color(nsColor: nsColor) }
}

enum ColorMode: String, CaseIterable, Identifiable {
    case category, age
    var id: String { rawValue }
    var title: String { self == .category ? "Category" : "Age" }
}

// MARK: - Formatting (nonisolated: also used inside Canvas renderers)

/// Finder-style decimal sizes ("12.4 GB").
func formatBytes(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
}

func formatSignedBytes(_ delta: Int64) -> String {
    let magnitude = ByteCountFormatter.string(fromByteCount: Int64(clamping: delta.magnitude), countStyle: .file)
    return delta > 0 ? "+" + magnitude : (delta < 0 ? "−" + magnitude : magnitude)
}

func formatCount(_ value: UInt64) -> String {
    value.formatted(.number.notation(.compactName))
}

/// "~/Library/Caches" for paths under the home folder.
func abbreviatePath(_ path: String) -> String {
    (path as NSString).abbreviatingWithTildeInPath
}

func relativeDate(_ date: Date) -> String {
    date.formatted(.relative(presentation: .named, unitsStyle: .wide))
}

// MARK: - Finder icons (cached; type-based so no file is ever opened)

@MainActor
enum FileIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for node: FileTreeNode) -> NSImage {
        if node.isOpaque { return symbol("internaldrive") }
        if node.isProtectedLocation { return symbol("lock.fill") }
        if node.parent == nil { return volumeOrFolderIcon(path: node.path) }
        if node.isDirectory {
            // Bundles and special folders: real icon (reads bundle metadata only).
            if node.flags.contains(.package) || node.parent?.parent == nil || node.depth <= 2 {
                return pathIcon(node.path)
            }
            return typeIcon(.folder)
        }
        if node.flags.contains(.cloudPlaceholder) { return symbol("icloud") }
        let ext = (node.name as NSString).pathExtension.lowercased()
        if ext.isEmpty { return typeIcon(.data) }
        return typeIcon(UTType(filenameExtension: ext) ?? .data)
    }

    static func icon(forPath path: String, isDirectory: Bool) -> NSImage {
        if isDirectory { return pathIcon(path) }
        let ext = (path as NSString).pathExtension.lowercased()
        return typeIcon(ext.isEmpty ? .data : (UTType(filenameExtension: ext) ?? .data))
    }

    static func typeIcon(_ type: UTType) -> NSImage {
        let key = "type:" + type.identifier
        if let cached = cache[key] { return cached }
        let image = NSWorkspace.shared.icon(for: type)
        cache[key] = image
        return image
    }

    static func pathIcon(_ path: String) -> NSImage {
        let key = "path:" + path
        if let cached = cache[key] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache[key] = image
        return image
    }

    static func volumeOrFolderIcon(path: String) -> NSImage {
        pathIcon(path)
    }

    static func symbol(_ name: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
    }
}

// MARK: - System actions

@MainActor
enum SystemActions {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    static func openApplication(bundleID: String) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    static func openStorageSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.Storage") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Bundle ids + names of installed apps (LaunchServices-visible locations).
    static func installedApps() -> InstalledApps {
        var ids = Set<String>()
        var names = Set<String>()
        let roots = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                     NSHomeDirectory() + "/Applications"]
        for root in roots {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            for item in items where item.hasSuffix(".app") {
                names.insert(String(item.dropLast(4)).lowercased())
                if let bundle = Bundle(path: root + "/" + item), let id = bundle.bundleIdentifier {
                    ids.insert(id.lowercased())
                }
            }
        }
        for app in NSWorkspace.shared.runningApplications {
            if let id = app.bundleIdentifier { ids.insert(id.lowercased()) }
            if let name = app.localizedName { names.insert(name.lowercased()) }
        }
        return InstalledApps(bundleIDs: ids, names: names)
    }
}

// MARK: - Small shared views

/// Rounded-square SF Symbol tile, like System Settings rows.
struct SymbolTile: View {
    let systemName: String
    let color: Color
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
    }
}

/// Finder icon for a node.
struct NodeIcon: View {
    let node: FileTreeNode
    var size: CGFloat = 16

    var body: some View {
        Image(nsImage: FileIcons.icon(for: node))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .foregroundStyle(.secondary)
    }
}

/// Safety label in the system's semantic color.
struct SafetyLabel: View {
    let level: SafetyLevel

    var body: some View {
        Label(level.displayName, systemImage: level.symbolName)
            .foregroundStyle(level.color)
            .help(level.summary)
    }
}

/// Wrapping layout for legends and evidence lists.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: width.isFinite ? width : maxX, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
