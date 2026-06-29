# termio Web — Architecture

This describes the `web/` project: the marketing site, and how termio is sold and
licensed. Selling, tax, and license keys are handled by **Lemon Squeezy**
(Merchant of Record) — there is no self-hosted backend. The desktop app lives in
the repository root (`Sources/termio`) and is out of scope here, except where it
activates a license.

## One sub-project

### `web/landing` — marketing site

The public website. A developer evaluates termio, reads pricing, and clicks
through to Lemon Squeezy checkout.

- **Stack:** Next.js + TypeScript, styled with Tailwind CSS and
  [shadcn/ui](https://ui.shadcn.com/) components.
- **Design:** modeled on [superwhisper.com](https://superwhisper.com/) — clean,
  dark, product-forward. (We borrow superwhisper's *visual* language, not its
  subscription pricing model.)
- **Pricing source:** `src/data/pricing.ts`, mirroring
  [`web/docs/pricing.json`](./pricing.json), so the pricing UI never drifts from
  the contract.
- **Responsibility:** present the product, render the two tiers + trial, and link
  out to the Lemon Squeezy checkout URLs in `src/lib/site.ts`.

## Selling & licensing: Lemon Squeezy (Merchant of Record)

We do not run an accounts/licensing backend. [Lemon Squeezy](https://www.lemonsqueezy.com/)
is the Merchant of Record, which means it:

- **Hosts checkout** — the landing "Buy" buttons link to a Lemon Squeezy checkout
  (or open the Lemon.js overlay).
- **Remits global tax** — it calculates and pays sales tax / VAT worldwide; we are
  not the tax-liable party and need no per-jurisdiction registrations.
- **Issues license keys** — each product has license keys enabled, so a purchase
  auto-generates a key and emails it to the buyer (and shows it on the success
  page + customer portal). A key's **activation limit** is the per-tier device cap
  (Solo = 1, Pro = 3).
- **Validates activations** — its [License API](https://docs.lemonsqueezy.com/api/license-api)
  (`activate` / `validate` / `deactivate`) is what the desktop app calls; the
  license key itself is the credential, so no server-side secret is involved in
  those calls.

Free / giveaway keys are issued as **100%-off discount codes** from the dashboard
(single-use or capped) — they run through normal checkout at $0 and produce a real,
fully-tracked key. Refunds disable the key automatically, so the next `validate`
fails closed.

## Request flow

```
 ┌──────────┐    visit / read pricing    ┌──────────────────┐
 │ Browser  │ ─────────────────────────▶ │  web/landing     │
 │ (dev)    │                            │  Next.js + shadcn │
 └──────────┘                            └─────────┬─────────┘
      │                                            │ "Buy" link
      │                                            ▼
      │                                  ┌───────────────────┐
      │            redirect to pay  ────▶│   Lemon Squeezy   │
      │                                  │   hosted checkout  │
      │                                  └─────────┬─────────┘
      │   license key (email + success page)       │ payment + tax handled by LS
      │ ◀──────────────────────────────────────────┘
      ▼
 ┌──────────────────────┐  activate / validate   ┌────────────────────────┐
 │  termio desktop app  │ ─────────────────────▶ │  Lemon Squeezy         │
 │  (macOS, local-only) │ ◀─── status / seat ─── │  License API           │
 └──────────────────────┘                        └────────────────────────┘
```

Plain-language version:

1. The developer lands on `web/landing` and reads the pricing.
2. They click Buy and pay on **Lemon Squeezy** (one-time payment; LS handles the
   card, the receipt, and the tax).
3. Lemon Squeezy **generates a lifetime license key** with the right **activation
   limit** (1 for Solo, 3 for Pro) and emails it to the buyer.
4. The **termio desktop app** activates that key against the Lemon Squeezy License
   API (binding this Mac as one activation "instance") to clear past the 7-day
   trial, and re-validates on launch. Because the app is local-only, this is a
   lightweight check, not a per-use gate.

## Tech stack — role of each piece

| Piece | Where | Role |
|-------|-------|------|
| Next.js + TypeScript | landing | Marketing site, SSR/SSG pages, checkout entry |
| Tailwind + shadcn/ui | landing | Styling and component primitives |
| `pricing.ts` / `pricing.json` | landing / docs | Tiers, device caps, trial, refund |
| Lemon Squeezy | external | MoR: checkout, global tax, license key issuance + validation |
| termio desktop | repo root | Activates/validates the license key via the License API |

## Local dev quickstart

- **Landing:** see [`web/landing/README.md`](../landing/README.md) — typically
  `npm install` then `npm run dev` (Next.js dev server).

There is no server to run.

## Deployment

| Component | Target | Notes |
|-----------|--------|-------|
| `web/landing` | **Vercel** | Native Next.js host; preview deploys per PR. |
| Selling / licensing | **Lemon Squeezy** | Hosted; configured in the LS dashboard, not deployed from this repo. |

### Configuration (high level)

- **Landing:** the Lemon Squeezy checkout URLs (per tier) in `src/lib/site.ts`.
- **Lemon Squeezy dashboard:** the store, the two products (Solo / Pro) with
  license keys enabled and the right activation limits, and any discount codes.
- **Desktop app:** the Lemon Squeezy purchase URL and License API base (see
  `Sources/termio/License.swift`). The License API needs no secret key — the
  license key is the credential.
