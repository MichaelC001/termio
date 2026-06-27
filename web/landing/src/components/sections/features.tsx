import {
  Terminal,
  Power,
  GitBranch,
  Lock,
  Sparkles,
  LayoutDashboard,
} from "lucide-react";
import { Card } from "@/components/ui/card";
import { Reveal } from "@/components/reveal";
import { cn } from "@/lib/utils";

// Small, purpose-built CSS/JSX visuals so every feature card carries its own
// illustration without shipping screenshots or an image pipeline.

function MultiAgentVisual() {
  const agents = [
    { name: "Claude Code", color: "bg-brand-amber-deep" },
    { name: "Codex", color: "bg-brand-green" },
    { name: "Gemini", color: "bg-brand-blue" },
    { name: "Amp", color: "bg-brand-purple" },
  ];
  return (
    <div className="grid grid-cols-2 gap-2">
      {agents.map((agent) => (
        <div
          key={agent.name}
          className="flex items-center gap-2 rounded-lg border border-border bg-background px-3 py-2"
        >
          <span className={cn("h-2 w-2 rounded-full", agent.color)} />
          <span className="font-mono text-xs text-foreground">{agent.name}</span>
        </div>
      ))}
    </div>
  );
}

function SessionsVisual() {
  return (
    <div className="space-y-2 font-mono text-[11px]">
      <div className="flex items-center justify-between rounded-md bg-[#1a1a1a] px-3 py-2 text-zinc-300">
        <span>agent running…</span>
        <span className="h-1.5 w-1.5 animate-pulse rounded-full bg-brand-green" />
      </div>
      <div className="flex items-center gap-2 px-1 text-muted-foreground">
        <Power className="h-3.5 w-3.5" aria-hidden="true" />
        <span>app quit &amp; reopened</span>
      </div>
      <div className="flex items-center justify-between rounded-md bg-[#1a1a1a] px-3 py-2 text-zinc-300">
        <span>reconnected · output replayed</span>
        <span className="h-1.5 w-1.5 rounded-full bg-brand-green" />
      </div>
    </div>
  );
}

function WorktreeVisual() {
  const branches = [
    { label: "agent/claude-auth", color: "text-brand-amber-deep" },
    { label: "agent/codex-drizzle", color: "text-brand-green" },
    { label: "agent/gemini-e2e", color: "text-brand-blue" },
  ];
  return (
    <div className="font-mono text-[11px]">
      <div className="mb-2 flex items-center gap-2 text-foreground">
        <GitBranch className="h-3.5 w-3.5" aria-hidden="true" />
        main
      </div>
      <ul className="space-y-1.5 border-l border-border pl-3">
        {branches.map((branch) => (
          <li key={branch.label} className={cn("flex items-center gap-2", branch.color)}>
            <span className="h-1.5 w-1.5 rounded-full bg-current" />
            {branch.label}
          </li>
        ))}
      </ul>
    </div>
  );
}

function LocalOnlyVisual() {
  const rows = ["Telemetry", "Cloud sync", "Account to start"];
  return (
    <div className="space-y-2">
      {rows.map((row) => (
        <div
          key={row}
          className="flex items-center justify-between rounded-lg border border-border bg-background px-3 py-2 text-sm"
        >
          <span className="text-foreground">{row}</span>
          <span className="font-mono text-xs text-muted-foreground line-through decoration-brand-red/70">
            off
          </span>
        </div>
      ))}
    </div>
  );
}

function AutoTitleVisual() {
  return (
    <div className="space-y-2 font-mono text-[11px]">
      <div className="rounded-md border border-border bg-background px-3 py-2 text-muted-foreground">
        Untitled session
      </div>
      <div className="flex items-center gap-2 px-1 text-brand-blue-deep">
        <Sparkles className="h-3.5 w-3.5" aria-hidden="true" />
        auto-titled
      </div>
      <div className="rounded-md border border-border bg-background px-3 py-2 font-medium text-foreground">
        Fix flaky checkout test
      </div>
    </div>
  );
}

