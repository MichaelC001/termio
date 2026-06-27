import { isNull } from "drizzle-orm";
import {
  boolean,
  integer,
  pgEnum,
  pgTable,
  text,
  timestamp,
  unique,
  uniqueIndex,
} from "drizzle-orm/pg-core";

/**
 * Schema is split into two groups:
 *   1. better-auth tables (user/session/account/verification) — these mirror the
 *      shape better-auth's Drizzle adapter expects. The JS property names match
 *      better-auth's model fields; column names are snake_case for SQL ergonomics.
 *   2. termio's own license-domain tables.
 *
 * The license model is a one-time LIFETIME purchase (see web/docs/pricing.json):
 * pay once, own it forever, all updates included. There is no subscription and no
 * renewal — a `purchase` issues one `license` whose `maxDevices` cap gates how many
 * `license_seat` (per-device) activations can be live at once. The purchase carries
 * a `refundableUntil` for the 30-day money-back guarantee.
 */

// ---------------------------------------------------------------------------
// better-auth core tables
// ---------------------------------------------------------------------------

export const user = pgTable("user", {
  id: text("id").primaryKey(),
  name: text("name").notNull(),
  email: text("email").notNull().unique(),
  emailVerified: boolean("email_verified").notNull().default(false),
  image: text("image"),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
});

export const session = pgTable("session", {
  id: text("id").primaryKey(),
  expiresAt: timestamp("expires_at", { withTimezone: true }).notNull(),
  token: text("token").notNull().unique(),
  ipAddress: text("ip_address"),
  userAgent: text("user_agent"),
  userId: text("user_id")
    .notNull()
    .references(() => user.id, { onDelete: "cascade" }),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
});

export const account = pgTable("account", {
  id: text("id").primaryKey(),
  accountId: text("account_id").notNull(),
  providerId: text("provider_id").notNull(),
  userId: text("user_id")
    .notNull()
    .references(() => user.id, { onDelete: "cascade" }),
  accessToken: text("access_token"),
  refreshToken: text("refresh_token"),
  idToken: text("id_token"),
  accessTokenExpiresAt: timestamp("access_token_expires_at", { withTimezone: true }),
  refreshTokenExpiresAt: timestamp("refresh_token_expires_at", { withTimezone: true }),
  scope: text("scope"),
  // Only set for the email/password provider; OAuth accounts leave this null.
  password: text("password"),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
});

export const verification = pgTable("verification", {
  id: text("id").primaryKey(),
  identifier: text("identifier").notNull(),
  value: text("value").notNull(),
  expiresAt: timestamp("expires_at", { withTimezone: true }).notNull(),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
});

// ---------------------------------------------------------------------------
// License-domain enums
// ---------------------------------------------------------------------------

export const billingType = pgEnum("billing_type", ["one-time"]);

export const purchaseStatus = pgEnum("purchase_status", [
  "pending",
  "completed",
  "refunded",
  "failed",
]);

export const licenseStatus = pgEnum("license_status", ["active", "revoked"]);

export const teamRole = pgEnum("team_role", ["owner", "admin", "member"]);

// ---------------------------------------------------------------------------
// Referral-domain enums (1.x scaffold — see web/docs/PRICING.md and referrals.ts)
// ---------------------------------------------------------------------------

/**
 * A referral progresses pending → activated → converted. It only reaches
 * `activated` once the invited friend genuinely uses the product (creates an
 * account AND runs ≥1 real agent session) and `converted` once they buy a
 * license. Signup alone never advances it past `pending` — see the "real
 * activation" guardrail in PRICING.md.
 */
export const referralStatus = pgEnum("referral_status", [
  "pending",
  "activated",
  "converted",
]);

export const referralRewardType = pgEnum("referral_reward_type", [
  "trial_extension",
  "free_license",
]);

// ---------------------------------------------------------------------------
// Catalog: product + price (seeded from pricing.json)
// ---------------------------------------------------------------------------

