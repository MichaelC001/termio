"use client";

import Image from "next/image";
import { useCallback, useEffect, useRef, useState } from "react";
import { cn } from "@/lib/utils";
import { useInView } from "@/lib/use-in-view";

export type HeroSlide = {
  src: string;
  alt: string;
  width: number;
  height: number;
};

const AUTOPLAY_MS = 5000;

// Cross-fade hero carousel (otty.sh-style): slides are stacked absolutely and
// fade between each other instead of sliding, so the window "changes content"
// in place. Autoplays, pauses on hover/focus, and respects reduced motion.
export function HeroCarousel({ slides }: { slides: readonly HeroSlide[] }) {
  const [active, setActive] = useState(0);
  const [paused, setPaused] = useState(false);
  const reducedMotion = useRef(false);
  const { ref: viewRef, inView } = useInView<HTMLDivElement>();

  const goTo = useCallback(
    (index: number) => setActive((index + slides.length) % slides.length),
    [slides.length],
  );

  useEffect(() => {
    reducedMotion.current = window.matchMedia(
      "(prefers-reduced-motion: reduce)",
    ).matches;
  }, []);

  useEffect(() => {
    if (paused || !inView || slides.length < 2 || reducedMotion.current) return;
    const timer = setInterval(
      () => setActive((i) => (i + 1) % slides.length),
      AUTOPLAY_MS,
    );
    return () => clearInterval(timer);
  }, [paused, inView, slides.length]);

  if (slides.length === 0) return null;
  const { width, height } = slides[0];

  return (
    <div
      ref={viewRef}
      role="region"
      aria-roledescription="carousel"
      aria-label="Termio screenshots"
      className="group relative w-full overflow-hidden rounded-2xl shadow-soft"
      style={{ aspectRatio: `${width} / ${height}` }}
      onMouseEnter={() => setPaused(true)}
      onMouseLeave={() => setPaused(false)}
      onFocus={() => setPaused(true)}
      onBlur={() => setPaused(false)}
      onKeyDown={(e) => {
        if (e.key === "ArrowLeft") goTo(active - 1);
        if (e.key === "ArrowRight") goTo(active + 1);
      }}
    >
      {slides.map((slide, i) => (
        <Image
          key={slide.src}
          src={slide.src}
          width={slide.width}
          height={slide.height}
          alt={slide.alt}
          priority={i === 0}
          draggable={false}
          aria-hidden={i !== active}
          className={cn(
            "absolute inset-0 h-full w-full object-cover transition-[opacity,transform] duration-700 ease-out",
            i === active
              ? "opacity-100 scale-100"
              : "pointer-events-none opacity-0 scale-[1.012]",
          )}
        />
      ))}

      {slides.length > 1 && (
        <>
          <CarouselArrow dir="prev" onClick={() => goTo(active - 1)} />
          <CarouselArrow dir="next" onClick={() => goTo(active + 1)} />

          <div
            aria-label="Choose screenshot"
            className="absolute bottom-3 left-1/2 z-10 inline-flex -translate-x-1/2 items-center gap-1.5 rounded-full bg-black/40 px-2 py-1.5 backdrop-blur-md"
          >
            {slides.map((slide, i) => (
              <button
                key={slide.src}
                type="button"
                aria-label={`Show screenshot ${i + 1}`}
                aria-current={i === active}
                onClick={() => goTo(i)}
                className={cn(
                  "h-1.5 rounded-full transition-all duration-200",
                  i === active
                    ? "w-4 bg-white"
                    : "w-1.5 bg-white/50 hover:bg-white/80",
                )}
              />
            ))}
          </div>
        </>
      )}
    </div>
  );
}

export function CarouselArrow({
  dir,
  onClick,
}: {
  dir: "prev" | "next";
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      aria-label={dir === "prev" ? "Previous screenshot" : "Next screenshot"}
      className={cn(
        "absolute top-1/2 z-10 grid size-12 -translate-y-1/2 place-items-center rounded-full sm:size-14",
        "bg-white/90 text-neutral-900 shadow-[0_1px_rgba(10,10,10,0.06),0_6px_18px_-6px_rgba(10,10,10,0.22)] backdrop-blur-md",
        "opacity-0 transition-[opacity,background-color] duration-200",
        "hover:bg-white active:scale-95",
        "group-hover:opacity-100 group-focus-within:opacity-100",
        dir === "prev" ? "left-4" : "right-4",
      )}
    >
      <svg
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        strokeWidth={2}
        strokeLinecap="round"
        strokeLinejoin="round"
        className="size-5 sm:size-6"
      >
        <path d={dir === "prev" ? "M15 6l-6 6 6 6" : "M9 6l6 6-6 6"} />
      </svg>
    </button>
  );
}
