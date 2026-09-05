//
//  AppInventory.swift — the state behind the Applications tab.
//
//  Same shape as ScanEngine: a @MainActor ObservableObject that does its I/O
//  on a detached task and publishes results back on the main actor.
//
//  Everything destructive here goes to the Trash via FileManager.trashItem,
//  never unlink(2) — the same rule the treemap's clean() follows. An uninstall
//  is therefore always undoable from the Finder.
//

import Foundation
import AppKit
import SwiftUI

enum AppSortOrder: String, CaseIterable, Identifiable {
    case size, name, lastUsed

    var id: String { rawValue }
    var title: String {
        switch self {
        case .size:     return "Largest"
        case .name:     return "Name"
        case .lastUsed: return "Least used"
        }
    }
}

/// What a completed uninstall did, so the status bar can report it honestly.
struct UninstallOutcome {
    var appName: String
    var bytesFreed: Int64
    var itemsTrashed: Int
    var failures: [String]
}

@MainActor
final class AppInventory: ObservableObject {

    @Published private(set) var apps: [InstalledApp] = []
    @Published private(set) var isScanning = false
    @Published private(set) var hasScanned = false
    @Published private(set) var scanProgress = ""

    @Published var searchText = ""
    @Published var sortOrder: AppSortOrder = .size
    @Published var hideProtected = true

    @Published private(set) var selected: InstalledApp?
    @Published private(set) var leftovers: [LeftoverItem] = []
    @Published private(set) var isLoadingLeftovers = false
    /// Leftovers the user has ticked for removal, by item id.
    @Published var chosenLeftovers: Set<UUID> = []

    @Published var lastOutcome: UninstallOutcome?
    @Published var errorMessage: String?

    // MARK: - Derived

    var visibleApps: [InstalledApp] {
        var result = apps

        if hideProtected { result = result.filter { !$0.isProtected } }

        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            result = result.filter {
                $0.name.lowercased().contains(query)
                    || ($0.bundleID?.lowercased().contains(query) ?? false)
            }
        }

