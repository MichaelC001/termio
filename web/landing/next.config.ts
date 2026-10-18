import type { NextConfig } from "next";
import { createMDX } from "fumadocs-mdx/next";
import { i18n } from "./src/lib/i18n";

const nextConfig: NextConfig = {
  images: {
    localPatterns: [
      { pathname: "/**", search: "" },
      // A new revision bypasses cached renditions of replaced screenshots.
      { pathname: "/screenshots/**", search: "?v=20261017" },
    ],
  },
  // Emit a self-contained server bundle so the Docker runtime image only needs
  // the standalone output plus static assets, not the full node_modules tree.
  // Skipped on Vercel: its builder traces files itself, and standalone plus
  // the Vercel adapter breaks the build on Next 16.3
  // (https://github.com/vercel/next.js/issues/96646).
  ...(process.env.VERCEL ? {} : { output: "standalone" as const }),
  // /docs/<slug>.md serves a page's raw Markdown for agents (llms.txt links
  // here). The handler lives at /docs-md because a route.ts can't sit beside
  // the docs page.tsx. A translated page keeps its locale prefix:
  // /zh-CN/docs/<slug>.md.
  // Only the docs are translated, so a locale prefix holds nothing but
  // /<lang>/docs. A link that drops the /docs segment — /zh-CN/keyboard —
  // lands on the page it meant instead of a 404.
  async redirects() {
    return i18n.languages
      .filter((lang) => lang !== i18n.defaultLanguage)
      .flatMap((lang) => [
        { source: `/${lang}`, destination: `/${lang}/docs`, permanent: true },
        {
          source: `/${lang}/:path((?!docs(?:/|$)).+)`,
          destination: `/${lang}/docs/:path`,
          permanent: true,
        },
      ]);
  },
  async rewrites() {
    return [
      { source: "/docs/:slug.md", destination: "/docs-md/:slug" },
      { source: "/:lang/docs/:slug.md", destination: "/docs-md/:lang/:slug" },
    ];
  },
};

// Wire Fumadocs MDX into the build: this generates the `.source` folder from
// content/docs on `next dev` / `next build` and lets us import compiled MDX.
const withMDX = createMDX();

export default withMDX(nextConfig);
