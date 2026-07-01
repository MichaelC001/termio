import Image from "next/image";
import { buttonVariants } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import { Reveal } from "@/components/reveal";
import { TermioWindow } from "@/components/termio-window";
import { AppleMark } from "@/components/section-label";
import { HeroGradient } from "@/components/hero-gradient";
import { downloadUrl, heroScreenshot } from "@/lib/site";

export function Hero() {
  return (
    <section
      id="top"
      className="hero-cinematic relative isolate flex min-h-screen flex-col overflow-hidden"
    >
      <HeroGradient className="absolute inset-0 -z-10" />
      <div
        aria-hidden="true"
        className="grain-overlay pointer-events-none absolute -inset-[6%] -z-10"
      />
      <div
        aria-hidden="true"
        className="pointer-events-none absolute inset-x-0 bottom-0 -z-10 h-72 bg-gradient-to-b from-transparent to-background"
      />
      <div className="relative mx-auto flex w-full max-w-6xl flex-1 flex-col items-center justify-center px-5 pb-20 pt-36 text-center sm:px-8 sm:pt-40">
        <Reveal delayMs={40}>
          <h1 className="text-balance text-6xl font-semibold leading-[0.9] tracking-[-0.05em] text-foreground sm:text-[7rem]">
            Run every agent.
            <br />
            Side by side.
          </h1>
        </Reveal>
        <Reveal delayMs={120}>
          <p className="mx-auto mt-8 max-w-xl text-pretty text-lg leading-relaxed text-muted-foreground sm:text-xl">
            A native Mac workspace for your AI coding agents — Claude Code, Codex,
            Gemini, Amp and more. Each gets a real terminal, you switch between
            them instantly, and nothing ever leaves your machine.
          </p>
        </Reveal>
        <Reveal delayMs={200}>
          <div className="mt-10 flex flex-col items-center justify-center gap-3 sm:flex-row">
            <a
              href={downloadUrl}
              className={cn(
                buttonVariants(),
                "h-12 gap-2 rounded-full px-7 text-base shadow-[0_6px_20px_-6px_rgba(0,113,227,0.5)]",
              )}
            >
              <AppleMark />
              Download for Mac
            </a>
            <a
              href="#features"
              className={cn(
                buttonVariants({ variant: "outline" }),
                "h-12 rounded-full px-7 text-base",
              )}
            >
              See features
            </a>
          </div>
        </Reveal>
        <Reveal delayMs={260}>
          <p className="mt-6 text-sm text-muted-foreground">
            Free to use · No account needed · Local-only, no telemetry
          </p>
        </Reveal>

        <Reveal delayMs={160} className="mt-auto w-full pt-20">
          <div className="mx-auto max-w-5xl [perspective:2400px]">
            <div className="origin-bottom [transform:rotateX(7deg)]">
              {heroScreenshot ? (
                <Image
                  src={heroScreenshot.src}
                  width={heroScreenshot.width}
                  height={heroScreenshot.height}
                  alt="The Termio app: a sidebar of AI coding-agent sessions beside a live terminal pane."
                  className="shadow-soft h-auto w-full rounded-2xl"
                  priority
                />
              ) : (
                <TermioWindow />
              )}
            </div>
          </div>
        </Reveal>
      </div>
    </section>
  );
}
