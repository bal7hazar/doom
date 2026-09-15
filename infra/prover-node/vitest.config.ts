import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    environment: "node",
    include: ["test/**/*.test.ts"],
    // Nothing here touches a network or a real prover: every stage is driven through its
    // interface with an in-memory or subprocess-free implementation. The root proof fixture
    // (~500 kB gzipped) is read from cairo/doom_contracts for the registration test.
    testTimeout: 120_000,
  },
});
