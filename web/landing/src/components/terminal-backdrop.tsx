"use client";

import { useEffect, useState } from "react";
import { GrainGradient } from "@paper-design/shaders-react";
import { cn } from "@/lib/utils";
import { useInView } from "@/lib/use-in-view";

// A slow Paper Shaders grain-gradient glow that sits only behind the session
// graph (never behind the transcript). It's a soft, filmic cool-slate haze
// that drifts almost imperceptibly — the "developer" cousin of the hero
// aurora, desaturated to a neutral graphite so the section carries no color
// cast. A grainy blob gradient — not a dot matrix — reads as an ambient light
// haze, calm behind the nodes. It fills its container (clipped by the rounded
// border) over a near-black base; a soft vignette darkens the far edges so the
// page stays legible over it.
//
// Motion + GPU work are fully gated: speed=0 (no rAF) when offscreen or when
// the user prefers reduced motion, and pixel ratio/count are capped hard since
// the gradient is soft and low-contrast.
export function TerminalBackdrop({ className }: { className?: string }) {
  const [mounted, setMounted] = useState(false);
  const [reduceMotion, setReduceMotion] = useState(false);
  const { ref, inView } = useInView<HTMLDivElement>();

  useEffect(() => {
    setReduceMotion(
      window.matchMedia("(prefers-reduced-motion: reduce)").matches,
    );
    setMounted(true);
  }, []);

  if (!mounted) return null;

  return (
    <div
      ref={ref}
      aria-hidden="true"
      className={cn("pointer-events-none absolute inset-0", className)}
    >
      {/* Near-black base so the window is dark enough for code even where the
          dithering is sparse. */}
      <div className="absolute inset-0 bg-[#0b0e12]" />
      <div
        className="absolute inset-0"
        style={{
          // Keep the field full through the center, fading it near the edges so
          // the border reads and text stays legible.
          WebkitMaskImage:
            "radial-gradient(130% 120% at 50% 45%, #000 55%, transparent 100%)",
          maskImage:
            "radial-gradient(130% 120% at 50% 45%, #000 55%, transparent 100%)",
        }}
      >
        <GrainGradient
          colorBack="#00000000"
          colors={["#0d0f14", "#1a1f2b", "#333b4a"]}
          shape="blob"
          softness={0.9}
          intensity={0.32}
          noise={0.28}
          scale={1.2}
          speed={reduceMotion || !inView ? 0 : 0.22}
          minPixelRatio={1}
          maxPixelCount={1280 * 720}
          className="h-full w-full opacity-70"
        />
      </div>
      {/* A gentle top-down darkening keeps the transcript readable while the
          dithering stays lively toward the bottom. */}
      <div className="absolute inset-0 bg-gradient-to-b from-black/25 via-transparent to-black/20" />
    </div>
  );
}
