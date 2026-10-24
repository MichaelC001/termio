import { SiteNav } from "@/components/site-nav";
import { Hero } from "@/components/sections/hero";
import { Agents } from "@/components/sections/agents";
import { Features } from "@/components/sections/features";
import { Faq } from "@/components/sections/faq";
import { CtaBand } from "@/components/sections/cta-band";
import { SiteFooter } from "@/components/site-footer";
import { downloadUrl } from "@/lib/site";

// SoftwareApplication structured data — tells search engines this page is a
// free, native macOS developer app with a direct download.
const appJsonLd = {
  "@context": "https://schema.org",
  "@type": "SoftwareApplication",
  name: "Termio",
  operatingSystem: "macOS",
  applicationCategory: "DeveloperApplication",
  offers: { "@type": "Offer", price: "0", priceCurrency: "USD" },
  url: "https://www.termio.sh",
  downloadUrl,
  image: "https://www.termio.sh/og.webp",
  description:
    "Termio is the Terminal-first Agentic Development Environment — a native Mac app for your AI coding agents: Claude Code, Codex, OpenCode, Pi Agent and more. Run them side by side, each in a real terminal, and nothing ever leaves your machine.",
};

export default function Home() {
  return (
    <>
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(appJsonLd) }}
      />
      <SiteNav />
      <main className="flex-1">
        <Hero />
        <Agents />
        <Features />
        <Faq />
        <CtaBand />
      </main>
      <SiteFooter />
    </>
  );
}
