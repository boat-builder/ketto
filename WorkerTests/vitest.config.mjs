import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

// Runs worker.js inside the real Workers runtime with an in-memory R2 bucket. The token
// binding here stands in for the KETTO_TOKEN secret that setup.sh installs in production.
export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.jsonc" },
      miniflare: { bindings: { KETTO_TOKEN: "test-token-0123456789abcdef" } },
    }),
  ],
  // The multipart test pushes 5 MiB through the runtime; on a loaded CI runner that can pass vitest's
  // default 5 s budget even though the work itself takes well under a second.
  test: { testTimeout: 30_000 },
});
