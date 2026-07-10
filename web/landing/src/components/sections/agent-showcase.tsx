"use client";

import Image from "next/image";
import { useCallback, useEffect, useRef, useState } from "react";
import { Reveal } from "@/components/reveal";
import { AgentIcon } from "@/components/agent-icons";
import { cn } from "@/lib/utils";
import { useInView } from "@/lib/use-in-view";

const AUTOPLAY_MS = 4000;

// One entry per agent capture in public/agent/ (all 1280×1236 @2x).
const agents = [
  {
    name: "Claude Code",
    blurb:
      "Anthropic's agentic coding CLI. Session status flows into the sidebar as it works.",
    src: "/agent/claude.png",
  },
  {
    name: "Codex",
    blurb: "OpenAI's coding agent, with your plan usage tracked in Settings.",
    src: "/agent/codex.png",
  },
  {
    name: "OpenCode",
    blurb: "The open-source terminal agent — full TUI, rendered natively.",
    src: "/agent/opencode.png",
  },
  {
    name: "Amp",
    blurb: "Sourcegraph's agent for big, multi-file changes.",
    src: "/agent/amp.png",
  },
  {
    name: "Kimi",
    blurb: "Moonshot AI's Kimi CLI, launched in one tap.",
    src: "/agent/kimi.png",
  },
  {
    name: "Pi",
    blurb: "Pi Agent — tracked in the sidebar like everything else.",
    src: "/agent/pi.png",
  },
] as const;

