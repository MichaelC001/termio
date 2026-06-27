import { Hono } from "hono";

import {
  activateSeat,
  deactivateSeat,
  validateLicenseKey,
} from "../licenses.js";
import type { AppEnv } from "../middleware.js";

/**
 * License routes called by the desktop app (not the web dashboard). These are
 * intentionally unauthenticated by session cookie — the license key itself is the
 * bearer credential — so they take the key in the JSON body.
 *
 * TODO(production): add per-IP rate limiting here to slow key brute-forcing.
 */
export const licenseRoutes = new Hono<AppEnv>();

interface ValidateBody {
  licenseKey?: unknown;
}
interface SeatBody {
  licenseKey?: unknown;
  deviceId?: unknown;
  deviceName?: unknown;
}

function readString(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() !== "" ? value.trim() : undefined;
}

licenseRoutes.post("/validate", async (context) => {
  const body = (await context.req.json().catch(() => ({}))) as ValidateBody;
  const key = readString(body.licenseKey);
  if (!key) {
    return context.json({ error: "licenseKey is required" }, 400);
  }

  const result = await validateLicenseKey(key);
  if (!result.valid) {
    return context.json({ valid: false, reason: result.reason }, 200);
  }
  return context.json({
    valid: true,
    productId: result.license.productId,
    maxDevices: result.license.maxDevices,
    seatsUsed: result.seatsUsed,
    seatsAvailable: result.seatsAvailable,
  });
});

licenseRoutes.post("/activate-seat", async (context) => {
  const body = (await context.req.json().catch(() => ({}))) as SeatBody;
  const key = readString(body.licenseKey);
  const deviceId = readString(body.deviceId);
  if (!key || !deviceId) {
    return context.json({ error: "licenseKey and deviceId are required" }, 400);
  }

  const result = await activateSeat(key, deviceId, readString(body.deviceName));
  if (!result.ok) {
    const status = result.reason === "seats-exhausted" ? 409 : 404;
    return context.json({ activated: false, reason: result.reason }, status);
  }
  return context.json({
    activated: true,
    alreadyActive: result.alreadyActive,
    seatId: result.seat.id,
  });
});

licenseRoutes.post("/deactivate-seat", async (context) => {
  const body = (await context.req.json().catch(() => ({}))) as SeatBody;
  const key = readString(body.licenseKey);
  const deviceId = readString(body.deviceId);
  if (!key || !deviceId) {
    return context.json({ error: "licenseKey and deviceId are required" }, 400);
  }

  const result = await deactivateSeat(key, deviceId);
  if (!result.ok) {
    const status = result.reason === "not-active" ? 409 : 404;
    return context.json({ deactivated: false, reason: result.reason }, status);
  }
  return context.json({ deactivated: true });
});
