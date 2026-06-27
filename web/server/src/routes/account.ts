import { eq } from "drizzle-orm";
import { Hono } from "hono";

import { database } from "../db/index.js";
import { license, licenseSeat } from "../db/schema.js";
import { type AppEnv, currentUser, requireAuth } from "../middleware.js";

/**
 * Account routes: everything the signed-in web dashboard needs to render a
 * customer's licenses and the devices currently using each seat.
 */
export const accountRoutes = new Hono<AppEnv>();

accountRoutes.use("*", requireAuth);

accountRoutes.get("/me", (context) => {
  const user = currentUser(context);
  return context.json({
    id: user.id,
    name: user.name,
    email: user.email,
    emailVerified: user.emailVerified,
    image: user.image,
  });
});

accountRoutes.get("/licenses", async (context) => {
  const user = currentUser(context);

  const ownedLicenses = await database
    .select()
    .from(license)
    .where(eq(license.ownerUserId, user.id));

  const withSeats = await Promise.all(
    ownedLicenses.map(async (owned) => {
      const seats = await database
        .select()
        .from(licenseSeat)
        .where(eq(licenseSeat.licenseId, owned.id));

      const liveSeats = seats.filter((seat) => seat.deactivatedAt === null);
      return {
        id: owned.id,
        licenseKey: owned.licenseKey,
        productId: owned.productId,
        maxDevices: owned.maxDevices,
        seatsUsed: liveSeats.length,
        status: owned.status,
        activations: seats.map((seat) => ({
          id: seat.id,
          deviceId: seat.deviceId,
          deviceName: seat.deviceName,
          activatedAt: seat.activatedAt,
          deactivatedAt: seat.deactivatedAt,
        })),
      };
    }),
  );

  return context.json({ licenses: withSeats });
});
