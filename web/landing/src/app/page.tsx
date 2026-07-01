import { SiteNav } from "@/components/site-nav";
import { Hero } from "@/components/sections/hero";
import { Features } from "@/components/sections/features";
import { Faq } from "@/components/sections/faq";
import { CtaBand } from "@/components/sections/cta-band";
import { SiteFooter } from "@/components/site-footer";
import { HeroGradient } from "@/components/hero-gradient";

export default function Home() {
  return (
    <>
      <SiteNav />
      <main className="flex-1">
        <Hero />
        <Features />
        <Faq />
      </main>
      {/* Shaded outro — mirrors the hero. The CTA band and footer share one slow
          aurora (same MeshGradient), and the footer floats over it as glass,
          echoing the way the nav floats over the hero shader up top. */}
      <div className="hero-cinematic relative isolate overflow-hidden">
        <HeroGradient className="absolute inset-0 -z-10" />
        {/* Frosted film grain over the aurora, matching the hero. */}
        <div
          aria-hidden="true"
          className="grain-overlay pointer-events-none absolute -inset-[6%] -z-10"
        />
        {/* Fade the page above down into the aurora (the hero's bottom fade, flipped). */}
        <div
          aria-hidden="true"
          className="pointer-events-none absolute inset-x-0 top-0 -z-10 h-72 bg-gradient-to-b from-background to-transparent"
        />
        <CtaBand />
        <SiteFooter />
      </div>
    </>
  );
}
