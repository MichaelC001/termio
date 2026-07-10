"use client";

import { useEffect, useState } from "react";
import { MeshGradient } from "@paper-design/shaders-react";
import { cn } from "@/lib/utils";
import { useInView } from "@/lib/use-in-view";

// A slow, restrained aurora behind the hero, via Paper Shaders (WebGL). Deep navy
// → indigo → violet over near-black, drifting almost imperceptibly — the matte
// "developer" look (Linear/Vercel/Resend), not a playful flowing blob. The real
// frosted texture comes from the grain layer on top (see `.grain-overlay` /
// hero.tsx); the in-shader grain just keeps the gradient from banding. The
// section's `.hero-cinematic` CSS gradient sits underneath as the SSR / no-WebGL
// fallback. Motion is paused for users who prefer reduced motion.
const PALETTE = ["#070710", "#102a5e", "#1f63b0", "#2f8aa0", "#191636"];

export function HeroGradient({ className }: { className?: string }) {
  const [mounted, setMounted] = useState(false);
  const [reduceMotion, setReduceMotion] = useState(false);
  // speed=0 cancels the shader's rAF loop entirely, so an offscreen aurora
  // (there are two on the page — hero and footer) costs nothing.
  const { ref, inView } = useInView<HTMLDivElement>();

  useEffect(() => {
    setReduceMotion(
      window.matchMedia("(prefers-reduced-motion: reduce)").matches,
    );
    setMounted(true);
  }, []);

  if (!mounted) return null;

  return (
    <MeshGradient
      ref={ref as React.Ref<never>}
      colors={PALETTE}
      speed={reduceMotion || !inView ? 0 : 0.3}
      distortion={0.55}
      swirl={0.22}
      grainOverlay={0.16}
      // The aurora is ultra-soft, so it doesn't need Retina resolution: 1x pixel
      // ratio capped at ~2MP quarters the per-frame fragment work vs. the
      // library defaults (minPixelRatio 2, ~8MP cap) with no visible difference
      // under the grain overlay.
      minPixelRatio={1}
      maxPixelCount={1920 * 1080}
      className={cn("h-full w-full", className)}
    />
  );
}
