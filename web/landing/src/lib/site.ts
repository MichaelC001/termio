// Shared site constants. termio ships free with Sparkle auto-updates today; paid
// lifetime licenses are sold through Lemon Squeezy (Merchant of Record), which
// hosts checkout and issues the license keys — there is no self-hosted backend.

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
  { label: "Features", href: "#features" },
  { label: "Pricing", href: "#pricing" },
  { label: "Docs", href: "#faq" },
] as const;

// The desktop build download — the stable Cloudflare R2 URL (behind
// downloads.termio.sh) that always serves the newest notarized DMG. The release
// workflow (.github/workflows/release.yml) overwrites this object on every tag.
export const downloadUrl = "https://downloads.termio.sh/termio.dmg";

// Lemon Squeezy hosted checkout links, one per tier (keyed by the plan `id` in
// pricing.ts). The Pricing section's "Buy" buttons point here. These are
// PLACEHOLDERS — replace them with the real checkout URLs from the Lemon Squeezy
// dashboard once the store and its two products (Solo / Pro) exist; appending
// `?embed=1` would open them in the Lemon.js overlay instead of a new tab.
export const checkoutUrls: Record<"solo" | "pro", string> = {
  solo: "https://termio.lemonsqueezy.com/buy/REPLACE_WITH_SOLO_VARIANT",
  pro: "https://termio.lemonsqueezy.com/buy/REPLACE_WITH_PRO_VARIANT",
};
