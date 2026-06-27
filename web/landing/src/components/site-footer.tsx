import { Logo } from "@/components/logo";
import { downloadUrl } from "@/lib/site";

const footerGroups: { heading: string; links: { label: string; href: string }[] }[] = [
  {
    heading: "Product",
    links: [
      { label: "Features", href: "#features" },
      { label: "How it works", href: "#how-it-works-heading" },
      { label: "Pricing", href: "#pricing" },
      { label: "Refer & earn", href: "/refer" },
      { label: "Download", href: downloadUrl },
    ],
  },
  {
    heading: "Resources",
    links: [
      { label: "Docs", href: "#faq" },
      { label: "FAQ", href: "#faq" },
      { label: "Supported agents", href: "#features" },
      { label: "Changelog", href: "#" },
    ],
  },
  {
    heading: "Legal",
    links: [
      { label: "Privacy", href: "#" },
      { label: "Terms", href: "#" },
      { label: "License", href: "#pricing" },
    ],
  },
];

export function SiteFooter() {
  return (
    <footer className="border-t border-border bg-background">
      <div className="mx-auto w-full max-w-6xl px-5 py-16 sm:px-8">
        <div className="grid gap-10 md:grid-cols-[1.5fr_1fr_1fr_1fr]">
          <div>
            <Logo />
            <p className="mt-4 max-w-xs text-sm text-muted-foreground">
              The native macOS terminal home for your AI coding agents.
            </p>
            <p className="mt-4 inline-flex items-center gap-2 rounded-full border border-border bg-card px-3 py-1.5 text-xs font-medium text-muted-foreground">
              <span className="h-1.5 w-1.5 rounded-full bg-brand-green" />
              Local-only · No telemetry
            </p>
          </div>

          {footerGroups.map((group) => (
            <nav key={group.heading} aria-label={group.heading}>
              <h2 className="text-xs font-semibold uppercase tracking-wider text-muted-foreground">
                {group.heading}
              </h2>
              <ul className="mt-4 space-y-3">
                {group.links.map((link) => (
                  <li key={link.label}>
                    <a
                      href={link.href}
                      className="text-sm text-[#333333] transition-colors hover:text-foreground"
                    >
                      {link.label}
                    </a>
                  </li>
                ))}
              </ul>
            </nav>
          ))}
        </div>

        <div className="mt-12 flex flex-col items-center justify-between gap-3 border-t border-border pt-6 text-sm text-muted-foreground sm:flex-row">
          <p>© {new Date().getFullYear()} termio. All rights reserved.</p>
          <p className="font-mono text-xs">Built for Apple Silicon.</p>
        </div>
      </div>
    </footer>
  );
}
