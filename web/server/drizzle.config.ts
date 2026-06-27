import "dotenv/config";
import { defineConfig } from "drizzle-kit";

/**
 * drizzle-kit reads DATABASE_URL only for `migrate`/`push`; `generate` works
 * purely from the schema file and needs no live database.
 */
export default defineConfig({
  schema: "./src/db/schema.ts",
  out: "./drizzle",
  dialect: "postgresql",
  dbCredentials: {
    url: process.env.DATABASE_URL ?? "",
  },
  casing: "snake_case",
});
