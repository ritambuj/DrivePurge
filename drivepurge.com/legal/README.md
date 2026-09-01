# Legal pages — what you must fill in before launch

These three documents were drafted to describe how DrivePurge and the licence
service **actually behave**, so the factual claims in them are accurate. What
they cannot know is who you are. Every `{{PLACEHOLDER}}` below is highlighted in
orange on the rendered page so an unfilled one is impossible to miss.

> **Not legal advice.** These are a starting draft. Have a lawyer qualified in
> your jurisdiction review them before you sell publicly — in particular the
> warranty disclaimer and liability cap in the Terms, which are the clauses that
> matter most given the app deletes files.

## Placeholders

| Token | What goes there | Appears in |
| --- | --- | --- |
| `{{LEGAL_ENTITY_NAME}}` | The name you trade and invoice under | privacy, terms |
| `{{LEGAL_FORM}}` | e.g. "a private limited company", "a sole trader" | privacy |
| `{{REGISTERED_ADDRESS}}` | Full registered address | privacy, terms |
| `{{COMPANY_NUMBER}}` | Company/VAT registration number, or delete the clause if a sole trader | privacy |
| `{{PRIVACY_EMAIL}}` | Address for data-subject requests (`privacy@drivepurge.com`) | privacy |
| `{{SUPPORT_EMAIL}}` | General support (`support@drivepurge.com`) | all pages + landing footer |
| `{{SUPERVISORY_AUTHORITY}}` | Your lead data protection authority and its website | privacy |
| `{{GOVERNING_LAW_JURISDICTION}}` | The law governing the contract | terms |
| `{{COURTS}}` | The courts with jurisdiction | terms |
| `{{TAX_RETENTION_YEARS}}` | Statutory record-keeping period where you are (often 7–10 years in the EU) | privacy |
| `{{DODO_LEGAL_ENTITY}}` | Dodo's full legal entity — take it verbatim from your signed merchant agreement, do not guess | privacy |
| `{{EMAIL_PROVIDER}}` | Whoever hosts your support mailbox | privacy |
| `{{DODO_PRODUCT_ID}}` | The Dodo product id — from the dashboard, also goes in `license-service/wrangler.toml` | index (both buy buttons) |
| `{{DOWNLOAD_URL}}` | Where the signed .dmg lives | index (three CTAs) |

Fill them with a single pass:

```sh
cd drivepurge.com
grep -rl '{{' . --include='*.html'          # find every page still holding a token
sed -i '' 's/{{SUPPORT_EMAIL}}/support@drivepurge.com/g' index.html legal/*/index.html thanks/index.html
```

Verify none are left before deploying:

```sh
grep -rn '{{' drivepurge.com --include='*.html' && echo "STILL UNFILLED" || echo "clean"
```

## Decisions already baked in

These are choices, not boilerplate — change the copy if you disagree:

- **Dodo Payments is named as merchant of record**, and the privacy policy says
  plainly that we never see card details. This is what makes the site's
  "prices include VAT… proper invoice" copy true. If you ever leave Dodo, all
  three documents need revisiting.
- **The refund policy does not ask customers to waive their statutory right of
  withdrawal.** Most sellers of instant-download software do ask. Not asking is
  more generous, simpler to explain, and removes a checkbox from checkout — but
  it does mean a customer can use the app for 13 days and still withdraw.
- **The privacy policy commits to no cookies and no analytics.** The site
  currently honours that. If you ever add analytics, this page must change
  first, and an EU cookie banner becomes necessary.
- **Device fingerprints are described as salted one-way hashes.** The client
  must actually do that — see `Sources/Licensing/DeviceIdentity.swift`. If that
  ever changes to send a raw hardware UUID, the policy becomes untrue.
- **The Terms promise 90 days' notice before end of support**, and that existing
  installs keep working. Both are commitments you are making.

## Regenerating

The pages were written once from a shared shell and are now plain HTML — edit
them directly. If you need to change the masthead or colophon on all of them,
change it in each file; there are only four, and there is no build step.
