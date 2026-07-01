import Image from "next/image";
import { buttonVariants } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import { Reveal } from "@/components/reveal";
import { HeroGradient } from "@/components/hero-gradient";
import { TermioWindow } from "@/components/termio-window";
import { AppleMark } from "@/components/section-label";
import { AgentMarquee } from "@/components/agent-icons";
import { downloadUrl, heroScreenshot, supportedAgents } from "@/lib/site";

export function Hero() {
  return (
    <section
      id="top"
      className="hero-cinematic relative isolate flex min-h-screen flex-col overflow-hidden text-foreground"
    >
      {/* Slow navy→indigo→violet aurora (WebGL MeshGradient) behind the hero. */}
      <HeroGradient className="absolute inset-0 -z-10" />
      {/* Frosted film grain over the aurora so it reads matte, not glossy. */}
      <div
        aria-hidden="true"
        className="grain-overlay pointer-events-none absolute -inset-[6%] -z-10"
      />
      {/* Fade the hero into the page below. */}
      <div
        aria-hidden="true"
        className="pointer-events-none absolute inset-x-0 bottom-0 -z-10 h-72 bg-gradient-to-b from-transparent to-background"
      />
      <div className="relative mx-auto flex w-full max-w-6xl flex-1 flex-col items-center justify-center px-5 pb-20 pt-36 text-center sm:px-8 sm:pt-40">
        <Reveal>
          {/* Glaze-style eyebrow: quiet sentence-case medium text, not an
              uppercase letterspaced label. */}
          <p className="text-sm font-medium text-muted-foreground sm:text-base">
            Modern agentic workspace
          </p>
        </Reveal>
        <Reveal delayMs={40}>
          <h1 className="mt-5 text-balance text-5xl font-medium leading-[1.1] tracking-tight text-foreground sm:text-6xl">
            Orchestrate your fleet of agents.
          </h1>
        </Reveal>
        <Reveal delayMs={120}>
          <p className="mx-auto mt-5 max-w-md text-pretty text-base leading-relaxed text-muted-foreground sm:text-lg">
            Each in its own real terminal. One native Mac window, and nothing
            ever leaves your machine.
          </p>
        </Reveal>
        <Reveal delayMs={170} className="mt-9 w-full max-w-3xl">
          <AgentMarquee agents={supportedAgents} />
        </Reveal>
        <Reveal delayMs={200}>
          <div className="mt-10 flex flex-col items-center justify-center gap-x-8 gap-y-3 sm:flex-row">
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
