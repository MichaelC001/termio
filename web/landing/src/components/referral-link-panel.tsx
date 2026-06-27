"use client";

import { useEffect, useState } from "react";
import { Check, Copy, Gift, LogIn, Mail } from "lucide-react";
import { buttonVariants } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import {
  REFERRAL_LADDER,
  ReferralError,
  getMyReferral,
  signInUrl,
  type ReferralMe,
} from "@/lib/referral";

type LoadState =
  | { status: "loading" }
  | { status: "ready"; data: ReferralMe }
  | { status: "signedOut" }
  | { status: "error" };

// Human-friendly progress line, e.g. "2 / 3 friends — 1 more for a free Solo
// license". Falls back to a celebratory line once every rung is earned.
function progressLabel(data: ReferralMe): string {
  const { activated } = data.stats;
  const threshold = data.nextThreshold;
  if (threshold == null) {
    return `${activated} friends activated — every reward unlocked. Thank you!`;
  }
  const remaining = Math.max(threshold - activated, 0);
  const rung = REFERRAL_LADDER.find((r) => r.threshold === threshold);
  const rewardName = rung ? rung.reward.toLowerCase() : "your next reward";
  const friendWord = remaining === 1 ? "friend" : "friends";
  return `${activated} / ${threshold} friends — ${remaining} more ${friendWord} for ${rewardName}.`;
}

function ProgressBar({ data }: { data: ReferralMe }) {
  const threshold = data.nextThreshold;
  const fraction =
    threshold && threshold > 0
      ? Math.min(data.stats.activated / threshold, 1)
      : 1;
  return (
    <div
      className="h-2 w-full overflow-hidden rounded-full bg-secondary"
      role="progressbar"
      aria-valuenow={data.stats.activated}
      aria-valuemin={0}
      aria-valuemax={threshold ?? data.stats.activated}
      aria-label="Referral progress"
    >
      <div
        className="h-full rounded-full bg-gradient-to-r from-brand-blue-deep via-brand-cyan to-brand-purple transition-[width] duration-500 motion-reduce:transition-none"
        style={{ width: `${Math.round(fraction * 100)}%` }}
      />
    </div>
  );
}

function CopyLink({ link }: { link: string }) {
  const [copied, setCopied] = useState(false);

  useEffect(() => {
    if (!copied) return;
    const timer = window.setTimeout(() => setCopied(false), 2000);
    return () => window.clearTimeout(timer);
  }, [copied]);

  async function copy() {
    try {
      await navigator.clipboard.writeText(link);
      setCopied(true);
    } catch {
      // Clipboard can be blocked (insecure context / permissions). Stay quiet
      // rather than throwing; the link remains visible to copy manually.
      setCopied(false);
    }
  }

  return (
    <div className="flex flex-col gap-3 sm:flex-row">
      <input
        readOnly
        value={link}
        aria-label="Your referral link"
        onFocus={(event) => event.currentTarget.select()}
        className="min-w-0 flex-1 rounded-full border border-border bg-secondary px-4 py-2.5 font-mono text-sm text-foreground focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring"
      />
      <button
        type="button"
        onClick={copy}
        aria-live="polite"
        className={cn(
          buttonVariants(),
          "h-11 shrink-0 rounded-full px-5",
        )}
      >
        {copied ? (
          <>
            <Check className="h-4 w-4" aria-hidden="true" /> Copied!
          </>
        ) : (
          <>
            <Copy className="h-4 w-4" aria-hidden="true" /> Copy link
          </>
        )}
      </button>
    </div>
  );
}

function ShareRow({ link }: { link: string }) {
  const subject = encodeURIComponent("Try termio — the terminal home for AI coding agents");
  const body = encodeURIComponent(
    `I've been using termio and thought you'd like it. Start a 14-day trial and get $5 off with my link: ${link}`,
  );
  const tweet = encodeURIComponent(
    `The terminal home for your AI coding agents. 14-day trial + $5 off via my link: ${link}`,
  );
  return (
    <div className="flex flex-wrap items-center gap-2 text-sm">
      <span className="text-muted-foreground">Share via</span>
      <a
        href={`mailto:?subject=${subject}&body=${body}`}
        className={cn(buttonVariants({ variant: "outline" }), "h-8 rounded-full bg-card px-3")}
      >
        <Mail className="h-4 w-4" aria-hidden="true" /> Email
      </a>
      <a
        href={`https://twitter.com/intent/tweet?text=${tweet}`}
        target="_blank"
        rel="noopener noreferrer"
        className={cn(buttonVariants({ variant: "outline" }), "h-8 rounded-full bg-card px-3")}
      >
        Post on X
      </a>
    </div>
  );
}

