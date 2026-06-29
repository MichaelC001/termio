import type { Metadata } from "next";
import { SiteNav } from "@/components/site-nav";
import { SiteFooter } from "@/components/site-footer";
import { SectionLabel } from "@/components/section-label";
import { Reveal } from "@/components/reveal";
import { changelog, type ChangeKind } from "@/data/changelog";

export const metadata: Metadata = {
  title: "Changelog",
  description:
    "What's new in termio — new features, improvements and fixes, shipped to every Mac through built-in auto-updates.",
};

const kindLabel: Record<ChangeKind, string> = {
  new: "New",
  improved: "Improved",
  fixed: "Fixed",
};

const kindAccent: Record<ChangeKind, string> = {
  new: "text-[#1a8f4c]",
  improved: "text-[#0071e3]",
  fixed: "text-[#b8740a]",
};

const kindOrder: ChangeKind[] = ["new", "improved", "fixed"];

function formatDate(iso: string): string {
  // Append a midday UTC time so the calendar date is stable regardless of the
  // renderer's timezone.
  return new Date(`${iso}T12:00:00Z`).toLocaleDateString("en-US", {
    year: "numeric",
    month: "short",
    day: "numeric",
    timeZone: "UTC",
  });
}

export default function ChangelogPage() {
  return (
    <>
      <SiteNav />
      <main className="flex-1">
        <section className="scroll-mt-24">
          <div className="mx-auto w-full max-w-3xl px-5 pb-32 pt-36 sm:px-8 sm:pb-40 sm:pt-44">
            <Reveal>
              <SectionLabel accent="violet">Changelog</SectionLabel>
              <h1 className="mt-4 text-balance text-4xl font-semibold tracking-[-0.045em] text-foreground sm:text-5xl">
                What&apos;s new in termio
              </h1>
              <p className="mt-5 max-w-xl text-base leading-relaxed text-muted-foreground">
                Every release ships to your Mac through built-in auto-updates —
                no reinstalling, no checking a website.
              </p>
            </Reveal>

            <div className="mt-16 space-y-16 border-l border-border pl-6 sm:mt-20 sm:space-y-20 sm:pl-10">
              {changelog.map((entry, index) => (
                <Reveal
                  as="article"
                  key={entry.version}
                  delayMs={Math.min(index, 3) * 70}
                  className="relative"
                >
                  <span
                    aria-hidden="true"
                    className="absolute -left-[calc(1.5rem+5px)] top-2 h-2.5 w-2.5 rounded-full bg-brand-purple ring-4 ring-background sm:-left-[calc(2.5rem+5px)]"
                  />
                  <div className="flex flex-wrap items-baseline gap-x-3 gap-y-1">
                    <h2 className="font-mono text-lg font-semibold text-foreground">
                      v{entry.version}
                    </h2>
                    <time className="text-sm text-muted-foreground">
                      {formatDate(entry.date)}
                    </time>
                  </div>

                  <div className="mt-6 space-y-6">
                    {kindOrder.map((kind) => {
                      const items = entry.changes[kind];
                      if (!items || items.length === 0) return null;
                      return (
                        <div key={kind}>
                          <h3
                            className={`text-xs font-semibold uppercase tracking-wider ${kindAccent[kind]}`}
                          >
                            {kindLabel[kind]}
                          </h3>
                          <ul className="mt-2.5 space-y-2.5">
                            {items.map((item) => (
                              <li
                                key={item}
                                className="flex gap-3 text-sm leading-relaxed text-muted-foreground"
                              >
                                <span
                                  aria-hidden="true"
                                  className="mt-2 h-1 w-1 shrink-0 rounded-full bg-muted-foreground/60"
                                />
                                <span>{item}</span>
                              </li>
                            ))}
                          </ul>
                        </div>
                      );
                    })}
                  </div>
                </Reveal>
              ))}
            </div>
          </div>
        </section>
      </main>
      <SiteFooter />
    </>
  );
}
