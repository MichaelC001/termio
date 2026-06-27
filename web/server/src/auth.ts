import { betterAuth } from "better-auth";
import { drizzleAdapter } from "better-auth/adapters/drizzle";

import { database } from "./db/index.js";
import * as schema from "./db/schema.js";
import { environment } from "./env.js";

/**
 * Build the social-provider config conditionally: better-auth rejects a provider
 * block with empty credentials, so we only register GitHub/Google when both the
 * id and secret are present. This lets the app boot in development without OAuth.
 */
function socialProviders() {
  const providers: Record<string, { clientId: string; clientSecret: string }> = {};

  if (environment.githubClientId && environment.githubClientSecret) {
    providers.github = {
      clientId: environment.githubClientId,
      clientSecret: environment.githubClientSecret,
    };
  }
  if (environment.googleClientId && environment.googleClientSecret) {
    providers.google = {
      clientId: environment.googleClientId,
      clientSecret: environment.googleClientSecret,
    };
  }
  return providers;
}

export const auth = betterAuth({
  secret: environment.betterAuthSecret,
  baseURL: environment.betterAuthUrl,
  basePath: "/api/auth",

  database: drizzleAdapter(database, {
    provider: "pg",
    schema: {
      user: schema.user,
      session: schema.session,
      account: schema.account,
      verification: schema.verification,
    },
  }),

  emailAndPassword: {
    enabled: true,
    // TODO(production): turn on requireEmailVerification once an email provider
    // (Resend/Postmark/SES) is wired into sendVerificationEmail below.
    requireEmailVerification: false,
  },

  socialProviders: socialProviders(),

  // The landing page lives on a different origin and calls this API with cookies.
  trustedOrigins: [environment.webOrigin],
});

export type Auth = typeof auth;
export type SessionUser = Auth["$Infer"]["Session"]["user"];
export type SessionData = Auth["$Infer"]["Session"];
