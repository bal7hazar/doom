import { defineConfig, devices } from "@playwright/test";

const PORT = Number(process.env.PORT ?? 4174);

/**
 * Playwright runs against `vite preview`, not `vite dev`, so the smoke test
 * exercises the *production* bundle and the production COOP/COEP headers
 * (roadmap P2.7) rather than the dev server's.
 *
 * Headless Chromium has no GPU here, so WebGL2 runs on SwiftShader. The
 * `--use-angle=swiftshader` flag makes that explicit and reproducible instead
 * of depending on what the machine happens to expose; the fps assertion is
 * calibrated for it, and `render.spec.ts` records which rasterizer it actually
 * got in the test output.
 */
export default defineConfig({
  testDir: "e2e",
  outputDir: "test-results",
  timeout: 180_000,
  expect: { timeout: 90_000 },
  fullyParallel: false,
  workers: 1,
  retries: 0,
  reporter: [["list"], ["html", { open: "never" }]],
  use: {
    baseURL: `http://localhost:${PORT}`,
    trace: "retain-on-failure",
    video: "off",
  },
  projects: [
    {
      name: "chromium",
      use: {
        ...devices["Desktop Chrome"],
        // Deliberately small and at scale 1: SwiftShader is a CPU rasterizer,
        // so the frame rate this test measures is dominated by the number of
        // fragments. 640x400 is twice Doom's own 320x200 and keeps the
        // measurement about the renderer rather than about the fill rate of a
        // machine with no GPU. `render.spec.ts` records the size it used.
        viewport: { width: 640, height: 400 },
        deviceScaleFactor: 1,
        launchOptions: {
          args: [
            "--use-gl=angle",
            "--use-angle=swiftshader",
            "--enable-unsafe-swiftshader",
          ],
        },
      },
    },
  ],
  webServer: {
    command: `npm run build && npm run preview -- --port ${PORT} --strictPort`,
    port: PORT,
    reuseExistingServer: !process.env.CI,
    timeout: 180_000,
    stdout: "pipe",
    stderr: "pipe",
  },
});
