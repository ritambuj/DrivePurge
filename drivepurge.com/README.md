# drivepurge.com

The DrivePurge marketing site — a static implementation of the
**DrivePurge Landing** design from the Claude Design project
`2613e1e4-07c7-474c-8729-60cca6a023bd`.

No build step, no dependencies. Open `index.html`, or serve the folder:

```sh
python3 -m http.server 4000 --directory drivepurge.com
# → http://localhost:4000
```

## Layout

```
index.html                  the landing page
thanks/index.html           post-checkout landing (Dodo redirect_url target)
legal/privacy/index.html    privacy policy
legal/terms/index.html      terms of sale + end-user licence
legal/refunds/index.html    refund policy and right of withdrawal
legal/README.md             the placeholders you must fill before launch
assets/css/modernist.css    design-system tokens + component classes
                            (verbatim copy of the project's _ds styles.css —
                             re-copy it when the design system changes)
assets/css/site.css         page-level styles, incl. the .prose block the
                            legal pages use
assets/js/landing.js        the two interactive pieces:
                            the hero disk map and the "safe to delete" chips
```

## Before you deploy

The pages carry `{{PLACEHOLDER}}` tokens for details only you can supply —
company name, addresses, the Dodo product id, the download URL. They render
highlighted in orange so an unfilled one is obvious. See `legal/README.md`, then:

```sh
grep -rn '{{' . --include='*.html' && echo "STILL UNFILLED" || echo "clean"
```

## The design system

`modernist.css` is the source of truth for colour, type and spacing. It is the
same system the macOS app's **Modernist** theme is built from
(`Sources/App.swift` → `Palette.modernist`), so a token change here should be
mirrored there. The key values:

| Token | Value |
| --- | --- |
| `--color-bg` | `#f3f2f2` |
| `--color-text` | `#201e1d` |
| `--color-accent` | `#ec3013` |
| `--radius-*` | `0` — nothing is rounded |
| `--font-heading` / `--font-body` | Archivo 400/600/800 |

Archivo loads from Google Fonts and falls back to `system-ui`.

## Deploying

Live on Cloudflare Pages, project **drivepurge** (account ritambuj@gmail.com):

```sh
npx wrangler pages deploy drivepurge.com --project-name=drivepurge --branch=main
```

- Production: <https://drivepurge.pages.dev>
- Custom domain `drivepurge.com` is attached to the project but stays
  **pending** until the apex `A 127.0.0.1` placeholder in the Cloudflare DNS
  tab is replaced with `CNAME drivepurge.com → drivepurge.pages.dev`
  (proxied). Cloudflare will not overwrite an existing apex record itself.

Any static host would do — the folder is the site root. There is no
server-side code, no analytics and no third-party script beyond the Google
Fonts stylesheet; drop that `<link>` and self-host the font if you want the
page to make zero external requests.
