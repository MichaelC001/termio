import { cn } from "@/lib/utils";

// The termio wordmark: a small terminal-window glyph carrying the traffic-light
// trio, set next to the lowercase name. Decorative — the surrounding link/anchor
// carries the accessible label.
export function Logo({ className }: { className?: string }) {
  return (
    <span className={cn("inline-flex items-center gap-2.5", className)}>
      <span
        aria-hidden="true"
        className="flex h-7 w-7 items-center justify-start gap-[3px] rounded-lg bg-foreground pl-[6px]"
      >
        <span className="h-1.5 w-1.5 rounded-full bg-brand-red" />
        <span className="h-1.5 w-1.5 rounded-full bg-brand-amber" />
        <span className="h-1.5 w-1.5 rounded-full bg-brand-green" />
      </span>
      <span className="text-lg font-semibold tracking-tight text-foreground">
        termio
      </span>
    </span>
  );
}
