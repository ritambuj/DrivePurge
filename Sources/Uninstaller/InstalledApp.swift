//
//  InstalledApp.swift — what an installed application is, and where it hides.
//
//  Dragging an app to the Trash leaves its support files, caches, containers
//  and login items behind; on an old Mac that residue is routinely gigabytes.
//  Finding it is the entire point of this feature, so most of this file is the
//  map of standard locations an app is allowed to write to.
//

import Foundation
import AppKit
import CoreServices

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Leftovers

/// A file or folder left behind by an application, grouped so the list reads
/// as a story rather than a pile of paths.
struct LeftoverItem: Identifiable, Hashable {
    enum Kind: String, CaseIterable {
        case support      = "Application Support"
        case caches       = "Caches"
        case preferences  = "Preferences"
        case container    = "Container"
        case savedState   = "Saved window state"
        case logs         = "Logs"
        case cookies      = "Cookies"
        case webData      = "Web data"
        case launchItem   = "Login & background items"
        case helperTool   = "Privileged helper"
        case scripts      = "Application scripts"

        /// Whether removing this is unambiguously safe. Preferences and
        /// containers hold real user data, so they are opt-in.
        var isSafeByDefault: Bool {
            switch self {
            case .caches, .savedState, .logs, .cookies, .webData, .launchItem:
                return true
            case .support, .preferences, .container, .helperTool, .scripts:
                return false
            }
        }

        var explanation: String {
            switch self {
            case .support:     return "Settings, plug-ins and data the app stored. May contain work you care about."
            case .caches:      return "Regenerable. Always safe to remove."
            case .preferences: return "Your settings for this app. Remove unless you plan to reinstall."
            case .container:   return "Sandboxed storage — for some apps this is where your documents live."
            case .savedState:  return "Restored window positions. Regenerable."
            case .logs:        return "Diagnostic logs. Regenerable."
            case .cookies:     return "Stored cookies for the app's web views."
            case .webData:     return "Web view storage and local databases."
            case .launchItem:  return "Starts the app or its helper at login. Removing it stops that."
            case .helperTool:  return "A privileged helper installed by the app."
            case .scripts:     return "Automation scripts the app installed."
            }
        }
    }

    let id = UUID()
    let url: URL
    let kind: Kind
    let size: Int64
    /// True for anything under /Library — trashing it needs an admin password,
    /// which a sandboxed app cannot obtain silently.
    let needsAdmin: Bool

