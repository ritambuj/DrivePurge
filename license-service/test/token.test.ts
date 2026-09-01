import { describe, expect, it, beforeAll } from 'vitest';
import { generateKeyPairSync } from 'node:crypto';
import type { Env } from '../src/env';
import { licenceFingerprint, signToken, verifyToken } from '../src/token';

let env: Env;
let publicKeyRaw: Uint8Array;

beforeAll(() => {
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  const spki = publicKey.export({ type: 'spki', format: 'der' });
  publicKeyRaw = new Uint8Array(spki.subarray(spki.length - 32));

  env = {
    SIGNING_KEY_PKCS8: privateKey.export({ type: 'pkcs8', format: 'der' }).toString('base64'),
    TOKEN_TTL_DAYS: '45',
  } as Env;
});

const claimsFor = (deviceHash: string) => ({
  deviceHash,
  licenseKey: 'DP1-TEST-TEST-TEST-TEST',
  email: 'buyer@example.com',
  seats: 3,
});

describe('licence tokens', () => {
  it('signs a token that verifies against the published public key', async () => {
    const { token, claims } = await signToken(env, claimsFor('a'.repeat(64)));
    const verified = await verifyToken(publicKeyRaw, token);

    expect(verified).not.toBeNull();
    expect(verified!.v).toBe(1);
    expect(verified!.sub).toBe('a'.repeat(64));
    expect(verified!.email).toBe('buyer@example.com');
    expect(verified!.seats).toBe(3);
    expect(verified!.exp).toBe(claims.exp);
  });

  it('expires 45 days out, per TOKEN_TTL_DAYS', async () => {
    const { claims } = await signToken(env, claimsFor('b'.repeat(64)));
    expect(claims.exp - claims.iat).toBe(45 * 86_400);
  });

  it('never carries the licence key itself, only a truncated hash', async () => {
    const { token, claims } = await signToken(env, claimsFor('c'.repeat(64)));
    expect(token).not.toContain('DP1-TEST');
    expect(atob(token.split('.')[0]!.replace(/-/g, '+').replace(/_/g, '/')))
      .not.toContain('DP1-TEST');
    expect(claims.lic).toBe(await licenceFingerprint('DP1-TEST-TEST-TEST-TEST'));
    expect(claims.lic).toHaveLength(16);
  });

  it('rejects a token whose payload was edited', async () => {
    const { token } = await signToken(env, claimsFor('d'.repeat(64)));
    const [, signature] = token.split('.');

    const forged = JSON.stringify({
      v: 1, sub: 'e'.repeat(64), lic: '0'.repeat(16),
      email: null, seats: 99, iat: 1, exp: 4_000_000_000,
    });
    const payload = btoa(forged).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

    expect(await verifyToken(publicKeyRaw, `${payload}.${signature}`)).toBeNull();
  });

  it('rejects a token signed by a different key', async () => {
    const other = generateKeyPairSync('ed25519');
    const otherEnv = {
      ...env,
      SIGNING_KEY_PKCS8: other.privateKey.export({ type: 'pkcs8', format: 'der' }).toString('base64'),
    } as Env;

    // signToken caches the imported key per module, so verify the inverse:
    // a token from our real key must fail against the *other* public key.
    const otherSpki = other.publicKey.export({ type: 'spki', format: 'der' });
    const otherPublic = new Uint8Array(otherSpki.subarray(otherSpki.length - 32));

    const { token } = await signToken(env, claimsFor('f'.repeat(64)));
    expect(await verifyToken(otherPublic, token)).toBeNull();
    expect(otherEnv.SIGNING_KEY_PKCS8).not.toBe(env.SIGNING_KEY_PKCS8);
  });

  it('rejects structurally broken tokens', async () => {
    for (const bad of ['', '.', 'onlyonepart', 'a.b.c', '...']) {
      expect(await verifyToken(publicKeyRaw, bad)).toBeNull();
    }
  });
});
