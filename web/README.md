# termio web

The website and licensing backend for **termio** — a native macOS (Apple
Silicon) terminal for AI coding agents. This folder sells termio and validates
the one-time lifetime licenses the desktop app checks. The desktop app itself
lives in the repository root (`Sources/termio`).

## Sub-projects

- **[`landing/`](./landing)** — the marketing site. Next.js + TypeScript +
  Tailwind + shadcn/ui, with a visual design modeled on superwhisper.com. Renders
  the product story and pricing, and hands off to checkout.
- **[`server/`](./server)** — the accounts & licensing backend. Hono.js +
  better-auth + Drizzle over Supabase Postgres, with Stripe for one-time license
  purchases and license-validation endpoints for the desktop app.

## Docs

- **[`docs/pricing.json`](./docs/pricing.json)** — the shared pricing contract.
  Single source of truth; both sub-projects read from it.
- **[`docs/PRICING.md`](./docs/PRICING.md)** — pricing strategy: the one-time
  lifetime model, the device-count tiers + trial, competitor comparison, and
  rationale.
- **[`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md)** — how the pieces fit:
  request flow, tech stack, local dev, and deployment.

## Pricing in one line

A **one-time lifetime license** — **Solo $19.90 (1 Mac)**, **Pro $39.90
(3 Macs)**, **Team $29.90/seat (5+)** — pay once, own it forever with all updates
included. **No subscription, no renewal.** A **30-day money-back guarantee** and a
**7-day no-account trial**.

## Quickstart

Each sub-project sets up independently from its own README. For the site, work in
[`landing/`](./landing) (`npm install && npm run dev`); for the API, work in
[`server/`](./server) (install deps, set env vars, run Drizzle migrations, start
the Hono server). Read **[`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md)** first
for how checkout, Stripe, license issuance, and desktop validation connect.
