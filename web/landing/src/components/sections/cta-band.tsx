import { buttonVariants } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import { Reveal } from "@/components/reveal";
import { downloadUrl } from "@/lib/site";

export function CtaBand() {
  return (
    <section aria-labelledby="cta-heading">
      <div className="mx-auto w-full max-w-6xl px-5 py-24 sm:px-8">
        <Reveal>
          <div className="brand-wash relative overflow-hidden rounded-3xl border border-border bg-card px-8 py-16 text-center shadow-sm sm:px-16">
            <h2
              id="cta-heading"
              className="mx-auto max-w-2xl text-balance text-3xl font-semibold tracking-tight text-foreground sm:text-4xl"
            >
              Give your coding agents a home
            </h2>
            <p className="mx-auto mt-4 max-w-xl text-base text-[#333333]">
              Run every agent, never lose a session. Try termio free for seven
              days — no account, no card.
            </p>
            <div className="mt-8 flex flex-col items-center justify-center gap-3 sm:flex-row">
              <a
                href={downloadUrl}
                className={cn(
                  buttonVariants(),
                  "h-12 rounded-full px-7 text-base",
                )}
              >
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
