import { serve } from "@hono/node-server";
import { Hono } from "hono";
import { cors } from "hono/cors";

import { auth } from "./auth.js";
import { environment } from "./env.js";
import type { AppEnv } from "./middleware.js";
import { accountRoutes } from "./routes/account.js";
import { checkoutRoutes } from "./routes/checkout.js";
import { licenseRoutes } from "./routes/license.js";
import { referralRoutes } from "./routes/referral.js";

const app = new Hono<AppEnv>();

// The landing page calls this API from a different origin with session cookies,
// so credentials must be allowed and the origin echoed (not "*").
app.use(
  "*",
  cors({
    origin: environment.webOrigin,
    credentials: true,
    allowMethods: ["GET", "POST", "OPTIONS"],
    allowHeaders: ["Content-Type", "Authorization"],
  }),
);

app.get("/health", (context) => context.json({ status: "ok" }));

// better-auth owns every method under its base path.
app.on(["GET", "POST"], "/api/auth/*", (context) =>
  auth.handler(context.req.raw),
);

app.route("/api/account", accountRoutes);
app.route("/api/license", licenseRoutes);
app.route("/api/checkout", checkoutRoutes);
app.route("/api/referral", referralRoutes);

// Centralized JSON error handling so handlers can throw and clients always get a
// structured body. We log the real error server-side and never leak its message.
app.onError((error, context) => {
  console.error("Unhandled request error:", error);
  return context.json({ error: "Internal Server Error" }, 500);
});

app.notFound((context) => context.json({ error: "Not Found" }, 404));

serve({ fetch: app.fetch, port: environment.port }, (info) => {
  console.log(`termio server listening on http://localhost:${info.port}`);
});
