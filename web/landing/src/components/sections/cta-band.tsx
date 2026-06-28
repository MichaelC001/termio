import { buttonVariants } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import { Reveal } from "@/components/reveal";
import { AppleMark } from "@/components/section-label";
import { downloadUrl } from "@/lib/site";

export function CtaBand() {
  return (
    <section aria-labelledby="cta-heading">
      <div className="mx-auto w-full max-w-6xl px-5 py-32 sm:py-40 sm:px-8">
        <Reveal>
          <div className="brand-wash shadow-soft relative overflow-hidden rounded-[2rem] border border-border bg-card px-8 py-20 text-center sm:px-16">
            <h2
              id="cta-heading"
              className="mx-auto max-w-2xl text-balance text-4xl font-bold tracking-[-0.045em] text-foreground sm:text-5xl"
            >
              Stop babysitting terminals
            </h2>
            <p className="mx-auto mt-5 max-w-xl text-lg text-muted-foreground">
              Launch every agent, walk away, come back to finished work. Free for
              seven days — no account, no card.
            </p>
            <div className="mt-9 flex flex-col items-center justify-center gap-3 sm:flex-row">
              <a
                href={downloadUrl}
                className={cn(
                  buttonVariants(),
                  "h-12 gap-2 rounded-full px-7 text-base",
                )}
              >
                <AppleMark />
                Download for Mac
              </a>
              <a
                href="#pricing"
                className={cn(
                  buttonVariants({ variant: "outline" }),
                  "h-12 rounded-full bg-card px-7 text-base",
                )}
              >
                See pricing
              </a>
            </div>
            <p className="mt-5 text-sm text-muted-foreground">
              macOS · Apple Silicon · Local-only, no telemetry
            </p>
          </div>
        </Reveal>
      </div>
    </section>
  );
}
