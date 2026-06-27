// Typed client for the referral API exposed by the licensing backend
// (web/server). The UI is built to this contract and must degrade gracefully
// when the backend is unreachable or the visitor is signed out — see
// src/app/refer/page.tsx for the offline/401 fallbacks.

import { apiBaseUrl } from "@/lib/site";

export type ReferralRewardType = "month" | "solo" | "pro" | string;

export type ReferralReward = {
  type: ReferralRewardType;
  detail: string;
  grantedAt: string;
};

export type ReferralLadderRung = {
  threshold: number;
  reward: string;
};

export type ReferralStats = {
  pending: number;
  activated: number;
  converted: number;
};

export type ReferralMe = {
  code: string;
  link: string;
  stats: ReferralStats;
  rewards: ReferralReward[];
  ladder: ReferralLadderRung[];
  nextThreshold: number | null;
};

export type FriendPerk = {
  trialDays: number;
  discountUsd: number;
};

export type ClaimResult = {
  ok: boolean;
  friendPerk: FriendPerk;
};

// The fixed reward ladder. The backend echoes its own `ladder`, but we mirror
// the three rungs here so the marketing page renders identically even when the
// API is down or the visitor is signed out.
export const REFERRAL_LADDER: ReferralLadderRung[] = [
  { threshold: 1, reward: "+1 month free" },
  { threshold: 3, reward: "Free Solo license" },
  { threshold: 5, reward: "Free Pro license" },
];

// The perk a referred friend receives. Mirrored so copy stays correct offline.
export const FRIEND_PERK: FriendPerk = { trialDays: 14, discountUsd: 5 };

// Distinct error type so callers can branch on "signed out" (401) versus a
// genuine failure (network/parse/5xx) without string-matching messages.
export class ReferralError extends Error {
  readonly status: number;
  readonly signedOut: boolean;

  constructor(message: string, status: number) {
    super(message);
    this.name = "ReferralError";
    this.status = status;
    this.signedOut = status === 401;
  }
}

async function readJson(response: Response): Promise<unknown> {
  // A reachable-but-misbehaving backend may return non-JSON; treat that as a
  // failure rather than letting a parse exception escape unhandled.
  try {
    return await response.json();
  } catch {
    throw new ReferralError("The referral service returned an unexpected response.", response.status);
  }
}

export async function getMyReferral(): Promise<ReferralMe> {
  let response: Response;
  try {
    response = await fetch(`${apiBaseUrl}/api/referral/me`, {
      method: "GET",
      credentials: "include",
      headers: { Accept: "application/json" },
    });
  } catch {
    // Offline, CORS, or the backend simply isn't running.
    throw new ReferralError("Could not reach the referral service.", 0);
  }

  if (response.status === 401) {
    throw new ReferralError("Sign in to view your referral link.", 401);
  }
  if (!response.ok) {
    throw new ReferralError("Could not load your referral status.", response.status);
  }

  const data = (await readJson(response)) as Partial<ReferralMe>;
  if (typeof data.code !== "string" || typeof data.link !== "string") {
    throw new ReferralError("The referral service returned incomplete data.", response.status);
  }

  return {
    code: data.code,
    link: data.link,
    stats: {
      pending: data.stats?.pending ?? 0,
      activated: data.stats?.activated ?? 0,
      converted: data.stats?.converted ?? 0,
    },
    rewards: data.rewards ?? [],
    ladder: data.ladder ?? REFERRAL_LADDER,
    nextThreshold: data.nextThreshold ?? null,
  };
}

export async function claimReferral(code: string): Promise<ClaimResult> {
  let response: Response;
  try {
    response = await fetch(`${apiBaseUrl}/api/referral/claim`, {
      method: "POST",
      credentials: "include",
      headers: { "Content-Type": "application/json", Accept: "application/json" },
      body: JSON.stringify({ code }),
    });
  } catch {
    throw new ReferralError("Could not reach the referral service.", 0);
  }

  if (!response.ok) {
    throw new ReferralError("Could not claim this referral code.", response.status);
  }

  const data = (await readJson(response)) as Partial<ClaimResult>;
  return {
    ok: data.ok ?? false,
    friendPerk: {
      trialDays: data.friendPerk?.trialDays ?? FRIEND_PERK.trialDays,
      discountUsd: data.friendPerk?.discountUsd ?? FRIEND_PERK.discountUsd,
    },
  };
}

// Where an unauthenticated visitor is sent to sign in. Placeholder until the
// real auth entry point ships; kept here so every CTA points at one source.
export const signInUrl = `${apiBaseUrl}/api/auth`;

const REF_COOKIE = "termio_ref";
const REF_COOKIE_MAX_AGE_DAYS = 30;

// Persist a captured `?ref=` code so it survives navigation between marketing
// pages until the visitor downloads/signs up. Client-only (uses document.cookie).
export function writeReferralCookie(code: string): void {
  if (typeof document === "undefined") return;
  const trimmed = code.trim();
  if (!trimmed) return;
  const maxAge = REF_COOKIE_MAX_AGE_DAYS * 24 * 60 * 60;
  document.cookie = `${REF_COOKIE}=${encodeURIComponent(trimmed)}; path=/; max-age=${maxAge}; SameSite=Lax`;
}

export function readReferralCookie(): string | null {
  if (typeof document === "undefined") return null;
  for (const part of document.cookie.split(";")) {
    const [name, ...rest] = part.trim().split("=");
    if (name === REF_COOKIE) {
      return decodeURIComponent(rest.join("=")) || null;
    }
  }
  return null;
}
