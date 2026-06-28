"use client";

import { useEffect, useState } from "react";
import { MeshGradient } from "@paper-design/shaders-react";
import { cn } from "@/lib/utils";

// Animated flowing mesh-gradient behind the hero, via Paper Shaders (WebGL). The
// section's `.hero-cinematic` CSS gradient sits underneath as the SSR / no-WebGL
// fallback, so this only needs to fade in once mounted. Motion is paused for
// users who prefer reduced motion.
const PALETTE = ["#0c1538", "#2a5bc4", "#5f82e0", "#9b8fd4", "#cbb4d3"];

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
      speed={reduceMotion ? 0 : 0.25}
      distortion={0.85}
      swirl={0.45}
      grainOverlay={0.04}
      className={cn("h-full w-full", className)}
    />
  );
}
