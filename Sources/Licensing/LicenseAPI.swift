//
//  LicenseAPI.swift — the only network code in DrivePurge.
//
//  Three calls, one host. Nothing about a scan, a file or a folder is ever
//  sent; the request bodies below are the complete set of what leaves the Mac.
//

import Foundation

struct LicenseSeat: Decodable, Identifiable, Equatable {
    let deviceHash: String
    let deviceName: String?
    let firstSeen: TimeInterval
    let lastSeen: TimeInterval

    var id: String { deviceHash }
    var isThisMac: Bool { deviceHash == DeviceIdentity.hash }
    var lastSeenDate: Date { Date(timeIntervalSince1970: lastSeen) }
}

struct LicenseGrant: Decodable {
    let token: String
    let expiresAt: TimeInterval
    let email: String?
    let seats: Int
    let devices: [LicenseSeat]
}

/// Mirrors the server's `ErrorCode` vocabulary so the UI can react to the
/// cause, not to a string.
enum LicenseError: Error, LocalizedError, Equatable {
    case unknownKey
    case inactive
    case revoked
    case seatLimitReached
    case notActivated
    case rateLimited
    case offline
    case server(String)

    init(code: String, detail: String) {
        switch code {
        case "unknown_key":        self = .unknownKey
        case "inactive":           self = .inactive
        case "revoked":            self = .revoked
        case "seat_limit_reached": self = .seatLimitReached
        case "not_activated":      self = .notActivated
        case "rate_limited":       self = .rateLimited
        default:                   self = .server(detail)
        }
    }

    var errorDescription: String? {
        switch self {
        case .unknownKey:
            return "That licence key was not recognised. Check for a typo, or paste it again from your email."
        case .inactive:
            return "That licence is not active. If you have just bought it, give it a minute and try again."
        case .revoked:
            return "That licence is no longer valid. Scanning stays free — contact support if this looks wrong."
        case .seatLimitReached:
            return "This licence is already on three Macs. Release one from the licence panel on that machine, or email support."
        case .notActivated:
            return "This Mac is not activated on that licence yet."
        case .rateLimited:
            return "Too many attempts. Please wait a minute and try again."
        case .offline:
            return "Could not reach the licence server. Check your connection and try again."
        case .server(let detail):
            return detail
        }
    }
}

enum LicenseAPI {

    /// Overridable so the service can be exercised against a local
    /// `wrangler dev` without shipping a debug build:
    ///   defaults write com.drivepurge.DrivePurge DrivePurge.licenseAPI http://localhost:8787
    static var baseURL: URL {
        let override = UserDefaults.standard.string(forKey: "DrivePurge.licenseAPI")
        return URL(string: override ?? "https://api.drivepurge.com")!
    }

    private struct ErrorBody: Decodable { let error: String; let detail: String }

    private static func post(_ path: String, _ body: [String: String]) async throws -> LicenseGrant {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 20

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw LicenseError.offline
        }

        guard let http = response as? HTTPURLResponse else { throw LicenseError.offline }

        guard (200..<300).contains(http.statusCode) else {
            if let body = try? JSONDecoder().decode(ErrorBody.self, from: data) {
                throw LicenseError(code: body.error, detail: body.detail)
            }
            throw LicenseError.server("The licence server returned an error (\(http.statusCode)).")
        }

        do {
            return try JSONDecoder().decode(LicenseGrant.self, from: data)
        } catch {
            throw LicenseError.server("The licence server returned an unexpected response.")
        }
    }

    static func activate(key: String) async throws -> LicenseGrant {
        try await post("/v1/activate", [
            "licenseKey": key,
            "deviceHash": DeviceIdentity.hash,
            "deviceName": DeviceIdentity.name,
        ])
    }

    static func refresh(key: String) async throws -> LicenseGrant {
        try await post("/v1/refresh", [
            "licenseKey": key,
            "deviceHash": DeviceIdentity.hash,
            "deviceName": DeviceIdentity.name,
        ])
    }

    static func deactivate(key: String) async throws -> LicenseGrant {
        try await post("/v1/deactivate", [
            "licenseKey": key,
            "deviceHash": DeviceIdentity.hash,
            "deviceName": DeviceIdentity.name,
        ])
    }
}
