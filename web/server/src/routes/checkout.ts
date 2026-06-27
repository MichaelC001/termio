import { randomUUID } from "node:crypto";

import { eq } from "drizzle-orm";
import { Hono } from "hono";
import type Stripe from "stripe";

import { database } from "../db/index.js";
import { price, product, purchase } from "../db/schema.js";
import { environment } from "../env.js";
import { issueLicense } from "../licenses.js";
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
 * This is a clearly-marked stub: it validates the plan + seat count, records a
 * `pending` purchase, and assembles the exact Checkout params. When STRIPE_SECRET_KEY
 * is set it creates a real session and returns its URL; otherwise it returns the
 * params so the wiring is reviewable without live keys.
 *
 * TODO(production): attach real Stripe Price ids (price.stripePriceId) instead of
 * inline price_data, and configure success/cancel URLs on WEB_ORIGIN.
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

  // The webhook reconciles by this purchase id, so it must round-trip through
  // Stripe metadata.
  const sessionParams: Stripe.Checkout.SessionCreateParams = {
    mode: "payment",
    success_url: `${environment.webOrigin}/checkout/success?purchase=${purchaseId}`,
    cancel_url: `${environment.webOrigin}/pricing`,
    client_reference_id: purchaseId,
    customer_email: user.email,
    metadata: { purchaseId, planId, ownerUserId: user.id },
    line_items: [
      {
        quantity,
        price_data: {
          currency: seatPrice.currency.toLowerCase(),
          unit_amount: seatPrice.amountCents,
          product_data: { name: `termio ${plan.name} — per seat` },
        },
      },
    ],
  };

  if (!stripe) {
    return context.json({
      stub: true,
      message: "STRIPE_SECRET_KEY not set — returning Checkout params only.",
      purchaseId,
      sessionParams,
    });
  }

  const checkoutSession = await stripe.checkout.sessions.create(sessionParams);
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
 * Stripe webhook. Verifies the signature, then on `checkout.session.completed`
 * marks the purchase completed and issues the license(s).
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

  if (event.type === "checkout.session.completed") {
    const session = event.data.object;
    await fulfillCheckout(session);
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
