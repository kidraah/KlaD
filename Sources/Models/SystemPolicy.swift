// SystemPolicy.swift — KlaDModels
//
// The single source of truth for what KlaD may READ and what it may ever
// MODIFY. Every layer (scanner, classification, duplicate finder, cleanup
// pre-flight, UI) asks this file — nothing hard-codes its own list.
//
//   1. KlaD never needs Full Disk Access. macOS-protected private data (Mail,
//      Messages, Safari, other apps' containers, iOS backups, Photos library…)
//      is NEVER opened, listed or read — not even when access was granted.
//      Its space is accounted for from APFS volume totals instead.
//   2. System locations are NEVER modified. In whole-disk mode the sealed
//      macOS volume and system directories are not even enumerated: their
//      size comes from the APFS container (like System Settings › Storage).
//   3. The ONLY items KlaD can ever move to the Trash live inside the user's
//      home folder, outside every protected location, below the standard
//      top-level folders — and the cleanup layer additionally demands a
//      rule-proven safety tier, matching inode, user ownership and no
//      restricted/immutable flags.

import Foundation

/// A privacy-protected place KlaD never opens, with guidance for managing it.
public struct ProtectedLocation: Sendable, Hashable, Identifiable {
    public var id: String { path }
    /// Absolute path.
    public let path: String
    /// "Mail", "Messages", "iPhone & iPad Backups".
    public let title: String
    /// What lives there and why KlaD doesn't look inside.
    public let explanation: String
    public let category: StorageCategory
    /// How to reclaim space with the owning app (never by KlaD).
    public let guidance: GuidedRemediation?

    public init(path: String, title: String, explanation: String, category: StorageCategory, guidance: GuidedRemediation?) {
        self.path = path
        self.title = title
        self.explanation = explanation
        self.category = category
        self.guidance = guidance
    }
}

public enum SystemPolicy {
    // MARK: - Reading

    /// System locations that whole-disk mode never enumerates. Their space is
    /// taken from APFS volume accounting.
    public static let systemRoots: [String] = [
        "/System", "/private", "/usr", "/bin", "/sbin", "/cores", "/dev", "/Library",
        "/Volumes", "/.vol", "/.nofollow", "/.resolve", "/etc", "/var", "/tmp",
    ]

    /// The only places whole-disk ("Macintosh HD") mode enumerates. All of them
    /// are user-owned or user-installed data; system-critical paths are excluded.
    public static func wholeDiskScanRoots(home: String) -> [String] {
        [home, "/Applications", "/Users/Shared", "/opt", "/usr/local", "/Library/Developer"]
    }

