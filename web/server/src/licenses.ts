import { randomInt, randomUUID } from "node:crypto";

import { and, eq, isNull, sql } from "drizzle-orm";

import { database } from "./db/index.js";
import { license, licenseSeat } from "./db/schema.js";

/**
 * Crockford-style alphabet with visually ambiguous characters removed
 * (no 0/O, 1/I/L) so a license key read off a screen or invoice is unambiguous.
 */
const KEY_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";
const KEY_GROUPS = 4;
const KEY_GROUP_LENGTH = 4;
const KEY_PREFIX = "TERMIO";

const keyGroupPattern = `[${KEY_ALPHABET}]{${KEY_GROUP_LENGTH}}`;
const LICENSE_KEY_PATTERN = new RegExp(
  `^${KEY_PREFIX}-${Array(KEY_GROUPS).fill(keyGroupPattern).join("-")}$`,
);

/**
 * Produce a cryptographically random license key such as
 * `TERMIO-7K4M-QP2X-9HRY-N3VW`. Uses crypto.randomInt (rejection-sampled, no
 * modulo bias) rather than Math.random so keys are not predictable.
 */
export function generateLicenseKey(): string {
  const groups: string[] = [];
  for (let group = 0; group < KEY_GROUPS; group += 1) {
    let chars = "";
    for (let index = 0; index < KEY_GROUP_LENGTH; index += 1) {
      chars += KEY_ALPHABET[randomInt(KEY_ALPHABET.length)];
    }
    groups.push(chars);
  }
  return `${KEY_PREFIX}-${groups.join("-")}`;
}

/** Cheap shape check before hitting the database on validate/activate calls. */
export function isWellFormedLicenseKey(key: string): boolean {
  return LICENSE_KEY_PATTERN.test(key);
}

export type LicenseValidation =
  | { valid: false; reason: "malformed" | "not-found" | "revoked" }
  | {
      valid: true;
      license: typeof license.$inferSelect;
      seatsUsed: number;
      seatsAvailable: number;
    };

/** Look up a key and report its status plus current device utilisation. */
export async function validateLicenseKey(
  key: string,
): Promise<LicenseValidation> {
  if (!isWellFormedLicenseKey(key)) {
    return { valid: false, reason: "malformed" };
  }

  const found = await database
    .select()
    .from(license)
    .where(eq(license.licenseKey, key))
    .limit(1);

  const record = found[0];
  if (!record) {
    return { valid: false, reason: "not-found" };
  }
  if (record.status === "revoked") {
    return { valid: false, reason: "revoked" };
  }

  const seatsUsed = await countLiveSeats(record.id);
  return {
    valid: true,
    license: record,
    seatsUsed,
    seatsAvailable: Math.max(0, record.maxDevices - seatsUsed),
  };
}

async function countLiveSeats(licenseId: string): Promise<number> {
  const rows = await database
    .select({ count: sql<number>`count(*)::int` })
    .from(licenseSeat)
    .where(
      and(eq(licenseSeat.licenseId, licenseId), isNull(licenseSeat.deactivatedAt)),
    );
  return rows[0]?.count ?? 0;
}

export type SeatActivation =
  | { ok: false; reason: "malformed" | "not-found" | "revoked" | "seats-exhausted" }
  | { ok: true; seat: typeof licenseSeat.$inferSelect; alreadyActive: boolean };

/**
 * Activate a device against a license. Re-activating the same device is
 * idempotent (returns the existing live seat). A new device is rejected once the
 * license's seat count is fully used.
 */
export async function activateSeat(
  key: string,
  deviceId: string,
  deviceName?: string,
): Promise<SeatActivation> {
  const validation = await validateLicenseKey(key);
  if (!validation.valid) {
    return { ok: false, reason: validation.reason };
  }
  const owner = validation.license;

  const existing = await database
    .select()
    .from(licenseSeat)
    .where(
      and(
        eq(licenseSeat.licenseId, owner.id),
        eq(licenseSeat.deviceId, deviceId),
        isNull(licenseSeat.deactivatedAt),
      ),
    )
    .limit(1);

  const liveSeat = existing[0];
  if (liveSeat) {
    return { ok: true, seat: liveSeat, alreadyActive: true };
  }

  if (validation.seatsAvailable <= 0) {
    return { ok: false, reason: "seats-exhausted" };
  }

  const inserted = await database
    .insert(licenseSeat)
    .values({
      id: randomUUID(),
      licenseId: owner.id,
      deviceId,
      deviceName: deviceName ?? null,
    })
    .returning();

  const seat = inserted[0];
  if (!seat) {
    // Insert with returning() should always yield a row; treat absence as a
    // hard failure rather than silently pretending success.
    throw new Error("Seat activation insert returned no row");
  }
  return { ok: true, seat, alreadyActive: false };
}

export type SeatDeactivation =
  | { ok: false; reason: "malformed" | "not-found" | "revoked" | "not-active" }
  | { ok: true };

/** Release a device's seat so it can be re-used by another machine. */
export async function deactivateSeat(
  key: string,
  deviceId: string,
): Promise<SeatDeactivation> {
  const validation = await validateLicenseKey(key);
  if (!validation.valid) {
    return { ok: false, reason: validation.reason };
  }

  const released = await database
    .update(licenseSeat)
    .set({ deactivatedAt: new Date() })
    .where(
      and(
        eq(licenseSeat.licenseId, validation.license.id),
        eq(licenseSeat.deviceId, deviceId),
        isNull(licenseSeat.deactivatedAt),
      ),
    )
    .returning();

  if (released.length === 0) {
    return { ok: false, reason: "not-active" };
  }
  return { ok: true };
}
