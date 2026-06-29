import { Check } from "lucide-react";
import { buttonVariants } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Reveal } from "@/components/reveal";
import { SectionLabel } from "@/components/section-label";
import { cn } from "@/lib/utils";
import { pricing, formatPrice, type PricingPlan } from "@/data/pricing";
import { checkoutUrls } from "@/lib/site";

function FeatureRow({ children }: { children: React.ReactNode }) {
  return (
    <li className="flex items-start gap-2.5 text-sm text-muted-foreground">
      <Check
        className="mt-0.5 h-4 w-4 shrink-0 text-brand-green-deep"
        aria-hidden="true"
      />
      <span>{children}</span>
    </li>
  );
}

// Two one-time lifetime tiers, split by how many Macs the license covers. Selling
// and license-key issuance run on Lemon Squeezy (Merchant of Record): each "Buy"
// links to the matching hosted checkout in `checkoutUrls`. Pro is the highlighted,
// recommended anchor.
function PlanCard({ plan }: { plan: PricingPlan }) {
  const checkoutUrl = checkoutUrls[plan.id as keyof typeof checkoutUrls];

  return (
    <Card
      className={cn(
        "relative flex flex-col gap-0 overflow-visible rounded-2xl p-8 shadow-sm",
        plan.recommended
          ? "border-brand-green-deep/40 ring-1 ring-brand-green-deep/30"
          : "border-border bg-card",
      )}
    >
      {plan.recommended ? (
        <span className="absolute -top-3 left-8 rounded-full bg-brand-green-deep px-3 py-1 text-xs font-medium text-white">
          Recommended
        </span>
      ) : null}

      <h3 className="text-lg font-semibold tracking-tight text-foreground">
        {plan.name}
      </h3>
      <p className="mt-1 text-sm text-muted-foreground">{plan.audience}</p>

      <div className="mt-6 flex items-baseline gap-2">
        <span className="text-4xl font-semibold tracking-tight text-foreground">
          {formatPrice(plan.priceCents)}
        </span>
        {plan.anchorPriceCents ? (
          <span className="text-base text-muted-foreground line-through">
            {formatPrice(plan.anchorPriceCents)}
          </span>
        ) : null}
        <span className="text-sm text-muted-foreground">once</span>
      </div>

      <ul className="mt-7 space-y-3">
        {plan.features.map((feature) => (
          <FeatureRow key={feature}>{feature}</FeatureRow>
        ))}
      </ul>

      <a
        href={checkoutUrl}
        className={cn(
          buttonVariants({ variant: plan.recommended ? "default" : "outline" }),
          "mt-8 inline-flex h-11 w-full items-center justify-center rounded-full",
        )}
      >
        Buy {plan.name}
      </a>
    </Card>
  );
}

export function Pricing() {
  return (
    <section id="pricing" className="scroll-mt-20">
      <div className="mx-auto w-full max-w-6xl px-5 py-32 sm:py-40 sm:px-8">
        <Reveal className="flex justify-center">
          <SectionLabel accent="green">Pricing</SectionLabel>
        </Reveal>
        <Reveal delayMs={60}>
          <h2 className="mx-auto mt-4 max-w-2xl text-balance text-center text-4xl font-bold tracking-[-0.045em] text-foreground sm:text-5xl">
            Pay once. Yours forever.
          </h2>
        </Reveal>
        <Reveal delayMs={100}>
          <p className="mx-auto mt-4 max-w-xl text-center text-base text-muted-foreground">
            A one-time lifetime license — no subscription, no renewal, all future
            updates included. Try it free for {pricing.trial.durationDays} days, no
            account, no card.
          </p>
        </Reveal>

        <div className="mx-auto mt-14 grid w-full max-w-3xl items-start gap-6 sm:grid-cols-2">
          {pricing.plans.map((plan, index) => (
            <Reveal key={plan.id} delayMs={120 + index * 60}>
              <PlanCard plan={plan} />
            </Reveal>
          ))}
        </div>

        <Reveal delayMs={260}>
          <p className="mt-8 text-center text-sm text-muted-foreground">
            {pricing.platformNote} {pricing.refund.blurb}
          </p>
        </Reveal>
      </div>
    </section>
  );
}
