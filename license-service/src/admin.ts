import type { Env } from './env';
import { ApiError, json, readJson, safeEqual, now } from './http';
import { mintKey, normaliseManualKey } from './keys';
import * as db from './db';
import * as dodo from './dodo';

/** Every admin route is bearer-authenticated against a single long secret and
 *  every mutation is written to `audit_log`, so a revocation can always be
 *  explained months later. */
export function requireAdmin(env: Env, request: Request): void {
  const header = request.headers.get('authorization') ?? '';
  const presented = header.startsWith('Bearer ') ? header.slice(7) : '';
  if (!env.ADMIN_TOKEN || !safeEqual(presented, env.ADMIN_TOKEN)) {
    throw new ApiError('unauthorized', 'Admin authentication failed.');
  }
}

const withSeats = async (env: Env, license: db.LicenseRow) => ({
  ...license,
  devices: (await db.liveActivations(env, license.key)).map((row) => ({
    deviceHash: row.device_hash,
    deviceName: row.device_name,
    firstSeen: row.first_seen,
    lastSeen: row.last_seen,
  })),
});

// POST /v1/admin/licenses — assign a licence to someone by hand.
export async function issue(env: Env, request: Request): Promise<Response> {
  const body = (await request.json().catch(() => ({}))) as {
    email?: string;
    name?: string;
    seats?: number;
    note?: string;
  };

  const key = mintKey();
  const seats = Number.isInteger(body.seats) && body.seats! > 0 ? body.seats! : 3;

  await db.upsertLicense(env, {
    key,
    source: 'manual',
    customer_email: body.email ?? null,
    customer_name: body.name ?? null,
    seat_limit: seats,
    note: body.note ?? null,
    created_at: now(),
  });
  await db.audit(env, 'admin', 'license.issued', key, JSON.stringify({ email: body.email, seats, note: body.note }));

  const license = await db.getLicense(env, key);
  return json(env, { license: license ? await withSeats(env, license) : null }, 201);
}

// GET /v1/admin/licenses?q=&status=&limit=
export async function search(env: Env, url: URL): Promise<Response> {
  const limitParam = Number.parseInt(url.searchParams.get('limit') ?? '50', 10);
  const limit = Number.isFinite(limitParam) ? Math.min(Math.max(limitParam, 1), 200) : 50;

  const licenses = await db.searchLicenses(
    env,
    url.searchParams.get('q'),
    url.searchParams.get('status'),
    limit,
  );
  return json(env, { licenses: await Promise.all(licenses.map((l) => withSeats(env, l))) });
}

// GET /v1/admin/licenses/:key
export async function detail(env: Env, key: string): Promise<Response> {
  const license = (await db.getLicense(env, normaliseManualKey(key) ?? key)) ?? null;
  if (!license) throw new ApiError('unknown_key', 'No such licence.');
  return json(env, { license: await withSeats(env, license) });
}

// POST /v1/admin/licenses/:key/revoke
export async function revoke(env: Env, request: Request, key: string): Promise<Response> {
  const body = (await request.json().catch(() => ({}))) as { reason?: string; restore?: boolean };
  const canonical = normaliseManualKey(key) ?? key;

  const license = await db.getLicense(env, canonical);
  if (!license) throw new ApiError('unknown_key', 'No such licence.');

  const status = body.restore ? 'active' : 'revoked';
  await db.setLicenseStatus(env, canonical, status, body.reason ?? null);
  await db.audit(env, 'admin', `license.${status}`, canonical, body.reason ?? null);

  const updated = await db.getLicense(env, canonical);
  return json(env, { license: updated ? await withSeats(env, updated) : null });
}

// POST /v1/admin/licenses/:key/seats/:deviceHash/release
export async function releaseSeat(env: Env, key: string, deviceHash: string): Promise<Response> {
  const canonical = normaliseManualKey(key) ?? key;
  const activation = await db.findActivation(env, canonical, deviceHash);
  if (!activation) throw new ApiError('not_activated', 'That Mac is not using this licence.');

  // Free the seat upstream too, or Dodo will keep counting it.
  if (activation.dodo_instance_id) {
    await dodo.deactivate(env, canonical, activation.dodo_instance_id);
  }
  await db.releaseActivation(env, canonical, deviceHash);
  await db.audit(env, 'admin', 'seat.released', canonical, deviceHash);

  const license = await db.getLicense(env, canonical);
  return json(env, { license: license ? await withSeats(env, license) : null });
}
