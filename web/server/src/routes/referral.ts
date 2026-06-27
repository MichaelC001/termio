import { randomUUID } from "node:crypto";

import { and, eq, inArray, sql } from "drizzle-orm";
import { Hono } from "hono";

import { database } from "../db/index.js";
import {
  product,
  purchase,
  referral,
  referralCode,
  referralReward,
} from "../db/schema.js";
import { environment } from "../env.js";
import { issueLicense } from "../licenses.js";
import { type AppEnv, currentUser, requireAuth } from "../middleware.js";
import { loadPricing } from "../pricing.js";
import {
  type FreePlanId,
  generateReferralCode,
  rewardForActiveReferralCount,
} from "../referrals.js";

/**
 * Referral program routes. The web dashboard renders a referrer's code and
 * progress (`/me`); the freshly-signed-up invitee attaches to a referrer
 * (`/claim`); and the desktop app reports a genuine activation (`/activate`).
 * Conversion (the invitee buying a license) is wired in the checkout webhook, not
 * here — both it and `/activate` re-use `evaluateAndGrantRewards` below.
 */
export const referralRoutes = new Hono<AppEnv>();

/**
 * The ladder rungs, ascending, mirroring `rewardForActiveReferralCount`. We grant
 * every rung up to the current active count (not just the one matching the count
 * exactly) so a count that jumps past a rung — e.g. several conversions landing at
 * once — never strands an unearned reward.
 */
const LADDER_THRESHOLDS = [1, 3, 5] as const;

/** Active referrals = those that reached `activated` or `converted`. */
const ACTIVE_STATUSES = ["activated", "converted"] as const;

/** Static ladder description returned to the dashboard. */
const LADDER_DESCRIPTION = [
  { threshold: 1, reward: "+1 month free" },
  { threshold: 3, reward: "Free Solo license" },
  { threshold: 5, reward: "Free Pro license" },
] as const;

function readString(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() !== ""
    ? value.trim()
    : undefined;
}

/**
 * Return the caller's referral code, creating one on first access. `code` is the
 * only unique column, so a generated collision is retried; uniqueness on the user
 * is best-effort for 1.x (one code per user is enough), so we re-check for a
 * concurrently-created row before giving up.
 */
async function getOrCreateReferralCode(
  userId: string,
): Promise<typeof referralCode.$inferSelect> {
  const existing = await database
    .select()
    .from(referralCode)
    .where(eq(referralCode.userId, userId))
    .limit(1);
  if (existing[0]) {
    return existing[0];
  }

  for (let attempt = 0; attempt < 5; attempt += 1) {
    try {
      const inserted = await database
        .insert(referralCode)
        .values({ id: randomUUID(), userId, code: generateReferralCode() })
        .returning();
      const row = inserted[0];
      if (row) {
        return row;
      }
    } catch (error) {
      // The only unique constraint is on `code`; a clash means regenerate. If a
      // concurrent request already created this user's row, adopt it.
      const raced = await database
        .select()
        .from(referralCode)
        .where(eq(referralCode.userId, userId))
        .limit(1);
      if (raced[0]) {
        return raced[0];
      }
      if (attempt === 4) {
        throw error;
      }
    }
  }
  throw new Error("Could not allocate a unique referral code after retries");
}

async function countActiveReferrals(referrerUserId: string): Promise<number> {
  const rows = await database
    .select({ count: sql<number>`count(*)::int` })
    .from(referral)
    .where(
      and(
        eq(referral.referrerUserId, referrerUserId),
        inArray(referral.status, [...ACTIVE_STATUSES]),
      ),
    );
  return rows[0]?.count ?? 0;
}

/** True when this referrer already holds the reward identified by (type, detail). */
async function hasReward(
  referrerUserId: string,
  type: typeof referralReward.$inferInsert.type,
  detail: string,
): Promise<boolean> {
  const rows = await database
    .select({ id: referralReward.id })
    .from(referralReward)
    .where(
      and(
        eq(referralReward.referrerUserId, referrerUserId),
        eq(referralReward.type, type),
        eq(referralReward.detail, detail),
      ),
    )
    .limit(1);
  return rows[0] !== undefined;
}

/**
 * Synthesize a zero-cost `purchase` and mint the earned license against it, so the
 * license's required `purchaseId` resolves and the grant is marked `source:
 * 'referral'`. `maxDevices` comes from the seeded `product` row, exactly as a paid
 * checkout would.
 */
async function mintReferralLicense(
  referrerUserId: string,
  planId: FreePlanId,
): Promise<void> {
  const planRows = await database
    .select()
    .from(product)
    .where(eq(product.id, planId))
    .limit(1);
  const plan = planRows[0];
  if (!plan) {
    // The ladder names a plan that must exist in the catalog; a missing seed is a
    // configuration error, not something to swallow.
    throw new Error(
      `Referral free license references unknown product '${planId}' — run db:seed`,
    );
  }

  const purchaseId = randomUUID();
  await database.insert(purchase).values({
    id: purchaseId,
    ownerUserId: referrerUserId,
    productId: planId,
    seats: 1,
    amountCents: 0,
    currency: loadPricing().currency,
    status: "completed",
    source: "referral",
  });

  await issueLicense({
    purchaseId,
    ownerUserId: referrerUserId,
    productId: planId,
    maxDevices: plan.maxDevices,
  });
}

/**
 * Re-evaluate a referrer's ladder and grant any newly-earned rewards, idempotently.
 * Idempotency is enforced by deduping on `(referrerUserId, type, detail)`: a trial
 * extension's `detail` is its month count, a free license's `detail` is the plan id,
 * so each rung maps to a distinct row that is inserted at most once. Safe to call
 * repeatedly (every `/activate` and every conversion does).
 */
