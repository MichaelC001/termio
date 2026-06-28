import type { Metadata, Viewport } from "next";
import { Inter } from "next/font/google";
import "./globals.css";

const inter = Inter({
  variable: "--font-inter",
  subsets: ["latin"],
  display: "swap",
});

const siteDescription =
  "termio is a native macOS terminal that gives every AI coding agent — Claude Code, Codex, Gemini, Amp and more — a first-class home. Sessions survive restarts, each agent gets its own git worktree, and everything stays local.";

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
        alt: "termio — every AI coding agent in one native Mac app, shown beside a live Claude Code session.",
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
    <html lang="en" className={`${inter.variable} h-full antialiased`}>
      <body className="min-h-full flex flex-col bg-background text-foreground">
        {children}
      </body>
    </html>
  );
}
