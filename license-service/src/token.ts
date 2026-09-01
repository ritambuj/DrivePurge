import type { Env } from './env';
import { tokenTtlSeconds } from './env';
import { now, sha256Hex } from './http';

/** The claims the macOS app verifies offline.
 *
 *  The licence key itself is deliberately absent — only a truncated hash of it
 *  travels in the token. A token lifted off one machine therefore cannot be
 *  replayed as a key on another: `sub` pins it to a single device fingerprint. */
export interface TokenClaims {
  /** Format version, so the client can reject anything it does not understand. */
  v: 1;
  /** Device hash this token is valid on. */
  sub: string;
  /** First 16 hex chars of SHA-256(licence key) — enough to correlate, not to use. */
  lic: string;
  /** Buyer email, shown in the app's licence panel. */
  email: string | null;
  /** Seats the licence allows, shown in the app. */
  seats: number;
  /** Issued at / expires at, seconds since epoch. */
  iat: number;
  exp: number;
}

const encoder = new TextEncoder();

export const b64urlEncode = (bytes: Uint8Array): string => {
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
};

export const b64urlDecode = (value: string): Uint8Array => {
  const padded = value.replace(/-/g, '+').replace(/_/g, '/');
  const binary = atob(padded + '='.repeat((4 - (padded.length % 4)) % 4));
  return Uint8Array.from(binary, (c) => c.charCodeAt(0));
};

const b64ToBytes = (value: string): Uint8Array =>
  Uint8Array.from(atob(value), (c) => c.charCodeAt(0));

let cachedKey: CryptoKey | null = null;

/** Ed25519 is native in the Workers runtime — no library, no compat flag. */
async function signingKey(env: Env): Promise<CryptoKey> {
  if (cachedKey) return cachedKey;
  if (!env.SIGNING_KEY_PKCS8) {
    throw new Error('SIGNING_KEY_PKCS8 is not set — run `npm run genkeys`.');
  }
  cachedKey = await crypto.subtle.importKey(
    'pkcs8',
    b64ToBytes(env.SIGNING_KEY_PKCS8),
    { name: 'Ed25519' },
    false,
    ['sign'],
  );
  return cachedKey;
}

export async function licenceFingerprint(licenseKey: string): Promise<string> {
  return (await sha256Hex(licenseKey)).slice(0, 16);
}

/** Produces `base64url(claims).base64url(signature)`. */
export async function signToken(
  env: Env,
  input: { deviceHash: string; licenseKey: string; email: string | null; seats: number },
): Promise<{ token: string; claims: TokenClaims }> {
  const issued = now();
  const claims: TokenClaims = {
    v: 1,
    sub: input.deviceHash,
    lic: await licenceFingerprint(input.licenseKey),
    email: input.email,
    seats: input.seats,
    iat: issued,
    exp: issued + tokenTtlSeconds(env),
  };

  const payload = b64urlEncode(encoder.encode(JSON.stringify(claims)));
  const signature = await crypto.subtle.sign(
    { name: 'Ed25519' },
    await signingKey(env),
    encoder.encode(payload),
  );
  return { token: `${payload}.${b64urlEncode(new Uint8Array(signature))}`, claims };
}

/** Verification lives in the macOS client; this mirror exists so the test suite
 *  can prove a signed token round-trips against the published public key. */
export async function verifyToken(
  publicKeyRaw: Uint8Array,
  token: string,
): Promise<TokenClaims | null> {
  const parts = token.split('.');
  if (parts.length !== 2) return null;
  const [payload, signature] = parts;
  if (!payload || !signature) return null;

  // A malformed token is an invalid token, never an exception — the client
  // must be able to treat "garbage on disk" and "wrong signature" alike.
  try {
    const key = await crypto.subtle.importKey(
      'raw',
      publicKeyRaw,
      { name: 'Ed25519' },
      false,
      ['verify'],
    );
    const ok = await crypto.subtle.verify(
      { name: 'Ed25519' },
      key,
      b64urlDecode(signature),
      encoder.encode(payload),
    );
    if (!ok) return null;

    return JSON.parse(new TextDecoder().decode(b64urlDecode(payload))) as TokenClaims;
  } catch {
    return null;
  }
}
