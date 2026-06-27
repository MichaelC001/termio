CREATE TYPE "public"."purchase_source" AS ENUM('purchase', 'referral');--> statement-breakpoint
ALTER TABLE "purchase" ADD COLUMN "source" "purchase_source" DEFAULT 'purchase' NOT NULL;