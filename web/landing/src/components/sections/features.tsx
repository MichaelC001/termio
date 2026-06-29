import { GitBranch, EyeOff } from "lucide-react";
import { Reveal } from "@/components/reveal";
import { SectionLabel, type Accent } from "@/components/section-label";
import { AgentIcon } from "@/components/agent-icons";
import { supportedAgents } from "@/lib/site";
import { cn } from "@/lib/utils";

// Compact mockups that pair with each bento card — pure JSX so they stay crisp
// at any size, no screenshots.

function MultiAgentVisual() {
  return (
    <div className="grid grid-cols-2 gap-2.5">
      {supportedAgents.map((agent) => (
        <div
          key={agent}
          className="flex items-center gap-2.5 rounded-xl bg-background px-3.5 py-3"
        >
          <AgentIcon name={agent} size={16} className="text-foreground" />
          <span className="font-mono text-xs text-foreground">{agent}</span>
        </div>
      ))}
    </div>
  );
}

function SessionsVisual() {
  const live = [
    "claude · refactor auth",
    "codex · migrate to Drizzle",
    "gemini · write e2e tests",
  ];
  return (
    <div className="space-y-3 font-mono text-xs">
      {live.map((session) => (
        <div
          key={session}
          className="flex items-center justify-between rounded-xl bg-background px-4 py-3 text-foreground"
        >
          <span>{session}</span>
          <span className="h-2 w-2 animate-pulse rounded-full bg-[#36d07a]" />
        </div>
      ))}
      <p className="px-1 text-muted-foreground">
        switch ⌘1–3 — every session stays live
      </p>
    </div>
  );
}

function WorktreeVisual() {
  const branches = [
    "agent/claude-auth",
    "agent/codex-drizzle",
    "agent/gemini-e2e",
    "agent/amp-audit",
  ];
  return (
    <div className="font-mono text-xs">
      <div className="mb-3 flex items-center gap-2 text-foreground">
        <GitBranch className="h-4 w-4" aria-hidden="true" />
        main
      </div>
      <ul className="space-y-2.5 border-l border-border pl-4">
        {branches.map((branch) => (
          <li key={branch} className="flex items-center gap-2.5 text-muted-foreground">
            <span className="h-1.5 w-1.5 rounded-full bg-current" />
            {branch}
          </li>
        ))}
      </ul>
    </div>
  );
}

function LocalOnlyVisual() {
  const rows = ["Telemetry", "Cloud sync", "Account to start"];
  return (
    <div className="space-y-2.5">
      {rows.map((row) => (
        <div
          key={row}
          className="flex items-center justify-between rounded-xl bg-background px-4 py-3 text-sm"
        >
          <span className="text-foreground">{row}</span>
          <span className="inline-flex items-center gap-1.5 font-mono text-xs text-muted-foreground">
            <EyeOff className="h-3.5 w-3.5" aria-hidden="true" />
            off
          </span>
        </div>
      ))}
    </div>
  );
}

type Bento = {
  accent: Accent;
  eyebrow: string;
  heading: string;
  intro: string;
  visual: React.ReactNode;
  wide: boolean;
};

const cards: Bento[] = [
  {
    accent: "pink",
    eyebrow: "Multi-agent",
    heading: "Every agent, first-class",
    intro:
      "Claude Code, Codex, Gemini and five more — each in a real native terminal, one tap to launch.",
    visual: <MultiAgentVisual />,
    wide: true,
  },
  {
    accent: "green",
    eyebrow: "Always live",
    heading: "Switch without tearing down",
    intro:
      "Open as many agents as you like — every session stays mounted and keeps running as you move between them, and your sidebar layout is remembered next launch.",
    visual: <SessionsVisual />,
    wide: false,
  },
  {
    accent: "blue",
    eyebrow: "Git-aware",
    heading: "Organized by branch",
    intro:
      "Run each agent in its own git worktree — termio groups them under the project and shows every branch live in the sidebar, so parallel work never gets confusing.",
    visual: <WorktreeVisual />,
    wide: false,
  },
  {
    accent: "yellow",
    eyebrow: "Private by default",
    heading: "Local-only, by design",
    intro:
      "No telemetry, no cloud sync, no account. Your code and your agents never leave your Mac.",
    visual: <LocalOnlyVisual />,
    wide: true,
  },
];

function BentoCard({ card, index }: { card: Bento; index: number }) {
  const header = (
    <div className={cn(card.wide && "md:max-w-sm")}>
      <SectionLabel accent={card.accent}>{card.eyebrow}</SectionLabel>
      <h3 className="mt-3 text-balance text-2xl font-semibold tracking-[-0.04em] text-foreground">
        {card.heading}
      </h3>
      <p className="mt-3 text-base leading-relaxed text-muted-foreground">
        {card.intro}
      </p>
    </div>
  );

  return (
    <Reveal
      as="article"
      delayMs={(index % 2) * 80}
      className={cn(
        "shadow-soft flex flex-col rounded-3xl bg-card p-8 sm:p-10",
        card.wide && "md:col-span-2",
      )}
    >
      {card.wide ? (
        <div className="grid items-center gap-8 md:grid-cols-2 md:gap-12">
          {header}
          <div className="rounded-2xl bg-secondary p-6">
            {card.visual}
          </div>
        </div>
      ) : (
        <>
          {header}
          <div className="mt-8 rounded-2xl bg-secondary p-6">
            {card.visual}
          </div>
        </>
      )}
    </Reveal>
  );
}

export function Features() {
  return (
    <section id="features" className="scroll-mt-24">
      <div className="mx-auto w-full max-w-6xl px-5 py-32 sm:py-40 sm:px-8">
        <Reveal>
          <SectionLabel accent="violet">What&apos;s inside</SectionLabel>
          <h2 className="mt-4 max-w-2xl text-balance text-4xl font-semibold tracking-[-0.045em] text-foreground sm:text-6xl">
            Everything your agents need.
            <br className="hidden sm:block" /> Nothing they don&apos;t.
          </h2>
        </Reveal>

        <div className="mt-16 grid gap-5 md:grid-cols-2">
          {cards.map((card, index) => (
            <BentoCard key={card.heading} card={card} index={index} />
          ))}
        </div>
      </div>
    </section>
  );
}
