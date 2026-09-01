-- DrivePurge licence service — initial schema.
--
-- Two kinds of licence live here:
--   source = 'dodo'    bought through Dodo Payments; Dodo owns the seat count
--                      and we mirror it for support and revocation.
--   source = 'manual'  minted by us (comped, press, team invoice); we own the
--                      seat count entirely.

CREATE TABLE licenses (
  key                 TEXT PRIMARY KEY,
  source              TEXT NOT NULL CHECK (source IN ('dodo', 'manual')),
  dodo_license_key_id TEXT,
  customer_email      TEXT,
  customer_name       TEXT,
  product_id          TEXT,
  payment_id          TEXT,
  status              TEXT NOT NULL DEFAULT 'active'
                      CHECK (status IN ('active', 'revoked', 'refunded')),
  seat_limit          INTEGER NOT NULL DEFAULT 3,
  note                TEXT,
  created_at          INTEGER NOT NULL,
  revoked_at          INTEGER,
  revoked_reason      TEXT
);

CREATE INDEX idx_licenses_email  ON licenses (customer_email);
CREATE INDEX idx_licenses_status ON licenses (status);
CREATE INDEX idx_licenses_dodo   ON licenses (dodo_license_key_id);

-- One row per machine a licence is active on. A released row is kept for the
-- audit trail; the partial unique index below means only one *live* activation
-- can exist per (licence, device).
CREATE TABLE activations (
  id               TEXT PRIMARY KEY,
  license_key      TEXT NOT NULL REFERENCES licenses(key) ON DELETE CASCADE,
  device_hash      TEXT NOT NULL,
  device_name      TEXT,
  dodo_instance_id TEXT,
  first_seen       INTEGER NOT NULL,
  last_seen        INTEGER NOT NULL,
  released_at      INTEGER
);

CREATE UNIQUE INDEX idx_activations_live
  ON activations (license_key, device_hash)
  WHERE released_at IS NULL;

CREATE INDEX idx_activations_license ON activations (license_key);

-- Webhook idempotency. Dodo retries on any non-2xx, so the same webhook-id can
-- arrive several times; the primary key is what makes replay a no-op.
CREATE TABLE webhook_events (
  webhook_id  TEXT PRIMARY KEY,
  type        TEXT NOT NULL,
  received_at INTEGER NOT NULL,
  payload     TEXT NOT NULL
);

CREATE INDEX idx_webhook_events_type ON webhook_events (type, received_at);

-- Every administrative action, so a revocation can always be explained.
CREATE TABLE audit_log (
  id      TEXT PRIMARY KEY,
  actor   TEXT NOT NULL,
  action  TEXT NOT NULL,
  subject TEXT,
  at      INTEGER NOT NULL,
  detail  TEXT
);

CREATE INDEX idx_audit_at ON audit_log (at);