    /// Privacy-protected locations inside the home folder (TCC / App Sandbox).
    public static func protectedLocations(home: String) -> [ProtectedLocation] {
        let lib = home + "/Library"
        func guided(_ headline: String, _ explanation: String, _ commands: [GuidedCommand] = [], app: String? = nil) -> GuidedRemediation {
            GuidedRemediation(headline: headline, explanation: explanation, commands: commands, applicationBundleID: app)
        }
        let storageSettings = GuidedCommand(label: "Open System Settings › Storage",
                                            command: "open \"x-apple.systempreferences:com.apple.settings.Storage\"",
                                            isDestructive: false)
        return [
            ProtectedLocation(path: lib + "/Mail", title: "Mail", explanation: "Your email and attachments.", category: .documents,
                              guidance: guided("Manage in Mail", "Delete large messages in Mail, then use Mailbox › Erase Deleted Items.", app: "com.apple.mail")),
            ProtectedLocation(path: lib + "/Messages", title: "Messages", explanation: "Conversations and attachments.", category: .documents,
                              guidance: guided("Review large attachments", "System Settings › General › Storage › Messages lists large attachments you can remove.", [storageSettings])),
            ProtectedLocation(path: lib + "/Safari", title: "Safari", explanation: "Browsing history, bookmarks and website data.", category: .applications,
                              guidance: guided("Manage in Safari", "Safari › Settings › Privacy › Manage Website Data.", app: "com.apple.Safari")),
            ProtectedLocation(path: lib + "/Containers", title: "App Containers", explanation: "Other apps' private, sandboxed data.", category: .applications,
                              guidance: guided("Manage in each app", "Apps store their private data here. Clear it from inside the app, or remove the app.", [storageSettings])),
            ProtectedLocation(path: lib + "/Group Containers", title: "Shared App Data", explanation: "Data shared between an app and its extensions.", category: .applications, guidance: nil),
            ProtectedLocation(path: lib + "/Daemon Containers", title: "System Service Data", explanation: "Private data of macOS background services.", category: .system, guidance: nil),
            ProtectedLocation(path: lib + "/Application Support/MobileSync", title: "iPhone & iPad Backups", explanation: "Local device backups made by Finder.", category: .documents,
                              guidance: guided("Manage backups in Finder", "Connect a device or select it in the Finder sidebar, then choose Manage Backups… to delete old backups.")),
            ProtectedLocation(path: lib + "/Application Support/AddressBook", title: "Contacts", explanation: "Your contacts database.", category: .documents, guidance: nil),
            ProtectedLocation(path: lib + "/Application Support/CallHistoryDB", title: "Call History", explanation: "Phone and FaceTime call history.", category: .documents, guidance: nil),
            ProtectedLocation(path: lib + "/Application Support/CallHistoryTransactions", title: "Call History", explanation: "Phone and FaceTime call history.", category: .documents, guidance: nil),
            ProtectedLocation(path: lib + "/Application Support/FaceTime", title: "FaceTime", explanation: "FaceTime data.", category: .documents, guidance: nil),
            ProtectedLocation(path: lib + "/Application Support/Knowledge", title: "Usage Knowledge", explanation: "On-device usage data used by Siri and Spotlight.", category: .system, guidance: nil),
            ProtectedLocation(path: lib + "/Application Support/com.apple.TCC", title: "Privacy Permissions", explanation: "macOS privacy permission database.", category: .system, guidance: nil),
            ProtectedLocation(path: lib + "/Calendars", title: "Calendars", explanation: "Your calendars.", category: .documents, guidance: nil),
            ProtectedLocation(path: lib + "/Reminders", title: "Reminders", explanation: "Your reminders.", category: .documents, guidance: nil),
            ProtectedLocation(path: lib + "/HomeKit", title: "Home", explanation: "HomeKit data.", category: .system, guidance: nil),
            ProtectedLocation(path: lib + "/IdentityServices", title: "Identity Services", explanation: "iMessage and FaceTime identity data.", category: .system, guidance: nil),
            ProtectedLocation(path: lib + "/Cookies", title: "Cookies", explanation: "Website cookies.", category: .system, guidance: nil),
            ProtectedLocation(path: lib + "/Accounts", title: "Internet Accounts", explanation: "Account credentials metadata.", category: .system, guidance: nil),
            ProtectedLocation(path: lib + "/Keychains", title: "Keychains", explanation: "Your passwords and keys.", category: .system, guidance: nil),
            ProtectedLocation(path: lib + "/Biome", title: "Biome", explanation: "On-device intelligence data.", category: .system, guidance: nil),
            ProtectedLocation(path: lib + "/DuetExpertCenter", title: "Siri Suggestions", explanation: "On-device suggestion data.", category: .system, guidance: nil),
            ProtectedLocation(path: lib + "/Suggestions", title: "Siri Suggestions", explanation: "On-device suggestion data.", category: .system, guidance: nil),
            ProtectedLocation(path: lib + "/PersonalizationPortrait", title: "Personalization", explanation: "On-device personalization data.", category: .system, guidance: nil),
            ProtectedLocation(path: lib + "/Sharing", title: "Sharing", explanation: "AirDrop and sharing data.", category: .system, guidance: nil),
            ProtectedLocation(path: lib + "/Trial", title: "System Trials", explanation: "macOS experiment assets.", category: .system, guidance: nil),
            ProtectedLocation(path: lib + "/Metadata/CoreSpotlight", title: "Spotlight Index", explanation: "Per-app Spotlight index.", category: .system, guidance: nil),
            ProtectedLocation(path: lib + "/Photos", title: "Photos", explanation: "Photos system data.", category: .media, guidance: nil),
            ProtectedLocation(path: home + "/Pictures/Photo Booth Library", title: "Photo Booth", explanation: "Photo Booth pictures and videos.", category: .media, guidance: nil),
            ProtectedLocation(path: lib + "/Application Support/Google/Chrome", title: "Chrome Profile", explanation: "Chrome browsing data, protected by macOS.", category: .applications,
                              guidance: guided("Manage in Chrome", "Chrome › Settings › Privacy and security › Delete browsing data.", app: "com.google.Chrome")),
            ProtectedLocation(path: lib + "/Application Support/Firefox", title: "Firefox Profiles", explanation: "Firefox browsing data, protected by macOS.", category: .applications,
                              guidance: guided("Manage in Firefox", "Firefox › Settings › Privacy & Security › Cookies and Site Data › Clear Data.", app: "org.mozilla.firefox")),
            ProtectedLocation(path: lib + "/Application Support/Microsoft Edge", title: "Edge Profile", explanation: "Edge browsing data, protected by macOS.", category: .applications,
                              guidance: guided("Manage in Edge", "Edge › Settings › Privacy › Clear browsing data.", app: "com.microsoft.edgemac")),
            ProtectedLocation(path: lib + "/Autosave Information", title: "Unsaved Documents", explanation: "Autosaved copies of documents you haven't saved yet.", category: .documents, guidance: nil),
            ProtectedLocation(path: lib + "/Shortcuts", title: "Shortcuts", explanation: "Your shortcuts.", category: .documents, guidance: nil),
            ProtectedLocation(path: lib + "/Weather", title: "Weather", explanation: "Weather app data.", category: .system, guidance: nil),
            ProtectedLocation(path: lib + "/Application Support/CloudDocs", title: "iCloud Drive Sync", explanation: "iCloud Drive's sync database.", category: .system, guidance: nil),
            ProtectedLocation(path: lib + "/Application Support/FileProvider", title: "File Provider", explanation: "Cloud storage sync state.", category: .system, guidance: nil),
            ProtectedLocation(path: lib + "/Application Support/DifferentialPrivacy", title: "Differential Privacy", explanation: "On-device privacy-preserving analytics.", category: .system, guidance: nil),
            ProtectedLocation(path: lib + "/Application Support/com.apple.sharedfilelist", title: "Recent Items", explanation: "Recent documents and servers lists.", category: .system, guidance: nil),
            ProtectedLocation(path: lib + "/Application Support/com.apple.avfoundation/Frecents", title: "Media Recents", explanation: "Recently used media devices.", category: .system, guidance: nil),
            ProtectedLocation(path: lib + "/Assistant/SiriVocabulary", title: "Siri Vocabulary", explanation: "Personal Siri vocabulary.", category: .system, guidance: nil),
            ProtectedLocation(path: lib + "/AppleMediaServices", title: "Apple Media Services", explanation: "App Store and Apple Media account data.", category: .system, guidance: nil),
            ProtectedLocation(path: lib + "/ContainerManager", title: "Container Manager", explanation: "App sandbox bookkeeping.", category: .system, guidance: nil),
            ProtectedLocation(path: lib + "/CoreFollowUp", title: "Follow-ups", explanation: "System follow-up notifications.", category: .system, guidance: nil),
            ProtectedLocation(path: lib + "/DoNotDisturb", title: "Focus", explanation: "Focus and Do Not Disturb data.", category: .system, guidance: nil),
            ProtectedLocation(path: lib + "/IntelligencePlatform", title: "Apple Intelligence", explanation: "On-device intelligence data.", category: .system, guidance: nil),
            ProtectedLocation(path: lib + "/com.apple.aiml.instrumentation", title: "Apple Intelligence", explanation: "On-device intelligence instrumentation.", category: .system, guidance: nil),
            ProtectedLocation(path: lib + "/StatusKit", title: "Status", explanation: "Shared Focus status data.", category: .system, guidance: nil),
            ProtectedLocation(path: lib + "/Metadata/com.apple.IntelligentSuggestions", title: "Suggestions", explanation: "On-device suggestion data.", category: .system, guidance: nil),
            ProtectedLocation(path: lib + "/Caches/CloudKit", title: "CloudKit Cache", explanation: "iCloud sync cache managed by macOS.", category: .caches, guidance: nil),
            ProtectedLocation(path: lib + "/Caches/com.apple.Safari", title: "Safari Cache", explanation: "Safari's cache, protected by macOS.", category: .caches,
                              guidance: guided("Clear in Safari", "Safari › Settings › Advanced › Show features for web developers, then Develop › Empty Caches.", app: "com.apple.Safari")),
            ProtectedLocation(path: lib + "/Caches/com.apple.Safari.SafeBrowsing", title: "Safe Browsing", explanation: "Safari Safe Browsing data.", category: .caches, guidance: nil),
            ProtectedLocation(path: lib + "/Caches/com.apple.HomeKit", title: "Home Cache", explanation: "HomeKit cache.", category: .caches, guidance: nil),
            ProtectedLocation(path: lib + "/Caches/com.apple.homed", title: "Home Cache", explanation: "HomeKit cache.", category: .caches, guidance: nil),
            ProtectedLocation(path: lib + "/Caches/com.apple.ap.adprivacyd", title: "Ad Privacy Cache", explanation: "Private system cache.", category: .caches, guidance: nil),
            ProtectedLocation(path: lib + "/Caches/com.apple.containermanagerd", title: "Container Cache", explanation: "Private system cache.", category: .caches, guidance: nil),
            ProtectedLocation(path: lib + "/Caches/com.apple.textunderstandingd/Private", title: "Text Understanding", explanation: "Private system cache.", category: .caches, guidance: nil),
            ProtectedLocation(path: lib + "/Caches/FamilyCircle", title: "Family Sharing", explanation: "Family Sharing cache.", category: .caches, guidance: nil),
            ProtectedLocation(path: lib + "/Caches/familycircled", title: "Family Sharing", explanation: "Family Sharing cache.", category: .caches, guidance: nil),
            ProtectedLocation(path: home + "/.Trash", title: "Trash", explanation: "Items you moved to the Trash.", category: .documents,
                              guidance: guided("Empty the Trash", "Items in the Trash still use space until you empty it: Finder › Empty Trash.", app: "com.apple.finder")),
        ]
    }

