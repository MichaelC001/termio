import {
  Accordion,
  AccordionItem,
  AccordionTrigger,
  AccordionContent,
} from "@/components/ui/accordion";
import { Reveal } from "@/components/reveal";
import { SectionLabel } from "@/components/section-label";
import { supportedAgents } from "@/lib/site";

const faqs: { question: string; answer: React.ReactNode }[] = [
  {
    question: "Is Termio free?",
    answer: (
      <p>
        Yes. Termio is free to use — every feature, no trial clock, no license
        key, no card. Just download it and go.
      </p>
    ),
  },
  {
    question: "How do I get updates?",
    answer: (
      <p>
        Automatically. Termio ships with built-in auto-updates, so once you
        download it the app keeps itself current — no reinstalling, no checking a
        website.
      </p>
    ),
  },
  {
    question: "Do I need an account?",
    answer: (
      <p>
        No. Download Termio and use every feature — the app runs entirely on your
        Mac, with no sign-in and no card.
      </p>
    ),
  },
  {
    question: "Which agents are supported?",
    answer: (
      <p>
        Termio gives a first-class native terminal to {supportedAgents.join(", ")}
        . Because each session is just a real PTY, any CLI-based agent works — and
        we add more as the ecosystem grows.
      </p>
    ),
  },
  {
    question: "Is my code private?",
    answer: (
      <p>
        Yes. Termio is local-only: no telemetry, no cloud sync, and no account is
        needed to start. Your repositories, agent output and sessions never leave
        your machine.
      </p>
    ),
  },
  {
    question: "What are the requirements?",
    answer: (
      <p>
        macOS, Apple Silicon. Termio is a native app built for Apple Silicon
        Macs. You bring your own agent CLIs and their API keys.
      </p>
    ),
  },
];

export function Faq() {
  return (
    <section id="faq" className="scroll-mt-24">
      <div className="mx-auto w-full max-w-2xl px-5 py-32 sm:py-40 sm:px-8">
        <Reveal className="flex flex-col items-center text-center">
          <SectionLabel accent="muted">Support</SectionLabel>
          <h2 className="mt-4 text-balance text-3xl font-medium leading-[1.1] tracking-tight text-foreground sm:text-[44px]">
            Frequently asked questions
          </h2>
          <p className="mt-5 max-w-md text-balance text-base leading-relaxed text-muted-foreground">
            Can&apos;t find the answer you&apos;re looking for? The docs go deeper,
            or reach out and a human will help.
          </p>
        </Reveal>

        <Reveal delayMs={80} className="mt-10">
          <Accordion className="border-t border-border">
            {faqs.map((faq) => (
              <AccordionItem key={faq.question} value={faq.question}>
                <AccordionTrigger className="items-center py-5 text-base font-medium">
                  {faq.question}
                </AccordionTrigger>
                <AccordionContent className="pr-8 text-muted-foreground">
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
