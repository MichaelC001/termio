import type { Metadata } from "next";
import { SiteNav } from "@/components/site-nav";
import { SiteFooter } from "@/components/site-footer";
import { SectionLabel } from "@/components/section-label";
import { Reveal } from "@/components/reveal";
import { changelog, type ChangeKind } from "@/data/changelog";

export const metadata: Metadata = {
  title: "Changelog",
  description:
    "What's new in Termio — new features, improvements and fixes, shipped to every Mac through built-in auto-updates.",
};

const kindLabel: Record<ChangeKind, string> = {
  new: "New",
  improved: "Improved",
  fixed: "Fixed",
};

// One restrained tone for every category — the labels read as structural
// eyebrows, not a rainbow. The single purple timeline dot is the only accent.
const kindAccent: Record<ChangeKind, string> = {
  new: "text-muted-foreground",
  improved: "text-muted-foreground",
  fixed: "text-muted-foreground",
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
              <SectionLabel accent="muted">Changelog</SectionLabel>
              <h1 className="mt-4 text-balance text-4xl font-semibold tracking-[-0.045em] text-foreground sm:text-5xl">
                What&apos;s new in Termio
              </h1>
              <p className="mt-5 max-w-xl text-base leading-relaxed text-muted-foreground">
                Every release ships to your Mac through built-in auto-updates —
                no reinstalling, no checking a website.
              </p>
            </Reveal>

            <div className="relative mt-14 sm:mt-16">
              {/* Continuous timeline rail behind the entries, fading out at the tail. */}
              <span
                aria-hidden="true"
                className="absolute bottom-3 left-[3px] top-2.5 w-px bg-gradient-to-b from-border via-border to-transparent"
              />
              <div className="space-y-12 sm:space-y-14">
                {changelog.map((entry, index) => (
                  <Reveal
                    as="article"
                    key={entry.version}
                    delayMs={Math.min(index, 3) * 70}
                    className="relative pl-7 sm:pl-8"
                  >
                    <span
                      aria-hidden="true"
                      className="absolute left-0 top-[7px] h-[7px] w-[7px] rounded-full bg-foreground ring-4 ring-background"
                    />
                    <div className="flex flex-wrap items-baseline gap-x-3 gap-y-1">
                      <h2 className="font-mono text-base font-semibold tracking-tight text-foreground">
                        v{entry.version}
                      </h2>
                      <time className="text-[13px] text-muted-foreground">
                        {formatDate(entry.date)}
                      </time>
                    </div>

                    <div className="mt-4 space-y-4">
                      {kindOrder.map((kind) => {
                        const items = entry.changes[kind];
                        if (!items || items.length === 0) return null;
                        return (
                          <div key={kind}>
                            <h3>
                              <span
                                className={`inline-flex items-center rounded-full border border-border bg-muted/40 px-2.5 py-0.5 text-[10px] font-medium uppercase tracking-[0.18em] ${kindAccent[kind]}`}
                              >
                                {kindLabel[kind]}
                              </span>
                            </h3>
                            <ul className="mt-2 space-y-2">
                              {items.map((item) => (
                                <li
                                  key={item}
                                  className="flex gap-2.5 text-[15px] leading-relaxed text-foreground/75"
                                >
                                  <span
                                    aria-hidden="true"
                                    className="mt-[9px] h-1 w-1 shrink-0 rounded-full bg-current opacity-40"
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
          </div>
        </section>
      </main>
      <SiteFooter />
    </>
  );
}
