import {
  Terminal,
  Power,
  GitBranch,
  Lock,
  Sparkles,
  RefreshCw,
  Layers,
  EyeOff,
} from "lucide-react";
import { Reveal } from "@/components/reveal";
import { SectionLabel, type Accent } from "@/components/section-label";
import { cn } from "@/lib/utils";

// Dark device mockups that pair with each showcase block — pure JSX so they stay
// crisp at any size, no screenshots.

function MultiAgentVisual() {
  const agents = [
    "Claude Code",
    "Codex",
    "Gemini",
    "Amp",
    "Pi",
    "OpenCode",
    "Copilot",
    "Cursor",
  ];
  return (
    <div className="grid grid-cols-2 gap-2.5">
      {agents.map((agent) => (
        <div
          key={agent}
          className="flex items-center gap-2.5 rounded-xl border border-border bg-white/[0.02] px-3.5 py-3"
        >
          <Terminal className="h-3.5 w-3.5 text-muted-foreground" aria-hidden="true" />
          <span className="font-mono text-xs text-foreground">{agent}</span>
        </div>
      ))}
    </div>
  );
}

function SessionsVisual() {
  return (
    <div className="space-y-3 font-mono text-xs">
      <div className="flex items-center justify-between rounded-xl border border-border bg-white/[0.02] px-4 py-3 text-foreground">
        <span>agent running…</span>
        <span className="h-2 w-2 animate-pulse rounded-full bg-[#36d07a]" />
      </div>
      <div className="flex items-center gap-2 px-1 text-muted-foreground">
        <Power className="h-3.5 w-3.5" aria-hidden="true" />
        <span>app quit &amp; reopened</span>
      </div>
      <div className="flex items-center justify-between rounded-xl border border-border bg-white/[0.02] px-4 py-3 text-foreground">
        <span>reconnected · output replayed</span>
        <span className="h-2 w-2 rounded-full bg-[#36d07a]" />
      </div>
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
          className="flex items-center justify-between rounded-xl border border-border bg-white/[0.02] px-4 py-3 text-sm"
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

type Row = { icon: typeof Terminal; title: string; description: string };

type Showcase = {
  accent: Accent;
  eyebrow: string;
  heading: string;
  intro: string;
  rows: Row[];
  visual: React.ReactNode;
};

const showcases: Showcase[] = [
  {
    accent: "pink",
    eyebrow: "Multi-agent",
    heading: "Every agent, first-class",
    intro:
      "Claude Code, Codex, Gemini, Amp, Pi, OpenCode, Copilot and Cursor each get a real native terminal — launch any of them with one tap.",
    rows: [
      {
        icon: Terminal,
        title: "A real PTY, every time",
        description:
          "Each session is a genuine login shell, so any CLI-based agent just works — no shims, no emulation.",
      },
      {
        icon: Sparkles,
        title: "Auto-titled sessions",
        description:
          "Sessions name themselves from what the agent is doing, so a long list stays scannable instead of a wall of “Untitled”.",
      },
    ],
    visual: <MultiAgentVisual />,
  },
  {
    accent: "green",
    eyebrow: "Always running",
    heading: "Sessions that survive anything",
    intro:
      "Each terminal runs in its own session-host process, independent of the window. Quit termio, restart your Mac — your agents keep working.",
    rows: [
      {
        icon: Power,
        title: "Hosted, not tied to the window",
        description:
          "The shell lives in a separate process. Close the app and nothing is killed.",
      },
      {
        icon: RefreshCw,
        title: "Reconnect & replay",
        description:
          "Reopen termio and every session reattaches with its full scrollback replayed.",
      },
    ],
    visual: <SessionsVisual />,
  },
  {
    accent: "blue",
    eyebrow: "Isolation",
    heading: "A git worktree per agent",
    intro:
      "Run several agents on the same repo at once without stepping on each other. Each gets its own branch and checkout, grouped under the project.",
    rows: [
      {
        icon: Layers,
        title: "Parallel without collisions",
        description:
          "Every agent works in a separate worktree, so simultaneous edits never clash.",
      },
      {
        icon: GitBranch,
        title: "Grouped under the project",
        description:
          "Branches stay organized in the sidebar so you always know who changed what.",
      },
    ],
    visual: <WorktreeVisual />,
  },
  {
    accent: "yellow",
    eyebrow: "Private by default",
    heading: "Local-only, by design",
    intro:
      "No telemetry, no cloud sync, no account to get started. Your code and your agents stay on your Mac — full stop.",
    rows: [
      {
        icon: Lock,
        title: "Nothing leaves your machine",
        description:
          "termio is not sandboxed and not phoning home. The only network traffic is the agents you run.",
      },
      {
        icon: EyeOff,
        title: "No account to start",
        description:
          "termio runs entirely offline — download it and go, with no sign-in and no card.",
      },
    ],
    visual: <LocalOnlyVisual />,
  },
];

function ShowcaseBlock({ block, reverse }: { block: Showcase; reverse: boolean }) {
  return (
    <div className="grid items-center gap-12 md:grid-cols-2 md:gap-20">
      <Reveal className={cn(reverse && "md:order-2")}>
        <SectionLabel accent={block.accent}>{block.eyebrow}</SectionLabel>
        <h3 className="mt-4 text-balance text-4xl font-bold tracking-[-0.045em] text-foreground sm:text-5xl">
          {block.heading}
        </h3>
        <p className="mt-5 max-w-md text-lg leading-relaxed text-muted-foreground">
          {block.intro}
        </p>
        <div className="mt-9 space-y-6">
          {block.rows.map((row) => {
            const Icon = row.icon;
            return (
              <div key={row.title} className="flex gap-4">
                <Icon
                  className="mt-0.5 h-5 w-5 shrink-0 text-muted-foreground"
                  aria-hidden="true"
                />
                <div>
                  <h4 className="text-base font-semibold text-foreground">
                    {row.title}
                  </h4>
                  <p className="mt-1 text-sm leading-relaxed text-muted-foreground">
                    {row.description}
                  </p>
                </div>
              </div>
            );
          })}
        </div>
      </Reveal>

      <Reveal delayMs={80} className={cn("[perspective:2400px]", reverse && "md:order-1")}>
        <div
          className={cn(
            "rounded-2xl border border-border bg-card p-7 shadow-soft sm:p-9",
            reverse ? "md:tilt-left" : "md:tilt-right",
          )}
        >
          {block.visual}
        </div>
      </Reveal>
    </div>
  );
}

export function Features() {
  return (
    <section id="features" className="scroll-mt-24">
      <div className="mx-auto w-full max-w-6xl px-5 py-32 sm:py-40 sm:px-8">
        <Reveal>
          <SectionLabel accent="violet">What&apos;s inside</SectionLabel>
          <h2 className="mt-4 max-w-2xl text-balance text-4xl font-bold tracking-[-0.045em] text-foreground sm:text-6xl">
            Everything your agents need.
            <br className="hidden sm:block" /> Nothing they don&apos;t.
          </h2>
        </Reveal>

        <div className="mt-20 space-y-32 sm:space-y-48">
          {showcases.map((block, index) => (
            <ShowcaseBlock key={block.heading} block={block} reverse={index % 2 === 1} />
          ))}
        </div>
      </div>
    </section>
  );
}
