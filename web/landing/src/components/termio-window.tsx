import { cn } from "@/lib/utils";

type Session = {
  name: string;
  agent: string;
  branch: string;
  active?: boolean;
  running?: boolean;
};

const sessions: Session[] = [
  { name: "Refactor auth flow", agent: "Claude Code", branch: "agent/claude-auth", active: true, running: true },
  { name: "Migrate to Drizzle", agent: "Codex", branch: "agent/codex-drizzle", running: true },
  { name: "Write e2e tests", agent: "Gemini", branch: "agent/gemini-e2e" },
  { name: "Audit dependencies", agent: "Amp", branch: "agent/amp-audit" },
];

const agentDotColor: Record<string, string> = {
  "Claude Code": "bg-brand-amber-deep",
  Codex: "bg-brand-green",
  Gemini: "bg-brand-blue",
  Amp: "bg-brand-purple",
};

// A pure-CSS mock of the termio app: a Mac-style title bar with traffic lights,
// a sidebar of agent sessions grouped under a project, and a live terminal pane.
// No screenshots — everything here is JSX so it stays crisp at any size.
export function TermioWindow({ className }: { className?: string }) {
  return (
    <div
      className={cn(
        "overflow-hidden rounded-2xl border border-border bg-card shadow-[0_30px_80px_-30px_rgba(20,30,60,0.35)] ring-1 ring-black/5",
        className,
      )}
      role="img"
      aria-label="The termio app showing a sidebar of AI coding-agent sessions and a live terminal pane"
    >
      {/* Title bar */}
      <div className="flex items-center gap-2 border-b border-border bg-[#f9f9f9] px-4 py-3">
        <span className="h-3 w-3 rounded-full bg-brand-red" />
        <span className="h-3 w-3 rounded-full bg-brand-amber" />
        <span className="h-3 w-3 rounded-full bg-brand-green" />
        <span className="ml-3 font-mono text-xs text-muted-foreground">
          termio — acme-api
        </span>
      </div>

      <div className="grid grid-cols-[150px_1fr] sm:grid-cols-[190px_1fr]">
        {/* Sidebar */}
        <aside className="border-r border-border bg-[#fbfbfc] p-3">
          <p className="px-1 pb-2 text-[10px] font-semibold uppercase tracking-wider text-muted-foreground">
            Project
          </p>
          <div className="mb-3 flex items-center gap-2 rounded-md px-1.5 py-1 text-xs font-medium text-foreground">
            <span className="h-2 w-2 rounded-sm bg-foreground" />
            acme-api
          </div>
          <p className="px-1 pb-1.5 text-[10px] font-semibold uppercase tracking-wider text-muted-foreground">
            Worktrees
          </p>
          <ul className="space-y-1">
            {sessions.map((session) => (
              <li
                key={session.name}
                className={cn(
                  "flex items-center gap-2 rounded-md px-1.5 py-1.5 text-[11px] leading-tight",
                  session.active
                    ? "bg-white text-foreground shadow-sm ring-1 ring-border"
                    : "text-muted-foreground",
                )}
              >
                <span
                  className={cn(
                    "h-1.5 w-1.5 shrink-0 rounded-full",
                    agentDotColor[session.agent] ?? "bg-muted-foreground",
                  )}
                />
                <span className="min-w-0">
                  <span className="block truncate font-medium text-foreground/90">
                    {session.name}
                  </span>
                  <span className="block truncate font-mono text-[9px] text-muted-foreground">
                    {session.branch}
                  </span>
                </span>
                {session.running ? (
                  <span className="ml-auto h-1.5 w-1.5 shrink-0 animate-pulse rounded-full bg-brand-green" />
                ) : null}
              </li>
            ))}
          </ul>
        </aside>

        {/* Terminal pane */}
        <div className="bg-[#1a1a1a] p-4 font-mono text-[11px] leading-relaxed text-zinc-300 sm:text-xs">
          <div className="mb-2 flex items-center gap-2 text-[10px] text-zinc-500">
            <span className="h-1.5 w-1.5 rounded-full bg-brand-amber-deep" />
            Claude Code · agent/claude-auth
          </div>
          <p>
            <span className="text-brand-green">~/acme-api</span>{" "}
            <span className="text-brand-cyan">claude</span> &quot;refactor the auth flow&quot;
          </p>
          <p className="text-zinc-400">· Reading src/auth/session.ts</p>
          <p className="text-zinc-400">· Found 3 call sites to update</p>
          <p>
            <span className="text-brand-blue">✓</span> Extracted{" "}
            <span className="text-zinc-100">refreshToken()</span> helper
          </p>
          <p>
            <span className="text-brand-blue">✓</span> Updated middleware guard
          </p>
          <p className="text-zinc-400">· Running test suite…</p>
          <p>
            <span className="text-brand-green">PASS</span> 42 passed, 0 failed
          </p>
          <p className="mt-1 flex items-center">
            <span className="text-brand-green">~/acme-api</span>
            <span className="ml-2 inline-block h-3.5 w-2 animate-pulse bg-zinc-300" />
          </p>
        </div>
      </div>
    </div>
  );
}
