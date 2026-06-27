import type { Metadata } from "next";
import { SiteNav } from "@/components/site-nav";
import { Pricing } from "@/components/sections/pricing";
import { Faq } from "@/components/sections/faq";
import { CtaBand } from "@/components/sections/cta-band";
import { SiteFooter } from "@/components/site-footer";

export const metadata: Metadata = {
  title: "Pricing",
  description:
    "termio is a one-time lifetime license — no subscription: Solo $19.90 for 1 Mac, Pro $39.90 for up to 3 Macs, plus a Team tier for 5+ seats. All future updates included, a 30-day money-back guarantee, and a 7-day no-account free trial.",
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
