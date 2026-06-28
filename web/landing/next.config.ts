import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // Emit a self-contained server bundle so the Docker runtime image only needs
  // the standalone output plus static assets, not the full node_modules tree.
  output: "standalone",
};

export default nextConfig;
