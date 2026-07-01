const footerLinks: { label: string; href: string }[] = [
  { label: "Docs", href: "/#faq" },
  { label: "Changelog", href: "/changelog" },
  { label: "Privacy", href: "#" },
  { label: "Terms", href: "#" },
];

export function SiteFooter() {
  return (
    <footer className="relative border-t border-white/10">
      <div className="mx-auto w-full max-w-6xl px-5 py-12 sm:px-8">
        <div className="flex flex-col gap-8 sm:flex-row sm:items-center sm:justify-between">
          <div className="max-w-xs">
            <p className="text-sm leading-relaxed text-white/70">
              The native macOS terminal home for your AI coding agents.
            </p>
          </div>
          <nav
            className="flex flex-wrap gap-x-7 gap-y-2 sm:justify-end"
            aria-label="Footer"
          >
            {footerLinks.map((link) => (
              <a
                key={link.label}
                href={link.href}
                className="text-sm text-white/80 transition-colors hover:text-white"
              >
                {link.label}
              </a>
            ))}
          </nav>
        </div>

        <div className="mt-10 flex flex-col items-center justify-between gap-3 pt-6 text-sm text-white/60 sm:flex-row">
          <p>© {new Date().getFullYear()} Termio. All rights reserved.</p>
          <p className="font-mono text-xs">Built for Apple Silicon.</p>
        </div>
      </div>
    </footer>
  );
}
