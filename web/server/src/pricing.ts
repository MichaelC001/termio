import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

/**
 * Shape of web/docs/pricing.json — the shared single source of truth between the
 * landing page and this backend. We re-declare the types here (rather than import
 * the JSON as a module) so this server stays self-contained and the file can live
 * outside the TypeScript rootDir.
 */
export interface PricingPlan {
  id: string;
  name: string;
  priceCents: number;
  /** Struck-through "was" price shown for contrast; not every plan sets one. */
  anchorPriceCents?: number;
  billing: "one-time";
  unit: string;
  minSeats?: number;
  /** How many of the buyer's Macs one purchased seat may be activated on. */
  maxDevices: number;
  recommended: boolean;
  audience: string;
  features: string[];
}

export interface PricingContract {
  model: string;
  currency: string;
  trial: {
    id: string;
    name: string;
    priceCents: number;
    durationDays: number;
    requiresAccount: boolean;
    blurb: string;
  };
  /** Money-back window; `days` also seeds each purchase's refundableUntil. */
  refund: {
    days: number;
    blurb: string;
  };
  plans: PricingPlan[];
  lifetimeNote: string;
  platformNote: string;
}

/**
 * Resolve web/docs/pricing.json relative to this module. Works both from src/
 * (via tsx) and from the compiled dist/, since both sit one level under
 * web/server/.
 */
const pricingPath = fileURLToPath(
  new URL("../../docs/pricing.json", import.meta.url),
);

export function loadPricing(): PricingContract {
  const raw = readFileSync(pricingPath, "utf8");
  const parsed = JSON.parse(raw) as PricingContract;

  // Fail loudly if the shared contract drifts from the shape this server relies
  // on, rather than letting an undefined field surface as a NOT NULL violation
  // deep inside a seed or a checkout webhook.
  if (!parsed.refund || typeof parsed.refund.days !== "number") {
    throw new Error("pricing.json is missing a numeric refund.days");
  }
  if (!Array.isArray(parsed.plans) || parsed.plans.length === 0) {
    throw new Error("pricing.json has no plans");
  }
  for (const plan of parsed.plans) {
    if (typeof plan.priceCents !== "number" || typeof plan.maxDevices !== "number") {
      throw new Error(
        `pricing.json plan '${plan.id}' must set numeric priceCents and maxDevices`,
      );
    }
  }

  return parsed;
}
