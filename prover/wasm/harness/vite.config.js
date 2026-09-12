import path from "node:path";
import { fileURLToPath } from "node:url";
import { defineConfig } from "vite";

const here = path.dirname(fileURLToPath(import.meta.url));
const pkg = path.resolve(here, "../pkg");

// COOP/COEP make the page cross-origin isolated: required for SharedArrayBuffer (the threaded
// artifact) and for performance.measureUserAgentSpecificMemory().
const isolationHeaders = {
  "Cross-Origin-Opener-Policy": "same-origin",
  "Cross-Origin-Embedder-Policy": "require-corp",
};

export default defineConfig({
  // build.sh copies dist/*.wasm here; served as-is with application/wasm.
  publicDir: "public",
  resolve: {
    // The harness drives the package from its build output (`npm run build` in ../pkg).
    alias: { "@hellproof/prover-wasm": path.join(pkg, "dist/index.js") },
  },
  server: {
    headers: isolationHeaders,
    port: 5173,
    strictPort: false,
    // ../pkg/dist (the package) and ../pkg/wasm (the artifacts) live outside the Vite root.
    fs: { allow: [here, pkg] },
  },
  preview: { headers: isolationHeaders },
  worker: { format: "es" },
  build: { target: "esnext" },
  optimizeDeps: { exclude: ["@hellproof/prover-wasm"] },
});
