"use client";

import { useEffect, useState } from "react";
import { GodRays } from "@paper-design/shaders-react";
import { cn } from "@/lib/utils";
import { useInView } from "@/lib/use-in-view";

// Soft god rays fanning out from behind the CTA heading — the same Paper
// Shaders family as the hero aurora, but directional instead of drifting, so
// the card reads as a single quiet light source rather than a texture. Colors
// stay on the site's navy → teal axis (the teal echoes the download button's
// glow) over the card's own `#0c0c0f`, so the shader fades into the card at
// the edges without any CSS mask. Renders only after mount (WebGL needs the
// client); until then the card's `bg-card` stands in, same black, no flash.
const RAY_COLORS = ["#102c50", "#17497f", "#1f6d86", "#4fb3a6"];

export function CtaRays({ className }: { className?: string }) {
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
    <GodRays
      ref={ref as React.Ref<never>}
      colorBack="#0c0c0f"
      colorBloom="#123055"
      colors={RAY_COLORS}
      // Light source sits just above the card's top edge, centered on the
      // heading, so the beams sweep down and outward across the copy.
      offsetX={0}
      offsetY={-0.6}
      density={0.16}
      spotty={0.28}
      midIntensity={0.25}
      midSize={0.3}
      intensity={0.35}
      bloom={0.18}
      speed={reduceMotion || !inView ? 0 : 0.25}
      // Same perf cap as the hero aurora: the rays are ultra-soft, so 1x
      // pixel ratio at ~2MP is indistinguishable from the library defaults.
      minPixelRatio={1}
      maxPixelCount={1920 * 1080}
      className={cn("h-full w-full", className)}
    />
  );
}
