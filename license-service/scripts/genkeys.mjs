#!/usr/bin/env node
/**
 * Generates the Ed25519 keypair that signs licence tokens.
 *
 *   node scripts/genkeys.mjs
 *
 * Run this ONCE. The private key goes into a Worker secret; the public key is
 * compiled into the macOS app. Rotating the pair invalidates every token that
 * has already been issued, so every customer would have to reactivate — keep
 * the private key backed up somewhere you will still have in five years.
 */
import { generateKeyPairSync } from 'node:crypto';

const { publicKey, privateKey } = generateKeyPairSync('ed25519');

const pkcs8 = privateKey.export({ type: 'pkcs8', format: 'der' }).toString('base64');

// The 32-byte raw public key sits at the end of the 44-byte SPKI DER wrapper.
// CryptoKit's Curve25519.Signing.PublicKey(rawRepresentation:) wants exactly
// those 32 bytes.
const spki = publicKey.export({ type: 'spki', format: 'der' });
const raw = spki.subarray(spki.length - 32);

const swiftBytes = [...raw]
  .map((b) => `0x${b.toString(16).padStart(2, '0')}`)
  .reduce((lines, byte, i) => {
    const line = Math.floor(i / 8);
    lines[line] = lines[line] ? `${lines[line]}, ${byte}` : byte;
    return lines;
  }, [])
  .map((line) => `        ${line},`)
  .join('\n');

console.log(`
─────────────────────────────────────────────────────────────────────────────
 1. PRIVATE KEY — set it as a Worker secret, then delete it from your terminal
    scrollback. It must never be committed.

    echo '${pkcs8}' | npx wrangler secret put SIGNING_KEY_PKCS8

─────────────────────────────────────────────────────────────────────────────
 2. PUBLIC KEY — paste into Sources/Licensing/LicenseToken.swift, replacing the
    body of \`signingPublicKey\`:

    private static let signingPublicKey: [UInt8] = [
${swiftBytes}
    ]

    Raw (base64), for reference: ${Buffer.from(raw).toString('base64')}
─────────────────────────────────────────────────────────────────────────────
`);
