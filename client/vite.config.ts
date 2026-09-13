import { resolve } from "node:path";
import { defineConfig } from "vite";

/**
 * Cross-origin isolation headers (roadmap P2.7).
 *
 * `SharedArrayBuffer` — which the sim Worker needs for the triple-buffered
 * snapshot ring (docs/spikes/S3.md §7.2) — and an unthrottled
 * `performance.now()` are only available to a *cross-origin isolated*
 * document. That requires both headers below on the top-level document; every
 * subresource then has to be same-origin or explicitly CORP/CORS-opted-in,
 * which is why the WAD and the level JSON are served from `public/` (same
 * origin) by default.
 *
 * Memory64 (needed by the Stwo prover build, S2) does not itself require
 * isolation, but the prover Workers do, so the whole app is served isolated.
 *
 * These headers must be reproduced by whatever serves `dist/` in production
 * (see `docs/` / infra); `vite preview` sets them too so the production build
 * can be exercised locally under the same constraints.
 */
const crossOriginIsolationHeaders = {
  "Cross-Origin-Embedder-Policy": "require-corp",
  "Cross-Origin-Opener-Policy": "same-origin",
  // Not required for isolation, but makes same-origin subresources loadable
  // by an isolated document without per-response opt-in surprises.
  "Cross-Origin-Resource-Policy": "same-origin",
};

export default defineConfig({
  server: {
    headers: crossOriginIsolationHeaders,
    // The WAD is large; disabling the dep-scan warning noise keeps dev output
    // readable. No other server tweaks are needed.
    fs: { strict: true },
  },
  preview: {
    headers: crossOriginIsolationHeaders,
  },
  build: {
    target: "es2022",
    sourcemap: true,
    rollupOptions: {
      // Two pages: the renderer preview and the proving pipeline harness
      // (P3.2), which the Playwright end-to-end test drives.
      input: {
        main: resolve(import.meta.dirname, "index.html"),
        prove: resolve(import.meta.dirname, "prove.html"),
      },
    },
  },
  worker: {
    format: "es",
  },
});
