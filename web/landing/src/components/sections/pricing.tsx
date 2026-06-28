import { Check } from "lucide-react";
import { buttonVariants } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Reveal } from "@/components/reveal";
import { SectionLabel } from "@/components/section-label";
import { AppleMark } from "@/components/section-label";
import { cn } from "@/lib/utils";
import { downloadUrl } from "@/lib/site";

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

// v1 ships free: every feature, no account, no card. Paid lifetime licenses land
// in a later version — keep this section a single honest "free while it's early"
// panel rather than advertising tiers the checkout can't yet fulfil.
export function Pricing() {
  return (
    <section id="pricing" className="scroll-mt-20">
      <div className="mx-auto w-full max-w-6xl px-5 py-32 sm:py-40 sm:px-8">
        <Reveal className="flex justify-center">
          <SectionLabel accent="green">Pricing</SectionLabel>
        </Reveal>
        <Reveal delayMs={60}>
          <h2 className="mx-auto mt-5 max-w-2xl text-balance text-center text-4xl font-bold tracking-[-0.045em] text-foreground sm:text-5xl">
            Free while it&apos;s early.
          </h2>
        </Reveal>
        <Reveal delayMs={100}>
          <p className="mx-auto mt-4 max-w-xl text-center text-base text-muted-foreground">
            termio is free during early access — every feature unlocked, no
            account, no card. Download it and it updates itself.
          </p>
        </Reveal>

        <div className="mt-14 flex justify-center">
          <Reveal className="w-full max-w-md">
            <Card className="flex h-full flex-col gap-0 rounded-2xl border-border bg-card p-8 shadow-sm">
              <h3 className="text-lg font-semibold tracking-tight text-foreground">
                Early access
              </h3>
              <p className="mt-1 text-sm text-muted-foreground">
                The full app, free for now.
              </p>
              <div className="mt-6 flex items-baseline gap-1.5">
                <span className="text-4xl font-semibold tracking-tight text-foreground">
                  Free
                </span>
              </div>
              <a
                href={downloadUrl}
                className={cn(
                  buttonVariants(),
                  "mt-6 inline-flex h-11 w-full items-center justify-center gap-1.5 rounded-full",
                )}
              >
                <AppleMark className="h-3.5 w-3.5" />
                Download for Mac
              </a>
              <ul className="mt-7 space-y-3">
                <FeatureRow>Every feature, unlocked</FeatureRow>
                <FeatureRow>No account, no card</FeatureRow>
                <FeatureRow>Automatic updates built in</FeatureRow>
                <FeatureRow>Local-only — no telemetry, no cloud</FeatureRow>
              </ul>
            </Card>
          </Reveal>
        </div>

        <Reveal delayMs={120}>
          <p className="mt-8 text-center text-sm text-muted-foreground">
            macOS, Apple Silicon. Paid lifetime licenses arrive in a later
            release — early adopters keep the app.
          </p>
        </Reveal>
      </div>
    </section>
  );
}