    var displayPath: String {
        url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Installed application

struct InstalledApp: Identifiable, Hashable {
    let id: String            // bundle id, or the path when there is none
    let url: URL
    let name: String
    let bundleID: String?
    let version: String?
    let size: Int64
    let lastUsed: Date?
    let isRunning: Bool
    /// Apple's own software, and anything DrivePurge must never offer to remove.
    let isProtected: Bool
    let protectionReason: String?

    var displayPath: String {
        url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }

    var lastUsedLabel: String {
        guard let lastUsed else { return "Never opened" }
        let days = Calendar.current.dateComponents([.day], from: lastUsed, to: Date()).day ?? 0
        switch days {
        case ..<1:   return "Used today"
        case 1:      return "Used yesterday"
        case ..<30:  return "Used \(days) days ago"
        case ..<365: return "Used \(days / 30) month\(days / 30 == 1 ? "" : "s") ago"
        default:     return "Used over a year ago"
        }
    }

    /// Surfaces the apps worth looking at first: big, and untouched for months.
    var isStale: Bool {
        guard let lastUsed else { return true }
        return Date().timeIntervalSince(lastUsed) > 180 * 86_400
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Discovery

enum AppDiscovery {

    /// Where third-party applications legitimately live. `/System/Applications`
    /// is deliberately absent — those are Apple's, they are SIP-protected, and
    /// offering to remove them would be a lie.
    static var searchRoots: [URL] {
        [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]
    }

    /// DrivePurge will not offer to uninstall these under any circumstances.
    private static let protectedBundlePrefixes = ["com.apple."]
    private static let protectedNames: Set<String> = [
        "Safari", "Finder", "Xcode", "DrivePurge",
    ]

    static func scan() -> [InstalledApp] {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let ourBundleID = Bundle.main.bundleIdentifier

        // Collect the bundles first, deduplicated — /Applications/Utilities
        // overlaps /Applications on some setups.
        var urls: [URL] = []
        var seen = Set<String>()
        for root in searchRoots {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isApplicationKey], options: [.skipsHiddenFiles])
            else { continue }
            for url in entries where url.pathExtension == "app" {
                if seen.insert(url.standardized.path).inserted { urls.append(url) }
            }
        }

        // Measuring a bundle means walking every file in it, and Xcode-sized
        // apps make that the whole cost of the scan. They are independent, so
        // measure them in parallel — on a typical Mac this is the difference
        // between a minute and a few seconds.
        var results = [InstalledApp?](repeating: nil, count: urls.count)
        let lock = NSLock()

        DispatchQueue.concurrentPerform(iterations: urls.count) { index in
            let ctx = ScanContext { _, _ in }
            let app = describe(urls[index], running: running, ourBundleID: ourBundleID, ctx: ctx)
            lock.lock()
            results[index] = app
            lock.unlock()
        }

        var found: [String: InstalledApp] = [:]
        for app in results.compactMap({ $0 }) { found[app.id] = app }
        return found.values.sorted { $0.size > $1.size }
    }

    private static func describe(
        _ url: URL, running: Set<String>, ourBundleID: String?, ctx: ScanContext
    ) -> InstalledApp? {
        let bundle = Bundle(url: url)
        let info = bundle?.infoDictionary
        let bundleID = bundle?.bundleIdentifier

        let name = (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent

        var protectionReason: String?
        if let bundleID, protectedBundlePrefixes.contains(where: bundleID.hasPrefix) {
            protectionReason = "Part of macOS. Removing it would break your system."
        } else if protectedNames.contains(name) {
            protectionReason = "Protected — DrivePurge will not remove this."
        } else if bundleID != nil, bundleID == ourBundleID {
            protectionReason = "This is DrivePurge."
        } else if url.path.hasPrefix("/System/") {
            protectionReason = "Protected by macOS."
        }

        return InstalledApp(
            id: bundleID ?? url.path,
            url: url,
            name: name,
            bundleID: bundleID,
            version: info?["CFBundleShortVersionString"] as? String,
            size: DiskScanner.directoryBytes(url, ctx),
            lastUsed: lastUsedDate(url),
            isRunning: bundleID.map(running.contains) ?? false,
            isProtected: protectionReason != nil,
            protectionReason: protectionReason
        )
    }

    /// Spotlight records when an app was last launched, which is far more
    /// reliable than an access timestamp — macOS mounts with `noatime`.
    private static func lastUsedDate(_ url: URL) -> Date? {
        if let item = MDItemCreate(nil, url.path as CFString),
           let value = MDItemCopyAttribute(item, kMDItemLastUsedDate) {
            return (value as? Date)
        }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Leftover discovery

enum LeftoverScanner {

    /// Display names can carry invisible formatting marks — WhatsApp's begins
    /// with U+200E — which would silently break a string comparison.
    private static func normalise(_ value: String) -> String {
        value.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
            .lowercased()
    }

    static func matchesGroupContainer(_ entry: String, bundleID: String?, appName: String) -> Bool {
        var body = entry

        // Strip the leading 10-character Apple Team ID, if present.
        if let dot = body.firstIndex(of: "."),
           body.distance(from: body.startIndex, to: dot) == 10 {
            body = String(body[body.index(after: dot)...])
        }
        for prefix in ["group.", "groups."] where body.hasPrefix(prefix) {
            body = String(body.dropFirst(prefix.count))
        }

        if let id = bundleID, !id.isEmpty {
            if body == id || body.hasSuffix(".\(id)") || body.hasPrefix("\(id).") { return true }
        }

        // "desktop.WhatsApp" — the trailing component is the app's own name.
        // Requires a distinctive name so short ones cannot collide.
        let name = normalise(appName)
        if name.count >= 4, let last = body.split(separator: ".").last,
           normalise(String(last)) == name {
            return true
        }
        return false
    }

    /// The standard places an application is allowed to write to. Everything is
    /// matched on the bundle identifier first — an exact, unambiguous key — and
    /// only then on the app's display name, which is fuzzier and so is limited
    /// to the two directories where name-based folders are the convention.
    static func find(for app: InstalledApp) -> [LeftoverItem] {
        let home = NSHomeDirectory()
        var candidates: [(url: URL, kind: LeftoverItem.Kind)] = []
        var seen = Set<String>()

        func add(_ path: String, _ kind: LeftoverItem.Kind) {
            let url = URL(fileURLWithPath: path)
            guard !seen.contains(url.standardized.path) else { return }
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            // Never propose deleting a whole standard directory because an app
            // had an empty bundle id.
            guard url.lastPathComponent.count > 1 else { return }

            seen.insert(url.standardized.path)
            candidates.append((url, kind))
        }

        if let id = app.bundleID, !id.isEmpty {
            add("\(home)/Library/Application Support/\(id)", .support)
            add("\(home)/Library/Caches/\(id)", .caches)
            add("\(home)/Library/Preferences/\(id).plist", .preferences)
            add("\(home)/Library/Containers/\(id)", .container)
            add("\(home)/Library/Saved Application State/\(id).savedState", .savedState)
            add("\(home)/Library/Logs/\(id)", .logs)
            add("\(home)/Library/Cookies/\(id).binarycookies", .cookies)
            add("\(home)/Library/WebKit/\(id)", .webData)
            add("\(home)/Library/HTTPStorages/\(id)", .webData)
            add("\(home)/Library/HTTPStorages/\(id).binarycookies", .cookies)
            add("\(home)/Library/Application Scripts/\(id)", .scripts)
            add("\(home)/Library/LaunchAgents/\(id).plist", .launchItem)
            add("/Library/LaunchAgents/\(id).plist", .launchItem)
            add("/Library/LaunchDaemons/\(id).plist", .launchItem)
            add("/Library/PrivilegedHelperTools/\(id)", .helperTool)

        }

        // Group containers are the messiest case and often the largest. Real
        // names on a typical Mac look like:
        //
        //   57T9237FN3.desktop.WhatsApp          ← no bundle id at all
        //   6H4HRTU5E3.group.com.avast.osx
        //   243LU875E5.groups.com.apple.podcasts
        //   2G98R5QYU5.wpsoffice                 ← unmatchable, and we skip it
        //
        // A false positive here would offer to delete another vendor's data,
        // so matching is deliberately conservative: dot-component boundaries
        // only, and we would rather miss one than guess.
        let groups = "\(home)/Library/Group Containers"
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: groups) {
            for entry in entries
            where matchesGroupContainer(entry, bundleID: app.bundleID, appName: app.name) {
                add("\(groups)/\(entry)", .container)
            }
        }

        // Plenty of apps use their display name rather than their bundle id.
        add("\(home)/Library/Application Support/\(app.name)", .support)
        add("\(home)/Library/Logs/\(app.name)", .logs)
        add("/Library/Application Support/\(app.name)", .support)

        // An Application Support folder can be gigabytes; size them in parallel
        // for the same reason the bundle scan does.
        var sizes = [Int64](repeating: 0, count: candidates.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: candidates.count) { index in
            let bytes = DiskScanner.directoryBytes(candidates[index].url, ScanContext { _, _ in })
            lock.lock()
            sizes[index] = bytes
            lock.unlock()
        }

        return candidates.enumerated()
            .map { index, candidate in
                LeftoverItem(
                    url: candidate.url,
                    kind: candidate.kind,
                    size: sizes[index],
                    needsAdmin: candidate.url.path.hasPrefix("/Library/")
                )
            }
            .sorted { $0.size > $1.size }
    }
}
