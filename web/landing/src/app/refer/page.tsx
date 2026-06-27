import type { Metadata } from "next";
import { Gift, Link2, Share2, Sparkles } from "lucide-react";
import { SiteNav } from "@/components/site-nav";
import { SiteFooter } from "@/components/site-footer";
import { Reveal } from "@/components/reveal";
import { ReferralLinkPanel } from "@/components/referral-link-panel";
import { REFERRAL_LADDER, FRIEND_PERK } from "@/lib/referral";

export const metadata: Metadata = {
  title: "Refer friends, get termio free",
  description:
    "Refer friends who actually use termio and earn up to a free Pro license — one-time, no catch. Your friends get a 14-day trial plus $5 off.",
};

// Visual treatment per ladder rung, keyed by threshold so the brand accents
// stay tied to the reward rather than array order.
const ladderAccents: Record<number, string> = {
  1: "from-brand-green/15 to-transparent text-brand-green-deep",
  3: "from-brand-blue/15 to-transparent text-brand-blue-deep",
  5: "from-brand-purple/15 to-transparent text-brand-purple",
};

const howItWorks = [
  {
    icon: Share2,
    title: "Share your link",
    description:
      "Grab your personal referral link and send it to friends who'd get value from termio.",
  },
  {
    icon: Link2,
    title: "They install & run termio",
    description:
      "Your friend starts a 14-day trial with $5 off. Once they actually run termio, the referral activates.",
  },
  {
    icon: Gift,
    title: "You earn rewards",
    description:
      "Climb the ladder: one month free at 1 friend, a free Solo license at 3, a free Pro license at 5.",
  },
];

export default function ReferPage() {
  return (
    <>
      <SiteNav />
      <main className="flex-1">
        {/* Hero */}
        <section className="brand-wash border-b border-border">
          <div className="mx-auto w-full max-w-6xl px-5 py-20 text-center sm:px-8 sm:py-24">
            <Reveal>
              <p className="inline-flex items-center gap-2 rounded-full border border-border bg-card px-3 py-1.5 text-xs font-medium text-muted-foreground">
                <Sparkles className="h-3.5 w-3.5 text-brand-purple" aria-hidden="true" />
                Referral program
              </p>
            </Reveal>
            <Reveal delayMs={60}>
              <h1 className="mx-auto mt-6 max-w-3xl text-balance text-4xl font-semibold tracking-tight text-foreground sm:text-5xl">
                Give termio, <span className="brand-text-gradient">get termio free</span>.
              </h1>
            </Reveal>
            <Reveal delayMs={100}>
              <p className="mx-auto mt-5 max-w-2xl text-balance text-base text-[#333333] sm:text-lg">
                Refer friends who actually use termio and earn up to a free Pro
                license. One-time, no catch — your friends get a head start, you
                get rewarded for spreading a tool you already love.
              </p>
            </Reveal>
          </div>
        </section>

        {/* Reward ladder */}
        <section aria-labelledby="ladder-heading">
          <div className="mx-auto w-full max-w-6xl px-5 py-20 sm:px-8">
            <Reveal>
              <p className="text-center text-xs font-semibold uppercase tracking-[0.18em] text-muted-foreground">
                Reward ladder
              </p>
            </Reveal>
            <Reveal delayMs={60}>
              <h2
                id="ladder-heading"
                className="mx-auto mt-4 max-w-2xl text-balance text-center text-3xl font-semibold tracking-tight text-foreground sm:text-4xl"
              >
                Every friend moves you up a rung
              </h2>
            </Reveal>

            <ol className="mt-14 grid gap-6 md:grid-cols-3">
              {REFERRAL_LADDER.map((rung, index) => (
                <Reveal as="li" key={rung.threshold} delayMs={index * 90}>
                  <div className="relative h-full overflow-hidden rounded-2xl border border-border bg-card p-7 shadow-sm">
                    <div
                      className={`pointer-events-none absolute inset-0 bg-gradient-to-br ${
                        ladderAccents[rung.threshold] ?? "from-brand-blue/15 to-transparent"
                      }`}
                      aria-hidden="true"
                    />
                    <div className="relative">
                      <span
                        className={`brand-text-gradient font-mono text-3xl font-semibold`}
                      >
                        {rung.threshold} {rung.threshold === 1 ? "friend" : "friends"}
                      </span>
                      <h3 className="mt-4 text-lg font-semibold tracking-tight text-foreground">
                        {rung.reward}
                      </h3>
                      <p className="mt-2 text-sm leading-relaxed text-[#333333]">
                        {rung.threshold === 1
                          ? "Your first activated friend adds a month to your license, on us."
                          : rung.threshold === 3
                          ? "Three activated friends earns you a free Solo license outright."
                          : "Five activated friends unlocks a free Pro license — the whole thing."}
                      </p>
                    </div>
                  </div>
                </Reveal>
              ))}
            </ol>
          </div>
        </section>

        {/* Your link panel */}
        <section aria-labelledby="your-link-heading" className="border-y border-border bg-[#f9f9f9]">
          <div className="mx-auto w-full max-w-3xl px-5 py-20 sm:px-8">
            <Reveal>
              <h2
                id="your-link-heading"
                className="text-center text-3xl font-semibold tracking-tight text-foreground sm:text-4xl"
              >
                Your referral link
              </h2>
            </Reveal>
            <Reveal delayMs={80}>
              <div className="mt-10">
                <ReferralLinkPanel />
              </div>
            </Reveal>
          </div>
        </section>

        {/* How it works */}
        <section aria-labelledby="refer-how-heading">
          <div className="mx-auto w-full max-w-6xl px-5 py-20 sm:px-8">
            <Reveal>
              <p className="text-center text-xs font-semibold uppercase tracking-[0.18em] text-muted-foreground">
                How it works
              </p>
            </Reveal>
            <Reveal delayMs={60}>
              <h2
                id="refer-how-heading"
                className="mx-auto mt-4 max-w-2xl text-balance text-center text-3xl font-semibold tracking-tight text-foreground sm:text-4xl"
              >
                Three steps, one reward at a time
              </h2>
            </Reveal>

            <ol className="mt-14 grid gap-6 md:grid-cols-3">
              {howItWorks.map((step, index) => (
                <Reveal as="li" key={step.title} delayMs={index * 90}>
                  <div className="h-full rounded-2xl border border-border bg-card p-7 shadow-sm">
                    <span className="inline-flex h-11 w-11 items-center justify-center rounded-full bg-secondary">
                      <step.icon className="h-5 w-5 text-brand-blue-deep" aria-hidden="true" />
                    </span>
                    <h3 className="mt-4 text-lg font-semibold tracking-tight text-foreground">
                      {step.title}
                    </h3>
                    <p className="mt-2 text-sm leading-relaxed text-[#333333]">
                      {step.description}
                    </p>
                  </div>
                </Reveal>
              ))}
            </ol>

            <Reveal delayMs={120}>
              <div className="mx-auto mt-10 max-w-2xl rounded-2xl border border-border bg-card p-6 text-center shadow-sm">
                <p className="text-sm font-medium text-foreground">
                  Your friend gets {FRIEND_PERK.trialDays} days + ${FRIEND_PERK.discountUsd} off.
                </p>
                <p className="mt-3 text-xs leading-relaxed text-muted-foreground">
                  Joining the referral program is the one thing that turns on a
                  minimal activation signal; termio is otherwise local-only.
                </p>
              </div>
            </Reveal>
          </div>
        </section>
      </main>
      <SiteFooter />
    </>
  );
}
