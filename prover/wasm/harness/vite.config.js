import { defineConfig } from "vite";

// COOP/COEP make the page cross-origin isolated: required for SharedArrayBuffer (future threads)
// and for performance.measureUserAgentSpecificMemory().
const isolationHeaders = {
  "Cross-Origin-Opener-Policy": "same-origin",
  "Cross-Origin-Embedder-Policy": "require-corp",
};

export default defineConfig({
  // build.sh copies dist/hellproof_prover_wasm.wasm here; served as-is with application/wasm.
  publicDir: "public",
  server: { headers: isolationHeaders, port: 5173, strictPort: false },
  preview: { headers: isolationHeaders },
  worker: { format: "es" },
  build: { target: "esnext" },
  optimizeDeps: { exclude: [] },
});
