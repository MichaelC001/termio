import { Reveal } from "@/components/reveal";
import { supportedAgents } from "@/lib/site";

export function SocialProof() {
  return (
    <section
      aria-label="Supported AI coding agents"
      className="border-y border-border bg-[#f9f9f9]"
    >
      <div className="mx-auto w-full max-w-6xl px-5 py-12 sm:px-8">
        <Reveal>
          <p className="text-center text-xs font-semibold uppercase tracking-[0.18em] text-muted-foreground">
            One home for the agents developers who move fast already run
          </p>
        </Reveal>
        <Reveal delayMs={80}>
          <ul className="mt-7 flex flex-wrap items-center justify-center gap-x-8 gap-y-4 sm:gap-x-12">
            {supportedAgents.map((agent) => (
              <li
                key={agent}
                className="font-mono text-sm font-medium text-[#888b91] transition-colors hover:text-foreground"
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
