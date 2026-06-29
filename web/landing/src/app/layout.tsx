import type { Metadata, Viewport } from "next";
import "./globals.css";

const siteDescription =
  "termio is a native Mac workspace for running multiple AI coding agents — Claude Code, Codex, Gemini, Amp and more — side by side. Sessions survive restarts, each agent gets its own git worktree, and everything stays local.";

export const metadata: Metadata = {
  metadataBase: new URL("https://termio.app"),
  title: {
    default: "termio — the terminal home for your AI coding agents",
    template: "%s — termio",
  },
  description: siteDescription,
  keywords: [
    "termio",
    "AI coding agents",
    "terminal",
    "macOS terminal",
    "Claude Code",
    "Codex",
    "git worktree",
    "Apple Silicon",
  ],
  applicationName: "termio",
  openGraph: {
    title: "termio — the terminal home for your AI coding agents",
    description: siteDescription,
    type: "website",
    siteName: "termio",
    url: "/",
    images: [
      {
        url: "/og.webp",
        type: "image/webp",
        width: 2400,
        height: 1260,
        alt: "termio — a native Mac workspace for running multiple AI coding agents, shown beside a live Claude Code session.",
      },
    ],
  },
  twitter: {
    card: "summary_large_image",
    title: "termio — the terminal home for your AI coding agents",
    description: siteDescription,
    images: ["/og.webp"],
  },
};

export const viewport: Viewport = {
  themeColor: "#050507",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en" className="h-full antialiased">
      <body className="min-h-full flex flex-col bg-background text-foreground">
        {children}
      </body>
    </html>
  );
}