/**
 * One row per purchasable plan. The primary key is the stable plan id from
 * pricing.json ("personal", "team") so seeds are idempotent and other tables can
 * reference a human-readable plan.
 */
export const product = pgTable("product", {
  id: text("id").primaryKey(),
  name: text("name").notNull(),
  billing: billingType("billing").notNull(),
  unit: text("unit").notNull(),
  minSeats: integer("min_seats").notNull().default(1),
  // How many Macs one seat of this plan may activate; copied onto each license.
  maxDevices: integer("max_devices").notNull(),
  recommended: boolean("recommended").notNull().default(false),
  audience: text("audience"),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
});

/**
 * The per-seat price for a product. Kept as its own table (rather than a column
 * on product) so a Stripe Price id can be attached and historical prices can be
 * deactivated rather than mutated.
 */
export const price = pgTable("price", {
  id: text("id").primaryKey(),
  productId: text("product_id")
    .notNull()
    .references(() => product.id, { onDelete: "cascade" }),
  currency: text("currency").notNull(),
  amountCents: integer("amount_cents").notNull(),
  stripePriceId: text("stripe_price_id"),
  active: boolean("active").notNull().default(true),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
});

// ---------------------------------------------------------------------------
// Purchases + licenses
// ---------------------------------------------------------------------------

/**
 * One row per completed (or in-flight) Stripe Checkout. `amountCents` is the
 * grand total actually charged; `seats` multiplies the per-seat price.
 * `refundableUntil` marks the end of the money-back window (set at fulfillment
 * from the contract's refund.days); null until the purchase is fulfilled.
 */
export const purchase = pgTable("purchase", {
  id: text("id").primaryKey(),
  ownerUserId: text("owner_user_id")
    .notNull()
    .references(() => user.id, { onDelete: "restrict" }),
  productId: text("product_id")
    .notNull()
    .references(() => product.id, { onDelete: "restrict" }),
  seats: integer("seats").notNull(),
  amountCents: integer("amount_cents").notNull(),
  currency: text("currency").notNull(),
  status: purchaseStatus("status").notNull().default("pending"),
  refundableUntil: timestamp("refundable_until", { withTimezone: true }),
  stripeCheckoutSessionId: text("stripe_checkout_session_id").unique(),
  stripePaymentIntentId: text("stripe_payment_intent_id"),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
});

/**
 * A license issued by a purchase. `licenseKey` is what the desktop app stores
 * and presents for validation. The license is lifetime — it never expires and
 * includes all updates — so the only gate is `maxDevices`, the number of devices
 * that may hold a live `license_seat` activation at once.
 */
export const license = pgTable("license", {
  id: text("id").primaryKey(),
  purchaseId: text("purchase_id")
    .notNull()
    .references(() => purchase.id, { onDelete: "restrict" }),
  ownerUserId: text("owner_user_id")
    .notNull()
    .references(() => user.id, { onDelete: "restrict" }),
  productId: text("product_id")
    .notNull()
    .references(() => product.id, { onDelete: "restrict" }),
  licenseKey: text("license_key").notNull().unique(),
  maxDevices: integer("max_devices").notNull(),
  status: licenseStatus("status").notNull().default("active"),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
});

/**
 * A single device activation against a license. A seat is "live" while
 * `deactivatedAt` is null; the partial unique index keeps one device from
 * holding two live seats on the same license.
 */
export const licenseSeat = pgTable(
  "license_seat",
  {
    id: text("id").primaryKey(),
    licenseId: text("license_id")
      .notNull()
      .references(() => license.id, { onDelete: "cascade" }),
    deviceId: text("device_id").notNull(),
    deviceName: text("device_name"),
    activatedAt: timestamp("activated_at", { withTimezone: true })
      .notNull()
      .defaultNow(),
    deactivatedAt: timestamp("deactivated_at", { withTimezone: true }),
  },
  (table) => [
    uniqueIndex("license_seat_active_device")
      .on(table.licenseId, table.deviceId)
      .where(isNull(table.deactivatedAt)),
  ],
);

