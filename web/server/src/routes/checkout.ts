import { randomUUID } from "node:crypto";

import { and, eq } from "drizzle-orm";
import { Hono } from "hono";
import type Stripe from "stripe";

import { database } from "../db/index.js";
import { price, product, purchase } from "../db/schema.js";
import { environment } from "../env.js";
import { issueLicense, revokeLicenseForPurchase } from "../licenses.js";
import { type AppEnv, currentUser, requireAuth } from "../middleware.js";
import { loadPricing } from "../pricing.js";
import { markReferralConverted } from "./referral.js";
import { stripe } from "../stripe.js";

export const checkoutRoutes = new Hono<AppEnv>();

interface CreateCheckoutBody {
  planId?: unknown;
  quantity?: unknown;
}

/**
 * Create a Stripe Checkout Session for a one-time, per-seat purchase.
 *
 * Validates the plan + seat count, records a `pending` purchase, and assembles the
 * Checkout params. When STRIPE_SECRET_KEY is set it creates a real session and
 * returns its URL; otherwise it returns the params so the wiring is reviewable
 * without live keys.
 *
 * Line items prefer the real Stripe Price id (price.stripePriceId, provisioned by
 * `pnpm stripe:setup`) for clean dashboard reporting and a reliable tax code,
 * falling back to inline price_data only when a plan has not been provisioned yet.
 */
checkoutRoutes.post("/session", requireAuth, async (context) => {
  const user = currentUser(context);
  const body = (await context.req.json().catch(() => ({}))) as CreateCheckoutBody;

  const planId = typeof body.planId === "string" ? body.planId : undefined;
  const quantity =
    typeof body.quantity === "number" && Number.isInteger(body.quantity)
      ? body.quantity
      : undefined;

  if (!planId || quantity === undefined) {
    return context.json(
      { error: "planId (string) and quantity (integer) are required" },
      400,
    );
  }

  const planRows = await database
    .select()
    .from(product)
    .where(eq(product.id, planId))
    .limit(1);
  const plan = planRows[0];
  if (!plan) {
    return context.json({ error: `Unknown plan '${planId}'` }, 404);
  }
  if (quantity < plan.minSeats) {
    return context.json(
      { error: `Plan '${planId}' requires at least ${plan.minSeats} seat(s)` },
      400,
    );
  }

  const priceRows = await database
    .select()
    .from(price)
    .where(eq(price.productId, planId))
    .limit(1);
  const seatPrice = priceRows[0];
  if (!seatPrice) {
    return context.json(
      { error: `No price configured for plan '${planId}' — run db:seed` },
      500,
    );
  }

  const amountCents = seatPrice.amountCents * quantity;
  const purchaseId = randomUUID();

  await database.insert(purchase).values({
    id: purchaseId,
    ownerUserId: user.id,
    productId: planId,
    seats: quantity,
    amountCents,
    currency: seatPrice.currency,
    status: "pending",
  });

  // Prefer the provisioned Stripe Price (carries its own tax code); only synthesize
  // inline price_data when this plan has not been run through `pnpm stripe:setup`.
  const lineItem: Stripe.Checkout.SessionCreateParams.LineItem = seatPrice
    .stripePriceId
    ? { price: seatPrice.stripePriceId, quantity }
    : {
        quantity,
        price_data: {
          currency: seatPrice.currency.toLowerCase(),
          unit_amount: seatPrice.amountCents,
          product_data: { name: `termio ${plan.name} — per seat` },
        },
      };

  // The webhook reconciles by this purchase id, so it must round-trip through
  // Stripe metadata.
  const sessionParams: Stripe.Checkout.SessionCreateParams = {
    mode: "payment",
    success_url: `${environment.webOrigin}/checkout/success?purchase=${purchaseId}`,
    cancel_url: `${environment.webOrigin}/pricing`,
    client_reference_id: purchaseId,
    customer_email: user.email,
    metadata: { purchaseId, planId, ownerUserId: user.id },
    line_items: [lineItem],
    // As Merchant of Record we must calculate + collect sales tax/VAT. Stripe Tax
    // computes it from the buyer's address and each Price's tax code; a billing
    // address is required for that calculation, and a Customer is always created so
    // the tax record, receipt, and any later refund resolve to a real Customer.
    automatic_tax: { enabled: true },
    billing_address_collection: "required",
    customer_creation: "always",
  };

  if (!stripe) {
    return context.json({
      stub: true,
      message: "STRIPE_SECRET_KEY not set — returning Checkout params only.",
      purchaseId,
      sessionParams,
    });
  }

  // Key on the purchase id so a retried request (network hiccup, double click)
  // reuses the same Checkout Session instead of creating a duplicate charge.
  const checkoutSession = await stripe.checkout.sessions.create(sessionParams, {
    idempotencyKey: purchaseId,
  });
  await database
    .update(purchase)
    .set({
      stripeCheckoutSessionId: checkoutSession.id,
      updatedAt: new Date(),
    })
    .where(eq(purchase.id, purchaseId));

  return context.json({ purchaseId, url: checkoutSession.url });
});

/**
 * Stripe webhook. Verifies the signature, then dispatches the exact events this
 * server handles (subscribe to only these in the dashboard):
 *   - checkout.session.completed → complete the purchase, mint the license
 *   - charge.refunded            → refund the purchase, revoke its license
 *   - checkout.session.expired   → mark an abandoned pending purchase
 *
 * Mounted on the raw body (see index.ts) because signature verification needs the
 * exact bytes Stripe sent — JSON parsing first would break it.
 */
