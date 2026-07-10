import { GitBranch } from "lucide-react";
import { Reveal } from "@/components/reveal";
import { cn } from "@/lib/utils";

// Compact mockups that pair with each bento card — pure JSX so they stay crisp
// at any size, no screenshots.

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

type Bento = {
  heading: string;
  intro: string;
  visual: React.ReactNode;
  wide: boolean;
};

const cards: Bento[] = [
  {
    heading: "Switch without tearing down",
    intro:
      "Every session stays mounted and keeps running as you switch. Your sidebar layout comes back exactly as you left it, next launch.",
    visual: <SessionsVisual />,
    wide: false,
  },
  {
    heading: "Organized by branch",
    intro:
      "Termio groups every git worktree under its project and shows each branch live in the sidebar — so parallel agents never blur together.",
    visual: <WorktreeVisual />,
    wide: false,
  },
];

// Glaze-style bento card: a flat, borderless tile whose surface reads a hair
// lighter than the canvas — the title + one-liner sit tight at the top, the
// visual fills the rest. No eyebrow, no inner panel.
function BentoCard({ card, index }: { card: Bento; index: number }) {
  const header = (
    <div className={cn(card.wide && "md:max-w-sm")}>
      <h3 className="text-balance text-2xl font-medium leading-tight tracking-tight text-foreground sm:text-3xl">
        {card.heading}
      </h3>
      <p className="mt-2 text-balance text-sm leading-relaxed text-muted-foreground sm:text-base">
        {card.intro}
      </p>
    </div>
  );

  return (
    <Reveal
      as="article"
      delayMs={(index % 2) * 80}
      className={cn(
        "flex flex-col overflow-hidden rounded-2xl bg-card p-6 sm:p-8",
        card.wide && "md:col-span-2",
      )}
    >
      {card.wide ? (
        <div className="grid items-center gap-6 md:grid-cols-2 md:gap-12">
          {header}
          <div>{card.visual}</div>
        </div>
      ) : (
        <>
          {header}
          <div className="mt-auto pt-8">{card.visual}</div>
        </>
      )}
    </Reveal>
  );
}

export function Features() {
  return (
    <section id="features" className="scroll-mt-24">
      <div className="mx-auto w-full max-w-6xl px-5 py-32 sm:py-40 sm:px-8">
        <Reveal className="flex flex-col items-center text-center">
          <p className="text-sm font-medium text-muted-foreground sm:text-base">
            What&apos;s inside
          </p>
          <h2 className="mt-3 max-w-2xl text-balance text-3xl font-medium leading-[1.1] tracking-tight text-foreground sm:text-[44px]">
            Everything your agents need.
            <br className="hidden sm:block" /> Nothing they don&apos;t.
          </h2>
        </Reveal>

        <div className="mt-12 grid gap-4 md:grid-cols-2 sm:gap-5">
          {cards.map((card, index) => (
            <BentoCard key={card.heading} card={card} index={index} />
          ))}
        </div>
      </div>
    </section>
  );
}
