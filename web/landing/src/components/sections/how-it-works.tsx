import { Reveal } from "@/components/reveal";

const steps = [
  {
    number: "01",
    title: "Open your project",
    description:
      "Point termio at a repo. It becomes a project in the dashboard sidebar, ready for any agent.",
  },
  {
    number: "02",
    title: "Launch an agent",
    description:
      "One tap spins up Claude Code, Codex, Gemini or any supported CLI in its own git worktree and hosted session.",
  },
  {
    number: "03",
    title: "Walk away",
    description:
      "Run several agents at once. Quit the app, restart your Mac — the sessions keep going and reconnect when you're back.",
  },
];

export function HowItWorks() {
  return (
    <section
      aria-labelledby="how-it-works-heading"
      className="border-y border-border bg-[#f9f9f9]"
    >
      <div className="mx-auto w-full max-w-6xl px-5 py-24 sm:px-8">
        <Reveal>
          <p className="text-center text-xs font-semibold uppercase tracking-[0.18em] text-muted-foreground">
            How it works
          </p>
        </Reveal>
        <Reveal delayMs={60}>
          <h2
            id="how-it-works-heading"
            className="mx-auto mt-4 max-w-2xl text-balance text-center text-3xl font-semibold tracking-tight text-foreground sm:text-4xl"
          >
            From clone to running agents in three steps
          </h2>
        </Reveal>

        <ol className="mt-14 grid gap-6 md:grid-cols-3">
          {steps.map((step, index) => (
            <Reveal as="li" key={step.number} delayMs={index * 90}>
              <div className="h-full rounded-2xl border border-border bg-card p-7 shadow-sm">
                <span className="brand-text-gradient font-mono text-3xl font-semibold">
                  {step.number}
                </span>
                <h3 className="mt-4 text-lg font-semibold tracking-tight text-foreground">
                  {step.title}
                </h3>
                <p className="mt-2 text-sm leading-relaxed text-[#333333]">
                  {step.description}
                </p>
              </div>
            </Reveal>
          ))}
        </ol>
      </div>
    </section>
  );
}
