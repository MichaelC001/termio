"use client";

import { useEffect, useState } from "react";
import { MeshGradient } from "@paper-design/shaders-react";
import { cn } from "@/lib/utils";
import { useInView } from "@/lib/use-in-view";

// A slow Paper Shaders aurora that spans the whole orchestration window,
// behind both the session graph and the transcript. Same MeshGradient hue
// family as the hero (see hero-gradient.tsx), but several stops darker: the
// full-brightness hero palette floated the window off the black page, so this
// one is dimmed until the glow sits *in* the dark instead of on top of it.
// Legibility over 13–14px code comes from the layers too: a radial edge mask
// so the window border reads, plus a top/bottom darkening that protects the
// text rows.
//
// Motion + GPU work are fully gated: speed=0 (no rAF) when offscreen or when
// the user prefers reduced motion, and pixel ratio/count are capped hard since
// the gradient is soft and low-contrast.
const PALETTE = ["#070710", "#0e234e", "#1a508f", "#267083", "#161330"];

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
          // Light grain only: 0.35 muddied the mesh motion, 0.9 read as pure
          // noise over 14px terminal text.
          grainOverlay={0.24}
          minPixelRatio={1}
          maxPixelCount={1280 * 720}
          className="h-full w-full opacity-[0.64]"
        />
      </div>
      {/* Dark anchors top and bottom, but the middle stays open so the mesh
          motion actually reads. */}
      <div className="absolute inset-0 bg-[linear-gradient(to_bottom,rgba(0,0,0,0.28),rgba(0,0,0,0.08)_48%,rgba(0,0,0,0.24))]" />
    </div>
  );
}
