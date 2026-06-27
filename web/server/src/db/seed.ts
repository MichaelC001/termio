import { database } from "./index.js";
import { price, product } from "./schema.js";
import { loadPricing } from "../pricing.js";

/**
 * Idempotently upsert the catalog from pricing.json. Safe to run repeatedly:
 * products key on their stable plan id, and each plan's per-seat price keys on a
 * derived id so re-seeding updates amounts rather than duplicating rows.
 */
async function seed(): Promise<void> {
  const pricing = loadPricing();

  for (const plan of pricing.plans) {
    await database
      .insert(product)
      .values({
        id: plan.id,
        name: plan.name,
        billing: plan.billing,
        unit: plan.unit,
        minSeats: plan.minSeats ?? 1,
        maxDevices: plan.maxDevices,
        recommended: plan.recommended,
        audience: plan.audience,
        updatedAt: new Date(),
      })
      .onConflictDoUpdate({
        target: product.id,
        set: {
          name: plan.name,
          billing: plan.billing,
          unit: plan.unit,
          minSeats: plan.minSeats ?? 1,
          maxDevices: plan.maxDevices,
          recommended: plan.recommended,
          audience: plan.audience,
          updatedAt: new Date(),
        },
      });

    const priceId = `${plan.id}-seat`;
    await database
      .insert(price)
      .values({
        id: priceId,
        productId: plan.id,
        currency: pricing.currency,
        amountCents: plan.priceCents,
        active: true,
      })
      .onConflictDoUpdate({
        target: price.id,
        set: {
          currency: pricing.currency,
          amountCents: plan.priceCents,
          active: true,
        },
      });

    console.log(
      `Seeded ${plan.id}: ${plan.name} — ${plan.priceCents} ${pricing.currency} ${plan.unit}`,
    );
  }
}

seed()
  .then(() => {
    console.log("Seed complete.");
    process.exit(0);
  })
  .catch((error: unknown) => {
    console.error("Seed failed:", error);
    process.exit(1);
  });
