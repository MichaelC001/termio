# Stripe go-live runbook

How to take the termio backend's Stripe integration from a fresh account to
charging real cards for one-time lifetime licenses. termio's seller is the
**Merchant of Record (MoR)** using raw Stripe — that means **you** are responsible
for sales tax / VAT registration and remittance. Stripe Tax (enabled below)
*calculates and collects* tax at checkout; it does **not** remit it for you.

Work top-to-bottom. Do everything in **test mode** first, then repeat the live-key
step at the end.

## What the code already does

- `POST /api/checkout/session` builds a Checkout Session with:
  - real `line_items: [{ price: <stripePriceId>, quantity }]` when the plan has been
    provisioned (falls back to inline `price_data` otherwise),
  - `automatic_tax.enabled = true`, `billing_address_collection = "required"`,
    `customer_creation = "always"`,
  - an idempotency key (the purchase id) so retries never double-charge.
- `POST /api/checkout/webhook` (signature-verified) handles exactly three events:
  - `checkout.session.completed` → mark the purchase `completed`, persist the
    Stripe Customer id, open the 30-day refund window, mint the license.
  - `charge.refunded` → mark the purchase `refunded` and **revoke** its license
    (deactivating its device seats). Idempotent.
  - `checkout.session.expired` → mark a still-`pending` purchase `expired`.
- `pnpm stripe:setup` provisions a Stripe Product + one-time Price (with a tax code)
  per plan and writes the ids back into the database.

## 1. Create and verify the Stripe account

1. Sign up at <https://dashboard.stripe.com>.
2. Activate the account: complete **business details** and add a **bank account**
   for payouts (Settings → Business / Payouts). Identity/bank verification can take
   a day or two — start early. Live charges are blocked until the account is active.

## 2. Stay in test mode first

Keep the dashboard's **Test mode** toggle ON for steps 3–7. Use the test secret
key (`sk_test_…`). Nothing here touches real money until step 8.

## 3. Provision the catalog

From `web/server/` with `DATABASE_URL` and a test `STRIPE_SECRET_KEY` set:

```sh
pnpm db:migrate   # apply schema (incl. purchase.stripe_customer_id, product.stripe_product_id)
pnpm db:seed      # upsert products/prices from web/docs/pricing.json
pnpm stripe:setup # create Stripe Products + Prices, write ids back to the DB
```

`pnpm stripe:setup` is idempotent — it searches by plan metadata / price lookup key
before creating, and re-running it after a price change mints a new Price and
deactivates the old one. It prints a summary of every product/price id.

## 4. Set the secret key

Put the test key in `web/server/.env`:

```sh
STRIPE_SECRET_KEY="sk_test_…"
```

## 5. Create the webhook endpoint

1. Dashboard → Developers → **Webhooks** → Add endpoint.
2. URL: `https://<your-deployed-host>/api/checkout/webhook`.
3. Subscribe to **exactly** these events (the code ignores everything else):
   - `checkout.session.completed`
   - `charge.refunded`
   - `checkout.session.expired`
4. Copy the endpoint's **signing secret** (`whsec_…`) into `.env`:

   ```sh
   STRIPE_WEBHOOK_SECRET="whsec_…"
   ```

> `charge.refunded` is Stripe's canonical "this charge was refunded" event (it fires
> for full and partial refunds). We deliberately do **not** also subscribe to
> `refund.updated` / `charge.refund.updated` — one event, one handler.

## 6. Enable Stripe Tax (required — you are the Merchant of Record)

1. Dashboard → Settings → **Tax** → enable Stripe Tax.
2. Set your **origin address** and add the **registrations** for every jurisdiction
   where you have a tax obligation (Tax → Registrations).
3. Confirm each plan's **product tax code**. `pnpm stripe:setup` sets
   `txcd_10202003` (downloadable software, non-customizable) on every Product —
   verify this matches how your tax advisor classifies termio and change it in the
   script's `PRODUCT_TAX_CODE` if needed, then re-run setup.
4. **Remittance is on you.** Stripe Tax calculates and collects the right amount at
   checkout and gives you reporting (Tax → Registrations/Reports), but filing and
   paying each jurisdiction is the MoR's responsibility.

## 7. Test the full flow

1. Run the server: `pnpm dev`.
2. Forward webhooks to localhost with the Stripe CLI and use the `whsec_` it prints:

   ```sh
   stripe login
   stripe listen --forward-to http://localhost:8787/api/checkout/webhook
   ```

3. Create a session (`POST /api/checkout/session` with `{ planId, quantity }`), open
   the returned `url`, and pay with a Stripe **test card**:
   - success: `4242 4242 4242 4242`, any future expiry, any CVC, a real-looking
     billing address (Stripe Tax needs it).
   - decline: `4000 0000 0000 0002`.
4. Verify: the purchase row flips to `completed`, a license is minted, and the
   Customer/tax line appear on the session in the dashboard.
5. Refund the payment in the dashboard and confirm the purchase flips to `refunded`
   and the license is `revoked` with its seats deactivated.
6. Let a session sit unpaid (or trigger `checkout.session.expired` from the CLI) and
   confirm the pending purchase flips to `expired`.

## 8. Flip to live

1. Switch the dashboard to **live mode** and re-verify Stripe Tax registrations
   exist for live mode too.
2. Swap `.env` to live values: `STRIPE_SECRET_KEY="sk_live_…"`.
3. Re-run `pnpm stripe:setup` against live mode (it provisions live Products/Prices
   and rewrites the ids).
4. Create the **live** webhook endpoint (step 5) and copy its live `whsec_` into
   `STRIPE_WEBHOOK_SECRET`.
5. Do one real low-value end-to-end purchase + refund to confirm wiring, then ship.
