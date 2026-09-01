import type { Env } from './env';
import { ApiError, errorResponse, json, preflight } from './http';
import * as licenses from './licenses';
import * as admin from './admin';
import { handleWebhook } from './webhook';

/** Small explicit router. The route table is short enough that a dependency
 *  would cost more than it saves, and every path here is security-relevant —
 *  worth being able to read the whole thing at once. */
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const { pathname } = url;
    const method = request.method.toUpperCase();

    if (method === 'OPTIONS') return preflight(env);

    try {
      if (pathname === '/v1/health' && method === 'GET') {
        return json(env, { ok: true, mode: env.DODO_MODE ?? 'test' });
      }

      // ── Client ──────────────────────────────────────────────────────────
      if (pathname === '/v1/activate' && method === 'POST') {
        return await licenses.activate(env, request);
      }
      if (pathname === '/v1/refresh' && method === 'POST') {
        return await licenses.refresh(env, request);
      }
      if (pathname === '/v1/deactivate' && method === 'POST') {
        return await licenses.deactivate(env, request);
      }

      // ── Dodo ────────────────────────────────────────────────────────────
      if (pathname === '/v1/webhooks/dodo' && method === 'POST') {
        return await handleWebhook(env, request);
      }

      // ── Admin ───────────────────────────────────────────────────────────
      if (pathname.startsWith('/v1/admin/')) {
        admin.requireAdmin(env, request);

        if (pathname === '/v1/admin/licenses') {
          if (method === 'POST') return await admin.issue(env, request);
          if (method === 'GET') return await admin.search(env, url);
        }

        const seatMatch = pathname.match(/^\/v1\/admin\/licenses\/([^/]+)\/seats\/([^/]+)\/release$/);
        if (seatMatch && method === 'POST') {
          return await admin.releaseSeat(
            env,
            decodeURIComponent(seatMatch[1]!),
            decodeURIComponent(seatMatch[2]!),
          );
        }

        const revokeMatch = pathname.match(/^\/v1\/admin\/licenses\/([^/]+)\/revoke$/);
        if (revokeMatch && method === 'POST') {
          return await admin.revoke(env, request, decodeURIComponent(revokeMatch[1]!));
        }

        const detailMatch = pathname.match(/^\/v1\/admin\/licenses\/([^/]+)$/);
        if (detailMatch && method === 'GET') {
          return await admin.detail(env, decodeURIComponent(detailMatch[1]!));
        }
      }

      return json(env, { error: 'not_found', detail: 'No such endpoint.' }, 404);
    } catch (error) {
      if (error instanceof ApiError) return errorResponse(env, error);

      // Never leak an internal message to a client; log it and return a stub.
      console.error('unhandled', error instanceof Error ? error.stack : String(error));
      return errorResponse(
        env,
        new ApiError('server_error', 'Something went wrong on our side. Please try again.'),
      );
    }
  },
};
