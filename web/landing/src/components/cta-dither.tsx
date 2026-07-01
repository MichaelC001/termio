"use client";

import { useEffect, useState } from "react";
import { Dithering } from "@paper-design/shaders-react";
import { cn } from "@/lib/utils";

// A frozen 1-bit dither behind the CTA card — a nod to the monochrome Mac /
// terminal heritage that fits Termio. `speed={0}` makes it a static, resolution-
// independent texture (no per-frame redraw, so it's essentially free next to the
// outro aurora). The two tones sit a hair apart on near-black so it reads as a
// sanded matte surface, not an op-art pattern; a radial mask keeps it densest
// behind the heading and fades to the card's own `#0c0c0f` at the edges. Renders
// only after mount (WebGL needs the client) — until then the card's `bg-card`
// stands in, which is the same black, so there's no flash.
export function CtaDither({ className }: { className?: string }) {
  const [mounted, setMounted] = useState(false);
  useEffect(() => setMounted(true), []);
  if (!mounted) return null;

  return (
    <Dithering
      colorBack="#0c0c0f"
      colorFront="#31507f"
      shape="simplex"
      type="4x4"
      size={4}
      speed={0}
      className={cn("h-full w-full", className)}
    />
  );
}
