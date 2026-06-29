import type { Metadata } from "next";
import { SiteNav } from "@/components/site-nav";
import { Pricing } from "@/components/sections/pricing";
import { Faq } from "@/components/sections/faq";
import { CtaBand } from "@/components/sections/cta-band";
import { SiteFooter } from "@/components/site-footer";

export const metadata: Metadata = {
  title: "Pricing",
  description:
    "termio is a one-time lifetime license — Solo $19.90 for one Mac, Pro $39.90 for up to three. Pay once, own it forever with all updates included. No subscription. 7-day free trial, 30-day money-back guarantee.",
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
