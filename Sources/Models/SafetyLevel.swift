// SafetyLevel.swift — KlaDModels
//
// Conservative, evidence-based safety tiers. An item is `safeToClear` ONLY with
// positive, deterministic proof that it is 100% regeneratable (e.g. node_modules
// next to package.json + a lockfile). Supporting signals (age, git state) never
// promote an item on their own.

import Foundation

public enum SafetyLevel: UInt8, Sendable, CaseIterable, Codable, Hashable, Identifiable, Comparable {
    /// Positive manifest proof it can be recreated deterministically.
    case safeToClear = 0
    /// Reclaimable, but may cost large re-downloads or hold unarchived artifacts.
    case reviewFirst = 1
    /// NEVER trash the backing file — remediate through the owning tool (Docker, tmutil…).
    case guidedExternalAction = 2
    /// System files, app bundles, user documents, protected locations.
    case doNotDelete = 3
    /// No positive evidence either way. Inspect only.
    case unknown = 4

    public var id: UInt8 { rawValue }

    public static func < (lhs: SafetyLevel, rhs: SafetyLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    public var displayName: String {
        switch self {
        case .safeToClear: return "Safe to Clear"
        case .reviewFirst: return "Review First"
        case .guidedExternalAction: return "Managed by Tool"
        case .doNotDelete: return "Do Not Delete"
        case .unknown: return "Unknown"
        }
    }

    /// Short badge text.
    public var badgeText: String {
        switch self {
        case .safeToClear: return "Safe · Regeneratable"
        case .reviewFirst: return "Review First"
        case .guidedExternalAction: return "Managed by Tool"
        case .doNotDelete: return "Protected"
        case .unknown: return "Unknown"
        }
    }

    /// Badge color, 0xRRGGBB.
    public var hexColor: UInt32 {
        switch self {
        case .safeToClear: return 0x34D399         // Mint green
        case .reviewFirst: return 0xFBBF24         // Amber gold
        case .guidedExternalAction: return 0x4F8CFF // Electric blue
        case .doNotDelete: return 0xF43F5E          // Crimson
        case .unknown: return 0x94A3B8              // Slate
        }
    }

    public var symbolName: String {
        switch self {
        case .safeToClear: return "checkmark.seal.fill"
        case .reviewFirst: return "exclamationmark.triangle.fill"
        case .guidedExternalAction: return "terminal.fill"
        case .doNotDelete: return "lock.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    /// One-line explanation of the tier.
    public var summary: String {
        switch self {
        case .safeToClear:
            return "Verified regeneratable from a manifest or tool — safe to move to Trash."
        case .reviewFirst:
            return "Reclaimable, but may require large re-downloads or contain artifacts worth keeping."
        case .guidedExternalAction:
            return "Owned by another tool. Don't trash the file — use the guided command instead."
        case .doNotDelete:
            return "System, application or personal data. KlaD will not delete this."
        case .unknown:
            return "No positive evidence it is regeneratable. Inspect only."
        }
    }

    /// Whether KlaD may move the item to the Trash at all (after pre-flight).
    public var permitsTrash: Bool {
        switch self {
        case .safeToClear, .reviewFirst: return true
        case .guidedExternalAction, .doNotDelete, .unknown: return false
        }
    }

    /// Whether the user must explicitly acknowledge a review before trashing.
    public var requiresExplicitReview: Bool { self == .reviewFirst }
}
