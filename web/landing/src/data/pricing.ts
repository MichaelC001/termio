// Mirrors web/docs/pricing.json — the pricing contract this landing page renders.
// termio is sold through Lemon Squeezy (Merchant of Record): it hosts checkout,
// remits global tax, and issues + validates the license keys. There is no
// self-hosted backend, so this typed copy and pricing.json are the only two places
// the numbers live; keep them in sync.

export type PricingPlan = {
  id: string;
  name: string;
  priceCents: number;
  // Original/list price, shown struck-through as a "was" anchor. Optional
  // because not every tier (e.g. Team) advertises a discount anchor.
  anchorPriceCents?: number;
  billing: "one-time";
  unit: string;
  maxDevices: number;
  recommended: boolean;
  audience: string;
  features: string[];
};

export type PricingTrial = {
  id: string;
  name: string;
  priceCents: number;
  durationDays: number;
  requiresAccount: boolean;
  blurb: string;
};

export type PricingRefund = {
  days: number;
  blurb: string;
};

export type Pricing = {
  model: "one-time-lifetime";
  currency: string;
  trial: PricingTrial;
  refund: PricingRefund;
  plans: PricingPlan[];
  lifetimeNote: string;
  platformNote: string;
};

export const pricing: Pricing = {
  model: "one-time-lifetime",
  currency: "USD",
  trial: {
    id: "trial",
    name: "Free Trial",
    priceCents: 0,
    durationDays: 7,
    requiresAccount: false,
    blurb: "Full app, every feature, 7 days. No account, no card.",
  },
  refund: {
    days: 30,
    blurb: "30-day money-back guarantee. No questions asked.",
  },
  plans: [
    {
      id: "solo",
      name: "Solo",
      priceCents: 1990,
      anchorPriceCents: 2900,
      billing: "one-time",
      unit: "per person",
      maxDevices: 1,
      recommended: false,
      audience: "For one Mac",
      features: [
        "Use on 1 Mac",
        "Every agent CLI — Claude Code, Codex, Gemini, Amp & more",
        "Sessions that survive restarts",
        "A git worktree per agent",
      ],
    },
    {
      id: "pro",
      name: "Pro",
      priceCents: 3990,
      anchorPriceCents: 5900,
      billing: "one-time",
      unit: "per person",
      maxDevices: 3,
      recommended: true,
      audience: "For up to 3 Macs",
      features: [
        "Everything in Solo",
        "Use on up to 3 Macs",
      ],
    },
  ],
  lifetimeNote:
    "One-time purchase. Yours forever, all updates included. No subscription, ever.",
  platformNote: "macOS, Apple Silicon.",
};

export function formatPrice(cents: number, currency = pricing.currency): string {
  const dollars = cents / 100;
  const hasFraction = !Number.isInteger(dollars);
  return new Intl.NumberFormat("en-US", {
    style: "currency",
    currency,
    minimumFractionDigits: hasFraction ? 2 : 0,
    maximumFractionDigits: 2,
  }).format(dollars);
}
