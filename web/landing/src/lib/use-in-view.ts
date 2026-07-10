"use client";

import { useCallback, useRef, useState } from "react";

// Tracks whether an element is (near) the viewport, so always-on animations —
// the WebGL aurora, carousel autoplay — can fully stop while scrolled away
// instead of burning CPU/GPU offscreen. `rootMargin` pre-wakes the animation
// slightly before it scrolls back in.
//
// Returns a CALLBACK ref on purpose: consumers like HeroGradient mount their
// target element a render late (after a `mounted` gate), so an effect that
// reads `ref.current` once would observe nothing and `inView` would stick true.
export function useInView<T extends HTMLElement>(rootMargin = "100px") {
  const [inView, setInView] = useState(true);
  const observerRef = useRef<IntersectionObserver | null>(null);

  const ref = useCallback(
    (node: T | null) => {
      observerRef.current?.disconnect();
      observerRef.current = null;
      if (!node) return;
      const observer = new IntersectionObserver(
        ([entry]) => setInView(entry.isIntersecting),
        { rootMargin },
      );
      observer.observe(node);
      observerRef.current = observer;
    },
    [rootMargin],
  );

  return { ref, inView };
}
