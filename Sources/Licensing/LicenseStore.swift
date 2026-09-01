//
//  LicenseStore.swift — the app's view of whether cleaning is unlocked.
//
//  Mirrors the shape of ThemeStore: a shared @MainActor singleton that writes
//  through on change and broadcasts over NotificationCenter.
//
//  The offline policy lives here, and it is the reason the site can promise
//  "Works offline":
//
//    · a token is good for 45 days from issue;
//    · once it is more than 7 days old the app quietly tries to refresh it;
//    · if that fails, cleaning keeps working for a further 30 days behind a
//      dismissible banner;
//    · only after ~75 days with no contact does cleaning lock.
//
//  The trade is deliberate: a refunded licence keeps working until its token
//  lapses. Locking a paying customer out of software they bought because their
//  Wi-Fi was down would be the worse failure.
//

import Foundation
import SwiftUI

enum LicenseState: Equatable {
    case unlicensed
    case active(LicenseToken)
    /// Past expiry but inside the grace window — still unlocked, with a nag.
    case grace(LicenseToken, until: Date)
    /// Past the grace window. Cleaning locks; scanning stays free.
    case expired(LicenseToken)

    var token: LicenseToken? {
        switch self {
        case .unlicensed: return nil
        case .active(let t), .grace(let t, _), .expired(let t): return t
        }
    }
}

@MainActor
final class LicenseStore: ObservableObject {
    static let shared = LicenseStore()

    /// How long past expiry the app keeps working with no server contact.
    static let graceInterval: TimeInterval = 30 * 86_400
    /// How old a token may get before we try to refresh it.
    static let refreshInterval: TimeInterval = 7 * 86_400

    @Published private(set) var state: LicenseState = .unlicensed
    @Published private(set) var seats: [LicenseSeat] = []
    @Published private(set) var isWorking = false
    /// Set when the user should see something — a failed activation, or the
    /// grace-period warning.
    @Published var message: String?
    @Published var isPresentingSheet = false

    /// The single question the rest of the app asks.
    var canClean: Bool {
        switch state {
        case .active, .grace: return true
        case .unlicensed, .expired: return false
        }
    }

    var isLicensed: Bool { state.token != nil }
    var email: String? { state.token?.email }

    var statusSummary: String {
        switch state {
        case .unlicensed:
            return "Not licensed — scanning is free, cleaning needs a licence."
        case .active(let token):
            let seats = token.seats
            return "Licensed\(token.email.map { " to \($0)" } ?? "") · \(seats) Macs"
        case .grace(_, let until):
            let days = max(0, Int(until.timeIntervalSinceNow / 86_400))
            return "Licensed — reconnect within \(days) day\(days == 1 ? "" : "s") to keep cleaning."
        case .expired:
            return "Licence needs rechecking. Connect to the internet and open the licence panel."
        }
    }

    // MARK: - Storage

    /// ~/Library/Application Support/DrivePurge/license.json
    private static var storeURL: URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        else { return nil }
        let directory = base.appendingPathComponent("DrivePurge", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("license.json")
    }

    private struct Persisted: Codable, Equatable {
        var key: String
        var token: String
    }

    private var persisted: Persisted? {
        didSet {
            guard persisted != nil || oldValue != nil else { return }
            writeThrough()
            recomputeState()
            NotificationCenter.default.post(name: .drivePurgeLicenseChanged, object: nil)
        }
    }

    /// The licence key, kept so the app can refresh and deactivate later.
    var licenseKey: String? { persisted?.key }

    private init() {
        if let url = Self.storeURL,
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(Persisted.self, from: data) {
            persisted = decoded
        }
        recomputeState()
    }

    private func writeThrough() {
        guard let url = Self.storeURL else { return }
        if let persisted, let data = try? JSONEncoder().encode(persisted) {
            try? data.write(to: url, options: [.atomic])
            // The token is a bearer-ish credential for this Mac only, but there
            // is no reason for other accounts to read it.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Re-derives `state` from the cached token and the clock. Called on launch,
    /// after every server round trip, and whenever the token changes.
    private func recomputeState() {
        guard let raw = persisted?.token,
              let token = LicenseTokenVerifier.verify(raw) else {
            state = .unlicensed
            return
        }

        let now = Date()
        if now < token.expiresAt {
            state = .active(token)
        } else {
            let deadline = token.expiresAt.addingTimeInterval(Self.graceInterval)
            state = now < deadline ? .grace(token, until: deadline) : .expired(token)
        }
    }

    // MARK: - Server round trips

    private func apply(_ grant: LicenseGrant, key: String) {
        seats = grant.devices
        persisted = Persisted(key: key, token: grant.token)
        if state.token == nil {
            // A grant whose token will not verify means the embedded public key
            // does not match the server's signing key — a build misconfiguration,
            // not something the customer can fix.
            message = "This build cannot verify licences. Please contact support."
        }
    }

    func activate(key trimmedInput: String) async {
        let key = trimmedInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }

        isWorking = true
        message = nil
        defer { isWorking = false }

        do {
            apply(try await LicenseAPI.activate(key: key), key: key)
            if canClean { isPresentingSheet = false }
        } catch {
            message = (error as? LicenseError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Called on launch. Silent by design: a refresh that fails must not
    /// interrupt someone who is simply offline.
    func refreshIfDue() async {
        guard let key = persisted?.key, let token = state.token else { return }
        guard Date().timeIntervalSince(token.issuedAt) > Self.refreshInterval else { return }

        do {
            apply(try await LicenseAPI.refresh(key: key), key: key)
        } catch LicenseError.revoked, LicenseError.inactive, LicenseError.unknownKey {
            // The server has spoken: this licence is genuinely gone.
            persisted = nil
            message = "This licence is no longer valid. Scanning stays free."
        } catch {
            // Offline, rate-limited or a server blip — keep the cached token and
            // let the grace window do its job.
        }
    }

    /// Frees this Mac's seat so the customer can use it elsewhere.
    func deactivateThisMac() async {
        guard let key = persisted?.key else { return }
        isWorking = true
        message = nil
        defer { isWorking = false }

        do {
            let grant = try await LicenseAPI.deactivate(key: key)
            seats = grant.devices
            persisted = nil
            message = "This Mac has been released. The licence is free to use elsewhere."
        } catch {
            message = (error as? LicenseError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - UI entry points

    func presentSheet() {
        message = nil
        isPresentingSheet = true
    }

    /// What the toolbar button says.
    var purchaseButtonTitle: String { isLicensed ? "Licence" : "Upgrade to Pro" }

    /// Shown in the status bar while in grace, so the warning is impossible to
    /// miss without being a modal.
    var graceWarning: String? {
        if case .grace = state { return statusSummary }
        if case .expired = state { return statusSummary }
        return nil
    }

    static let purchaseURL = URL(string: "https://drivepurge.com/#pricing")!
}

extension Notification.Name {
    static let drivePurgeLicenseChanged = Notification.Name("DrivePurgeLicenseChanged")
}
