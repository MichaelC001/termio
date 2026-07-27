"use client";

import { useEffect, useRef, useState } from "react";
import { useInView } from "@/lib/use-in-view";
import { TerminalBackdrop } from "@/components/terminal-backdrop";
import { AgentIcon } from "@/components/agent-icons";

// The orchestration section's animated demo: a hub-and-spoke graph (claude
// supervising five worker sessions) synced beat-for-beat to a terminal that
// types itself. One state machine drives both — as each worker becomes active
// the LEFT graph lights that node and pulses its beam, while the RIGHT terminal
// types that worker's command and prints its result. Together they narrate one
// ship-a-feature pipeline: plan → build → review → secure-tag → feedback. Falls
// back to a static done-state summary for SSR, screen readers, and reduced
// motion.

type TranscriptLine = {
  text?: string;
  prompt?: boolean;
  json?: boolean;
  blank?: boolean;
  id?: number; // stable key so a freshly-pushed line animates in exactly once
};

type Status = "idle" | "working" | "needs-you" | "done";

type Pulse = {
  id: number;
  dir: "out" | "back";
  color: string;
  y: number;
};

type Frame = {
  lines: TranscriptLine[];
  typing: string | null;
  statuses: Status[]; // index-aligned with WORKERS
  pulse: Pulse | null;
};

// Section palette — no green. Neutral light for "working" (a data packet
// traveling the beam), sky for "done", amber for "needs-you".
const ACTIVE = "#e2e8f0";
const AMBER = "#fbbf24";
const SKY = "#7dd3fc";

// The five workers, in pipeline order (index = story order = top-to-bottom in
// the graph). Each drives one stage of shipping a change; the middle worker
// (y=170) gets the straight beam. `name` keys the real brand logo.
type Worker = { name: string; handle: string; y: number };

const WORKERS: readonly Worker[] = [
  { name: "Claude Code", handle: "claude@9b3e11d0", y: 40 },
  { name: "Codex", handle: "codex@7c1f2a4e", y: 105 },
  { name: "DeepSeek", handle: "deepseek@5a77c0e2", y: 170 },
  { name: "Grok", handle: "grok@d4e6b209", y: 235 },
  { name: "Kimi", handle: "kimi@3f8a2c11", y: 300 },
];

// One story beat per worker. `interaction` (codex only) shows a needs-you round
// trip: the agent asks, claude answers, the agent resumes.
type Beat = {
  worker: number;
  cmd: string;
  started: string;
  interaction?: { needsYou: string; answer: string; sent: string };
  done: string;
};

const BEATS: readonly Beat[] = [
  {
    worker: 0,
    cmd: 'termio sessions spawn "plan the auth refactor" --agent claude',
    started: "started claude@9b3e11d0 — planning",
    done: '{"handle":"claude@9b3e11d0","status":"done","plan":"7 steps -> PLAN.md"}',
  },
  {
    worker: 1,
    cmd: 'termio sessions spawn "implement PLAN.md" --agent codex',
    started: "started codex@7c1f2a4e — building",
    interaction: {
      needsYou: '{"handle":"codex@7c1f2a4e","status":"needs-you","prompt":"Run pnpm test? (y/n)"}',
      answer: 'termio sessions send codex@7c1f2a4e "y"',
      sent: "sent to codex@7c1f2a4e",
    },
    done: '{"handle":"codex@7c1f2a4e","status":"done","diff":"+412 -128, tests pass"}',
  },
  {
    worker: 2,
    cmd: 'termio sessions spawn "review the diff" --agent deepseek',
    started: "started deepseek@5a77c0e2 — reviewing",
    done: '{"handle":"deepseek@5a77c0e2","status":"done","review":"2 nits, 0 blockers"}',
  },
  {
    worker: 3,
    cmd: 'termio sessions spawn "security scan, then tag v0.22.0" --agent grok',
    started: "started grok@d4e6b209 — scanning",
    done: '{"handle":"grok@d4e6b209","status":"done","secure":"clean, tagged v0.22.0"}',
  },
  {
    worker: 4,
    cmd: 'termio sessions spawn "summarize the week\'s feedback" --agent kimi',
    started: "started kimi@3f8a2c11 — gathering",
    done: '{"handle":"kimi@3f8a2c11","status":"done","feedback":"5 themes -> FEEDBACK.md"}',
  },
];

// Static fallback / screen-reader copy: the whole pipeline in its done state.
const DONE_SUMMARY: readonly TranscriptLine[] = BEATS.map((b) => ({
  json: true,
  text: b.done,
}));

const STATIC_FRAME: Frame = {
  lines: [...DONE_SUMMARY],
  typing: null,
  statuses: WORKERS.map(() => "done"),
  pulse: null,
};

