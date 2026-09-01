//
//  DeviceIdentity.swift — how this Mac identifies itself to the licence server.
//
//  The privacy policy promises that the hardware identifier is salted and
//  hashed *before it leaves the machine*, and that we store only the digest.
//  This file is what makes that true — if it ever sends a raw IOPlatformUUID,
//  drivepurge.com/legal/privacy becomes a false statement.
//

import Foundation
import CryptoKit
import IOKit

enum DeviceIdentity {

    /// Compiled into the binary and mixed into every hash, so a digest taken
    /// from our database cannot be matched against a hardware UUID obtained
    /// elsewhere. Not a secret in the cryptographic sense — it raises the cost
    /// of a correlation attack, it does not prevent one.
    private static let pepper = "drivepurge.device.v1"

    /// The Mac's hardware UUID, from the IORegistry. Stable across reinstalls
    /// and OS upgrades, which is exactly what seat counting needs.
    private static func platformUUID() -> String? {
        let matching = IOServiceMatching("IOPlatformExpertDevice")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        let property = IORegistryEntryCreateCFProperty(
            service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)
        return property?.takeRetainedValue() as? String
    }

    /// Falls back to a random identifier persisted in UserDefaults when the
    /// IORegistry is unavailable (it should not be, but a licence must never
    /// fail to activate because of a registry quirk). A reinstall then costs
    /// the customer a seat, which they can release themselves.
    private static func rawIdentifier() -> String {
        if let uuid = platformUUID(), !uuid.isEmpty { return uuid }

        let key = "DrivePurge.fallbackDeviceID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }

    /// SHA-256 of pepper + hardware UUID, hex encoded. This — and only this —
    /// is what the server ever sees.
    static let hash: String = {
        let digest = SHA256.hash(data: Data("\(pepper):\(rawIdentifier())".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }()

    /// The name the Mac already advertises on the local network, so a customer
    /// can recognise their own machines in the seat list.
    static var name: String {
        let host = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        return host.isEmpty ? "Mac" : host
    }
}
