"use client";

import Image from "next/image";
import { useEffect, useRef, useState } from "react";
import { Reveal } from "@/components/reveal";
import { AgentIcon } from "@/components/agent-icons";
import { cn } from "@/lib/utils";

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

// Vertical showcase carousel (otty.sh-style): the left column lists every
// agent — the active row expands into a card with its one-liner — while the
// right column vertically slide-fades to that agent's screenshot. Autoplays
// top to bottom, pauses on hover/focus, click selects.
export function AgentShowcase() {
  const [active, setActive] = useState(0);
  const [paused, setPaused] = useState(false);
  const reducedMotion = useRef(false);

  useEffect(() => {
    reducedMotion.current = window.matchMedia(
      "(prefers-reduced-motion: reduce)",
    ).matches;
  }, []);

  useEffect(() => {
    if (paused || reducedMotion.current) return;
    const timer = setInterval(
      () => setActive((i) => (i + 1) % agents.length),
      AUTOPLAY_MS,
    );
    return () => clearInterval(timer);
  }, [paused]);

  return (
    <section id="agents" className="scroll-mt-24">
      <div className="mx-auto w-full max-w-6xl px-5 pb-32 sm:pb-40 sm:px-8">
        <Reveal as="article" className="rounded-3xl bg-card p-6 sm:p-10 lg:p-14">
          <div
            className="grid items-center gap-10 lg:grid-cols-[minmax(0,5fr)_minmax(0,6fr)] lg:gap-14"
            onMouseEnter={() => setPaused(true)}
            onMouseLeave={() => setPaused(false)}
            onFocus={() => setPaused(true)}
            onBlur={() => setPaused(false)}
          >
            {/* Left: heading + vertical agent list. */}
            <div>
              <h2 className="text-balance text-3xl font-medium leading-tight tracking-tight text-foreground sm:text-4xl">
                Works with the agents you already run.
              </h2>
              <p className="mt-4 max-w-md text-pretty text-sm leading-relaxed text-muted-foreground sm:text-base">
                One tap launches each of them in a real, native terminal —
                signed in with your own account, on your own machine.
              </p>

              <div
                role="tablist"
                aria-label="Supported agents"
                aria-orientation="vertical"
                className="mt-8 space-y-1"
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

            {/* Right: vertically slide-fading screenshot stack. */}
            <div
              className="relative overflow-hidden rounded-2xl"
              style={{ aspectRatio: "1280 / 1236" }}
            >
              {agents.map((agent, i) => (
                <Image
                  key={agent.src}
                  src={agent.src}
                  width={1280}
                  height={1236}
                  alt={`${agent.name} running in Termio`}
                  loading="lazy"
                  draggable={false}
                  aria-hidden={i !== active}
                  className={cn(
                    "absolute inset-0 h-full w-full object-cover transition-[opacity,transform] duration-500 ease-out",
                    i === active
                      ? "translate-y-0 opacity-100"
                      : "pointer-events-none opacity-0",
                    i !== active && (i < active ? "-translate-y-6" : "translate-y-6"),
                  )}
                />
              ))}
            </div>
          </div>
        </Reveal>
      </div>
    </section>
  );
}