export function ReferralLinkPanel() {
  const [state, setState] = useState<LoadState>({ status: "loading" });

  useEffect(() => {
    let active = true;
    getMyReferral()
      .then((data) => {
        if (active) setState({ status: "ready", data });
      })
      .catch((error: unknown) => {
        if (!active) return;
        if (error instanceof ReferralError && error.signedOut) {
          setState({ status: "signedOut" });
        } else {
          // Unreachable API, parse failure, or 5xx all collapse to the same
          // friendly signed-out-style prompt so the page never appears broken.
          setState({ status: "error" });
        }
      });
    return () => {
      active = false;
    };
  }, []);

  return (
    <div className="rounded-2xl border border-border bg-card p-7 shadow-sm">
      {state.status === "loading" ? (
        <div className="flex items-center gap-3 text-sm text-muted-foreground">
          <span className="h-2 w-2 animate-pulse rounded-full bg-brand-blue motion-reduce:animate-none" />
          Loading your referral link…
        </div>
      ) : state.status === "ready" ? (
        <ReadyPanel data={state.data} />
      ) : (
        <SignedOutPanel unreachable={state.status === "error"} />
      )}
    </div>
  );
}

function ReadyPanel({ data }: { data: ReferralMe }) {
  return (
    <div className="flex flex-col gap-6">
      <div>
        <h3 className="text-lg font-semibold tracking-tight text-foreground">
          Your referral link
        </h3>
        <p className="mt-1 text-sm text-muted-foreground">
          Share it anywhere. Friends get 14 days + $5 off; you climb the ladder.
        </p>
      </div>

      <CopyLink link={data.link} />
      <ShareRow link={data.link} />

      <div className="rounded-xl border border-border bg-secondary/40 p-5">
        <p className="text-sm font-medium text-foreground">{progressLabel(data)}</p>
        <div className="mt-3">
          <ProgressBar data={data} />
        </div>
        <dl className="mt-4 grid grid-cols-3 gap-3 text-center">
          {[
            { label: "Pending", value: data.stats.pending },
            { label: "Activated", value: data.stats.activated },
            { label: "Converted", value: data.stats.converted },
          ].map((stat) => (
            <div key={stat.label} className="rounded-lg bg-card px-2 py-3 ring-1 ring-foreground/10">
              <dd className="text-2xl font-semibold tracking-tight text-foreground">
                {stat.value}
              </dd>
              <dt className="mt-0.5 text-xs uppercase tracking-wide text-muted-foreground">
                {stat.label}
              </dt>
            </div>
          ))}
        </dl>
      </div>

      {data.rewards.length > 0 ? (
        <div>
          <h4 className="text-sm font-semibold text-foreground">Rewards earned</h4>
          <ul className="mt-3 space-y-2">
            {data.rewards.map((reward, index) => (
              <li
                key={`${reward.type}-${reward.grantedAt}-${index}`}
                className="flex items-center gap-2.5 rounded-lg border border-border bg-card px-3 py-2 text-sm text-[#333333]"
              >
                <Gift className="h-4 w-4 shrink-0 text-brand-green-deep" aria-hidden="true" />
                <span className="font-medium text-foreground">{reward.detail}</span>
              </li>
            ))}
          </ul>
        </div>
      ) : null}
    </div>
  );
}

function SignedOutPanel({ unreachable }: { unreachable: boolean }) {
  return (
    <div className="flex flex-col items-start gap-4">
      <div className="flex h-11 w-11 items-center justify-center rounded-full bg-secondary">
        <LogIn className="h-5 w-5 text-brand-blue-deep" aria-hidden="true" />
      </div>
      <div>
        <h3 className="text-lg font-semibold tracking-tight text-foreground">
          Sign in to get your link
        </h3>
        <p className="mt-1 max-w-md text-sm text-[#333333]">
          {unreachable
            ? "We couldn't reach the referral service right now. Sign in to view your personal link and track rewards."
            : "Sign in to your termio account to grab your personal referral link and track who you've invited."}
        </p>
      </div>
      <a
        href={signInUrl}
        className={cn(buttonVariants(), "h-11 rounded-full px-6")}
      >
        <LogIn className="h-4 w-4" aria-hidden="true" /> Sign in
      </a>
    </div>
  );
}
