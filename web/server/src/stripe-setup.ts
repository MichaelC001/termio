import { eq } from "drizzle-orm";

import { database } from "./db/index.js";
import { price, product } from "./db/schema.js";
import { loadPricing } from "./pricing.js";
import { stripe } from "./stripe.js";

/**
 * One-shot provisioning: turn the seeded plans into real Stripe Products + one-time
 * Prices, then write the resulting ids back onto our `product`/`price` rows so
 * checkout can build line_items from a real Price id (clean reporting + reliable
 * tax code). Run AFTER `pnpm db:migrate && pnpm db:seed`, and re-run safely any
 * time — every step is idempotent (search by metadata / lookup_key before create).
 */

/**
 * Stripe product tax code applied to every plan so Stripe Tax can compute the
 * correct rate per jurisdiction. termio ships as downloadable macOS software sold
 * under a one-time license, so the "downloadable software (non-customizable)"
 * category fits. As Merchant of Record you own this classification — confirm the
 * exact code against Stripe's product-tax-code list in the dashboard and adjust if
 * your tax advisor recommends a different category.
 */
const PRODUCT_TAX_CODE = "txcd_10202003";

/** Stable lookup key per plan so re-runs find the existing Price instead of duplicating. */
function lookupKeyFor(planId: string): string {
  return `termio_${planId}_seat`;
}

async function provision(): Promise<void> {
  if (!stripe) {
    // No key means we cannot talk to Stripe at all; exit non-zero so a CI/setup
    // step fails loudly rather than appearing to succeed.
    console.error(
      "STRIPE_SECRET_KEY is not set. Set it (sk_test_… first) and re-run `pnpm stripe:setup`.",
    );
    process.exit(1);
  }

  const pricing = loadPricing();
  const summary: Array<{
    plan: string;
    stripeProductId: string;
    stripePriceId: string;
    reusedPrice: boolean;
  }> = [];

  for (const plan of pricing.plans) {
    // --- Product: reuse the one tagged with this plan id, else create it. ---
    const foundProducts = await stripe.products.search({
      query: `metadata['termioPlanId']:'${plan.id}'`,
    });

    const productName = `termio ${plan.name}`;
    let stripeProductId: string;
    const existingProduct = foundProducts.data[0];
    if (existingProduct) {
      // Keep name + tax code in sync without creating a duplicate.
      await stripe.products.update(existingProduct.id, {
        name: productName,
        tax_code: PRODUCT_TAX_CODE,
      });
      stripeProductId = existingProduct.id;
    } else {
      const created = await stripe.products.create({
        name: productName,
        tax_code: PRODUCT_TAX_CODE,
        metadata: { termioPlanId: plan.id },
      });
      stripeProductId = created.id;
    }

    // --- Price: a Stripe Price amount is immutable, so reuse only when it already
    // matches; otherwise mint a new Price and move the lookup key onto it. ---
    const lookupKey = lookupKeyFor(plan.id);
    const currency = pricing.currency.toLowerCase();
    const existingPrices = await stripe.prices.list({
      lookup_keys: [lookupKey],
      active: true,
      limit: 1,
    });

    const existingPrice = existingPrices.data[0];
    let stripePriceId: string;
    let reusedPrice: boolean;
    if (
      existingPrice &&
      existingPrice.unit_amount === plan.priceCents &&
      existingPrice.currency === currency &&
      existingPrice.product === stripeProductId
    ) {
      stripePriceId = existingPrice.id;
      reusedPrice = true;
    } else {
      const createdPrice = await stripe.prices.create({
        product: stripeProductId,
        currency,
        unit_amount: plan.priceCents,
        lookup_key: lookupKey,
        // Move the lookup key off any stale price so this becomes the canonical one.
        transfer_lookup_key: existingPrice !== undefined,
        // US Merchant-of-Record convention: list price is tax-exclusive (tax added
        // on top at checkout). Switch to "inclusive" only if you advertise tax-in.
        tax_behavior: "exclusive",
        metadata: { termioPlanId: plan.id },
      });
      stripePriceId = createdPrice.id;
      reusedPrice = false;

      // Deactivate the superseded price so it stops appearing as a live option.
      if (existingPrice) {
        await stripe.prices.update(existingPrice.id, { active: false });
      }
    }

    // --- Write the ids back so checkout uses the real Price. ---
    await database
      .update(product)
      .set({ stripeProductId, updatedAt: new Date() })
      .where(eq(product.id, plan.id));
    await database
      .update(price)
      .set({ stripePriceId })
      .where(eq(price.productId, plan.id));

    summary.push({ plan: plan.id, stripeProductId, stripePriceId, reusedPrice });
  }

  console.log("Stripe provisioning complete:");
  for (const row of summary) {
    console.log(
      `  ${row.plan}: product ${row.stripeProductId}, price ${row.stripePriceId}` +
        ` (${row.reusedPrice ? "reused" : "created"})`,
    );
  }
}

provision()
  .then(() => process.exit(0))
  .catch((error: unknown) => {
    console.error("Stripe provisioning failed:", error);
    process.exit(1);
  });
