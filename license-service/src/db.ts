import type { Env } from './env';
import { now, uuid } from './http';

export interface LicenseRow {
  key: string;
  source: 'dodo' | 'manual';
  dodo_license_key_id: string | null;
  customer_email: string | null;
  customer_name: string | null;
  product_id: string | null;
  payment_id: string | null;
  status: 'active' | 'revoked' | 'refunded';
  seat_limit: number;
  note: string | null;
  created_at: number;
  revoked_at: number | null;
  revoked_reason: string | null;
}

export interface ActivationRow {
  id: string;
  license_key: string;
  device_hash: string;
  device_name: string | null;
  dodo_instance_id: string | null;
  first_seen: number;
  last_seen: number;
  released_at: number | null;
}

export const getLicense = (env: Env, key: string): Promise<LicenseRow | null> =>
  env.DB.prepare('SELECT * FROM licenses WHERE key = ?').bind(key).first<LicenseRow>();

export const getLicenseByDodoId = (env: Env, dodoId: string): Promise<LicenseRow | null> =>
  env.DB.prepare('SELECT * FROM licenses WHERE dodo_license_key_id = ?')
    .bind(dodoId)
    .first<LicenseRow>();

export async function upsertLicense(
  env: Env,
  row: Pick<LicenseRow, 'key' | 'source'> & Partial<LicenseRow>,
): Promise<void> {
  await env.DB.prepare(
    `INSERT INTO licenses
       (key, source, dodo_license_key_id, customer_email, customer_name,
        product_id, payment_id, status, seat_limit, note, created_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
     ON CONFLICT(key) DO UPDATE SET
       dodo_license_key_id = COALESCE(excluded.dodo_license_key_id, licenses.dodo_license_key_id),
       customer_email      = COALESCE(excluded.customer_email,      licenses.customer_email),
       customer_name       = COALESCE(excluded.customer_name,       licenses.customer_name),
       product_id          = COALESCE(excluded.product_id,          licenses.product_id),
       payment_id          = COALESCE(excluded.payment_id,          licenses.payment_id)`,
  )
    .bind(
      row.key,
      row.source,
      row.dodo_license_key_id ?? null,
      row.customer_email ?? null,
      row.customer_name ?? null,
      row.product_id ?? null,
      row.payment_id ?? null,
      row.status ?? 'active',
      row.seat_limit ?? 3,
      row.note ?? null,
      row.created_at ?? now(),
    )
    .run();
}

export async function setLicenseStatus(
  env: Env,
  key: string,
  status: 'active' | 'revoked' | 'refunded',
  reason: string | null,
): Promise<void> {
  await env.DB.prepare(
    `UPDATE licenses
        SET status = ?2,
            revoked_at = CASE WHEN ?2 = 'active' THEN NULL ELSE ?3 END,
            revoked_reason = CASE WHEN ?2 = 'active' THEN NULL ELSE ?4 END
      WHERE key = ?1`,
  )
    .bind(key, status, now(), reason)
    .run();
}

/** Revokes by Dodo's licence-key id, which is what refund and dispute webhooks
 *  carry. Returns the affected licence keys so the caller can log them. */
export async function revokeByDodoIdOrPayment(
  env: Env,
  dodoLicenseKeyId: string | null,
  paymentId: string | null,
  status: 'revoked' | 'refunded',
  reason: string,
): Promise<string[]> {
  const rows = await env.DB.prepare(
    `SELECT key FROM licenses
      WHERE (?1 IS NOT NULL AND dodo_license_key_id = ?1)
         OR (?2 IS NOT NULL AND payment_id = ?2)`,
  )
    .bind(dodoLicenseKeyId, paymentId)
    .all<{ key: string }>();

  const keys = (rows.results ?? []).map((r) => r.key);
  for (const key of keys) await setLicenseStatus(env, key, status, reason);
  return keys;
}

export const liveActivations = async (env: Env, key: string): Promise<ActivationRow[]> => {
  const rows = await env.DB.prepare(
    'SELECT * FROM activations WHERE license_key = ? AND released_at IS NULL ORDER BY first_seen',
  )
    .bind(key)
    .all<ActivationRow>();
  return rows.results ?? [];
};

export const findActivation = (
  env: Env,
  key: string,
  deviceHash: string,
): Promise<ActivationRow | null> =>
  env.DB.prepare(
    'SELECT * FROM activations WHERE license_key = ? AND device_hash = ? AND released_at IS NULL',
  )
    .bind(key, deviceHash)
    .first<ActivationRow>();

export async function recordActivation(
  env: Env,
  input: {
    licenseKey: string;
    deviceHash: string;
    deviceName: string;
    dodoInstanceId: string | null;
  },
): Promise<void> {
  const timestamp = now();
  await env.DB.prepare(
    `INSERT INTO activations
       (id, license_key, device_hash, device_name, dodo_instance_id, first_seen, last_seen)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6)
     ON CONFLICT(license_key, device_hash) WHERE released_at IS NULL
     DO UPDATE SET last_seen = ?6,
                   device_name = excluded.device_name,
                   dodo_instance_id = COALESCE(excluded.dodo_instance_id, activations.dodo_instance_id)`,
  )
    .bind(
      uuid(),
      input.licenseKey,
      input.deviceHash,
      input.deviceName,
      input.dodoInstanceId,
      timestamp,
    )
    .run();
}

export const touchActivation = (env: Env, key: string, deviceHash: string): Promise<unknown> =>
  env.DB.prepare(
    'UPDATE activations SET last_seen = ?3 WHERE license_key = ?1 AND device_hash = ?2 AND released_at IS NULL',
  )
    .bind(key, deviceHash, now())
    .run();

export const releaseActivation = (env: Env, key: string, deviceHash: string): Promise<unknown> =>
  env.DB.prepare(
    'UPDATE activations SET released_at = ?3 WHERE license_key = ?1 AND device_hash = ?2 AND released_at IS NULL',
  )
    .bind(key, deviceHash, now())
    .run();

/** Idempotency gate for webhooks — true means "already handled, skip". */
export async function webhookSeen(
  env: Env,
  webhookId: string,
  type: string,
  payload: string,
): Promise<boolean> {
  const result = await env.DB.prepare(
    `INSERT INTO webhook_events (webhook_id, type, received_at, payload)
     VALUES (?1, ?2, ?3, ?4)
     ON CONFLICT(webhook_id) DO NOTHING`,
  )
    .bind(webhookId, type, now(), payload)
    .run();
  return (result.meta?.changes ?? 0) === 0;
}

export const audit = (
  env: Env,
  actor: string,
  action: string,
  subject: string | null,
  detail: string | null,
): Promise<unknown> =>
  env.DB.prepare(
    'INSERT INTO audit_log (id, actor, action, subject, at, detail) VALUES (?1, ?2, ?3, ?4, ?5, ?6)',
  )
    .bind(uuid(), actor, action, subject, now(), detail)
    .run();

export async function searchLicenses(
  env: Env,
  query: string | null,
  status: string | null,
  limit: number,
): Promise<LicenseRow[]> {
  const like = query ? `%${query}%` : null;
  const rows = await env.DB.prepare(
    `SELECT * FROM licenses
      WHERE (?1 IS NULL OR key LIKE ?1 OR customer_email LIKE ?1 OR note LIKE ?1)
        AND (?2 IS NULL OR status = ?2)
      ORDER BY created_at DESC
      LIMIT ?3`,
  )
    .bind(like, status, limit)
    .all<LicenseRow>();
  return rows.results ?? [];
}
