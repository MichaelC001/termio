import type { Metadata } from "next";
import { SiteNav } from "@/components/site-nav";
import { Pricing } from "@/components/sections/pricing";
import { Faq } from "@/components/sections/faq";
import { CtaBand } from "@/components/sections/cta-band";
import { SiteFooter } from "@/components/site-footer";

export const metadata: Metadata = {
  title: "Pricing",
  description:
    "termio is free during early access — every feature unlocked, no account, no card, with automatic updates built in. Paid lifetime licenses arrive in a later release.",
};

export default function PricingPage() {
  return (
    <>
      <SiteNav />
      <main className="flex-1 pt-8">
        <Pricing />
        <Faq />
        <CtaBand />
      </main>
      <SiteFooter />
    </>
  );
}
