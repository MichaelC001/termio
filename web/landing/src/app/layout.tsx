import type { Metadata, Viewport } from "next";
import "./globals.css";

const siteDescription =
  "Termio is a native Mac workspace for your AI coding agents — Claude Code, Codex, OpenCode, Pi Agent and more. Run them side by side, each in a real terminal, switch between them instantly, and nothing ever leaves your machine.";

export const metadata: Metadata = {
  metadataBase: new URL("https://www.termio.sh"),
  title: {
    default: "Termio — the terminal home for your AI coding agents",
    template: "%s — Termio",
  },
  description: siteDescription,
  keywords: [
    "Termio",
    "AI coding agents",
    "terminal",
    "macOS terminal",
    "Claude Code",
    "Codex",
    "git worktree",
    "Apple Silicon",
  ],
  applicationName: "Termio",
  alternates: {
    canonical: "/",
  },
  openGraph: {
    title: "Termio — the terminal home for your AI coding agents",
    description: siteDescription,
    type: "website",
    siteName: "Termio",
    url: "/",
    images: [
      {
        url: "/og.webp",
        type: "image/webp",
        width: 2400,
        height: 1260,
        alt: "Termio — a native Mac workspace for running multiple AI coding agents, shown beside a live Claude Code session.",
      },
    ],
  },
  twitter: {
    card: "summary_large_image",
    title: "Termio — the terminal home for your AI coding agents",
    description: siteDescription,
    images: ["/og.webp"],
  },
};

export const viewport: Viewport = {
  themeColor: "#08080a",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en" className="dark h-full antialiased">
      <body className="min-h-full flex flex-col bg-background text-foreground">
        {children}
      </body>
    </html>
  );
}