function SidebarVisual() {
  return (
    <div className="rounded-lg border border-border bg-background p-2">
      <p className="px-1 pb-1 text-[9px] font-semibold uppercase tracking-wider text-muted-foreground">
        acme-api
      </p>
      <ul className="space-y-1 text-[11px]">
        {["Refactor auth flow", "Migrate to Drizzle", "Write e2e tests"].map(
          (item, index) => (
            <li
              key={item}
              className={cn(
                "rounded px-2 py-1",
                index === 0
                  ? "bg-card text-foreground shadow-sm ring-1 ring-border"
                  : "text-muted-foreground",
              )}
            >
              {item}
            </li>
          ),
        )}
      </ul>
    </div>
  );
}

type Feature = {
  icon: typeof Terminal;
  title: string;
  description: string;
  visual: React.ReactNode;
  span?: boolean;
};

const features: Feature[] = [
  {
    icon: Terminal,
    title: "Every agent CLI, first-class",
    description:
      "Claude Code, Codex, Gemini, Amp, Pi, OpenCode, Copilot and Cursor each get a real native terminal. Launch any of them with one tap.",
    visual: <MultiAgentVisual />,
    span: true,
  },
  {
    icon: Power,
    title: "Sessions survive restarts",
    description:
      "Each terminal runs in its own session-host process, independent of the window. Quit or restart termio and your agents keep working — reconnect and replay the saved output.",
    visual: <SessionsVisual />,
    span: true,
  },
  {
    icon: GitBranch,
    title: "A git worktree per agent",
    description:
      "Run several agents on the same repo at once without stepping on each other. Each gets its own branch and checkout, grouped under the project.",
    visual: <WorktreeVisual />,
  },
  {
    icon: Lock,
    title: "Local-only by design",
    description:
      "No telemetry, no cloud sync, no account to start the trial. Your code and your agents stay on your Mac.",
    visual: <LocalOnlyVisual />,
  },
  {
    icon: Sparkles,
    title: "Auto-titling & one-tap launch",
    description:
      "Sessions name themselves from what the agent is doing, so a long list stays scannable instead of a wall of “Untitled”.",
    visual: <AutoTitleVisual />,
  },
  {
    icon: LayoutDashboard,
    title: "A dashboard sidebar",
    description:
      "Every project and every agent session in one place. See what's running at a glance and jump straight to it.",
    visual: <SidebarVisual />,
  },
];

export function Features() {
  return (
    <section id="features" className="scroll-mt-20">
      <div className="mx-auto w-full max-w-6xl px-5 py-24 sm:px-8">
        <Reveal>
          <p className="text-center text-xs font-semibold uppercase tracking-[0.18em] text-muted-foreground">
            Powerful features
          </p>
        </Reveal>
        <Reveal delayMs={60}>
          <h2 className="mx-auto mt-4 max-w-2xl text-balance text-center text-3xl font-semibold tracking-tight text-foreground sm:text-4xl">
            Built for running real coding agents, all day
          </h2>
        </Reveal>

        <div className="mt-14 grid gap-5 md:grid-cols-2">
          {features.map((feature, index) => {
            const Icon = feature.icon;
            return (
              <Reveal
                key={feature.title}
                delayMs={(index % 2) * 80}
                className={cn(feature.span && "md:col-span-2")}
              >
                <Card
                  className={cn(
                    "h-full gap-0 rounded-2xl border-border bg-card p-7 shadow-sm transition-shadow hover:shadow-md",
                    feature.span && "md:grid md:grid-cols-2 md:items-center md:gap-8",
                  )}
                >
                  <div>
                    <span className="inline-flex h-10 w-10 items-center justify-center rounded-xl bg-secondary text-foreground">
                      <Icon className="h-5 w-5" aria-hidden="true" />
                    </span>
                    <h3 className="mt-5 text-lg font-semibold tracking-tight text-foreground">
                      {feature.title}
                    </h3>
                    <p className="mt-2 text-sm leading-relaxed text-[#333333]">
                      {feature.description}
                    </p>
                  </div>
                  <div className="mt-6 md:mt-0">{feature.visual}</div>
                </Card>
              </Reveal>
            );
          })}
        </div>
      </div>
    </section>
  );
}
