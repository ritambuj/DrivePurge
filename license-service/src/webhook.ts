import type { Env } from './env';
import { ApiError, now, safeEqual } from './http';
import { revokeByDodoIdOrPayment, upsertLicense, webhookSeen, audit } from './db';

/** Dodo signs webhooks to the Standard Webhooks spec:
 *
 *    signed = HMAC-SHA256(secret, `${webhook-id}.${webhook-timestamp}.${rawBody}`)
 *
 *  The `webhook-signature` header carries one or more space-separated
 *  `v1,<base64>` pairs — more than one during a secret rotation — and any match
 *  is enough. The secret itself is base64 behind a `whsec_` prefix. */
const TOLERANCE_SECONDS = 300;

export async function verifySignature(
  env: Env,
  headers: Headers,
  rawBody: string,
): Promise<{ webhookId: string }> {
  const webhookId = headers.get('webhook-id');
  const timestamp = headers.get('webhook-timestamp');
  const signature = headers.get('webhook-signature');

  if (!webhookId || !timestamp || !signature) {
    throw new ApiError('unauthorized', 'Missing webhook signature headers.');
  }

  // Reject replays outside a five-minute window.
  const sent = Number.parseInt(timestamp, 10);
  if (!Number.isFinite(sent) || Math.abs(now() - sent) > TOLERANCE_SECONDS) {
    throw new ApiError('unauthorized', 'Webhook timestamp is outside the accepted window.');
  }

  const secret = env.DODO_WEBHOOK_SECRET ?? '';
  const rawSecret = secret.startsWith('whsec_') ? secret.slice('whsec_'.length) : secret;

  const key = await crypto.subtle.importKey(
    'raw',
    Uint8Array.from(atob(rawSecret), (c) => c.charCodeAt(0)),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const mac = await crypto.subtle.sign(
    'HMAC',
    key,
    new TextEncoder().encode(`${webhookId}.${timestamp}.${rawBody}`),
  );
  const expected = btoa(String.fromCharCode(...new Uint8Array(mac)));

  const presented = signature
    .split(' ')
    .map((part) => (part.startsWith('v1,') ? part.slice(3) : part));

  if (!presented.some((candidate) => safeEqual(candidate, expected))) {
    throw new ApiError('unauthorized', 'Webhook signature did not verify.');
  }

  return { webhookId };
}

/** Dodo's payload shapes vary by event and are documented per-event rather than
 *  centrally, so every field is read defensively and the raw body is stored
 *  regardless — a webhook we cannot fully parse must never be a lost sale. */
const pick = (source: unknown, ...path: string[]): string | null => {
  let cursor: unknown = source;
  for (const segment of path) {
    if (typeof cursor !== 'object' || cursor === null) return null;
    cursor = (cursor as Record<string, unknown>)[segment];
  }
  return typeof cursor === 'string' && cursor !== '' ? cursor : null;
};

export async function handleWebhook(env: Env, request: Request): Promise<Response> {
  const rawBody = await request.text();
  const { webhookId } = await verifySignature(env, request.headers, rawBody);

  let event: Record<string, unknown>;
  try {
    event = JSON.parse(rawBody) as Record<string, unknown>;
  } catch {
    throw new ApiError('bad_request', 'Webhook body was not valid JSON.');
  }

  const type = typeof event.type === 'string' ? event.type : 'unknown';

  // Replays are acknowledged, not reprocessed.
  if (await webhookSeen(env, webhookId, type, rawBody)) {
    return new Response(JSON.stringify({ ok: true, deduplicated: true }), {
      status: 200,
      headers: { 'content-type': 'application/json' },
    });
  }

  const data = event.data;

  switch (type) {
    // A key exists the moment Dodo mints it. Mirroring it here is what makes
    // support ("which Macs is my key on?") and revocation possible.
    case 'license_key.created': {
      const key = pick(data, 'key') ?? pick(data, 'license_key');
      if (key) {
        await upsertLicense(env, {
          key,
          source: 'dodo',
          dodo_license_key_id: pick(data, 'id'),
          customer_email: pick(data, 'customer', 'email'),
          customer_name: pick(data, 'customer', 'name'),
          product_id: pick(data, 'product_id') ?? pick(data, 'product', 'product_id'),
          payment_id: pick(data, 'payment_id'),
        });
      }
      break;
    }

    // Payment alone does not carry the key on every plan, so this only enriches
    // a record we may already have from license_key.created.
    case 'payment.succeeded': {
      const key = pick(data, 'license_key') ?? pick(data, 'license_key_id');
      if (key) {
        await upsertLicense(env, {
          key,
          source: 'dodo',
          customer_email: pick(data, 'customer', 'email'),
          customer_name: pick(data, 'customer', 'name'),
          payment_id: pick(data, 'payment_id'),
          product_id: pick(data, 'product_id'),
        });
      }
      break;
    }

    case 'refund.succeeded':
    case 'refund.created': {
      const revoked = await revokeByDodoIdOrPayment(
        env,
        pick(data, 'license_key_id'),
        pick(data, 'payment_id'),
        'refunded',
        'refund issued',
      );
      await audit(env, 'webhook', 'license.refunded', revoked.join(','), type);
      break;
    }

    case 'dispute.opened':
    case 'dispute.accepted': {
      const revoked = await revokeByDodoIdOrPayment(
        env,
        pick(data, 'license_key_id'),
        pick(data, 'payment_id'),
        'revoked',
        'payment disputed',
      );
      await audit(env, 'webhook', 'license.disputed', revoked.join(','), type);
      break;
    }

    default:
      // Stored above for the record; nothing else to do.
      break;
  }

  return new Response(JSON.stringify({ ok: true }), {
    status: 200,
    headers: { 'content-type': 'application/json' },
  });
}