// Beam from the hub's right edge (104,170) to a worker's left edge (184,y), and
// the reverse. The middle worker (y=170) gets a straight line.
const beamPath = (y: number) =>
  y === 170 ? "M104 170 L 184 170" : `M104 170 C 142 170, 142 ${y}, 184 ${y}`;
const beamPathBack = (y: number) =>
  y === 170 ? "M184 170 L 104 170" : `M184 ${y} C 142 ${y}, 142 170, 104 170`;

// Per-status pill styling for the worker nodes.
const STATUS_BORDER: Record<Status, string> = {
  idle: "rgba(255,255,255,0.1)",
  working: "rgba(226,232,240,0.45)",
  "needs-you": "rgba(251,191,36,0.6)",
  done: "rgba(125,211,252,0.4)",
};
const STATUS_GLOW: Record<Status, string> = {
  idle: "none",
  working: "0 0 0 1px rgba(226,232,240,0.22), 0 0 14px rgba(226,232,240,0.12)",
  "needs-you": "0 0 0 1px rgba(251,191,36,0.3), 0 0 14px rgba(251,191,36,0.18)",
  done: "none",
};

const MAX_LINES = 8; // rolling transcript window (fits the reserved height)

function sleep(ms: number) {
  return new Promise<void>((resolve) => setTimeout(resolve, ms));
}

