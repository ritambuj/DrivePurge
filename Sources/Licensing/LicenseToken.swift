//
//  LicenseToken.swift — offline verification of a signed licence token.
//
//  This is what lets the app honour "Works offline". The server signs a small
//  set of claims with Ed25519; the app verifies them against a public key
//  compiled into the binary, with no network involved. Tampering with the
//  cached file, or lifting a token from another Mac, both fail here.
//

import Foundation
import CryptoKit

struct LicenseToken: Codable, Equatable {
    /// Format version. Anything we do not recognise is treated as invalid
    /// rather than guessed at.
    let v: Int
    /// The device hash this token is valid on.
    let sub: String
    /// Truncated hash of the licence key — enough to correlate with a support
    /// request, useless as a key.
    let lic: String
    let email: String?
    let seats: Int
    let iat: TimeInterval
    let exp: TimeInterval

    var issuedAt: Date { Date(timeIntervalSince1970: iat) }
    var expiresAt: Date { Date(timeIntervalSince1970: exp) }
}

enum LicenseTokenVerifier {

    /// The public half of the signing key, replaced by `npm run genkeys` in
    /// license-service. The placeholder below is all zeroes, which cannot
    /// verify anything — the app therefore fails closed until a real key is
    /// pasted in, rather than silently accepting unsigned tokens.
    private static let signingPublicKey: [UInt8] = [
        0xc2, 0x00, 0x8b, 0xb6, 0x4e, 0x23, 0xc9, 0x43,
        0xe9, 0x9b, 0xc2, 0x20, 0xfc, 0x7a, 0xcc, 0x02,
        0x64, 0x29, 0x0f, 0xb3, 0xeb, 0xb3, 0x99, 0x1a,
        0x86, 0x9b, 0x85, 0x37, 0x49, 0x50, 0x28, 0x98,
    ]

    static var isConfigured: Bool { signingPublicKey.contains { $0 != 0 } }

    /// Verifies the signature and the device binding. Returns nil for anything
    /// that does not check out — a malformed file, a bad signature, an
    /// unknown version, or a token minted for a different Mac.
    static func verify(_ raw: String, deviceHash: String = DeviceIdentity.hash) -> LicenseToken? {
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let payloadData = base64URLDecode(String(parts[0])),
              let signature = base64URLDecode(String(parts[1])),
              let signedBytes = String(parts[0]).data(using: .utf8)
        else { return nil }

        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: Data(signingPublicKey)),
              key.isValidSignature(signature, for: signedBytes)
        else { return nil }

        guard let token = try? JSONDecoder().decode(LicenseToken.self, from: payloadData),
              token.v == 1,
              token.sub == deviceHash
        else { return nil }

        return token
    }

    static func base64URLDecode(_ value: String) -> Data? {
        var s = value.replacingOccurrences(of: "-", with: "+")
                     .replacingOccurrences(of: "_", with: "/")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        return Data(base64Encoded: s)
    }
}
