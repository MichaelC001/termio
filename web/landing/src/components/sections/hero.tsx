import { buttonVariants } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import { Reveal } from "@/components/reveal";
import { TermioWindow } from "@/components/termio-window";
import { downloadUrl } from "@/lib/site";

export function Hero() {
  return (
    <section id="top" className="relative overflow-hidden">
      <div aria-hidden="true" className="brand-wash absolute inset-0 -z-10" />
      <div className="mx-auto w-full max-w-6xl px-5 pb-20 pt-16 sm:px-8 sm:pt-24">
        <div className="mx-auto max-w-3xl text-center">
          <Reveal>
            <p className="text-xs font-semibold uppercase tracking-[0.18em] text-muted-foreground">
              Native macOS · Apple Silicon
            </p>
          </Reveal>
          <Reveal delayMs={60}>
            <h1 className="mt-5 text-balance text-4xl font-semibold leading-[1.05] tracking-tight text-foreground sm:text-6xl">
              The terminal home for your{" "}
              <span className="brand-text-gradient">AI coding agents</span>
            </h1>
          </Reveal>
          <Reveal delayMs={120}>
            <p className="mx-auto mt-6 max-w-2xl text-pretty text-base leading-relaxed text-[#333333] sm:text-lg">
              Run every coding agent — Claude Code, Codex, Gemini, Amp and more —
              from one native app. Hosted sessions survive restarts, each agent
              works in its own git worktree, and nothing ever leaves your Mac.
            </p>
          </Reveal>
          <Reveal delayMs={180}>
            <div className="mt-9 flex flex-col items-center justify-center gap-3 sm:flex-row">
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
                href="#features"
                className={cn(
                  buttonVariants({ variant: "outline" }),
                  "h-12 rounded-full bg-card px-7 text-base",
                )}
              >
                See features
              </a>
            </div>
          </Reveal>
          <Reveal delayMs={240}>
            <p className="mt-5 text-sm text-muted-foreground">
              Available on macOS · Apple Silicon · 7-day trial, no account needed
            </p>
          </Reveal>
        </div>

        <Reveal delayMs={120} className="mt-16">
          <div className="mx-auto max-w-4xl">
            <TermioWindow />
          </div>
        </Reveal>
      </div>
    </section>
  );
}
