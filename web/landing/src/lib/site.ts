// Shared site constants and the bridge to the web/server licensing backend.

// The licensing backend (web/server, a Hono app) defaults to port 8787 in local
// dev. Override with NEXT_PUBLIC_API_URL for staging/production.
export const apiBaseUrl =
  process.env.NEXT_PUBLIC_API_URL?.replace(/\/$/, "") ?? "http://localhost:8787";

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
  { label: "Refer", href: "/refer" },
  { label: "Docs", href: "#faq" },
] as const;

// The desktop build download — the stable Cloudflare R2 URL (behind
// downloads.termio.sh) that always serves the newest notarized DMG. The release
// workflow (.github/workflows/release.yml) overwrites this object on every tag.
export const downloadUrl = "https://downloads.termio.sh/termio.dmg";

// Backend endpoint that mints a Stripe Checkout Session for a plan + quantity.
// See web/server: POST /api/checkout/session (requires an authenticated
// session). TODO: this currently links to the in-page #pricing anchor / backend
// route; wire it to the real authenticated checkout flow (sign-in, then POST
// with { planId, quantity }) when accounts go live.
export const checkoutSessionUrl = `${apiBaseUrl}/api/checkout/session`;
