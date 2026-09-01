import { describe, expect, it } from 'vitest';
import type { Env } from '../src/env';
import { verifySignature } from '../src/webhook';
import { ApiError } from '../src/http';

const SECRET_RAW = 'c2VjcmV0LXZhbHVlLWZvci10ZXN0aW5nLXB1cnBvc2Vz';
const env = { DODO_WEBHOOK_SECRET: `whsec_${SECRET_RAW}` } as Env;

/** Re-implements the Standard Webhooks signing scheme so the test exercises the
 *  verifier against an independently produced signature, not its own output. */
async function sign(id: string, timestamp: number, body: string, secret = SECRET_RAW) {
  const key = await crypto.subtle.importKey(
    'raw',
    Uint8Array.from(atob(secret), (c) => c.charCodeAt(0)),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const mac = await crypto.subtle.sign(
    'HMAC',
    key,
    new TextEncoder().encode(`${id}.${timestamp}.${body}`),
  );
  return btoa(String.fromCharCode(...new Uint8Array(mac)));
}

const headers = (id: string, ts: number, sig: string) =>
  new Headers({ 'webhook-id': id, 'webhook-timestamp': String(ts), 'webhook-signature': sig });

const nowSeconds = () => Math.floor(Date.now() / 1000);

describe('Dodo webhook signatures', () => {
  const body = JSON.stringify({ type: 'payment.succeeded', data: { payment_id: 'pay_1' } });

  it('accepts a correctly signed request', async () => {
    const ts = nowSeconds();
    const sig = await sign('msg_1', ts, body);
    const result = await verifySignature(env, headers('msg_1', ts, `v1,${sig}`), body);
    expect(result.webhookId).toBe('msg_1');
  });

  it('accepts a signature list, as sent during secret rotation', async () => {
    const ts = nowSeconds();
    const good = await sign('msg_2', ts, body);
    const list = `v1,ZmFrZXNpZ25hdHVyZXZhbHVlaGVyZQ== v1,${good}`;
    await expect(verifySignature(env, headers('msg_2', ts, list), body)).resolves.toBeTruthy();
  });

  it('rejects a tampered body', async () => {
    const ts = nowSeconds();
    const sig = await sign('msg_3', ts, body);
    const tampered = body.replace('pay_1', 'pay_999');
    await expect(
      verifySignature(env, headers('msg_3', ts, `v1,${sig}`), tampered),
    ).rejects.toBeInstanceOf(ApiError);
  });

  it('rejects a signature made with the wrong secret', async () => {
    const ts = nowSeconds();
    const sig = await sign('msg_4', ts, body, 'd3Jvbmctc2VjcmV0LXZhbHVlLWZvci10ZXN0aW5n');
    await expect(
      verifySignature(env, headers('msg_4', ts, `v1,${sig}`), body),
    ).rejects.toBeInstanceOf(ApiError);
  });

  it('rejects a replay from outside the five-minute window', async () => {
    const stale = nowSeconds() - 600;
    const sig = await sign('msg_5', stale, body);
    await expect(
      verifySignature(env, headers('msg_5', stale, `v1,${sig}`), body),
    ).rejects.toThrow(/timestamp/i);
  });

  it('rejects a request signed for a different webhook id', async () => {
    const ts = nowSeconds();
    const sig = await sign('msg_6', ts, body);
    await expect(
      verifySignature(env, headers('msg_DIFFERENT', ts, `v1,${sig}`), body),
    ).rejects.toBeInstanceOf(ApiError);
  });

  it('rejects a request with headers missing entirely', async () => {
    await expect(verifySignature(env, new Headers(), body)).rejects.toThrow(/Missing/);
  });
});
