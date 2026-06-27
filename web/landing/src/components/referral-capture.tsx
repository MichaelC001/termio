"use client";

import { Suspense, useEffect, useState } from "react";
import { useSearchParams } from "next/navigation";
import { X } from "lucide-react";
import { writeReferralCookie } from "@/lib/referral";

// Reads `?ref=CODE` from the URL, persists it to the `termio_ref` cookie so it
// survives the visitor's journey to download/sign-up, and surfaces a slim
// dismissible banner. Mounted in the root layout so invite links like
// `/?ref=CODE` and `/refer?ref=CODE` are captured everywhere.
//
// useSearchParams() requires a Suspense boundary during prerender, hence the
// wrapper export below.
function ReferralCaptureInner() {
  const searchParams = useSearchParams();
  const ref = searchParams.get("ref");
  const [dismissed, setDismissed] = useState(false);

  useEffect(() => {
    if (ref) writeReferralCookie(ref);
  }, [ref]);

  if (!ref || dismissed) return null;

  return (
    <div
      role="region"
      aria-label="Referral invitation"
      className="border-b border-border bg-card"
    >
      <div className="mx-auto flex w-full max-w-6xl items-center gap-3 px-5 py-2.5 text-sm sm:px-8">
        <p className="flex-1 text-[#333333]">
          <span aria-hidden="true">🎁</span>{" "}
          <span className="font-medium text-foreground">You were invited</span> —
          start your 14-day trial and get $5 off.
        </p>
        <button
          type="button"
          onClick={() => setDismissed(true)}
          aria-label="Dismiss invitation"
          className="rounded-md p-1 text-muted-foreground transition-colors hover:text-foreground focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring"
        >
          <X className="h-4 w-4" aria-hidden="true" />
        </button>
      </div>
    </div>
  );
}

export function ReferralCapture() {
  return (
    <Suspense fallback={null}>
      <ReferralCaptureInner />
    </Suspense>
  );
}