export function OrchestrationDemo() {
  const { ref, inView } = useInView<HTMLDivElement>("80px");
  const [frame, setFrame] = useState<Frame>(STATIC_FRAME);
  const pulseId = useRef(0);

  useEffect(() => {
    if (!inView) return;
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;

    let cancelled = false;
    const patch = (p: Partial<Frame>) =>
      setFrame((f) => (cancelled ? f : { ...f, ...p }));
    const pulse = (dir: Pulse["dir"], color: string, y: number) =>
      patch({ pulse: { id: ++pulseId.current, dir, color, y } });

    const buf: TranscriptLine[] = [];
    let lineSeq = 0;
    const commit = () => patch({ lines: buf.slice(-MAX_LINES) });
    const push = (line: TranscriptLine) => {
      // Stable id so React keeps each rendered line and only the newly pushed
      // one mounts (and plays its fade-in) — buffer shifts never replay it.
      buf.push({ ...line, id: ++lineSeq });
      commit();
    };

    const type = async (cmd: string) => {
      // The command (input) is typed a little at a time, like a keystroke feed.
      // Small chunks keep it smooth without a re-render per character; kept
      // deliberately unhurried.
      for (let i = 0; i <= cmd.length; i += 2) {
        if (cancelled) return;
        patch({ typing: cmd.slice(0, i) });
        await sleep(34);
      }
      patch({ typing: null });
      push({ prompt: true, text: cmd });
    };

    const play = async () => {
      while (!cancelled) {
        buf.length = 0;
        const statuses: Status[] = WORKERS.map(() => "idle");
        patch({ lines: [], typing: null, statuses: [...statuses], pulse: null });
        await sleep(700);
        if (cancelled) return;

        for (let b = 0; b < BEATS.length; b++) {
          const beat = BEATS[b];
          const w = WORKERS[beat.worker];
          const last = b === BEATS.length - 1;

          // The worker comes alive: left node lights, beam pulses hub → worker,
          // right terminal types its command.
          statuses[beat.worker] = "working";
          patch({ statuses: [...statuses] });
          pulse("out", ACTIVE, w.y);
          await type(beat.cmd);
          if (cancelled) return;
          // The result arrives all at once (a whole line), after a short beat.
          await sleep(360);
          push({ text: beat.started });
          await sleep(beat.interaction ? 850 : 1500);
          if (cancelled) return;

          if (beat.interaction) {
            push({ json: true, text: beat.interaction.needsYou });
            statuses[beat.worker] = "needs-you";
            patch({ statuses: [...statuses] });
            pulse("back", AMBER, w.y);
            await sleep(1600);
            if (cancelled) return;
            await type(beat.interaction.answer);
            if (cancelled) return;
            await sleep(320);
            push({ text: beat.interaction.sent });
            statuses[beat.worker] = "working";
            patch({ statuses: [...statuses] });
            pulse("out", ACTIVE, w.y);
            await sleep(1500);
            if (cancelled) return;
          }

          // Result streams back: node settles to done, beam pulses worker → hub.
          push({ json: true, text: beat.done });
          statuses[beat.worker] = "done";
          patch({ statuses: [...statuses] });
          pulse("back", SKY, w.y);
          push({ blank: true });
          await sleep(last ? 4200 : 1250);
        }
      }
    };

    void play();
    return () => {
      cancelled = true;
    };
  }, [inView]);

  const pulsePath = frame.pulse
    ? frame.pulse.dir === "back"
      ? beamPathBack(frame.pulse.y)
      : beamPath(frame.pulse.y)
    : null;

  return (
    // One terminal window: a solid near-black panel. The Paper grain-gradient
    // glow lives only behind the left session graph (never behind the
    // transcript, where it would fight the code). Title bar spans the top;
    // below it the graph (left) and the live CLI transcript (right) sit side by
    // side.
    <div
      ref={ref}
      className="relative overflow-hidden rounded-3xl border border-white/10 bg-[#0b0e12] shadow-[0_24px_64px_rgba(10,12,16,0.45)]"
    >
      <div className="relative">
        <div className="grid lg:grid-cols-[minmax(0,3fr)_minmax(0,8fr)]">
          {/* Left: the live session graph — claude code driving five workers,
              each a real brand logo. The active node lights and its beam pulses
              in sync with the command running on the right. */}
          <div
            aria-hidden="true"
            className="relative flex items-center justify-center overflow-hidden border-b border-white/[0.06] p-5 sm:p-6 lg:border-b-0 lg:border-r"
          >
            {/* Grain-gradient glow lives only here, behind the graph. */}
            <TerminalBackdrop />
            <svg viewBox="0 0 340 340" className="relative w-full max-w-[320px]" fill="none">
              {/* Static edges from the hub to each worker. */}
              {WORKERS.map((w) => (
                <path
                  key={`edge-${w.handle}`}
                  d={beamPath(w.y)}
                  stroke="rgba(255,255,255,0.09)"
                  strokeWidth="1"
                />
              ))}
              {frame.pulse && pulsePath && (
                <path
                  key={frame.pulse.id}
                  d={pulsePath}
                  pathLength={100}
                  stroke={frame.pulse.color}
                  strokeWidth="1.5"
                  className="beam-pulse"
                />
              )}

              {/* Hub: the supervising claude-code session (real logo). */}
              <foreignObject x="2" y="150" width="114" height="40">
                <div className="flex h-10 items-center gap-2.5 rounded-full border border-white/20 bg-[#0b0e12]/85 px-3">
                  <AgentIcon name="Claude Code" size={20} color />
                  <span className="font-mono text-[13px] font-medium text-white/90">
                    claude
                  </span>
                </div>
              </foreignObject>

              {/* Worker sessions: real color logos, status shown by border/glow
                  as each lights up through the pipeline. */}
              {WORKERS.map((w, i) => {
                const status = frame.statuses[i] ?? "idle";
                return (
                  <foreignObject
                    key={w.handle}
                    x="182"
                    y={w.y - 17}
                    width="156"
                    height="34"
                    style={{
                      opacity: status === "idle" ? 0.5 : 1,
                      transition: "opacity 0.5s ease",
                    }}
                  >
                    <div
                      className="flex h-[34px] items-center gap-2 rounded-full border bg-[#0b0e12]/80 px-2.5"
                      style={{
                        borderColor: STATUS_BORDER[status],
                        boxShadow: STATUS_GLOW[status],
                        transition: "border-color 0.4s ease, box-shadow 0.4s ease",
                      }}
                    >
                      <AgentIcon name={w.name} size={18} color />
                      <span className="truncate font-mono text-[10px] text-white/75">
                        {w.handle}
                      </span>
                    </div>
                  </foreignObject>
                );
              })}
            </svg>
          </div>

          {/* Right: the CLI transcript, floating directly on the glow. */}
          <div>
            {/* Screen-reader copy of the pipeline's outcome; the animated pane
                re-renders too often to be useful aloud. */}
            <pre className="sr-only">
              {DONE_SUMMARY.map((l) => `${l.text}\n`).join("")}
            </pre>

            {/* min-height reserves the rolling window's space so the window does
                not grow line by line while typing. */}
            <pre
              aria-hidden="true"
              className="min-h-[251px] overflow-x-auto p-5 font-mono text-[13px] leading-relaxed sm:min-h-[259px] sm:p-6"
            >
              {frame.lines.map((line, i) =>
                line.blank ? (
                  <span key={line.id ?? i}>{"\n"}</span>
                ) : (
                  <span
                    key={line.id ?? i}
                    className={
                      // Output lines fade in on arrival; typed prompt lines
                      // are already animated by the typewriter, so they don't.
                      line.prompt
                        ? "block whitespace-pre"
                        : "line-in block whitespace-pre"
                    }
                  >
                    {line.prompt ? (
                      <>
                        <span className="select-none text-white/45">$ </span>
                        <span className="text-white/90">{line.text}</span>
                      </>
                    ) : (
                      <span className={line.json ? "text-[#7dd3fc]/90" : "text-white/60"}>
                        {line.text}
                      </span>
                    )}
                  </span>
                ),
              )}
              {frame.typing !== null && (
                <span className="block whitespace-pre">
                  <span className="select-none text-white/45">$ </span>
                  <span className="text-white/90">{frame.typing}</span>
                  <span className="demo-cursor text-white/70">▋</span>
                </span>
              )}
            </pre>
          </div>
        </div>
      </div>
    </div>
  );
}
