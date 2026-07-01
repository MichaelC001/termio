"use client";

import { useEffect, useState } from "react";
import { MeshGradient } from "@paper-design/shaders-react";
import { cn } from "@/lib/utils";

// A slow, restrained aurora behind the hero, via Paper Shaders (WebGL). Soft
// paper-light tints — bone → pale blue → warm clay — drifting almost
// imperceptibly over the off-white canvas, the matte "developer" look
// (Linear/Vercel/Resend), not a playful flowing blob. The real frosted texture
// comes from the grain layer on top (see `.grain-overlay` / hero.tsx); the
// in-shader grain just keeps the gradient from banding. The section's
// `.hero-cinematic` CSS gradient sits underneath as the SSR / no-WebGL fallback.
// Motion is paused for users who prefer reduced motion.
const PALETTE = ["#f8f5ee", "#e6ecf9", "#d7e4fb", "#f3e4da", "#eef0f6"];

export function HeroGradient({ className }: { className?: string }) {
  const [mounted, setMounted] = useState(false);
  const [reduceMotion, setReduceMotion] = useState(false);

  useEffect(() => {
    setReduceMotion(
      window.matchMedia("(prefers-reduced-motion: reduce)").matches,
    );
    setMounted(true);
  }, []);

  if (!mounted) return null;

  return (
    <MeshGradient
      colors={PALETTE}
      speed={reduceMotion ? 0 : 0.1}
      distortion={0.55}
      swirl={0.22}
      grainOverlay={0.16}
      className={cn("h-full w-full", className)}
    />
  );
}
