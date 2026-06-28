import { cn } from "@/lib/utils";

// Superwhisper's section eyebrow: small, semibold, *colored* text — each section
// carries a different accent ("What's inside" magenta, "Custom Mode" blue, "Beep
// boop" yellow). Not a pill, not uppercase — just a tinted one-liner above the
// heading.
export type Accent = "pink" | "blue" | "green" | "yellow" | "violet" | "muted";

const accentText: Record<Accent, string> = {
  pink: "text-[#e879c6]",
  blue: "text-[#5b9bff]",
  green: "text-[#36d07a]",
  yellow: "text-[#e7b84b]",
  violet: "text-[#9b7bff]",
  muted: "text-muted-foreground",
};

export function SectionLabel({
  children,
  accent = "muted",
  className,
}: {
  children: React.ReactNode;
  accent?: Accent;
  className?: string;
}) {
  return (
    <span
      className={cn(
        "block text-sm font-semibold tracking-tight",
        accentText[accent],
        className,
      )}
    >
      {children}
    </span>
  );
}

// Apple logo glyph for the "Download for Mac" pills — the single most recognizable
// cue that this is a native Mac app.
export function AppleMark({ className }: { className?: string }) {
  return (
    <svg
      viewBox="0 0 16 16"
      aria-hidden="true"
      className={cn("h-[1.05em] w-[1.05em]", className)}
      fill="currentColor"
    >
      <path d="M11.182 8.41c.013 1.473 1.292 1.963 1.306 1.969-.011.035-.204.7-.673 1.385-.405.592-.825 1.182-1.487 1.194-.65.012-.86-.385-1.602-.385-.743 0-.976.373-1.591.397-.64.024-1.126-.64-1.534-1.23-.835-1.21-1.473-3.42-.616-4.91.425-.74 1.185-1.21 2.01-1.222.628-.012 1.221.422 1.605.422.384 0 1.105-.522 1.863-.445.317.013 1.208.128 1.78.964-.046.029-1.063.62-1.05 1.85ZM9.96 4.69c.34-.412.57-.985.507-1.555-.49.02-1.083.327-1.435.738-.315.365-.591.948-.517 1.508.547.042 1.105-.278 1.445-.69Z" />
    </svg>
  );
}
