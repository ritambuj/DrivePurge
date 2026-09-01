import type { Env } from './env';

/** Machine-readable error codes. The macOS client switches on these, so they
 *  are part of the contract — add codes, never rename them. */
export type ErrorCode =
  | 'bad_request'
  | 'unknown_key'
  | 'inactive'
  | 'revoked'
  | 'seat_limit_reached'
  | 'not_activated'
  | 'unauthorized'
  | 'rate_limited'
  | 'upstream_error'
  | 'server_error';

const STATUS: Record<ErrorCode, number> = {
  bad_request: 400,
  unknown_key: 404,
  inactive: 403,
  revoked: 403,
  seat_limit_reached: 409,
  not_activated: 404,
  unauthorized: 401,
  rate_limited: 429,
  upstream_error: 502,
  server_error: 500,
};

export class ApiError extends Error {
  constructor(
    readonly code: ErrorCode,
    /** Shown to the user in the app, so write it for a person, not a log. */
    readonly detail: string,
  ) {
    super(`${code}: ${detail}`);
  }
}

const baseHeaders = (env: Env): Record<string, string> => ({
  'content-type': 'application/json; charset=utf-8',
  'cache-control': 'no-store',
  'access-control-allow-origin': env.SITE_ORIGIN ?? 'https://drivepurge.com',
  'access-control-allow-headers': 'content-type, authorization',
  'access-control-allow-methods': 'GET, POST, OPTIONS',
  'referrer-policy': 'no-referrer',
  'x-content-type-options': 'nosniff',
});

export const json = (env: Env, body: unknown, status = 200): Response =>
  new Response(JSON.stringify(body), { status, headers: baseHeaders(env) });

export const errorResponse = (env: Env, error: ApiError): Response =>
  json(env, { error: error.code, detail: error.detail }, STATUS[error.code]);

export const preflight = (env: Env): Response =>
  new Response(null, { status: 204, headers: baseHeaders(env) });

/** Parses and shape-checks a JSON body. Anything malformed is a 400 with a
 *  message the app can show, not a stack trace. */
export async function readJson<T extends Record<string, unknown>>(
  request: Request,
  required: readonly (keyof T & string)[],
): Promise<T> {
  let body: unknown;
  try {
    body = await request.json();
  } catch {
    throw new ApiError('bad_request', 'The request body was not valid JSON.');
  }
  if (typeof body !== 'object' || body === null || Array.isArray(body)) {
    throw new ApiError('bad_request', 'The request body must be a JSON object.');
  }
  const record = body as Record<string, unknown>;
  for (const field of required) {
    const value = record[field];
    if (typeof value !== 'string' || value.trim() === '') {
      throw new ApiError('bad_request', `Missing or empty field: ${field}.`);
    }
  }
  return record as T;
}

/** Timing-safe string comparison for secrets. */
export function safeEqual(a: string, b: string): boolean {
  const left = new TextEncoder().encode(a);
  const right = new TextEncoder().encode(b);
  // Compare a fixed-length digest so length itself does not leak via timing.
  if (left.length !== right.length) return false;
  let diff = 0;
  for (let i = 0; i < left.length; i++) diff |= left[i]! ^ right[i]!;
  return diff === 0;
}

export const now = (): number => Math.floor(Date.now() / 1000);

export const uuid = (): string => crypto.randomUUID();

export async function sha256Hex(input: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(input));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

/** Licence keys must never reach a log in full. */
export const redactKey = (key: string): string =>
  key.length <= 4 ? '****' : `****${key.slice(-4)}`;

export const clientIp = (request: Request): string =>
  request.headers.get('cf-connecting-ip') ?? '0.0.0.0';
