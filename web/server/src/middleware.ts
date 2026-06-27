import type { Context, MiddlewareHandler } from "hono";

import { auth, type SessionData, type SessionUser } from "./auth.js";

/**
 * Hono environment for routes behind authentication. `user`/`session` are only
 * populated after `requireAuth` runs, so they are typed as possibly-undefined and
 * read through the helpers below to keep call sites honest.
 */
export interface AppEnv {
  Variables: {
    user: SessionUser | undefined;
    session: SessionData["session"] | undefined;
  };
}

/**
 * Gate a route on a valid better-auth session. better-auth reads the session from
 * the request cookies; we hand it the raw Headers and 401 when there is none.
 */
export const requireAuth: MiddlewareHandler<AppEnv> = async (context, next) => {
  const data = await auth.api.getSession({ headers: context.req.raw.headers });
  if (!data) {
    return context.json({ error: "Authentication required" }, 401);
  }
  context.set("user", data.user);
  context.set("session", data.session);
  await next();
};

/** Read the authenticated user, asserting `requireAuth` ran first. */
export function currentUser(context: Context<AppEnv>): SessionUser {
  const user = context.get("user");
  if (!user) {
    // Reaching here means a route forgot to apply requireAuth — fail loudly.
    throw new Error("currentUser called without requireAuth on the route");
  }
  return user;
}