checkoutRoutes.post("/webhook", async (context) => {
  if (!stripe || !environment.stripeWebhookSecret) {
    return context.json(
      { error: "Stripe webhook not configured (missing key or secret)" },
      503,
    );
  }

  const signature = context.req.header("stripe-signature");
  if (!signature) {
    return context.json({ error: "Missing stripe-signature header" }, 400);
  }

  const payload = await context.req.text();
  let event: Stripe.Event;
  try {
    event = stripe.webhooks.constructEvent(
      payload,
      signature,
      environment.stripeWebhookSecret,
    );
  } catch (error) {
    // A failed signature check is the one place we expect untrusted input; log
    // and reject rather than process a possibly-forged event.
    console.error("Stripe webhook signature verification failed:", error);
    return context.json({ error: "Invalid signature" }, 400);
  }

  switch (event.type) {
    case "checkout.session.completed":
      await fulfillCheckout(event.data.object);
      break;
    case "charge.refunded":
      // `charge.refunded` is Stripe's canonical event for a refunded charge (full
      // or partial); it fires whenever a refund is created/updated to a refunded
      // state. We treat any refund on the charge as voiding the license.
      await refundPurchase(event.data.object);
      break;
    case "checkout.session.expired":
      await expireCheckout(event.data.object);
      break;
    default:
      // Acknowledge unsubscribed event types so Stripe stops retrying; we only act
      // on the three above.
      break;
  }

  return context.json({ received: true });
});

/** Idempotently complete a purchase and mint its license. */
async function fulfillCheckout(
  session: Stripe.Checkout.Session,
): Promise<void> {
  const purchaseId = session.metadata?.purchaseId ?? session.client_reference_id;
  if (!purchaseId) {
    console.error("checkout.session.completed without a purchaseId reference");
    return;
  }

  const rows = await database
    .select()
    .from(purchase)
    .where(eq(purchase.id, purchaseId))
    .limit(1);
  const record = rows[0];
  if (!record) {
    console.error(`Webhook referenced unknown purchase ${purchaseId}`);
    return;
  }
  if (record.status === "completed") {
    return; // Stripe retries; never issue a second license for the same purchase.
  }

  const planRows = await database
    .select()
    .from(product)
    .where(eq(product.id, record.productId))
    .limit(1);
  const plan = planRows[0];
  if (!plan) {
    console.error(`Purchase ${purchaseId} references unknown product`);
    return;
  }

  // Open the money-back window now that payment has cleared. The clock runs from
  // fulfillment for the contract's refund.days.
  const refundDays = loadPricing().refund.days;
  const refundableUntil = new Date();
  refundableUntil.setDate(refundableUntil.getDate() + refundDays);

  await database
    .update(purchase)
    .set({
      status: "completed",
      refundableUntil,
      stripePaymentIntentId:
        typeof session.payment_intent === "string"
          ? session.payment_intent
          : (session.payment_intent?.id ?? null),
      // The Customer (customer_creation: "always") backs receipts/refunds/tax.
      stripeCustomerId:
        typeof session.customer === "string"
          ? session.customer
          : (session.customer?.id ?? null),
      updatedAt: new Date(),
    })
    .where(eq(purchase.id, purchaseId));

  await issueLicense({
    purchaseId,
    ownerUserId: record.ownerUserId,
    productId: record.productId,
    maxDevices: plan.maxDevices,
  });

  // Referral conversion: if this buyer was invited by someone, the paid purchase
  // converts their referral and may push the referrer up the reward ladder. Kept
  // here (not in /activate) because conversion is defined as the friend buying.
  await markReferralConverted(record.ownerUserId);
}

/**
 * Honour the 30-day money-back guarantee: when a charge is refunded, mark the
 * matching purchase `refunded` and revoke its license so it stops working and its
 * device seats are freed. Idempotent — an already-`refunded` purchase is a no-op,
 * so Stripe's retries (and partial-then-full refunds) never double-process.
 */
async function refundPurchase(charge: Stripe.Charge): Promise<void> {
  const paymentIntentId =
    typeof charge.payment_intent === "string"
      ? charge.payment_intent
      : (charge.payment_intent?.id ?? null);
  if (!paymentIntentId) {
    // Without a payment intent we cannot tie the refund back to a purchase; log
    // rather than silently drop it.
    console.error("charge.refunded without a payment_intent reference");
    return;
  }

  const rows = await database
    .select()
    .from(purchase)
    .where(eq(purchase.stripePaymentIntentId, paymentIntentId))
    .limit(1);
  const record = rows[0];
  if (!record) {
    console.error(
      `charge.refunded referenced unknown payment intent ${paymentIntentId}`,
    );
    return;
  }
  if (record.status === "refunded") {
    return; // Already handled; do not revoke twice.
  }

  await database
    .update(purchase)
    .set({ status: "refunded", updatedAt: new Date() })
    .where(eq(purchase.id, record.id));

  await revokeLicenseForPurchase(record.id);
}

/**
 * A Checkout Session expired before the buyer paid (Stripe's default 24h window).
 * Move the still-`pending` purchase to `expired` so abandoned carts are visible in
 * reporting and do not linger as if in-flight. Only `pending` is touched — a race
 * where completion landed first must never be downgraded.
 */
async function expireCheckout(session: Stripe.Checkout.Session): Promise<void> {
  const purchaseId = session.metadata?.purchaseId ?? session.client_reference_id;
  if (!purchaseId) {
    console.error("checkout.session.expired without a purchaseId reference");
    return;
  }

  await database
    .update(purchase)
    .set({ status: "expired", updatedAt: new Date() })
    .where(and(eq(purchase.id, purchaseId), eq(purchase.status, "pending")));
}
