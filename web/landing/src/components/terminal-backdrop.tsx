"use client";

import { useEffect, useState } from "react";
import { MeshGradient } from "@paper-design/shaders-react";
import { cn } from "@/lib/utils";
import { useInView } from "@/lib/use-in-view";

// A slow Paper Shaders aurora that spans the whole orchestration window,
// behind both the session graph and the transcript. Same MeshGradient and same
// navy → blue → teal palette as the hero (see hero-gradient.tsx) — the user
// liked the top/bottom auroras, so this is that look, not a desaturated
// cousin. Legibility over 13–14px code comes from the layers, not the palette:
// a radial edge mask so the window border reads, plus a top/bottom darkening
// that protects the text rows.
//
// Motion + GPU work are fully gated: speed=0 (no rAF) when offscreen or when
// the user prefers reduced motion, and pixel ratio/count are capped hard since
// the gradient is soft and low-contrast.
const PALETTE = ["#070710", "#102a5e", "#1f63b0", "#2f8aa0", "#191636"];

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
          aurora is faint. */}
      <div className="absolute inset-0 bg-[#0b0e12]" />
      <div
        className="absolute inset-0"
        style={{
          WebkitMaskImage:
            "radial-gradient(130% 120% at 50% 45%, #000 55%, transparent 100%)",
          maskImage:
            "radial-gradient(130% 120% at 50% 45%, #000 55%, transparent 100%)",
        }}
      >
        <MeshGradient
          colors={PALETTE}
          speed={reduceMotion || !inView ? 0 : 0.3}
          distortion={0.55}
          swirl={0.22}
          // Grainier than the hero's 0.16, but kept moderate so the 14px
          // terminal text stays clean (0.9 was tried and read as noise).
          grainOverlay={0.35}
          minPixelRatio={1}
          maxPixelCount={1280 * 720}
          className="h-full w-full opacity-75"
        />
      </div>
      {/* A gentle top-down darkening keeps the transcript readable while the
          aurora stays lively toward the middle. */}
      <div className="absolute inset-0 bg-gradient-to-b from-black/25 via-transparent to-black/20" />
    </div>
  );
}
