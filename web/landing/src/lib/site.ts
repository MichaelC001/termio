// Shared site constants. Termio is free to use and ships with Sparkle
// auto-updates — no account, no license keys, no payment backend. (Source will be
// opened later; not yet.)

export const supportedAgents = [
  "Claude Code",
  "Codex",
  "Gemini",
  "Amp",
  "Pi",
  "OpenCode",
  "Copilot",
  "Cursor",
] as const;

export const navLinks = [
  { label: "Changelog", href: "/changelog" },
  { label: "Docs", href: "/#faq" },
] as const;

// The desktop build download — the stable Cloudflare R2 URL (behind
// downloads.termio.sh) that always serves the newest notarized DMG. The release
// workflow (.github/workflows/release.yml) overwrites this object on every tag.
export const downloadUrl = "https://downloads.termio.sh/termio.dmg";

// Real app screenshot for the hero. Drop a polished capture at
// public/screenshots/hero.png (or .webp) — the Termio window, dark, ~2× the
// window size (≈1996×1210) showing the sidebar + a live agent session — then set
// this to its path and its real pixel dimensions. While null, the hero shows the
// hand-built CSS mock instead, so nothing breaks and nothing false ships.
export const heroScreenshot: { src: string; width: number; height: number } | null =
  null;
