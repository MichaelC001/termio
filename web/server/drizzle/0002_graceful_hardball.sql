ALTER TYPE "public"."purchase_status" ADD VALUE 'expired';--> statement-breakpoint
ALTER TABLE "product" ADD COLUMN "stripe_product_id" text;--> statement-breakpoint
ALTER TABLE "purchase" ADD COLUMN "stripe_customer_id" text;