        switch sortOrder {
        case .size: result.sort { $0.size > $1.size }
        case .name: result.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .lastUsed:
            // Never-opened first, then oldest — the apps worth reclaiming.
            result.sort {
                ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast)
            }
        }
        return result
    }

    var totalBytes: Int64 { visibleApps.reduce(0) { $0 + $1.size } }

    var staleCount: Int { visibleApps.filter(\.isStale).count }

    /// The app plus every ticked leftover — what the confirmation will quote.
    var reclaimableBytes: Int64 {
        guard let selected else { return 0 }
        return selected.size + leftovers
            .filter { chosenLeftovers.contains($0.id) }
            .reduce(0) { $0 + $1.size }
    }

    var leftoverBytes: Int64 { leftovers.reduce(0) { $0 + $1.size } }

    var summaryLabel: String {
        if isScanning { return "Reading applications… \(scanProgress)" }
        guard hasScanned else { return "Applications have not been scanned yet." }
        let count = visibleApps.count
        return "\(count) app\(count == 1 ? "" : "s") · \(Bytes.format(totalBytes))"
            + (staleCount > 0 ? " · \(staleCount) unused for 6 months" : "")
    }

    // MARK: - Scanning

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        scanProgress = ""
        errorMessage = nil

        Task {
            let found = await Task.detached(priority: .userInitiated) {
                AppDiscovery.scan()
            }.value

            self.apps = found
            self.isScanning = false
            self.hasScanned = true

            // Keep the selection pointed at fresh data after a rescan.
            if let current = self.selected {
                self.selected = found.first { $0.id == current.id }
                if self.selected == nil { self.clearSelection() }
            }
        }
    }

    func select(_ app: InstalledApp) {
        guard selected?.id != app.id else { return }
        selected = app
        leftovers = []
        chosenLeftovers = []
        isLoadingLeftovers = true

        Task {
            let found = await Task.detached(priority: .userInitiated) {
                LeftoverScanner.find(for: app)
            }.value

            // A slower scan for a previous selection must not overwrite a newer one.
            guard self.selected?.id == app.id else { return }
            self.leftovers = found
            // Caches and logs are pre-ticked; anything holding user data is not.
            self.chosenLeftovers = Set(found.filter { $0.kind.isSafeByDefault }.map(\.id))
            self.isLoadingLeftovers = false
        }
    }

    func clearSelection() {
        selected = nil
        leftovers = []
        chosenLeftovers = []
    }

    func toggle(_ item: LeftoverItem) {
        if chosenLeftovers.contains(item.id) { chosenLeftovers.remove(item.id) }
        else { chosenLeftovers.insert(item.id) }
    }

    func selectAllLeftovers() { chosenLeftovers = Set(leftovers.map(\.id)) }
    func selectSafeLeftovers() {
        chosenLeftovers = Set(leftovers.filter { $0.kind.isSafeByDefault }.map(\.id))
    }
    func selectNoLeftovers() { chosenLeftovers = [] }

    // MARK: - Uninstalling

    /// Asks, then moves the bundle and the ticked leftovers to the Trash.
    func uninstallSelected() {
        guard let app = selected else { return }

        // Uninstalling is destructive, so it sits behind the same paywall as
        // the treemap's clean().
        guard LicenseStore.shared.canClean else {
            LicenseStore.shared.presentSheet()
            return
        }

        guard !app.isProtected else {
            errorMessage = app.protectionReason
            return
        }

        if app.isRunning, !confirmQuit(app) { return }

        let chosen = leftovers.filter { chosenLeftovers.contains($0.id) }
        guard confirmUninstall(app, chosen) else { return }

        var freed: Int64 = 0
        var trashed = 0
        var failures: [String] = []

        // The bundle goes first: if that fails there is no point orphaning its
        // support files.
        do {
            try FileManager.default.trashItem(at: app.url, resultingItemURL: nil)
            freed += app.size
            trashed += 1
        } catch {
            errorMessage = "Could not remove \(app.name): \(error.localizedDescription)"
            return
        }

        for item in chosen {
            do {
                try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
                freed += item.size
                trashed += 1
            } catch {
                // /Library items need an admin password we cannot request, so
                // report them rather than pretending they went.
                failures.append(item.displayPath)
            }
        }

        lastOutcome = UninstallOutcome(
            appName: app.name, bytesFreed: freed, itemsTrashed: trashed, failures: failures)
        errorMessage = failures.isEmpty ? nil :
            "\(failures.count) item\(failures.count == 1 ? "" : "s") need an administrator and were left in place."

        apps.removeAll { $0.id == app.id }
        clearSelection()
    }

    func revealInFinder(_ app: InstalledApp) {
        NSWorkspace.shared.activateFileViewerSelecting([app.url])
    }

    func revealInFinder(_ item: LeftoverItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    // MARK: - Confirmation

    private func confirmQuit(_ app: InstalledApp) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(app.name)” is running."
        alert.informativeText =
            "Quit it before uninstalling, or macOS may keep parts of it in use."
        alert.addButton(withTitle: "Quit and Continue")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        for running in NSWorkspace.shared.runningApplications
        where running.bundleIdentifier == app.bundleID {
            running.terminate()
        }
        // Give the app a moment to go away before we move its bundle.
        Thread.sleep(forTimeInterval: 0.6)
        return true
    }

    private func confirmUninstall(_ app: InstalledApp, _ chosen: [LeftoverItem]) -> Bool {
        let total = app.size + chosen.reduce(0) { $0 + $1.size }

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Uninstall “\(app.name)”?"

        var detail = """
        \(app.displayPath)

        \(Bytes.format(total)) will be moved to the Trash — the app itself plus \
        \(chosen.count) leftover item\(chosen.count == 1 ? "" : "s").
        """
        if !chosen.isEmpty {
            let listed = chosen.prefix(8)
                .map { "· \($0.kind.rawValue) — \($0.displayPath) (\(Bytes.format($0.size)))" }
                .joined(separator: "\n")
            detail += "\n\n" + listed
            if chosen.count > listed.count {
                detail += "\n· and \(chosen.count - listed.count) more"
            }
        }
        detail += "\n\nNothing is erased — you can put it all back from the Trash."

        alert.informativeText = detail
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
