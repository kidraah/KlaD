// Theme.swift — KlaD design system
//
// Deep obsidian-slate translucent surfaces, 1 px white/8 % hairlines, semantic
// category colors, monospaced digits for every number.

import AppKit
import SwiftUI
import KlaDModels

// MARK: - Color tokens

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

enum Theme {
    // Surfaces
    static let obsidian = Color(hex: 0x070A10)
    static let slate900 = Color(hex: 0x0D1220)
    static let slate850 = Color(hex: 0x111827)
    static let slate800 = Color(hex: 0x172033)
    static let panel = Color(hex: 0x0E1422, opacity: 0.72)
    static let panelRaised = Color(hex: 0x141C2E, opacity: 0.82)
    static let hairline = Color.white.opacity(0.08)
    static let hairlineStrong = Color.white.opacity(0.14)

    // Text
    static let textPrimary = Color.white.opacity(0.94)
    static let textSecondary = Color(hex: 0x94A3B8)
    static let textTertiary = Color(hex: 0x64748B)

    // Accents
    static let accent = Color(hex: 0x22D3EE)          // cyan glow
    static let accentSoft = Color(hex: 0x22D3EE, opacity: 0.16)
    static let positive = Color(hex: 0x34D399)
    static let warning = Color(hex: 0xFBBF24)
    static let danger = Color(hex: 0xF43F5E)
    static let info = Color(hex: 0x4F8CFF)
    static let aggregate = Color(hex: 0x334155)

    static let radius: CGFloat = 10
    static let smallRadius: CGFloat = 6
}

extension StorageCategory {
    var color: Color { Color(hex: hexColor) }
}

extension SafetyLevel {
    var color: Color { Color(hex: hexColor) }
}

// MARK: - Formatting (nonisolated: used inside Canvas renderers)

/// Finder-style decimal byte formatting ("12.4 GB").
func formatBytes(_ bytes: UInt64) -> String {
    if bytes < 1000 { return "\(bytes) B" }
    let units = ["KB", "MB", "GB", "TB", "PB"]
    var value = Double(bytes) / 1000
    var index = 0
    while value >= 1000 && index < units.count - 1 {
        value /= 1000
        index += 1
    }
    let number: String
    if value >= 100 { number = String(Int(value.rounded())) }
    else if value >= 10 { number = String(format: "%.1f", value) }
    else { number = String(format: "%.2f", value) }
    return number + " " + units[index]
}

func formatSignedBytes(_ delta: Int64) -> String {
    let sign = delta > 0 ? "+" : (delta < 0 ? "−" : "±")
    return sign + formatBytes(delta.magnitude)
}

func formatCount(_ value: UInt64) -> String {
    if value < 10_000 { return value.formatted(.number) }
    if value < 1_000_000 { return String(format: "%.1fK", Double(value) / 1000) }
    return String(format: "%.2fM", Double(value) / 1_000_000)
}

/// "~/Library/Caches" for paths under the home directory.
func abbreviatePath(_ path: String) -> String {
    let home = NSHomeDirectory()
    if path == home { return "~" }
    if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
    return path
}

func relativeDays(_ date: Date, now: Date = Date()) -> String {
    let days = Int(now.timeIntervalSince(date) / 86_400)
    if days <= 0 { return "today" }
    if days == 1 { return "yesterday" }
    if days < 30 { return "\(days)d ago" }
    if days < 365 { return "\(days / 30)mo ago" }
    return "\(days / 365)y ago"
}

// MARK: - Surfaces

/// NSVisualEffectView backdrop (behind-window blending).
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

/// Glass panel: translucent obsidian fill + 1 px hairline.
struct GlassPanel: ViewModifier {
    var radius: CGFloat = Theme.radius
    var fill: Color = Theme.panel

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
    }
}

extension View {
    func glassPanel(radius: CGFloat = Theme.radius, fill: Color = Theme.panel) -> some View {
        modifier(GlassPanel(radius: radius, fill: fill))
    }

    /// Section label style ("STORAGE", "SAFETY").
    func eyebrow() -> some View {
        self.font(.system(size: 10, weight: .semibold))
            .tracking(1.1)
            .foregroundStyle(Theme.textTertiary)
    }
}

// MARK: - Badges & chips

struct SafetyBadge: View {
    let level: SafetyLevel
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: level.symbolName)
                .font(.system(size: compact ? 9 : 10, weight: .semibold))
            if !compact {
                Text(level.badgeText)
                    .font(.system(size: 10.5, weight: .semibold))
            }
        }
        .foregroundStyle(level.color)
        .padding(.horizontal, compact ? 5 : 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(level.color.opacity(0.13)))
        .overlay(Capsule().strokeBorder(level.color.opacity(0.28), lineWidth: 0.5))
        .help(level.summary)
    }
}

struct CategoryDot: View {
    let category: StorageCategory
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(category.color)
            .frame(width: size, height: size)
            .shadow(color: category.color.opacity(0.6), radius: 3)
    }
}

struct Chip: View {
    let text: String
    var symbol: String? = nil
    var tint: Color = Theme.textSecondary
    var filled = false

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            }
            Text(text).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(filled ? 0.18 : 0.08)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.18), lineWidth: 0.5))
    }
}

struct SignalChip: View {
    let signal: SupportingSignal

    var body: some View {
        Chip(text: signal.text, symbol: signal.symbolName, tint: signal.isWarning ? Theme.warning : Theme.textSecondary)
    }
}

/// A thin horizontal proportion bar.
struct ProportionBar: View {
    let fraction: Double
    var tint: Color = Theme.accent
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.06))
                Capsule()
                    .fill(tint.gradient)
                    .frame(width: max(fraction > 0 ? 2 : 0, proxy.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
    }
}

/// Monospaced value + caption.
struct MetricReadout: View {
    let label: String
    let value: String
    var tint: Color = Theme.textPrimary
    var help: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).eyebrow()
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
        }
        .help(help ?? "")
    }
}

// MARK: - Clipboard / Finder

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

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
