import Image from "next/image";
import { cn } from "@/lib/utils";

// The termio wordmark: the real macOS app icon set next to the lowercase name.
// Decorative — the surrounding link/anchor carries the accessible label.
export function Logo({ className }: { className?: string }) {
  return (
    <span className={cn("inline-flex items-center gap-2.5", className)}>
      <Image
        src="/logo.png"
        alt=""
        aria-hidden="true"
        width={28}
        height={28}
        className="h-7 w-7"
        priority
      />
      <span className="text-lg font-semibold tracking-tight text-foreground">
        termio
      </span>
    </span>
  );
}
