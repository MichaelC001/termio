import Stripe from "stripe";

import { environment } from "./env.js";

/**
 * Lazily construct the Stripe client only when a secret key is configured. In a
 * fresh checkout the absence of a client is a clear "Stripe not configured"
 * signal rather than a crash, which keeps the scaffold runnable without keys.
 */
export const stripe: Stripe | null = environment.stripeSecretKey
  ? new Stripe(environment.stripeSecretKey)
  : null;
