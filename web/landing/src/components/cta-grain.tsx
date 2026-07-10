"use client";

import { useEffect, useState } from "react";
import { GrainGradient } from "@paper-design/shaders-react";
import { cn } from "@/lib/utils";
import { useInView } from "@/lib/use-in-view";

// Grainy wave gradient behind the CTA card (Paper Shaders' grain-gradient,
// `wave` shape) — slow bands of light rolling across the card, with the
// shader's own grain doing the matte/frosted work. Tuned from the paper.design
// playground preset but recolored from its warm amber onto the site's navy →
// teal axis (the teal echoes the download button's glow) over the card's own
// near-black. Renders only after mount (WebGL needs the client); until then
// the card's `bg-card` stands in, same black, no flash.
// Brightness stays capped well below the card's white copy — the playground
// preset's cream highlight would wash out the subtitle sitting on the crest.
const WAVE_COLORS = ["#123a66", "#20668a", "#3f9e94"];

export function CtaGrain({ className }: { className?: string }) {
  const [mounted, setMounted] = useState(false);
  const [reduceMotion, setReduceMotion] = useState(false);
  // speed=0 cancels the shader's rAF loop while the card is offscreen.
  const { ref, inView } = useInView<HTMLDivElement>();

  useEffect(() => {
    setReduceMotion(
      window.matchMedia("(prefers-reduced-motion: reduce)").matches,
    );
    setMounted(true);
  }, []);

  if (!mounted) return null;

  return (
    <GrainGradient
      ref={ref as React.Ref<never>}
      colorBack="#0c0c0f"
      colors={WAVE_COLORS}
      shape="wave"
      softness={0.7}
      intensity={0.15}
      noise={0.5}
      speed={reduceMotion || !inView ? 0 : 1}
      // Same perf cap as the hero aurora: the waves are ultra-soft, so 1x
      // pixel ratio at ~2MP is indistinguishable from the library defaults.
      minPixelRatio={1}
      maxPixelCount={1920 * 1080}
      className={cn("h-full w-full", className)}
    />
  );
}
