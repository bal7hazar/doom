import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    environment: "node",
    include: ["test/**/*.test.ts"],
    // The devnet integration test skips itself when nothing answers on INDEXER_TEST_RPC.
    testTimeout: 120_000,
  },
});
