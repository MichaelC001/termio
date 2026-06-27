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
  },
  twitter: {
    card: "summary_large_image",
    title: "termio — the terminal home for your AI coding agents",
    description: siteDescription,
  },
  icons: {
    icon: "/favicon.svg",
  },
};

export const viewport: Viewport = {
  themeColor: "#fafafa",
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