export async function evaluateAndGrantRewards(
  referrerUserId: string,
): Promise<void> {
  const activeCount = await countActiveReferrals(referrerUserId);

  for (const threshold of LADDER_THRESHOLDS) {
    if (activeCount < threshold) {
      // Thresholds ascend, so once one is out of reach the rest are too.
      break;
    }
    const outcome = rewardForActiveReferralCount(threshold);

    if (outcome.months !== undefined) {
      const detail = String(outcome.months);
      if (!(await hasReward(referrerUserId, "trial_extension", detail))) {
        // TODO(1.x): apply the actual trial extension in the desktop trial system;
        // here we only record the earned entitlement.
        await database.insert(referralReward).values({
          id: randomUUID(),
          referrerUserId,
          type: "trial_extension",
          detail,
        });
      }
    } else if (outcome.freePlanId !== undefined) {
      const detail = outcome.freePlanId;
      if (!(await hasReward(referrerUserId, "free_license", detail))) {
        // Mint the license first; only on success record the reward, so a failed
        // mint is retried rather than masked by a reward row with no license.
        await mintReferralLicense(referrerUserId, outcome.freePlanId);
        await database.insert(referralReward).values({
          id: randomUUID(),
          referrerUserId,
          type: "free_license",
          detail,
        });
      }
    }
  }
}

/**
 * Mark an invitee's referral `converted` (idempotently) and re-run the referrer's
 * ladder. Called from the checkout webhook when a referred buyer's purchase clears.
 */
export async function markReferralConverted(
  inviteeUserId: string,
): Promise<void> {
  const rows = await database
    .select()
    .from(referral)
    .where(eq(referral.inviteeUserId, inviteeUserId))
    .limit(1);
  const row = rows[0];
  if (!row || row.status === "converted") {
    return;
  }

  await database
    .update(referral)
    .set({ status: "converted", convertedAt: new Date() })
    .where(eq(referral.id, row.id));

  await evaluateAndGrantRewards(row.referrerUserId);
}

referralRoutes.get("/me", requireAuth, async (context) => {
  const user = currentUser(context);
  const codeRow = await getOrCreateReferralCode(user.id);

  const statusCounts = await database
    .select({ status: referral.status, count: sql<number>`count(*)::int` })
    .from(referral)
    .where(eq(referral.referrerUserId, user.id))
    .groupBy(referral.status);

  const stats = { pending: 0, activated: 0, converted: 0 };
  for (const row of statusCounts) {
    stats[row.status] = row.count;
  }
  const activeCount = stats.activated + stats.converted;

  const rewardRows = await database
    .select()
    .from(referralReward)
    .where(eq(referralReward.referrerUserId, user.id));

  const nextThreshold =
    LADDER_THRESHOLDS.find((threshold) => activeCount < threshold) ?? null;

  return context.json({
    code: codeRow.code,
    link: `${environment.webOrigin}/refer?ref=${codeRow.code}`,
    stats,
    rewards: rewardRows.map((reward) => ({
      type: reward.type,
      detail: reward.detail,
      grantedAt: reward.grantedAt,
    })),
    ladder: LADDER_DESCRIPTION,
    nextThreshold,
  });
});

referralRoutes.post("/claim", requireAuth, async (context) => {
  const user = currentUser(context);
  const body = (await context.req.json().catch(() => ({}))) as {
    code?: unknown;
  };
  const code = readString(body.code);
  if (!code) {
    return context.json({ error: "code (string) is required" }, 400);
  }

  const codeRows = await database
    .select()
    .from(referralCode)
    .where(eq(referralCode.code, code))
    .limit(1);
  const referrerCode = codeRows[0];
  if (!referrerCode) {
    return context.json({ error: "Unknown referral code" }, 404);
  }

  if (referrerCode.userId === user.id) {
    return context.json({ error: "You cannot refer yourself" }, 409);
  }

  // One referral per invitee, regardless of which referrer claimed them first.
  const already = await database
    .select({ id: referral.id })
    .from(referral)
    .where(eq(referral.inviteeUserId, user.id))
    .limit(1);
  if (already[0]) {
    return context.json({ error: "Already attached to a referrer" }, 409);
  }

  await database.insert(referral).values({
    id: randomUUID(),
    referralCodeId: referrerCode.id,
    referrerUserId: referrerCode.userId,
    inviteeUserId: user.id,
    status: "pending",
  });

  // TODO(1.x): apply the invitee's extended trial / first-purchase discount in the
  // trial + checkout systems. We record intent here rather than fake the perk.
  return context.json({
    ok: true,
    friendPerk: { trialDays: 14, discountUsd: 5 },
  });
});

referralRoutes.post("/activate", requireAuth, async (context) => {
  // TODO(1.x): desktop device-token auth — the desktop app should be able to call
  // this with a device token instead of a web session cookie. Session-gated for now.
  const user = currentUser(context);

  const rows = await database
    .select()
    .from(referral)
    .where(eq(referral.inviteeUserId, user.id))
    .limit(1);
  const row = rows[0];
  if (!row) {
    return context.json({ error: "No referral to activate" }, 404);
  }

  // Idempotent: a referral that already advanced past `pending` is a no-op success.
  if (row.status === "pending") {
    await database
      .update(referral)
      .set({ status: "activated", activatedAt: new Date() })
      .where(eq(referral.id, row.id));

    await evaluateAndGrantRewards(row.referrerUserId);
  }

  return context.json({ ok: true, status: "activated" });
});