    /// Package extensions that are privacy-protected wherever they live.
    public static let protectedPackageExtensions: Set<String> = ["photoslibrary", "photolibrary"]

    /// Exact directory paths the scanner must never open (protected locations).
    public static func neverEnterPaths(home: String) -> Set<String> {
        Set(protectedLocations(home: home).map(\.path))
    }

    /// Whether a directory with this name is a protected package (e.g. "Photos Library.photoslibrary").
    public static func isProtectedPackage(name: String) -> Bool {
        guard let dot = name.lastIndex(of: ".") else { return false }
        return protectedPackageExtensions.contains(name[name.index(after: dot)...].lowercased())
    }

    /// The protected location containing (or equal to) `path`, if any.
    public static func protectedLocation(containing path: String, home: String) -> ProtectedLocation? {
        protectedLocations(home: home).first { path == $0.path || path.hasPrefix($0.path + "/") }
    }

    // MARK: - Modifying

    /// Top-level folders of the home directory that are never trashed themselves.
    public static let protectedHomeFolders: Set<String> = [
        "Applications", "Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures", "Public",
        ".Trash", ".ssh", ".gnupg", ".config", ".local", ".cache", ".npm", ".cargo", ".rustup", ".ollama",
    ]

    /// Whether KlaD may EVER offer to move `path` to the Trash. Necessary, not
    /// sufficient — the cleanup pre-flight adds tier, identity, ownership and
    /// flag checks.
    public static func mayModify(_ path: String, home: String) -> Bool {
        let normalized = normalize(path)
        let homePath = normalize(home)
        guard normalized.hasPrefix(homePath + "/") else { return false }       // home folder only
        let relative = normalized.dropFirst(homePath.count + 1)
        let components = relative.split(separator: "/", omittingEmptySubsequences: true)
        guard let first = components.first, !components.contains("..") else { return false }
        if components.count == 1 && protectedHomeFolders.contains(String(first)) { return false }
        if components.count == 1 && first == "Library" { return false }
        if components.count == 2 && first == "Library" { return false }     // ~/Library/Caches itself, ~/Library/Developer itself…
        if protectedLocation(containing: normalized, home: homePath) != nil { return false }
        if components.contains(where: { isProtectedPackage(name: String($0)) }) { return false }
        return true
    }

    /// iCloud Drive / File Provider locations — deleting here deletes everywhere.
    public static func isCloudSynced(_ path: String, home: String) -> Bool {
        let normalized = normalize(path)
        return normalized.hasPrefix(home + "/Library/Mobile Documents/") || normalized.hasPrefix(home + "/Library/CloudStorage/")
    }

    /// Deletes at least this large require an explicit acknowledgement.
    public static let largeDeleteBytes: UInt64 = 10_000_000_000
    public static let largeDeleteItems: UInt64 = 50_000

    /// Lexical normalization: strips trailing slashes and "." components.
    public static func normalize(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) where part != "." {
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }
}
