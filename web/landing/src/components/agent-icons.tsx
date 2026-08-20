"use client";

import {
  ClaudeCode,
  Codex,
  Antigravity,
  Amp,
  OpenCode,
  GithubCopilot,
  Cursor,
  Kimi,
  Grok,
  DeepSeek,
} from "@lobehub/icons";
import { cn } from "@/lib/utils";

// Real brand glyphs for every supported agent, keyed by the names in
// `supportedAgents`. Each lobehub icon is a compound component: the default
// export is the monochrome (`.Mono`) mark (renders in `currentColor`, our
// default so the logos stay legible on the near-black canvas), and `.Color` is
// the full brand-color mark. Pass `color` to opt into `.Color`; brands with no
// color variant (e.g. Grok — xAI's mark is monochrome by design) fall back to
// the mono mark, which is already their brand look.
//
// Two agents have no icon in the set, and rather than draw a logo for someone
// else's product they get the character each already prints for itself: Pi's π,
// and the diagonal hatch Crush rules its banner with.
type GlyphProps = { size?: number };
type BrandIcon = React.ComponentType<GlyphProps> & {
  Color?: React.ComponentType<GlyphProps>;
};

const brandByAgent: Record<string, BrandIcon> = {
  "Claude Code": ClaudeCode,
  Codex: Codex,
  Antigravity: Antigravity,
  Amp: Amp,
  OpenCode: OpenCode,
  Copilot: GithubCopilot,
  Cursor: Cursor,
  Kimi: Kimi,
  Grok: Grok,
  DeepSeek: DeepSeek,
};

const glyphByAgent: Record<string, string> = {
  Pi: "π",
  Crush: "╱╱",
};

function TextGlyph({ size = 20, text }: GlyphProps & { text: string }) {
  return (
    <span
      aria-hidden="true"
      className="inline-flex items-center justify-center font-mono font-semibold leading-none"
      style={{ width: size, height: size, fontSize: size * 0.95 }}
    >
      {text}
    </span>
  );
}

export function AgentIcon({
  name,
  size = 20,
  className,
  color = false,
}: {
  name: string;
  size?: number;
  className?: string;
  /** Render the brand's full-color mark instead of the monochrome one. */
  color?: boolean;
}) {
  const Brand = brandByAgent[name];
  const Glyph = Brand && (color ? (Brand.Color ?? Brand) : Brand);
  return (
    <span className={cn("inline-flex shrink-0", className)} aria-hidden="true">
      {Glyph ? (
        <Glyph size={size} />
      ) : (
        <TextGlyph size={size} text={glyphByAgent[name] ?? name.slice(0, 1)} />
      )}
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
