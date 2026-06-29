# Integrating Lemon Squeezy

A go-live runbook for selling and licensing termio through **Lemon Squeezy** — from
an empty account to a working **buy → emailed key → activate-on-this-Mac** flow.

termio has **no licensing backend of its own**. Lemon Squeezy is the Merchant of
Record: it hosts checkout, remits global sales tax / VAT, generates the license
keys, and validates activations. Everything below is configured in the Lemon
Squeezy dashboard plus two small code touchpoints in this repo.

> Read [`ARCHITECTURE.md`](./ARCHITECTURE.md) for how the pieces fit and
> [`PRICING.md`](./PRICING.md) for the pricing rationale. This file is the
> step-by-step "how do I actually wire it up".

## What you're wiring up

```
 landing "Buy" link ──▶ Lemon Squeezy checkout ──▶ buyer pays (LS handles card + tax)
                                                         │
                                          LS emails a license key + shows it on success page
                                                         │
 termio app: paste key ──▶ LS License API /activate ──▶ this Mac bound as one "instance"
 termio app on launch  ──▶ LS License API /validate ──▶ stays licensed (or drops if refunded)
```

The device cap (Solo = 1 Mac, Pro = 3 Macs) is the key's **activation limit**,
enforced by Lemon Squeezy — we don't count seats ourselves.

---

## Step 0 — Prerequisites

- A Lemon Squeezy account (sign up at <https://lemonsqueezy.com>). An individual
  works; you don't need a company entity (that's the point of using a MoR).
- Your payout details (Wise / PayPal / bank) and a tax/ID form — Lemon Squeezy
  walks you through these during onboarding before it will release funds.
- Do all of the steps below in **Test mode first** (toggle in the dashboard).
  Test mode has its own store data and API keys, and accepts the test card
  `4242 4242 4242 4242`. Switch to Live mode only once the full flow works.

---

## Step 1 — Create the store

1. Dashboard → create a **Store** (name it `termio`). Note the store's subdomain,
   e.g. `termio.lemonsqueezy.com` — your checkout URLs hang off it.
2. Set the store currency to **USD** (matches `pricing.json`).

---

## Step 2 — Create the two products with license keys

Create **two products** mirroring `web/docs/pricing.json` / `landing/src/data/pricing.ts`:

| Product | Price (one-time) | License activation limit |
|---------|------------------|--------------------------|
| termio Solo | **$19.90** | **1** |
| termio Pro  | **$39.90** | **3** |

For **each** product:

1. **Pricing model:** Single payment (one-time). Not a subscription.
2. **Enable license keys.** In the product/variant settings turn on
   *"Generate license keys for each purchase"*.
3. **Activation limit:** set to **1** for Solo, **3** for Pro. This is the device
   cap the app relies on.
4. **License length / expiration:** **never expires** — termio is a lifetime
   license. Leave the expiration off so keys don't lapse.
5. (Optional) Set the product name exactly to `termio Solo` / `termio Pro` and add
   the same feature copy as the pricing cards, for a consistent receipt.

> If you ever want a single product with two options instead of two products, use
> two **variants** — but two products keeps the checkout URLs and reporting
> simplest, and matches the two `id`s (`solo`, `pro`) the code uses.

---

## Step 3 — Wire the checkout URLs into the code

Each product has a **Share / checkout link** like
`https://termio.lemonsqueezy.com/buy/<variant-uuid>`. Copy both, then:

**Landing site** — `web/landing/src/lib/site.ts`:

```ts
export const checkoutUrls: Record<"solo" | "pro", string> = {
  solo: "https://termio.lemonsqueezy.com/buy/<SOLO-VARIANT-UUID>",
  pro:  "https://termio.lemonsqueezy.com/buy/<PRO-VARIANT-UUID>",
};
```

The Pricing section (`web/landing/src/components/sections/pricing.tsx`) already
reads these for its "Buy" buttons. (Appending `?embed=1` opens the Lemon.js
overlay instead of a new tab — only if you also add the Lemon.js script; a plain
link is fine to start.)

**Desktop app** — `Sources/termio/License.swift`, in `LicenseConfiguration`:

```swift
static let purchaseURLString = "https://termio.lemonsqueezy.com"  // your store URL
```

This is where the in-app "Buy termio…" button and the daily reminder send people.

That's the entire code change. The License API base
(`https://api.lemonsqueezy.com/v1/licenses`) is global and already set.

---

## Step 4 — Verify the desktop activation flow

The app already implements this (`Sources/termio/License.swift` +
the License tab in `SettingsView.swift`); you only need to test it end to end:

1. Buy a product in **Test mode** with card `4242 4242 4242 4242`.
2. Copy the license key from the confirmation email / success page.
3. In termio: **Settings ▸ License → paste the key → Activate**. It should flip to
   **Licensed** and show "1 of N devices".
