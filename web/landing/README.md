# termio — landing page

The marketing site for **termio**, a native macOS terminal that gives every AI
coding agent (Claude Code, Codex, Gemini, Amp, and more) a first-class home.

Built with **Next.js (App Router) + TypeScript + Tailwind CSS v4 + shadcn/ui**.
The visual design is modeled on [superwhisper.com](https://superwhisper.com) — a
light, airy, gradient-forward Mac-app aesthetic — while all copy and product
facts are about termio.

## Run it

```sh
pnpm install
pnpm dev      # http://localhost:3000
```

Other scripts:

```sh
pnpm build    # production build (type-checks the whole app)
pnpm start    # serve the production build
pnpm lint     # ESLint
```

## Environment

| Variable              | Default                 | Purpose                                                               |
| --------------------- | ----------------------- | -------------------------------------------------------------------- |
| `NEXT_PUBLIC_API_URL` | `http://localhost:8787` | Base URL of the licensing backend in [`../server`](../server) (Hono). |

Copy `.env.example` to `.env.local` and adjust as needed. The page uses this base
URL to build the **Download** link and the **Buy license** checkout links. The
checkout buttons currently point at the backend's `POST /api/checkout/session`
endpoint as a placeholder — see the `TODO` in
`src/components/sections/pricing.tsx` and `src/lib/site.ts` for where the real
authenticated checkout flow (sign-in, then `{ planId, quantity }`) connects.

## Where the pricing comes from

Pricing is data-driven. The single source of truth is the shared contract at
[`../docs/pricing.json`](../docs/pricing.json), which both this site and the
backend read. It is mirrored as a typed module in
[`src/data/pricing.ts`](src/data/pricing.ts) — keep the numbers in sync with the
JSON. The pricing section renders entirely from that data (trial + the two
one-time per-seat plans, updates window, and renewal note).

## Structure

```
src/
  app/
    layout.tsx          # Inter font, SEO metadata, favicon
    page.tsx            # the landing page (assembles all sections)
    pricing/page.tsx    # standalone /pricing route
    globals.css         # light theme + brand palette + reveal animation
  components/
    site-nav.tsx        # sticky nav
    site-footer.tsx     # grouped footer links
    logo.tsx            # termio wordmark
    termio-window.tsx   # CSS/JSX mock of the app (hero visual)
    reveal.tsx          # IntersectionObserver scroll-entrance wrapper
    sections/           # hero, social-proof, features, how-it-works,
                        # pricing, faq, cta-band
    ui/                 # shadcn components (button, card, accordion, badge, separator)
  data/pricing.ts       # typed mirror of ../docs/pricing.json
  lib/site.ts           # API base URL, nav links, supported agents, checkout/download URLs
```

## Notes

- **Theme: light only**, matching the design source. Brand accents use the
  terminal traffic-light trio (red/amber/green) plus gradient blues, cyan, and
  purple, exposed as Tailwind tokens (`bg-brand-*`) and gradient utilities in
  `globals.css`.
- Scroll-entrance animations are a tiny IntersectionObserver wrapper (no heavy
  animation library) and respect `prefers-reduced-motion`.
- The hero/feature visuals are pure CSS/JSX mocks — no screenshots required.