// ---------------------------------------------------------------------------
// Teams (Team plan)
// ---------------------------------------------------------------------------

export const team = pgTable("team", {
  id: text("id").primaryKey(),
  name: text("name").notNull(),
  ownerUserId: text("owner_user_id")
    .notNull()
    .references(() => user.id, { onDelete: "restrict" }),
  licenseId: text("license_id").references(() => license.id, {
    onDelete: "set null",
  }),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
});

/**
 * Membership of a team. `userId` is null for an invited-but-not-yet-registered
 * member (matched later by `email`); `seatId` links the member to the specific
 * license seat assigned to them.
 */
export const teamMember = pgTable(
  "team_member",
  {
    id: text("id").primaryKey(),
    teamId: text("team_id")
      .notNull()
      .references(() => team.id, { onDelete: "cascade" }),
    userId: text("user_id").references(() => user.id, { onDelete: "set null" }),
    email: text("email").notNull(),
    role: teamRole("role").notNull().default("member"),
    seatId: text("seat_id").references(() => licenseSeat.id, {
      onDelete: "set null",
    }),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (table) => [unique("team_member_unique_email").on(table.teamId, table.email)],
);

// ---------------------------------------------------------------------------
// Referral program (1.x scaffold — NOT wired into checkout/auth/desktop yet)
// ---------------------------------------------------------------------------

/**
 * A referrer's shareable code. The program is strictly opt-in, so a row exists
 * only for a user who chose to join (see PRICING.md privacy constraint). One
 * active code per user is sufficient for 1.x; `code` is unique and indexed
 * because invite links are looked up by code on every signup.
 */
export const referralCode = pgTable(
  "referral_code",
  {
    id: text("id").primaryKey(),
    userId: text("user_id")
      .notNull()
      .references(() => user.id, { onDelete: "cascade" }),
    code: text("code").notNull().unique(),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (table) => [uniqueIndex("referral_code_code_idx").on(table.code)],
);

/**
 * One invited friend tied to a referrer. `inviteeUserId` is null until the
 * friend actually signs up (before that we only know `inviteeEmail`).
 * `referrerUserId` is denormalized off the code's owner for convenient
 * per-referrer aggregation. The unique index keeps the same friend from being
 * counted twice toward the same referrer.
 */
export const referral = pgTable(
  "referral",
  {
    id: text("id").primaryKey(),
    referralCodeId: text("referral_code_id")
      .notNull()
      .references(() => referralCode.id, { onDelete: "cascade" }),
    referrerUserId: text("referrer_user_id")
      .notNull()
      .references(() => user.id, { onDelete: "cascade" }),
    inviteeUserId: text("invitee_user_id").references(() => user.id, {
      onDelete: "set null",
    }),
    inviteeEmail: text("invitee_email"),
    status: referralStatus("status").notNull().default("pending"),
    activatedAt: timestamp("activated_at", { withTimezone: true }),
    convertedAt: timestamp("converted_at", { withTimezone: true }),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (table) => [
    uniqueIndex("referral_unique_invitee").on(
      table.referrerUserId,
      table.inviteeUserId,
    ),
  ],
);

/**
 * A reward granted to a referrer as they climb the ladder (see
 * `rewardForActiveReferralCount` in referrals.ts). `referralId` is null for
 * milestone rewards that aren't attributable to one specific referral (e.g. the
 * free license earned at 3/5 active referrals). `detail` carries the concrete
 * grant — months for a trial extension, or the free plan id for a license.
 */
export const referralReward = pgTable("referral_reward", {
  id: text("id").primaryKey(),
  referrerUserId: text("referrer_user_id")
    .notNull()
    .references(() => user.id, { onDelete: "cascade" }),
  referralId: text("referral_id").references(() => referral.id, {
    onDelete: "set null",
  }),
  type: referralRewardType("type").notNull(),
  detail: text("detail").notNull(),
  grantedAt: timestamp("granted_at", { withTimezone: true }).notNull().defaultNow(),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
});
