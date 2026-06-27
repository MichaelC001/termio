import { randomInt } from "node:crypto";

/**
 * 1.x referral-program scaffold. These are pure, side-effect-free helpers only:
 * NOTHING here is wired into checkout, auth, or the desktop app yet. They model
 * the design in web/docs/PRICING.md ("Growth: referral program") so the schema
 * (referral_code / referral / referral_reward) has a typed home for its logic,
 * but no route reads them and no flow grants a reward. Wiring lands in 1.x.
 */

/**
 * Unambiguous alphabet shared in spirit with the license keys (no 0/O, 1/I/L)
 * so a referral code copied off a screen or read aloud can't be mistyped.
 */
const CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";
const CODE_LENGTH = 8;

/**
 * Produce a cryptographically random referral code such as `7K4MQP2X`. Uses
 * crypto.randomInt (rejection-sampled, no modulo bias) rather than Math.random
 * so codes are not guessable. Uniqueness is enforced by the `referral_code.code`
 * unique constraint when (later) persisted; callers retry on collision.
 */
export function generateReferralCode(): string {
  let code = "";
  for (let index = 0; index < CODE_LENGTH; index += 1) {
    code += CODE_ALPHABET[randomInt(CODE_ALPHABET.length)];
  }
  return code;
}

/** The plans that can be earned outright on the ladder (mirrors pricing.json). */
export type FreePlanId = "solo" | "pro";

/**
 * What a given count of *active* referrals entitles the referrer to. A trial
 * extension grants `months`; a free license names `freePlanId`. The empty object
 * means the count hasn't reached the next rung yet.
 */
export interface ReferralRewardOutcome {
  months?: number;
  freePlanId?: FreePlanId;
}

/**
 * The reward ladder from PRICING.md, keyed on how many friends genuinely
 * activated (created an account AND ran ≥1 real agent session — counted
 * elsewhere, not here):
 *
 *   1 active referral  → +1 month of free use (trial extension)
 *   3 active referrals → a free Solo license (1 Mac, lifetime)
 *   5 active referrals → a free Pro license (up to 3 Macs, lifetime)
 *
 * "Free Pro" is the ceiling — you can't earn more than the product. This returns
 * the outcome for *reaching* a rung exactly; counts between rungs (e.g. 2, 4) and
 * counts past 5 carry no new reward, so this returns an empty outcome for them.
 * Translating an outcome into a `referral_reward` row is a 1.x concern.
 */
export function rewardForActiveReferralCount(
  count: number,
): ReferralRewardOutcome {
  switch (count) {
    case 1:
      return { months: 1 };
    case 3:
      return { freePlanId: "solo" };
    case 5:
      return { freePlanId: "pro" };
    default:
      return {};
  }
}
