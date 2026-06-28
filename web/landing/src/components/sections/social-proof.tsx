import { Reveal } from "@/components/reveal";
import { supportedAgents } from "@/lib/site";

export function SocialProof() {
  return (
    <section
      aria-label="Supported AI coding agents"
      className=""
    >
      <div className="mx-auto w-full max-w-6xl px-5 py-32 sm:py-40 sm:px-8">
        <Reveal>
          <h2 className="text-center text-4xl font-bold tracking-[-0.045em] text-foreground sm:text-5xl">
            Built for developers who move fast
          </h2>
        </Reveal>
        <Reveal delayMs={60}>
          <p className="mx-auto mt-4 max-w-xl text-center text-base text-muted-foreground">
            One roof for every agent the fastest-moving teams already run.
          </p>
        </Reveal>
        <Reveal delayMs={120}>
          <ul className="mt-12 flex flex-wrap items-center justify-center gap-x-8 gap-y-4 sm:gap-x-12">
            {supportedAgents.map((agent) => (
              <li
                key={agent}
                className="font-mono text-sm font-medium text-muted-foreground/70 transition-colors hover:text-foreground"
              >
                {agent}
              </li>
            ))}
          </ul>
        </Reveal>
      </div>
    </section>
  );
}
