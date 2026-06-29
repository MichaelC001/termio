# termio web

The marketing site for **termio** — a native macOS (Apple Silicon) terminal for
AI coding agents. Selling and license-key issuance/validation are handled by
**Lemon Squeezy** (Merchant of Record), so this folder is just the public site;
there is no self-hosted backend. The desktop app itself lives in the repository
root (`Sources/termio`).

## Sub-projects

- **[`landing/`](./landing)** — the marketing site. Next.js + TypeScript +
  Tailwind + shadcn/ui, with a visual design modeled on superwhisper.com. Renders
  the product story and pricing, and links out to Lemon Squeezy checkout.

## Selling: Lemon Squeezy (Merchant of Record)

termio is sold through [Lemon Squeezy](https://www.lemonsqueezy.com/). As Merchant
of Record it hosts checkout, **remits global sales tax / VAT** on our behalf, and
**generates + validates the license keys** — its License API (`activate` /
`validate` / `deactivate`) enforces the per-tier device limit. This replaces the
former self-hosted Hono + better-auth + Stripe backend (deleted): no accounts, no
database, no payment/webhook code to run. The desktop app talks to the Lemon
Squeezy License API directly; free/giveaway keys are issued via 100%-off discount
codes from the Lemon Squeezy dashboard.

## Docs

- **[`docs/pricing.json`](./docs/pricing.json)** — the pricing contract (the
  human-readable record; the typed copy the site renders is
  `landing/src/data/pricing.ts`).
- **[`docs/PRICING.md`](./docs/PRICING.md)** — pricing strategy: the one-time
  lifetime model, the device-count tiers + trial, competitor comparison, and
  rationale.
- **[`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md)** — how the pieces fit:
  the site, Lemon Squeezy, and desktop activation.
- **[`docs/LEMON_SQUEEZY.md`](./docs/LEMON_SQUEEZY.md)** — go-live runbook: set up
  the store, products, license keys, checkout URLs, giveaways, and going live.

## Pricing in one line

A **one-time lifetime license** — **Solo $19.90 (1 Mac)** and **Pro $39.90
(3 Macs)** — pay once, own it forever with all updates included. **No
subscription, no renewal.** A **30-day money-back guarantee** and a **7-day
no-account trial**.

## Quickstart

The site sets up from its own README: work in [`landing/`](./landing)
(`npm install && npm run dev`). Read **[`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md)**
for how the site, Lemon Squeezy checkout, and desktop license activation connect.
