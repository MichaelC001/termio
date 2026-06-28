# termio server

Accounts + one-time lifetime license backend for termio.

Stack: TypeScript, [Hono](https://hono.dev) on Node (`@hono/node-server`),
[better-auth](https://better-auth.com) for auth, [Drizzle ORM](https://orm.drizzle.team)
on Supabase Postgres (postgres.js driver), and [Stripe](https://stripe.com) for
one-time checkout. Package manager: **pnpm**.

The pricing model is a **one-time lifetime license** (see `web/docs/pricing.json`):
pay once, own it forever, all future updates included — no subscription and no
renewals. Personal plans come in two device tiers, Solo (1 Mac) and Pro (up to 3
Macs); a volume Team plan covers 5+ seats. A purchase issues a license whose
`maxDevices` cap limits how many devices can be activated at once, and records a
**30-day money-back guarantee** window (`purchase.refundableUntil`). A 7-day,
no-account free trial is offered before purchase.

## Setup

1. **Create a Supabase project** at <https://supabase.com>.
2. **Copy the connection string**: Project Settings → Database → Connection
   string. Use the **pooled** URL (Transaction mode, port `6543`) for the running
   app. If `db:migrate` is rejected by the pooler, use the **direct** URL
   (port `5432`) just for migrations.
3. **Configure env**: `cp .env.example .env` and fill in `DATABASE_URL` and
   `BETTER_AUTH_SECRET` (`openssl rand -base64 32`). OAuth/Stripe vars can stay
   blank for local development.
4. **Install**: `pnpm install`
5. **Generate migrations** (already committed, regenerate after schema edits):
   `pnpm db:generate`
6. **Apply migrations**: `pnpm db:migrate`
7. **Seed the catalog** from `pricing.json`: `pnpm db:seed`
8. **Run**: `pnpm dev` (watch mode) — listens on `PORT` (default `8787`).

## Scripts

| Script             | Purpose                                            |
| ------------------ | -------------------------------------------------- |
| `pnpm dev`         | Run with `tsx watch`                               |
| `pnpm build`       | Compile to `dist/` with `tsc`                      |
| `pnpm start`       | Run the compiled server (`node dist/index.js`)     |
| `pnpm typecheck`   | `tsc --noEmit`                                      |
| `pnpm db:generate` | Generate SQL migrations from the Drizzle schema    |
| `pnpm db:migrate`  | Apply migrations to `DATABASE_URL`                 |
| `pnpm db:seed`     | Upsert products/prices from `pricing.json`         |
| `pnpm stripe:setup`| Provision Stripe Products/Prices, store ids in DB  |

## Routes

| Method | Path                            | Auth        | Purpose                                                      |
| ------ | ------------------------------- | ----------- | ----------------------------------------------------------- |
| GET    | `/health`                       | none        | Liveness probe                                              |
| ALL    | `/api/auth/*`                   | n/a         | better-auth (email+password, GitHub, Google)               |
| GET    | `/api/account/me`               | session     | Current signed-in user                                      |
| GET    | `/api/account/licenses`         | session     | Caller's licenses with per-seat activations                 |
| POST   | `/api/checkout/session`         | session     | Create a Stripe Checkout Session for a plan + quantity      |
| POST   | `/api/checkout/webhook`         | Stripe sig  | `checkout.session.completed`→fulfill, `charge.refunded`→revoke, `checkout.session.expired`→mark expired |
| POST   | `/api/license/validate`         | license key | Validate a key, report device usage vs. `maxDevices`        |
| POST   | `/api/license/activate-seat`    | license key | Activate a device (enforces device cap; idempotent per device)|
| POST   | `/api/license/deactivate-seat`  | license key | Release a device's seat                                     |

The `/api/account/*` routes use better-auth session cookies (browser dashboard).
The `/api/license/*` routes are called by the desktop app and treat the license
key itself as the credential (no session cookie).

## Database tables

better-auth core: `user`, `session`, `account`, `verification`.
License domain: `product`, `price`, `purchase`, `license`, `license_seat`,
`team`, `team_member`.
Referral domain (1.x scaffold): `referral_code`, `referral`, `referral_reward`.

## Referral (1.x scaffold)

A minimal, strictly opt-in referral program (see `web/docs/pricing.md` §
"Growth: referral program") is scaffolded but **not wired into any live flow**.
The `referral_code` / `referral` / `referral_reward` tables exist, and the reward
ladder — 1 active referral → +1 free month, 3 → free Solo license, 5 → free Pro
license — lives as a pure function (`rewardForActiveReferralCount`) alongside
`generateReferralCode` in `src/referrals.ts`. There are no referral routes yet
and nothing in checkout, auth, or the desktop app reads these tables; activation
event ingestion and reward granting land in 1.x.

## Stripe (go-live)

Checkout is production-shaped: it uses real Stripe Price ids when present (run
`pnpm stripe:setup`), enables **Stripe Tax** (`automatic_tax`, required billing
address, always-create Customer), and the webhook fulfills, refunds+revokes, and
expires purchases. termio is sold as **Merchant of Record** — Stripe Tax
calculates/collects tax but **you** register and remit. The full runbook (account
setup → test mode → `stripe:setup` → webhook events → enable Tax → CLI testing →
live keys) is in [`docs/STRIPE.md`](docs/STRIPE.md).

## TODO before production

1. **OAuth apps**: create GitHub and Google OAuth apps and set their client
   id/secret; callback URL is `<BETTER_AUTH_URL>/api/auth/callback/{github,google}`.
2. **Email provider**: wire an email sender (Resend/Postmark/SES) into
   better-auth and set `emailAndPassword.requireEmailVerification = true` in
   `src/auth.ts` so sign-ups verify their address.

Also worth doing: per-IP rate limiting on `/api/license/*` to slow key
brute-forcing.
