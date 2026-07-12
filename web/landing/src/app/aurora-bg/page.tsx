"use client";

import { HeroGradient } from "@/components/hero-gradient";

// Temporary render target for App Store panel backgrounds: screenshot
// http://localhost:<port>/aurora-bg at 1284×2778 with headless Chrome, then
// delete this route. Bare aurora + grain, no content — the panels lay their
// own caption and device frame over it. Not linked from anywhere.
export default function AuroraBackgroundPage() {
  return (
    <main
      className="relative overflow-hidden bg-background"
      style={{ width: 1284, height: 2778 }}
    >
      <style>{`nextjs-portal { display: none; }`}</style>
      <HeroGradient className="absolute inset-0" />
      <div
        aria-hidden="true"
        className="grain-overlay pointer-events-none absolute -inset-[6%]"
      />
    </main>
  );
}
