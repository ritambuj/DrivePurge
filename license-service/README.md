# DrivePurge licence service

A Cloudflare Worker that sits between the macOS app and Dodo Payments. It does
three jobs Dodo alone cannot:

1. **Makes offline use possible.** Dodo's `/licenses/validate` is an online
   call. This service turns a validation into a short-lived **Ed25519-signed
   token** that the app verifies locally, so DrivePurge keeps working with the
   network off — which is what drivepurge.com promises.
2. **Holds licences we mint ourselves** (`DP1-…` keys) for comped, press and
   invoiced-team copies that never went through checkout.
3. **Revokes.** Refund and dispute webhooks mark a licence dead, and the next
   refresh locks it.

Dodo remains the source of truth for anything bought through checkout —
including the three-seat limit, which is enforced by Dodo's own *Activations
Limit* setting rather than reimplemented here.

## Layout

```
src/index.ts      router — the whole route table, readable at a glance
src/licenses.ts   activate / refresh / deactivate
src/admin.ts      bearer-authenticated admin API
src/webhook.ts    Standard Webhooks verification + event handling
src/dodo.ts       Dodo's three public licence endpoints
src/token.ts      Ed25519 signing
src/keys.ts       DP1- key minting and checksum
src/db.ts         D1 queries
migrations/       schema
test/             vitest units + an end-to-end script
```

## Local development

```sh
npm install
npm run genkeys                        # once — see "Signing keys" below
cp .dev.vars.example .dev.vars         # then fill it in
npm run migrate:local
npm run dev                            # http://localhost:8787
```

Verify it:

```sh
npm test                               # 20 unit tests
python3 test/e2e.py                    # 38 checks against a running `npm run dev`
```

`test/e2e.py` walks the whole lifecycle on the `DP1-` path, so it needs no Dodo
account: issue → activate three Macs → refuse the fourth → idempotent
re-activation → refresh → deactivate → reuse the freed seat → revoke → restore.

## Deploying

```sh
wrangler d1 create drivepurge-licenses     # already done: ff65c1dd-…
npm run migrate:remote
wrangler secret put DODO_API_KEY
wrangler secret put DODO_WEBHOOK_SECRET
wrangler secret put SIGNING_KEY_PKCS8
wrangler secret put ADMIN_TOKEN
npm run deploy
```

`wrangler.toml` routes the Worker at `api.drivepurge.com/*`. That hostname needs
a DNS record, which is blocked on the same apex fix the Pages site needs.

## Signing keys

`npm run genkeys` prints a private key (→ `SIGNING_KEY_PKCS8` secret) and a
public key (→ `Sources/Licensing/LicenseToken.swift`). **Run it once and keep
the private key backed up.** Rotating it invalidates every token already issued,
forcing every customer to reactivate.

Until a real key is pasted into the Swift client the placeholder is all zeroes,
which cannot verify anything — the app fails closed rather than accepting
unsigned tokens. `LicenseTokenVerifier.isConfigured` reports this, and
`DrivePurge --license-audit` prints it.

## Dodo configuration

In the Dodo dashboard:

- Create the €34 product, enable **licence keys**, set **Activations Limit = 3**.
- Put the product id in `wrangler.toml` (`PRODUCT_ID`) and in the checkout links
  in `drivepurge.com/index.html` (`{{DODO_PRODUCT_ID}}`).
- Add a webhook to `https://api.drivepurge.com/v1/webhooks/dodo` subscribed to
  `license_key.created`, `payment.succeeded`, `refund.succeeded` and
  `dispute.opened`. Copy the `whsec_…` secret into `DODO_WEBHOOK_SECRET`.

Start in **test mode** (`DODO_MODE = "test"`), run a sandbox purchase end to
end, then flip to `"live"`.

## The offline policy

| | |
|---|---|
| Token lifetime | 45 days (`TOKEN_TTL_DAYS`) |
| Refresh attempted | once the token is >7 days old, on launch, silently |
| Grace past expiry | 30 days, cleaning still works, banner shown |
| Total offline runway | ~75 days |

The deliberate cost: **a refunded licence keeps working until its token lapses.**
The alternative — a launch-time server check — would lock out paying customers
during any outage and contradict the site's "works offline" and "nothing sent
back to us" copy. Shorten `TOKEN_TTL_DAYS` if you would rather trade offline
runway for faster revocation.

## Security notes

- Licence keys are never logged in full — only the last four characters.
- The app sends a salted SHA-256 of the hardware UUID, never the UUID itself
  (`Sources/Licensing/DeviceIdentity.swift`). The privacy policy says so; keep
  it true.
- Webhook signatures are verified with a constant-time compare over
  `webhook-id.webhook-timestamp.body`, with a ±5-minute window and `webhook-id`
  deduplication.
- `/v1/activate` is rate-limited per IP **and** per key, so a stolen key list
  cannot be worked through from many addresses.
- Admin routes are bearer-authenticated with a constant-time compare, and every
  mutation lands in `audit_log`.
