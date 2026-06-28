import {
  Accordion,
  AccordionItem,
  AccordionTrigger,
  AccordionContent,
} from "@/components/ui/accordion";
import { Reveal } from "@/components/reveal";
import { SectionLabel } from "@/components/section-label";
import { supportedAgents } from "@/lib/site";
import { pricing } from "@/data/pricing";

const faqs: { question: string; answer: React.ReactNode }[] = [
  {
    question: "What does termio cost?",
    answer: (
      <p>
        Nothing right now. termio is free during early access — every feature is
        unlocked, with no account and no card. Paid lifetime licenses arrive in a
        later release, and early adopters keep the app.
      </p>
    ),
  },
  {
    question: "How do I get updates?",
    answer: (
      <p>
        Automatically. termio ships with built-in auto-updates, so once you
        download it the app keeps itself current — no reinstalling, no checking a
        website.
      </p>
    ),
  },
  {
    question: "Do I need an account?",
    answer: (
      <p>
        No. Download termio and use every feature — the app runs entirely on your
        Mac, with no sign-in and no card.
      </p>
    ),
  },
  {
    question: "Which agents are supported?",
    answer: (
      <p>
        termio gives a first-class native terminal to {supportedAgents.join(", ")}
        . Because each session is just a real PTY, any CLI-based agent works — and
        we add more as the ecosystem grows.
      </p>
    ),
  },
  {
    question: "Is my code private?",
    answer: (
      <p>
        Yes. termio is local-only: no telemetry, no cloud sync, and no account is
        needed to start. Your repositories, agent output and sessions never leave
        your machine.
      </p>
    ),
  },
  {
    question: "What are the requirements?",
    answer: (
      <p>
        {pricing.platformNote} termio is a native app built for Apple Silicon
        Macs. You bring your own agent CLIs and their API keys.
      </p>
    ),
  },
];

export function Faq() {
  return (
    <section id="faq" className="scroll-mt-24 border-t border-border">
      <div className="mx-auto grid w-full max-w-6xl gap-10 px-5 py-32 sm:py-40 sm:px-8 md:grid-cols-[0.85fr_1.15fr] md:gap-16">
        <Reveal>
          <SectionLabel accent="muted">Support</SectionLabel>
          <h2 className="mt-3 text-balance text-4xl font-bold tracking-[-0.045em] text-foreground sm:text-5xl">
            Frequently asked questions
          </h2>
          <p className="mt-5 max-w-sm text-base leading-relaxed text-muted-foreground">
            Can&apos;t find the answer you&apos;re looking for? The docs go deeper,
            or reach out and a human will help.
          </p>
          <a
            href="#top"
            className="mt-6 inline-flex items-center gap-2 rounded-full border border-border bg-card px-5 py-2.5 text-sm font-medium text-foreground transition-colors hover:bg-white/5"
          >
            Documentation
            <span aria-hidden="true">→</span>
          </a>
        </Reveal>

        <Reveal delayMs={80}>
          <Accordion className="border-t border-border">
            {faqs.map((faq) => (
              <AccordionItem key={faq.question} value={faq.question}>
                <AccordionTrigger className="py-5 text-base">
                  {faq.question}
                </AccordionTrigger>
                <AccordionContent className="text-muted-foreground">
                  {faq.answer}
                </AccordionContent>
              </AccordionItem>
            ))}
          </Accordion>
        </Reveal>
      </div>
    </section>
  );
}
