import type { Env } from './env';
import { ApiError } from './http';

/** Dodo's licence endpoints are public and keyless by design — they are meant
 *  to be called from desktop clients. We proxy them anyway so that the app
 *  talks to exactly one host, and so we can mint an offline token on top. */
const host = (env: Env): string =>
  env.DODO_MODE === 'live' ? 'https://live.dodopayments.com' : 'https://test.dodopayments.com';

export interface DodoActivation {
  instanceId: string;
  email: string | null;
  name: string | null;
  productId: string | null;
  licenseKeyId: string | null;
}

interface DodoActivateResponse {
  id?: string;
  license_key_id?: string;
  product?: { product_id?: string };
  customer?: { email?: string; name?: string };
}

async function post(env: Env, path: string, body: unknown): Promise<Response> {
  try {
    return await fetch(`${host(env)}${path}`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body),
    });
  } catch (cause) {
    throw new ApiError(
      'upstream_error',
      'We could not reach the licence server. Please try again in a moment.',
    );
  }
}

/** Maps Dodo's documented status codes onto our own error vocabulary.
 *  403 inactive · 404 not found · 422 activation limit reached. */
export async function activate(
  env: Env,
  licenseKey: string,
  deviceName: string,
): Promise<DodoActivation> {
  const response = await post(env, '/licenses/activate', {
    license_key: licenseKey,
    name: deviceName,
  });

  if (response.status === 404) {
    throw new ApiError('unknown_key', 'That licence key was not recognised.');
  }
  if (response.status === 403) {
    throw new ApiError(
      'inactive',
      'That licence is no longer active. If you believe this is wrong, contact support.',
    );
  }
  if (response.status === 422) {
    throw new ApiError(
      'seat_limit_reached',
      'This licence is already active on the maximum number of Macs. ' +
        'Release one from the licence panel on that machine, or contact support.',
    );
  }
  if (!response.ok) {
    throw new ApiError('upstream_error', 'The licence server rejected the request.');
  }

  const body = (await response.json().catch(() => ({}))) as DodoActivateResponse;
  if (!body.id) {
    throw new ApiError('upstream_error', 'The licence server returned an unexpected response.');
  }

  return {
    instanceId: body.id,
    email: body.customer?.email ?? null,
    name: body.customer?.name ?? null,
    productId: body.product?.product_id ?? null,
    licenseKeyId: body.license_key_id ?? null,
  };
}

/** Returns Dodo's own view of whether the key (and optionally one instance)
 *  is still good. Network failure returns null so the caller can decide
 *  whether to fail open — a refresh should not lock a paying customer out
 *  because Dodo had a bad minute. */
export async function validate(
  env: Env,
  licenseKey: string,
  instanceId: string | null,
): Promise<boolean | null> {
  let response: Response;
  try {
    response = await post(env, '/licenses/validate', {
      license_key: licenseKey,
      ...(instanceId ? { license_key_instance_id: instanceId } : {}),
    });
  } catch {
    return null;
  }
  if (response.status >= 500) return null;
  if (!response.ok) return false;

  const body = (await response.json().catch(() => ({}))) as { valid?: boolean };
  return body.valid === true;
}

/** Frees a seat. Best-effort: if Dodo refuses we still release our own row,
 *  because the customer's intent is unambiguous and a stuck seat is worse
 *  than a slightly over-counted one. */
export async function deactivate(
  env: Env,
  licenseKey: string,
  instanceId: string,
): Promise<boolean> {
  try {
    const response = await post(env, '/licenses/deactivate', {
      license_key: licenseKey,
      license_key_instance_id: instanceId,
    });
    return response.ok;
  } catch {
    return false;
  }
}
