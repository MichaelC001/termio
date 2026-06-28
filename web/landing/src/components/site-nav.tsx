import Link from "next/link";
import { cn } from "@/lib/utils";
import { Logo } from "@/components/logo";
import { AppleMark } from "@/components/section-label";
import { navLinks, downloadUrl } from "@/lib/site";

// Superwhisper's nav: a single centered floating pill holding the links + a white
// Download button, with the wordmark parked on the far left.
export function SiteNav() {
  return (
    <header className="fixed inset-x-0 top-0 z-50 pt-4">
      <div className="relative mx-auto flex w-full max-w-6xl items-center justify-center px-5 sm:px-8">
        <Link
          href="#top"
          className="absolute left-5 hidden rounded-md focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-ring sm:left-8 sm:block"
          aria-label="termio home"
        >
          <Logo />
        </Link>

        <nav
          aria-label="Primary"
          className="flex items-center gap-1 rounded-full border border-border bg-card/70 p-1.5 backdrop-blur-xl"
        >
          {navLinks.map((link) => (
            <a
              key={link.href}
              href={link.href}
              className="rounded-full px-4 py-1.5 text-sm font-medium text-muted-foreground transition-colors hover:bg-white/5 hover:text-foreground"
            >
              {link.label}
            </a>
          ))}
          <a
            href={downloadUrl}
            className={cn(
              "ml-1 inline-flex items-center gap-1.5 rounded-full bg-white px-4 py-1.5 text-sm font-semibold text-black transition-colors hover:bg-white/90",
            )}
          >
            <AppleMark className="h-3.5 w-3.5" />
            Download
          </a>
        </nav>
      </div>
    </header>
  );
}
