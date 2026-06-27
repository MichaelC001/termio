import { drizzle } from "drizzle-orm/postgres-js";
import postgres from "postgres";

import { environment } from "../env.js";
import * as schema from "./schema.js";

/**
 * Single postgres.js connection pool for the process.
 *
 * `prepare: false` is required when connecting through Supabase's transaction-mode
 * pooler (PgBouncer), which does not support prepared statements. It is harmless
 * on a direct connection, so we set it unconditionally.
 */
const client = postgres(environment.databaseUrl, { prepare: false });

export const database = drizzle(client, { schema });

export { schema };
