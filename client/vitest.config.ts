import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    environment: "node",
    include: ["test/**/*.test.ts"],
    // The asset-decoding tests read a fixture extracted from freedoom1.wad;
    // they are skipped (not failed) when the fixture is absent, so a clone
    // without the WAD still has a green `npm test`.
    testTimeout: 20_000,
  },
});
