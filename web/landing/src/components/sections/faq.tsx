import {
  Accordion,
  AccordionItem,
  AccordionTrigger,
  AccordionContent,
} from "@/components/ui/accordion";
import { Reveal } from "@/components/reveal";
import { supportedAgents } from "@/lib/site";
import { pricing, formatPrice } from "@/data/pricing";

const solo = pricing.plans.find((plan) => plan.id === "solo");
const pro = pricing.plans.find((plan) => plan.id === "pro");

const faqs: { question: string; answer: React.ReactNode }[] = [
  {
    question: "Is termio a subscription?",
    answer: (
      <p>
        No. termio is a one-time purchase —{" "}
        {solo ? formatPrice(solo.priceCents) : "$19.90"} for Solo,{" "}
        {pro ? formatPrice(pro.priceCents) : "$39.90"} for Pro. You pay once and
        own it forever, including every future update. There is no yearly
        renewal and no recurring charge, ever.
      </p>
    ),
  },
  {
    question: "Solo vs Pro — how many Macs can I use it on?",
    answer: (
      <p>
        Solo ({solo ? formatPrice(solo.priceCents) : "$19.90"}) licenses one Mac.
        Pro ({pro ? formatPrice(pro.priceCents) : "$39.90"}) covers up to three
        of your own Macs — pick Pro if you switch between, say, a desktop and a
        laptop. Both are one-time purchases with all updates included.
      </p>
    ),
  },
  {
    question: "What is the refund policy?",
    answer: (
      <p>
        Every purchase comes with a {pricing.refund.days}-day money-back
        guarantee. If termio is not for you, email us within {pricing.refund.days}{" "}
        days and we refund you in full — no questions asked.
      </p>
    ),
  },
  {
    question: "How does the free trial work?",
    answer: (
      <p>
        Download termio and use every feature for {pricing.trial.durationDays}{" "}
        days. No account and no card — the trial runs entirely on your Mac. When
        you buy a license, the same install unlocks; you don&apos;t reinstall
        anything.
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
    <section id="faq" className="scroll-mt-20 border-t border-border bg-[#f9f9f9]">
      <div className="mx-auto w-full max-w-3xl px-5 py-24 sm:px-8">
        <Reveal>
          <p className="text-center text-xs font-semibold uppercase tracking-[0.18em] text-muted-foreground">
            FAQ
          </p>
        </Reveal>
        <Reveal delayMs={60}>
          <h2 className="mt-4 text-balance text-center text-3xl font-semibold tracking-tight text-foreground sm:text-4xl">
            Questions, answered
          </h2>
        </Reveal>

        <Reveal delayMs={100} className="mt-12">
          <Accordion className="rounded-2xl border border-border bg-card px-6">
            {faqs.map((faq) => (
              <AccordionItem key={faq.question} value={faq.question}>
                <AccordionTrigger className="py-5 text-base">
                  {faq.question}
                </AccordionTrigger>
                <AccordionContent className="text-[#333333]">
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
