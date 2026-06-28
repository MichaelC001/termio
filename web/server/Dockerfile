# Single-stage image: the server is small and its migration step (drizzle-kit)
# needs the dev dependencies, so there is little to gain from pruning to prod-only.
FROM node:22-alpine

WORKDIR /app

# pnpm is pinned by packageManager/corepack; enable it before installing.
RUN corepack enable

# Install with the lockfile first so this layer caches across source changes.
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
RUN pnpm install --frozen-lockfile

COPY . .
RUN pnpm build

EXPOSE 8787

# Apply any pending migrations, then start the compiled server. Running migrate
# on boot keeps a fresh `docker compose up` self-contained.
CMD ["sh", "-c", "pnpm db:migrate && node dist/index.js"]