4. The app calls these Lemon Squeezy **License API** endpoints (the license key is
   the credential — *no API key is sent*):
   - `POST /v1/licenses/activate` — `license_key`, `instance_name` (the Mac's name).
     Returns an `instance.id` the app stores.
   - `POST /v1/licenses/validate` — `license_key`, `instance_id`. Called on launch.
   - `POST /v1/licenses/deactivate` — frees this Mac's seat ("Deactivate on this Mac").
5. Test the cap: activate on more Macs than the limit — the extra one should fail
   with an activation-limit error (surfaced in the License tab).

Trial + reminder behavior (no Lemon Squeezy involvement): fresh installs get a
**7-day trial**; after it lapses with no valid key the app **stays fully usable**
and shows a **once-per-day** purchase reminder. It never locks.

---

## Step 5 — Giving away free keys

There is no "make a naked key" button — keys are always tied to an order. To gift
one, create a **100%-off discount code**:

1. Dashboard → **Discounts → New discount**.
2. Type **Percent**, amount **100**.
3. Restrict it to the termio product(s); set **max redemptions** (1 for a single
   gift, N for a giveaway) and an optional expiry.
4. Send the code. The recipient checks out at **$0** (no card needed) and Lemon
   Squeezy emails them a real, fully-tracked key with the normal activation limit.

To revoke a key later (abuse, etc.): **Store → Licenses → Disable key**. The next
`validate` then fails and the app drops back to the trial/expired state.

---

## Step 6 — Refunds

Honor the 30-day money-back guarantee from the dashboard: refunding an order
**automatically disables its license key**. The app's launch `validate` then sees a
non-active key and stops counting it as licensed — no work on our side, no webhook
needed.

---

## Step 7 — Sales & customer data (optional, via API)

For your own dashboards, create an **API key** (Settings → API) and call the main
API with `Authorization: Bearer <key>`:

- `GET /v1/stores` — `total_revenue` / `total_sales` / `thirty_day_revenue` for an
  at-a-glance total (this is **gross**; Lemon Squeezy's ~5% + fees and the tax it
  remits are not yours to keep).
- `GET /v1/orders`, `GET /v1/customers` — per-order / per-customer detail to
  aggregate however you like.
- `GET /v1/discount-redemptions` — who used which giveaway code.
- `POST /v1/discounts` — create discount codes programmatically (e.g. a future
  referral reward = auto-create a 100%-off code).

This is the **main** API (Bearer key required), distinct from the **License** API
in Step 4 (no key). Webhooks (`order_created`, `order_refunded`) are available if
you later want push notifications, but nothing in termio requires them today.

---

## Step 8 — Go live

1. Re-do Steps 1–3 in **Live mode** (test-mode products/keys don't carry over) — or
   confirm the products exist in Live and grab the **live** checkout URLs.
2. Put the **live** checkout URLs in `site.ts` and the store URL in `License.swift`.
3. Complete Lemon Squeezy's payout + tax onboarding so funds can be released.
4. Do one **real** purchase (you can refund yourself) to confirm: email arrives,
   key activates in the app, the cap holds, a refund disables the key.
5. Decide when to surface paid pricing publicly — the landing Pricing section is
   already two-tier and wired; deploy when ready.

---

## Code touchpoints (quick map)

| What | Where |
|------|-------|
| Checkout URLs (Buy buttons) | `web/landing/src/lib/site.ts` → `checkoutUrls` |
| Pricing cards | `web/landing/src/components/sections/pricing.tsx` |
| Tiers / prices / device caps | `web/landing/src/data/pricing.ts` + `web/docs/pricing.json` |
| Store / purchase URL, License API client, trial, daily reminder | `Sources/termio/License.swift` |
| License settings tab (paste key, activate, deactivate) | `Sources/termio/SettingsView.swift` |
| Launch validate + reminder wiring | `Sources/termio/App.swift` |

## Gotchas

- **Test vs Live are separate worlds.** Products, keys, discounts, and API keys do
  not cross over. Build in Test, then redo/confirm in Live.
- **Gross ≠ net.** API/dashboard revenue is before Lemon Squeezy's cut (~5% +
  payment fees) and the tax it remits. Read net from **Payouts**.
- **The activation limit is the device cap.** Don't try to enforce it in the app —
  Lemon Squeezy already does, and the app just reports what `validate` returns.
- **One activation = one instance.** Each `activate` consumes a seat and returns an
  `instance.id`; re-pasting the same key on the same Mac without deactivating first
  would consume another. The app stores the instance id so it validates the same
  one and offers "Deactivate on this Mac" to free it.
- **Trial enforcement is honest, not hardened.** The 7-day clock lives in
  `UserDefaults`; a determined user can reset it. That's an accepted trade for a
  local-only tool — matching how indie Mac apps in this category behave.

## References

- Lemon Squeezy licensing: <https://docs.lemonsqueezy.com/help/licensing>
- License API (activate / validate / deactivate): <https://docs.lemonsqueezy.com/api/license-api>
- Discounts API: <https://docs.lemonsqueezy.com/api/discounts>
- Main API reference: <https://docs.lemonsqueezy.com/api>
