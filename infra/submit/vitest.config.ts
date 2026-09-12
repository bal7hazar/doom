import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    environment: "node",
    include: ["test/**/*.test.ts"],
    // The devnet integration test skips itself when nothing answers on SUBMIT_TEST_RPC; the
    // fixture tests read the committed root proofs (~500 kB gzipped), which are always there.
    testTimeout: 300_000,
  },
});
