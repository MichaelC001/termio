"use client";

import {
  ClaudeCode,
  Codex,
  Gemini,
  Amp,
  OpenCode,
  GithubCopilot,
  Cursor,
} from "@lobehub/icons";
import { cn } from "@/lib/utils";

// Real brand glyphs for every supported agent, keyed by the names in
// `supportedAgents`. We use each brand's monochrome (`.Mono`) variant so the
// logos render in `currentColor` — on Termio's near-black canvas the full-color
// variants of the black-on-white brands (Codex, Copilot, Cursor, OpenCode) would
// otherwise vanish. Pi has no brand icon in the set, so it falls back to a glyph.
type GlyphProps = { size?: number };

const glyphByAgent: Record<string, React.ComponentType<GlyphProps>> = {
  "Claude Code": ClaudeCode,
  Codex: Codex,
  Gemini: Gemini,
  Amp: Amp,
  OpenCode: OpenCode,
  Copilot: GithubCopilot,
  Cursor: Cursor,
};

function PiGlyph({ size = 20 }: GlyphProps) {
  return (
    <span
      aria-hidden="true"
      className="inline-flex items-center justify-center font-mono font-semibold leading-none"
      style={{ width: size, height: size, fontSize: size * 0.95 }}
    >
      π
    </span>
  );
}

export function AgentIcon({
  name,
  size = 20,
  className,
}: {
  name: string;
  size?: number;
  className?: string;
}) {
  const Glyph = glyphByAgent[name] ?? PiGlyph;
  return (
    <span className={cn("inline-flex shrink-0", className)} aria-hidden="true">
      <Glyph size={size} />
    </span>
  );
}

// A seamless, auto-scrolling logo carousel: the agent list is rendered twice and
// translated by -50%, so the loop is continuous. It pauses on hover and respects
// reduced-motion (the keyframes are disabled in globals.css).
export function AgentMarquee({ agents }: { agents: readonly string[] }) {
  const lane = [...agents, ...agents];
  return (
    <div className="marquee-mask group relative overflow-hidden">
      <ul className="animate-marquee flex w-max items-center gap-12 group-hover:[animation-play-state:paused] sm:gap-16">
        {lane.map((agent, index) => (
          <li
            key={`${agent}-${index}`}
            className="flex items-center gap-2.5 text-muted-foreground/70 transition-colors hover:text-foreground"
            aria-hidden={index >= agents.length ? true : undefined}
          >
            <AgentIcon name={agent} size={22} />
            <span className="whitespace-nowrap font-mono text-sm font-medium">
              {agent}
            </span>
          </li>
        ))}
      </ul>
    </div>
  );
}
