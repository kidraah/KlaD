// StorageCategory.swift — KlaDModels
//
// Semantic categories used to color the visualizers and group cleanup cards.
// Colors are stored as 0xRRGGBB so this module stays UI-framework-free; the UI
// maps them to SwiftUI `Color`.

import Foundation

public enum StorageCategory: UInt8, Sendable, CaseIterable, Codable, Hashable, Identifiable, Comparable {
    /// node_modules, Rust target/, Swift .build/, .next/, dist/, build/, venvs.
    case developerBuilds = 0
    /// ~/.ollama, ~/.cache/huggingface, ~/.lmstudio, *.gguf / *.safetensors weights.
    case aiModels = 1
    /// Docker.raw, OrbStack, Colima, UTM / Parallels / VMware disks.
    case containersVMs = 2
    /// DerivedData, Archives, iOS DeviceSupport, CoreSimulator.
    case xcode = 3
    /// .app bundles and their support payloads.
    case applications = 4
    /// Photos, video, audio, images.
    case media = 5
    /// ~/Library/Caches, package-manager caches, browser caches.
    case caches = 6
    /// /System, /Library, /private — OS-owned or protected.
    case system = 7
    /// User documents, archives, installers and other personal files.
    case documents = 8
    /// Not yet classified.
    case other = 9

    public var id: UInt8 { rawValue }

    public static func < (lhs: StorageCategory, rhs: StorageCategory) -> Bool { lhs.rawValue < rhs.rawValue }

    public var displayName: String {
        switch self {
        case .developerBuilds: return "Developer Builds"
        case .aiModels: return "AI / LLM Models"
        case .containersVMs: return "Containers & VMs"
        case .xcode: return "Xcode"
        case .applications: return "Applications"
        case .media: return "Media"
        case .caches: return "Caches"
        case .system: return "System & Protected"
        case .documents: return "Documents & Files"
        case .other: return "Other"
        }
    }

    /// Brand color, 0xRRGGBB.
    public var hexColor: UInt32 {
        switch self {
        case .developerBuilds: return 0x06B6D4  // Cyan
        case .aiModels: return 0x8B5CF6         // Violet
        case .containersVMs: return 0x3B82F6    // Indigo / Blue
        case .xcode: return 0x0EA5E9            // Sky
        case .applications: return 0x10B981     // Emerald
        case .media: return 0xF59E0B            // Amber
        case .caches: return 0xF97316           // Coral / Orange
        case .system: return 0x64748B           // Slate
        case .documents: return 0xF472B6        // Pink
        case .other: return 0x94A3B8            // Slate-400 (neutral)
        }
    }

    /// SF Symbol name.
    public var symbolName: String {
        switch self {
        case .developerBuilds: return "hammer.fill"
        case .aiModels: return "brain"
        case .containersVMs: return "shippingbox.fill"
        case .xcode: return "swift"
        case .applications: return "app.badge.fill"
        case .media: return "photo.on.rectangle.angled"
        case .caches: return "archivebox.fill"
        case .system: return "lock.shield.fill"
        case .documents: return "doc.fill"
        case .other: return "questionmark.folder.fill"
        }
    }
}
