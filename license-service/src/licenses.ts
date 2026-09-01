import type { Env } from './env';
import { ApiError, json, readJson, clientIp, redactKey, sha256Hex } from './http';
import { isManualKey, normaliseKey, normaliseManualKey } from './keys';
import * as dodo from './dodo';
import * as db from './db';
import { signToken } from './token';

interface ActivateBody extends Record<string, unknown> {
  licenseKey: string;
  deviceHash: string;
  deviceName: string;
}

/** The device hash arrives already salted and hashed by the client — we never
 *  receive a raw hardware identifier. This only sanity-checks the shape. */
function requireDeviceHash(value: string): string {
  const hash = value.trim().toLowerCase();
  if (!/^[0-9a-f]{32,64}$/.test(hash)) {
    throw new ApiError('bad_request', 'Device identifier was not in the expected format.');
  }
  return hash;
}

const seatSummary = (rows: db.ActivationRow[]) =>
  rows.map((row) => ({
    deviceHash: row.device_hash,
    deviceName: row.device_name,
    firstSeen: row.first_seen,
    lastSeen: row.last_seen,
  }));

function assertUsable(license: db.LicenseRow): void {
  if (license.status === 'refunded') {
    throw new ApiError(
      'revoked',
      'This licence was refunded and is no longer valid. Scanning stays free.',
    );
  }
  if (license.status === 'revoked') {
    throw new ApiError(
      'revoked',
      'This licence has been revoked. Please contact support if you think that is a mistake.',
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// POST /v1/activate

export async function activate(env: Env, request: Request): Promise<Response> {
  const body = await readJson<ActivateBody>(request, ['licenseKey', 'deviceHash', 'deviceName']);
  const deviceHash = requireDeviceHash(body.deviceHash);
  const deviceName = body.deviceName.trim().slice(0, 120);
  const key = normaliseKey(body.licenseKey);

  // Two ceilings: one per caller, one per key. The second is what actually
  // stops someone working through a stolen key list from many addresses.
  const ip = clientIp(request);
  const keyBucket = await sha256Hex(key);
  for (const bucket of [`ip:${ip}`, `key:${keyBucket}`]) {
    const { success } = await env.ACTIVATE_LIMITER.limit({ key: bucket });
    if (!success) {
      throw new ApiError('rate_limited', 'Too many attempts. Please wait a minute and try again.');
    }
  }

  const existing = await db.getLicense(env, key);
  if (existing) assertUsable(existing);

  // Re-activating a machine we already know is free and idempotent: it must not
  // burn a second seat just because someone reinstalled or wiped their token.
  const known = await db.findActivation(env, key, deviceHash);

  let email = existing?.customer_email ?? null;
  let seats = existing?.seat_limit ?? 3;
  let instanceId = known?.dodo_instance_id ?? null;

  if (isManualKey(key)) {
    const canonical = normaliseManualKey(key);
    if (!canonical) throw new ApiError('unknown_key', 'That licence key was not recognised.');
    if (!existing) throw new ApiError('unknown_key', 'That licence key was not recognised.');

    if (!known) {
      const live = await db.liveActivations(env, canonical);
      if (live.length >= existing.seat_limit) {
        throw new ApiError(
          'seat_limit_reached',
          `This licence is already active on ${existing.seat_limit} Macs. ` +
            'Release one from the licence panel on that machine, or contact support.',
        );
      }
    }
  } else if (!known) {
    // Dodo owns the seat count for keys it issued — let it be the one to refuse.
    const activation = await dodo.activate(env, key, deviceName);
    instanceId = activation.instanceId;
    email = activation.email ?? email;

    await db.upsertLicense(env, {
      key,
      source: 'dodo',
      dodo_license_key_id: activation.licenseKeyId,
      customer_email: activation.email,
      customer_name: activation.name,
      product_id: activation.productId,
      seat_limit: seats,
    });
  }

  await db.recordActivation(env, {
    licenseKey: key,
    deviceHash,
    deviceName,
    dodoInstanceId: instanceId,
  });

  const license = await db.getLicense(env, key);
  if (license) {
    assertUsable(license);
    email = license.customer_email;
    seats = license.seat_limit;
  }

  const { token, claims } = await signToken(env, {
    deviceHash,
    licenseKey: key,
    email,
    seats,
  });

  console.log(
    JSON.stringify({ event: 'activate', key: redactKey(key), deviceHash, source: license?.source }),
  );

  return json(env, {
    token,
    expiresAt: claims.exp,
    email,
    seats,
    devices: seatSummary(await db.liveActivations(env, key)),
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// POST /v1/refresh

export async function refresh(env: Env, request: Request): Promise<Response> {
  const body = await readJson<ActivateBody>(request, ['licenseKey', 'deviceHash']);
  const deviceHash = requireDeviceHash(body.deviceHash);
  const key = normaliseKey(body.licenseKey);

  const { success } = await env.REFRESH_LIMITER.limit({ key: `ip:${clientIp(request)}` });
  if (!success) {
    throw new ApiError('rate_limited', 'Too many attempts. Please wait a minute and try again.');
  }

  const license = await db.getLicense(env, key);
  if (!license) throw new ApiError('unknown_key', 'That licence key was not recognised.');
  assertUsable(license);

  const activation = await db.findActivation(env, key, deviceHash);
  if (!activation) {
    throw new ApiError(
      'not_activated',
      'This Mac is not activated on that licence. Activate it to continue.',
    );
  }

  // Dodo is asked again so a key revoked upstream stops working here too.
  // A null answer means Dodo was unreachable — we deliberately fail open and
  // re-issue, because an outage must not lock out a paying customer.
  if (license.source === 'dodo') {
    const valid = await dodo.validate(env, key, activation.dodo_instance_id);
    if (valid === false) {
      await db.setLicenseStatus(env, key, 'revoked', 'invalid upstream');
      throw new ApiError('revoked', 'This licence is no longer valid.');
    }
  }

  await db.touchActivation(env, key, deviceHash);

  const { token, claims } = await signToken(env, {
    deviceHash,
    licenseKey: key,
    email: license.customer_email,
    seats: license.seat_limit,
  });

  return json(env, {
    token,
    expiresAt: claims.exp,
    email: license.customer_email,
    seats: license.seat_limit,
    devices: seatSummary(await db.liveActivations(env, key)),
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// POST /v1/deactivate — how a customer moves to a new Mac

export async function deactivate(env: Env, request: Request): Promise<Response> {
  const body = await readJson<ActivateBody>(request, ['licenseKey', 'deviceHash']);
  const deviceHash = requireDeviceHash(body.deviceHash);
  const key = normaliseKey(body.licenseKey);

  const activation = await db.findActivation(env, key, deviceHash);
  if (!activation) {
    throw new ApiError('not_activated', 'That Mac is not currently using this licence.');
  }

  if (activation.dodo_instance_id) {
    await dodo.deactivate(env, key, activation.dodo_instance_id);
  }
  await db.releaseActivation(env, key, deviceHash);

  console.log(JSON.stringify({ event: 'deactivate', key: redactKey(key), deviceHash }));

  return json(env, { released: true, devices: seatSummary(await db.liveActivations(env, key)) });
}
