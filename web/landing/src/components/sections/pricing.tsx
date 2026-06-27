import { Check, ShieldCheck } from "lucide-react";
import { buttonVariants } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Reveal } from "@/components/reveal";
import { cn } from "@/lib/utils";
import { pricing, formatPrice } from "@/data/pricing";
import { downloadUrl, checkoutSessionUrl } from "@/lib/site";

const { trial, plans, refund, lifetimeNote, platformNote } = pricing;

// Human-readable device allowance shown under each tier's price.
function deviceLabel(maxDevices: number): string {
  return maxDevices === 1 ? "1 Mac" : `up to ${maxDevices} Macs`;
}

function FeatureRow({ children }: { children: React.ReactNode }) {
  return (
    <li className="flex items-start gap-2.5 text-sm text-[#333333]">
      <Check
        className="mt-0.5 h-4 w-4 shrink-0 text-brand-green-deep"
        aria-hidden="true"
      />
      <span>{children}</span>
    </li>
  );
}

export function Pricing() {
  return (
    <section id="pricing" className="scroll-mt-20">
      <div className="mx-auto w-full max-w-6xl px-5 py-24 sm:px-8">
        <Reveal>
          <p className="text-center text-xs font-semibold uppercase tracking-[0.18em] text-muted-foreground">
            Pricing
          </p>
        </Reveal>
        <Reveal delayMs={60}>
          <h2 className="mx-auto mt-4 max-w-2xl text-balance text-center text-3xl font-semibold tracking-tight text-foreground sm:text-4xl">
            Buy it once. It&apos;s yours.
          </h2>
        </Reveal>
        <Reveal delayMs={100}>
          <p className="mx-auto mt-4 max-w-xl text-center text-base text-[#333333]">
            {lifetimeNote}
          </p>
        </Reveal>
        <Reveal delayMs={130}>
          <p className="mx-auto mt-4 flex items-center justify-center gap-2 text-sm font-medium text-brand-green-deep">
            <ShieldCheck className="h-4 w-4 shrink-0" aria-hidden="true" />
            {refund.blurb}
          </p>
        </Reveal>

        <div className="mt-14 grid items-stretch gap-5 lg:grid-cols-3">
          {/* Free trial */}
          <Reveal>
            <Card className="flex h-full flex-col gap-0 rounded-2xl border-border bg-card p-7 shadow-sm">
              <h3 className="text-lg font-semibold tracking-tight text-foreground">
                {trial.name}
              </h3>
              <p className="mt-1 text-sm text-muted-foreground">{trial.blurb}</p>
              <div className="mt-6 flex items-baseline gap-1.5">
                <span className="text-4xl font-semibold tracking-tight text-foreground">
                  {formatPrice(trial.priceCents)}
                </span>
                <span className="text-sm text-muted-foreground">
                  for {trial.durationDays} days
                </span>
              </div>
              <a
                href={downloadUrl}
                className={cn(
                  buttonVariants({ variant: "outline" }),
                  "mt-6 h-11 w-full rounded-full",
                )}
              >
                Download for Mac
              </a>
              <ul className="mt-7 space-y-3">
                <FeatureRow>Every feature, unlocked</FeatureRow>
                <FeatureRow>No account, no card</FeatureRow>
                <FeatureRow>Turns into a license when you buy</FeatureRow>
              </ul>
            </Card>
          </Reveal>

          {/* Paid plans */}
          {plans.map((plan, index) => (
            <Reveal key={plan.id} delayMs={(index + 1) * 70}>
              <Card
                className={cn(
                  "relative flex h-full flex-col gap-0 rounded-2xl p-7 shadow-sm",
                  plan.recommended
                    ? "border-transparent bg-card ring-2 ring-brand-blue"
                    : "border-border bg-card",
                )}
              >
                <div className="flex items-center justify-between">
                  <h3 className="text-lg font-semibold tracking-tight text-foreground">
                    {plan.name}
                  </h3>
                  {plan.recommended ? (
                    <Badge className="rounded-full border-transparent bg-brand-blue text-white">
                      Recommended
                    </Badge>
                  ) : null}
                </div>
                <p className="mt-1 text-sm text-muted-foreground">
                  {plan.audience}
                </p>
                <div className="mt-6 flex items-baseline gap-2">
                  <span className="text-4xl font-semibold tracking-tight text-foreground">
                    {formatPrice(plan.priceCents)}
                  </span>
                  {plan.anchorPriceCents ? (
                    <span
                      className="text-lg font-medium text-muted-foreground line-through"
                      aria-label={`was ${formatPrice(plan.anchorPriceCents)}`}
                    >
                      {formatPrice(plan.anchorPriceCents)}
                    </span>
                  ) : null}
                  <span className="text-sm text-muted-foreground">
                    {plan.unit}
                  </span>
                </div>
                <p className="mt-1 text-xs text-muted-foreground">
                  {plan.minSeats ? `From ${plan.minSeats} seats · ` : ""}
                  One-time purchase. No subscription · {deviceLabel(plan.maxDevices)}
                </p>
                {/* TODO: wire to the real authenticated checkout. The backend's
                    POST /api/checkout/session needs a signed-in session +
                    { planId, quantity }; this link is a placeholder that points
                    at that endpoint via checkoutSessionUrl. */}
                <a
                  href={`${checkoutSessionUrl}?plan=${plan.id}`}
                  className={cn(
                    buttonVariants(),
                    "mt-6 h-11 w-full rounded-full",
                    !plan.recommended &&
                      "bg-secondary text-foreground hover:bg-secondary/80",
                  )}
                >
                  Buy license
                </a>
                <ul className="mt-7 space-y-3">
                  {plan.features.map((feature) => (
                    <FeatureRow key={feature}>{feature}</FeatureRow>
                  ))}
                </ul>
              </Card>
            </Reveal>
          ))}
        </div>

        <Reveal delayMs={120}>
          <p className="mt-8 text-center text-sm text-muted-foreground">
            {platformNote} One-time purchase, no subscription — yours forever
            with every future update.
          </p>
        </Reveal>
      </div>
    </section>
  );
}
