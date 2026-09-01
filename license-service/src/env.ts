export interface RateLimiter {
  limit(options: { key: string }): Promise<{ success: boolean }>;
}

export interface Env {
  DB: D1Database;
  ACTIVATE_LIMITER: RateLimiter;
  REFRESH_LIMITER: RateLimiter;

  // vars
  DODO_MODE: string;
  PRODUCT_ID: string;
  SITE_ORIGIN: string;
  TOKEN_TTL_DAYS: string;

  // secrets
  DODO_API_KEY: string;
  DODO_WEBHOOK_SECRET: string;
  SIGNING_KEY_PKCS8: string;
  ADMIN_TOKEN: string;
}

export const tokenTtlSeconds = (env: Env): number => {
  const days = Number.parseInt(env.TOKEN_TTL_DAYS ?? '45', 10);
  return (Number.isFinite(days) && days > 0 ? days : 45) * 86_400;
};
