import { Reveal } from "@/components/reveal";
import { AgentMarquee } from "@/components/agent-icons";
import { supportedAgents } from "@/lib/site";

export function SocialProof() {
  return (
    <section aria-label="Supported AI coding agents">
      <div className="mx-auto w-full max-w-6xl px-5 py-32 sm:py-40 sm:px-8">
        <Reveal>
          <h2 className="text-center text-4xl font-semibold tracking-[-0.045em] text-foreground sm:text-5xl">
            Works with the agents you already use
          </h2>
        </Reveal>
        <Reveal delayMs={60}>
          <p className="mx-auto mt-4 max-w-xl text-center text-base text-muted-foreground">
            Bring your own CLI and API keys — termio gives each one a real native
            terminal.
          </p>
        </Reveal>
        <Reveal delayMs={120} className="mt-12">
          <AgentMarquee agents={supportedAgents} />
        </Reveal>
      </div>
    </section>
  );
}
