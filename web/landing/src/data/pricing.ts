// Mirrors web/docs/pricing.json — the shared pricing contract that is the single
// source of truth for both this landing page and the web/server backend. The
// displayed numbers must always match that file; keep this typed copy in sync.

export type PricingPlan = {
  id: string;
  name: string;
  priceCents: number;
  // Original/list price, shown struck-through as a "was" anchor. Optional
  // because not every tier (e.g. Team) advertises a discount anchor.
  anchorPriceCents?: number;
  billing: "one-time";
  unit: string;
  minSeats?: number;
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
        "Pay once — yours forever, no subscription",
        "All future updates included",
        "Use on 1 Mac",
        "Every agent CLI (Claude Code, Codex, Gemini, Amp, more)",
        "Hosted-PTY sessions that survive restarts",
        "Git worktree per agent",
        "Local-only — no telemetry, no cloud",
        "30-day money-back guarantee",
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
        "Use on up to 3 of your Macs",
        "Pay once — yours forever, no subscription",
        "All future updates included",
        "Every agent CLI (Claude Code, Codex, Gemini, Amp, more)",
        "Hosted-PTY sessions that survive restarts",
        "Git worktree per agent",
        "Local-only — no telemetry, no cloud",
        "30-day money-back guarantee",
      ],
    },
    {
      id: "team",
      name: "Team",
      priceCents: 3990,
      billing: "one-time",
      unit: "per seat",
      minSeats: 5,
      maxDevices: 3,
      recommended: false,
      audience: "For teams of 5+",
      features: [
        "Everything in Pro, on up to 3 Macs per seat",
        "For teams of 5 or more",
        "Centralized license + seat management",
        "Priority support",
        "Single invoice / PO billing",
        "Custom volume pricing for 50+ — talk to us",
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
