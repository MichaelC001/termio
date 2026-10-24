import {
  Accordion,
  AccordionItem,
  AccordionTrigger,
  AccordionContent,
} from "@/components/ui/accordion";
import { Reveal } from "@/components/reveal";
import Link from "next/link";
import { Section } from "@/components/section-label";

// Plain strings (not JSX) so the same copy feeds both the rendered accordion
// and the FAQPage structured data below. Only the questions a visitor asks
// before downloading; the rest live in the docs.
const faqs: { question: string; answer: string }[] = [
  {
    question: "Is Termio free?",
    answer: "Yes. Termio is free and open source. No account, no cloud.",
  },
  {
    question:
      "What happens to a running agent when I quit Termio or close the laptop?",
    answer:
      "Sessions are hosted by termiod, not the app window. Quit Termio, sleep the laptop, or reboot — the agent keeps running. Reattach restores the exact screen.",
  },
  {
    question: "Can I run agents on a remote machine?",
    answer:
      "Yes. Any Linux VPS you can ssh to — Termio reads ~/.ssh/config and never rewrites it. Set Up copies one binary over SSH, starts the daemon, and installs the agents’ hooks there. Local and remote sessions run through the same host.",
  },
  {
    question: "How is this different from Zed remote or VS Code Remote?",
    answer:
      "The session lives on the machine, not in the connection. Drop the link and the agent keeps running; reattach restores the exact screen. Zed Remote and VS Code Remote keep remote work inside a live connection.",
  },
  {
    question: "How is this different from tmux?",
    answer:
      "tmux is a prefix-key multiplexer you attach a terminal to. Termio is a native Mac app with its own session host — same sessions on this Mac, a remote box, or the iPhone companion. You don’t have to learn tmux. There is no prefix key to remember.",
  },
  {
    question: "Is my code private?",
    answer:
      "Yes. No account, no cloud, no telemetry. Code never leaves machines you own.",
  },
];

// FAQPage structured data so the questions are eligible for rich results.
const faqJsonLd = {
  "@context": "https://schema.org",
  "@type": "FAQPage",
  mainEntity: faqs.map((faq) => ({
    "@type": "Question",
    name: faq.question,
    acceptedAnswer: { "@type": "Answer", text: faq.answer },
  })),
};

export function Faq() {
  return (
    <Section id="faq">
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(faqJsonLd) }}
      />
      <div className="grid gap-10 lg:grid-cols-[minmax(0,2fr)_minmax(0,3fr)] lg:gap-16">
        <Reveal className="flex flex-col items-start">
          <h2 className="text-balance text-4xl font-medium leading-[1.05] tracking-tight text-foreground sm:text-5xl">
            Questions.
          </h2>
          <p className="mt-5 max-w-sm text-pretty text-base leading-relaxed text-muted-foreground">
            The docs go deeper, or reach out and a human will help.
          </p>
          <Link
            href="/docs"
            className="mt-6 text-sm font-medium text-foreground underline-offset-4 hover:underline"
          >
            Read the docs
          </Link>
        </Reveal>

        <Reveal delayMs={80}>
          <Accordion className="border-t border-border">
            {faqs.map((faq) => (
              <AccordionItem key={faq.question} value={faq.question}>
                <AccordionTrigger className="items-center py-5 text-base font-medium">
                  {faq.question}
                </AccordionTrigger>
                <AccordionContent className="pr-8 text-muted-foreground">
                  <p>{faq.answer}</p>
                </AccordionContent>
              </AccordionItem>
            ))}
          </Accordion>
        </Reveal>
      </div>
    </Section>
  );
}
