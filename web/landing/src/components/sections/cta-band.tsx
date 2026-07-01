import { buttonVariants } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import { Reveal } from "@/components/reveal";
import { AppleMark } from "@/components/section-label";
import { CtaDither } from "@/components/cta-dither";
import { downloadUrl } from "@/lib/site";

export function CtaBand() {
  return (
    <section aria-labelledby="cta-heading">
      <div className="mx-auto w-full max-w-6xl px-5 py-32 sm:py-40 sm:px-8">
        <Reveal>
          <div className="brand-wash shadow-soft relative isolate overflow-hidden rounded-[2rem] border border-white/10 bg-card px-8 py-20 text-center sm:px-16">
            {/* Frozen 1-bit dither texture, masked to bloom behind the heading. */}
            <div
              aria-hidden="true"
              className="pointer-events-none absolute inset-0 -z-10 opacity-90 [mask-image:radial-gradient(70%_65%_at_50%_38%,#000_0%,transparent_78%)]"
            >
              <CtaDither />
            </div>
            <h2
              id="cta-heading"
              className="mx-auto max-w-2xl text-balance text-4xl font-semibold tracking-[-0.045em] text-foreground sm:text-5xl"
            >
              Stop babysitting terminals
            </h2>
            <p className="mx-auto mt-5 max-w-xl text-lg text-muted-foreground">
              Run Claude Code, Codex, OpenCode, Pi Agent and more side by side in
              one native
              window. Free to use — no account, no card.
            </p>
            <div className="mt-9 flex flex-col items-center justify-center gap-3 sm:flex-row">
              <a
                href={downloadUrl}
                className={cn(
                  buttonVariants(),
                  "h-12 gap-2 rounded-full px-7 text-base",
                  "shadow-[0_12px_32px_rgba(20,23,28,0.18),0_0_0_1px_rgba(0,211,199,0.14)]",
                )}
              >
                <AppleMark />
                Download for Mac
              </a>
            </div>
          </div>
        </Reveal>
      </div>
    </section>
  );
}
