import Link from "next/link";
import { Reveal } from "@/components/reveal";
import { SectionLabel } from "@/components/section-label";

// The orchestration API — the machinery behind the hero's "orchestrate your
// fleet" claim. Copy and the terminal transcript mirror the real CLI surface
// (scripts/termio + /docs/session-control); nothing here is aspirational.
const pillars = [
  {
    title: "Delegate",
    body: (
      <>
        <code>spawn</code> a sibling agent on a prompt, <code>run</code> a dev
        server in a plain pane, <code>send</code> follow-ups or menu answers.
        Every session is addressed by a stable{" "}
        <code>&lt;agent&gt;@&lt;id&gt;</code> handle, and every command is
        scoped to the caller&apos;s own project.
      </>
    ),
  },
  {
    title: "Supervise",
    body: (
      <>
        <code>watch</code> streams one line per status change instead of
        polling: <code>done</code> events carry the transcript range to read,{" "}
        <code>needs-you</code> events carry the on-screen question, and an
        opt-in <code>stalled</code> signal flags a session that has worked 20+
        minutes with nothing to show for it — a signal, never a kill.
      </>
    ),
  },
  {
    title: "Trust the contract",
    body: (
      <>
        <code>--wait</code> blocks until the outcome and splits it across exit
        codes; every <code>--json</code> reply is schema-versioned; results are
        read from the agent&apos;s own transcript, never scraped off the
        screen.
      </>
    ),
  },
] as const;

// A condensed but shape-accurate exchange: spawn → watch → answer → done.
type TranscriptLine = {
  text?: string;
  prompt?: boolean;
  json?: boolean;
  blank?: boolean;
};

const transcript: readonly TranscriptLine[] = [
  { prompt: true, text: 'termio sessions spawn "fix the failing auth tests" --agent codex' },
  { text: "started codex@7c1f2a4e — prompt queued; use this handle for follow-ups" },
  { blank: true },
  { prompt: true, text: "termio sessions watch --state done,needs-you,stalled --json" },
  { json: true, text: '{"handle":"codex@7c1f2a4e","prompt":"Run pnpm test? (y/n)","status":"needs-you"}' },
  { blank: true },
  { prompt: true, text: 'termio sessions send codex@7c1f2a4e "y"' },
  { text: "sent to codex@7c1f2a4e" },
  { blank: true },
  { json: true, text: '{"cursor_end":214,"handle":"codex@7c1f2a4e","status":"done","transcript":"…/rollout-7c1f.jsonl"}' },
];

export function Orchestration() {
  return (
    <section id="orchestration" className="scroll-mt-24">
      <div className="mx-auto w-full max-w-6xl px-5 pb-32 pt-8 sm:px-8 sm:pb-40 sm:pt-10">
        <Reveal className="flex flex-col items-center text-center">
          <SectionLabel accent="green">Orchestration API</SectionLabel>
          <h2 className="mt-4 text-balance text-3xl font-medium leading-[1.1] tracking-tight text-foreground sm:text-[44px]">
            Agents driving agents
          </h2>
          <p className="mt-5 max-w-lg text-balance text-base leading-relaxed text-muted-foreground">
            The <code className="font-mono text-[0.92em]">termio sessions</code>{" "}
            CLI turns the fleet into an API: any agent — or your own scripts —
            can start siblings, answer their prompts, and supervise the whole
            project without touching a GUI.
          </p>
        </Reveal>

        <div className="mt-12 grid items-start gap-5 sm:gap-6 lg:grid-cols-[minmax(0,5fr)_minmax(0,6fr)]">
          <div className="flex flex-col gap-5 sm:gap-6">
            {pillars.map((pillar, i) => (
              <Reveal
                key={pillar.title}
                as="article"
                delayMs={i * 80}
                className="rounded-3xl bg-card p-6 sm:p-8 [&_code]:font-mono [&_code]:text-[0.92em] [&_code]:text-foreground/90"
              >
                <h3 className="text-xl font-medium tracking-tight text-foreground">
                  {pillar.title}
                </h3>
                <p className="mt-2 text-pretty text-sm leading-relaxed text-muted-foreground">
                  {pillar.body}
                </p>
              </Reveal>
            ))}
          </div>

          <Reveal delayMs={160} className="lg:sticky lg:top-24">
            <div className="overflow-hidden rounded-3xl border border-white/10 bg-[#101418] shadow-[0_24px_64px_rgba(10,12,16,0.45)]">
              {/* Title-bar strip so the panel reads as a terminal, not a code block. */}
              <div className="flex items-center gap-1.5 border-b border-white/[0.06] px-5 py-3.5">
                <span className="h-2.5 w-2.5 rounded-full bg-white/15" />
                <span className="h-2.5 w-2.5 rounded-full bg-white/15" />
                <span className="h-2.5 w-2.5 rounded-full bg-white/15" />
                <span className="ml-3 font-mono text-xs text-white/35">
                  claude — supervising 3 sessions
                </span>
              </div>
              <pre className="overflow-x-auto p-5 font-mono text-[13px] leading-relaxed sm:p-6">
                {transcript.map((line, i) =>
                  line.blank ? (
                    <span key={i}>{"\n"}</span>
                  ) : (
                    <span key={i} className="block whitespace-pre">
                      {line.prompt ? (
                        <>
                          <span className="select-none text-[#34d399]">$ </span>
                          <span className="text-white/90">{line.text}</span>
                        </>
                      ) : (
                        <span
                          className={
                            line.json ? "text-[#7dd3fc]/80" : "text-white/55"
                          }
                        >
                          {line.text}
                        </span>
                      )}
                    </span>
                  ),
                )}
              </pre>
            </div>
            <p className="mt-4 text-center text-sm text-muted-foreground">
              Pinned JSON shapes, explicit waits, honest exit codes —{" "}
              <Link
                href="/docs/session-control"
                className="font-medium text-foreground underline-offset-4 hover:underline"
              >
                read the API docs
              </Link>
              .
            </p>
          </Reveal>
        </div>
      </div>
    </section>
  );
}
