import { buttonVariants } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import { Reveal } from "@/components/reveal";
import { TermioWindow } from "@/components/termio-window";
import { AppleMark } from "@/components/section-label";
import { HeroGradient } from "@/components/hero-gradient";
import { downloadUrl } from "@/lib/site";

export function Hero() {
  return (
    <section
      id="top"
      className="hero-cinematic relative isolate flex min-h-screen flex-col overflow-hidden"
    >
      <HeroGradient className="absolute inset-0 -z-10" />
      <div
        aria-hidden="true"
        className="pointer-events-none absolute inset-x-0 bottom-0 -z-10 h-72 bg-gradient-to-b from-transparent to-background"
      />
      <div className="relative mx-auto flex w-full max-w-6xl flex-1 flex-col items-center justify-center px-5 pb-20 pt-36 text-center sm:px-8 sm:pt-40">
        <Reveal delayMs={40}>
          <h1 className="text-balance text-6xl font-bold leading-[0.9] tracking-[-0.05em] text-white drop-shadow-[0_2px_40px_rgba(0,0,0,0.45)] sm:text-[7rem]">
            Run every agent.
            <br />
            Lose nothing.
          </h1>
        </Reveal>
        <Reveal delayMs={120}>
          <p className="mx-auto mt-8 max-w-xl text-pretty text-lg leading-relaxed text-white/75 sm:text-xl">
            Claude Code, Codex, Gemini, Amp and more — every coding agent in one
            native Mac app. Sessions survive restarts, each agent works in its own
            git worktree, and nothing ever leaves your machine.
          </p>
        </Reveal>
        <Reveal delayMs={200}>
          <div className="mt-10 flex flex-col items-center justify-center gap-3 sm:flex-row">
            <a
              href={downloadUrl}
              className={cn(
                buttonVariants(),
                "h-12 gap-2 rounded-full px-7 text-base shadow-lg shadow-black/30",
              )}
            >
              <AppleMark />
              Download for Mac
            </a>
            <a
              href="#features"
              className={cn(
                buttonVariants({ variant: "outline" }),
                "h-12 rounded-full border-white/15 bg-white/5 px-7 text-base text-white backdrop-blur-md hover:bg-white/10",
              )}
            >
              See how it works
            </a>
          </div>
        </Reveal>
        <Reveal delayMs={260}>
          <p className="mt-6 text-sm text-white/50">
            Free during early access · No account needed · Local-only, no telemetry
          </p>
        </Reveal>

        <Reveal delayMs={160} className="mt-auto w-full pt-20">
          <div className="mx-auto max-w-5xl [perspective:2400px]">
            <div className="origin-bottom [transform:rotateX(7deg)]">
              <TermioWindow />
            </div>
          </div>
        </Reveal>
      </div>
    </section>
  );
}
