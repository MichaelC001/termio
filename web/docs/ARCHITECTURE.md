# termio Web — Architecture

This describes the `web/` project: the marketing site and the licensing backend
that together sell and validate termio licenses. The desktop app itself lives in
the repository root (`Sources/termio`) and is out of scope here, except where it
validates a license.

> Some sub-projects are being built concurrently by other agents. This document
> describes them **by intent**; paths it references may not all exist yet.

## Two sub-projects

### `web/landing` — marketing site

The public website. A developer evaluates termio, reads pricing, and starts
checkout here.

- **Stack:** Next.js + TypeScript, styled with Tailwind CSS and
  [shadcn/ui](https://ui.shadcn.com/) components.
- **Design:** modeled on [superwhisper.com](https://superwhisper.com/) — clean,
  dark, product-forward. (We borrow superwhisper's *visual* language, not its
  subscription pricing model.)
- **Pricing source:** reads [`web/docs/pricing.json`](./pricing.json) so the
  pricing UI never drifts from the contract.
- **Responsibility:** present the product, render the pricing tiers and trial,
  and hand off to checkout on the backend.

### `web/server` — accounts & licensing backend

The API that turns a purchase into a license and answers "is this license
valid?".

- **Stack:** [Hono.js](https://hono.dev/) (HTTP), [better-auth](https://www.better-auth.com/)
  (accounts/sessions), [Drizzle ORM](https://orm.drizzle.team/) over a
  **Supabase Postgres** database.
- **Payments:** Stripe for a **one-time** payment. No subscriptions, no recurring
  billing, no renewal webhooks.
- **Responsibility:** user accounts, Stripe checkout, issuing **lifetime,
  device-capped licenses** (a device cap of 1 for Solo or 3 for Pro), recording
  the 30-day refund window, seat/org management for Team plans, and a
  license-validation endpoint the desktop app calls.

## Request flow

```
 ┌──────────┐    visit/read     ┌──────────────────┐
 │ Browser  │ ────────────────▶ │  web/landing     │
 │ (dev)    │                   │  Next.js + shadcn │
 └──────────┘                   └─────────┬─────────┘
      │                                   │ "Buy" → checkout
      │                                   ▼
      │                         ┌───────────────────┐
      │      better-auth        │   web/server      │
      │ ◀────── session ──────▶ │   Hono.js + Drizzle│
      │                         └─────────┬─────────┘
      │                                   │ create checkout session
      │                                   ▼
      │                         ┌───────────────────┐
      │   redirect to pay  ────▶│      Stripe       │
      │                         └─────────┬─────────┘
      │                                   │ webhook: payment succeeded
      │                                   ▼
      │                         ┌───────────────────┐
      │                         │  License issuance │
      │                         │  (web/server →    │
      │                         │   Supabase PG)    │
      │                         └─────────┬─────────┘
      │        license key                │
      │ ◀─────────────────────────────────┘
      ▼
 ┌──────────────────────┐   validate license   ┌───────────────────┐
 │  termio desktop app  │ ───────────────────▶ │  web/server       │
 │  (macOS, local-only) │ ◀─── valid / seat ── │  /license/verify  │
 └──────────────────────┘                      └───────────────────┘
```

Plain-language version:

1. The developer lands on `web/landing` and reads the pricing.
2. They start checkout; `web/server` (Hono) authenticates them via better-auth
   and creates a **Stripe** checkout session for a **one-time payment** (Solo,
   Pro, or N Team seats).
3. Stripe collects the payment and fires a single `payment succeeded` webhook
   back to `web/server`. There is no subscription, so there are no recurring or
   renewal webhooks to handle.
4. `web/server` **mints a lifetime license** with the right **device cap** (1 for
   Solo, 3 for Pro) and stamps a **30-day refund window** on it (and, for Team,
   allocates seats in an org), persists it to Supabase Postgres via Drizzle, and
   returns the license to the buyer.
5. The **termio desktop app** validates that license against `web/server` to
   unlock past the 7-day trial. Validation checks the license is active and the
   requesting Mac fits under the device cap. Because the app is local-only, this
   is a lightweight check, not a per-use gate.

## Tech stack — role of each piece

| Piece | Where | Role |
|-------|-------|------|
| Next.js + TypeScript | landing | Marketing site, SSR/SSG pages, checkout entry |
| Tailwind + shadcn/ui | landing | Styling and component primitives |
| `pricing.json` | docs | Single source of truth for tiers, device caps, trial, refund |
| Hono.js | server | HTTP API framework |
| better-auth | server | Accounts, sessions, auth flows |
| Drizzle ORM | server | Type-safe DB schema and queries (`web/server/drizzle`) |
| Supabase Postgres | server | Persistent store for users, orgs, seats, licenses |
| Stripe | server | One-time license payment + `payment succeeded` webhook (no subscriptions) |
| termio desktop | repo root | Consumes the license-validation endpoint |

## Local dev quickstart

Each sub-project owns its own setup; start from its README:

- **Landing:** see [`web/landing/README.md`](../landing/README.md) — typically
  `npm install` then `npm run dev` (Next.js dev server).
- **Server:** see [`web/server/README.md`](../server/README.md) — typically
  install deps, set env vars, run Drizzle migrations, then start the Hono server.

(Those READMEs are authored by the agents building each sub-project and may not
exist yet at the time you read this.)

## Deployment

| Component | Target | Notes |
|-----------|--------|-------|
| `web/landing` | **Vercel** | Native Next.js host; preview deploys per PR. |
| `web/server` | A **Node host** | Any Node-capable runtime (Render, Fly, Railway, a VM). Hono runs on Node. |
| Database | **Supabase** | Managed Postgres; Drizzle migrations applied on deploy. |

### Environment variables (high level)

Exact names live in each sub-project's README/`.env.example`. At a high level:

- **Landing:** the public API base URL for `web/server`, and any Stripe
  *publishable* key needed client-side.
- **Server:** `DATABASE_URL` (Supabase Postgres), better-auth secret(s), Stripe
  **secret** key and **webhook signing secret**, and the allowed origin(s) for
  the landing site.

Keep all secrets out of the repo; use the host's env/secret manager.