// Agent showcase carousel: heading on top, then a two-column row where the
// screenshot's aspect ratio sets the height and the agent list stretches to
// match it (justify-between). The image pane cross-fades like the hero
// carousel and stays in sync with the list; a vertical dot rail beside the
// list shows progress. Autoplays, pauses on hover/focus, respects reduced
// motion.
export function AgentShowcase() {
  const [active, setActive] = useState(0);
  const [paused, setPaused] = useState(false);
  // The stacked slides defeat `loading="lazy"` once the section scrolls into
  // view, so only mount slides the user has seen plus the upcoming one (mounted
  // an autoplay interval early so it's loaded before it fades in).
  const [visited, setVisited] = useState<ReadonlySet<number>>(
    () => new Set([0]),
  );
  const reducedMotion = useRef(false);
  const { ref: viewRef, inView } = useInView<HTMLDivElement>();

  useEffect(() => {
    setVisited((prev) => (prev.has(active) ? prev : new Set(prev).add(active)));
  }, [active]);

  const goTo = useCallback(
    (index: number) => setActive((index + agents.length) % agents.length),
    [],
  );

  useEffect(() => {
    reducedMotion.current = window.matchMedia(
      "(prefers-reduced-motion: reduce)",
    ).matches;
  }, []);

  useEffect(() => {
    if (paused || !inView || reducedMotion.current) return;
    const timer = setInterval(
      () => setActive((i) => (i + 1) % agents.length),
      AUTOPLAY_MS,
    );
    return () => clearInterval(timer);
  }, [paused, inView]);

  return (
    <section id="agents" className="scroll-mt-24">
      <div className="mx-auto w-full max-w-6xl px-5 pb-32 sm:pb-40 sm:px-8">
        <Reveal
          as="article"
          className="rounded-3xl bg-card p-6 sm:p-10 lg:p-14"
        >
          <div
            ref={viewRef}
            onMouseEnter={() => setPaused(true)}
            onMouseLeave={() => setPaused(false)}
            onFocus={() => setPaused(true)}
            onBlur={() => setPaused(false)}
            onKeyDown={(e) => {
              if (e.key === "ArrowLeft") goTo(active - 1);
              if (e.key === "ArrowRight") goTo(active + 1);
            }}
          >
            <h2 className="max-w-xl text-balance text-3xl font-medium leading-tight tracking-tight text-foreground sm:text-4xl">
              Works with the agents you already run.
            </h2>
            <p className="mt-4 max-w-md text-pretty text-sm leading-relaxed text-muted-foreground sm:text-base">
              One tap launches each of them in a real, native terminal — signed
              in with your own account, on your own machine.
            </p>

            <div className="mt-10 grid gap-10 lg:grid-cols-[minmax(0,5fr)_minmax(0,6fr)] lg:items-stretch lg:gap-14">
              {/* Left: vertical progress dots, then the agent list stretched
                  to the image's height. */}
              <div className="flex gap-4 sm:gap-5">
                <div
                  aria-label="Choose agent"
                  className="flex flex-col items-center justify-center gap-1.5"
                >
                  {agents.map((agent, i) => (
                    <button
                      key={agent.src}
                      type="button"
                      aria-label={`Show ${agent.name}`}
                      aria-current={i === active}
                      onClick={() => goTo(i)}
                      className={cn(
                        "w-1.5 rounded-full transition-all duration-200",
                        i === active
                          ? "h-4 bg-foreground"
                          : "h-1.5 bg-foreground/25 hover:bg-foreground/60",
                      )}
                    />
                  ))}
                </div>

                <div
                  role="tablist"
                  aria-label="Supported agents"
                  aria-orientation="vertical"
                  className="flex min-w-0 flex-1 flex-col justify-between gap-1"
                >
                  {agents.map((agent, i) => {
                    const isActive = i === active;
                    return (
                      <button
                        key={agent.name}
                        type="button"
                        role="tab"
                        aria-selected={isActive}
                        onClick={() => setActive(i)}
                        className={cn(
                          "block w-full rounded-xl px-4 text-left transition-all duration-300",
                          isActive
                            ? "bg-background py-3.5 shadow-[0_1px_2px_rgba(20,23,28,0.06)]"
                            : "py-2.5 opacity-55 hover:opacity-90",
                        )}
                      >
                        <span className="flex items-center gap-3">
                          <AgentIcon
                            name={agent.name}
                            size={18}
                            className="text-foreground"
                          />
                          <span className="text-base font-medium text-foreground">
                            {agent.name}
                          </span>
                        </span>
                        {/* 0fr→1fr grid trick: the blurb slides open only on the
                          active row without measuring heights. */}
                        <span
                          className={cn(
                            "grid transition-[grid-template-rows] duration-300",
                            isActive
                              ? "[grid-template-rows:1fr]"
                              : "[grid-template-rows:0fr]",
                          )}
                        >
                          <span className="overflow-hidden">
                            <span className="block pl-[30px] pt-1 text-sm leading-relaxed text-muted-foreground">
                              {agent.blurb}
                            </span>
                          </span>
                        </span>
                      </button>
                    );
                  })}
                </div>
              </div>

              {/* Right: hero-style cross-fade carousel, synced with the list.
                  The @container wrapper lets the corner radius scale with the
                  rendered image width (cqw), same as the hero carousel. */}
              <div className="@container">
                <div
                  role="region"
                  aria-roledescription="carousel"
                  aria-label="Agent screenshots"
                  className="relative overflow-hidden rounded-[clamp(6px,1cqw,12px)]"
                  style={{ aspectRatio: "1280 / 1236" }}
                >
                  {agents.map((agent, i) =>
                    visited.has(i) || i === (active + 1) % agents.length ? (
                      <Image
                        key={agent.src}
                        src={agent.src}
                        width={1280}
                        height={1236}
                        alt={`${agent.name} running in Termio`}
                        loading="lazy"
                        // The captures are 1280px wide but render in the ~32rem
                        // right column of the card; without `sizes` the browser
                        // downloads the 3840px rendition.
                        sizes="(min-width: 64rem) 32rem, calc(100vw - 5.5rem)"
                        draggable={false}
                        aria-hidden={i !== active}
                        className={cn(
                          "absolute inset-0 h-full w-full object-cover transition-[opacity,transform] duration-700 ease-out",
                          i === active
                            ? "opacity-100 scale-100"
                            : "pointer-events-none opacity-0 scale-[1.012]",
                        )}
                      />
                    ) : null,
                  )}
                </div>
              </div>
            </div>
          </div>
        </Reveal>
      </div>
    </section>
  );
}
