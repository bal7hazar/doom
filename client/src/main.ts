import { selectPalette } from "@hellproof/wad";
import { buildAssetStore, type AssetStore } from "./assets/assetStore.js";
import { atlasOccupancy } from "./assets/atlas.js";
import { chooseProfile, probeCapabilities, probeStorage } from "./caps/capabilities.js";
import { findDynamicSectors, type LevelJson } from "./map/level.js";
import { Renderer, type RenderOptions } from "./render/renderer.js";
import { TicScheduler } from "./sim/scheduler.js";
import { interpolate, SnapshotRing, type InterpolatedView } from "./sim/snapshot.js";
import { createStubSim } from "./sim/stubSim.js";
import { CairoClient } from "./sim/cairoClient.js";
import { CairoScheduler } from "./sim/cairoScheduler.js";
import { bindCairoPageLifecycle } from "./sim/cairoPageLifecycle.js";
import { PlaySession } from "./game/playSession.js";
import { DEFAULT_AUTOMAP, drawAutomap, type AutomapOptions } from "./ui/automap.js";
import { renderDiagnostics } from "./ui/diagnostics.js";
import { Hud } from "./ui/hud.js";

/**
 * Application entry point.
 *
 * Boot order matters: probe capabilities *before* allocating the snapshot ring
 * (its transport depends on cross-origin isolation), fetch the two assets in
 * parallel, then build the asset store, the renderer and the sim, and finally
 * start the 35 Hz scheduler and the rAF loop.
 */

const WAD_URL = import.meta.env?.VITE_WAD_URL ?? "/freedoom1.wad";
const LEVEL_URL = import.meta.env?.VITE_LEVEL_URL ?? "/levels/e1m1.json";

export interface FrameHistogram {
  /** Number of distinct RGB values in the frame. A cleared buffer has one. */
  distinct: number;
  /** Fraction of pixels that are not pure black. */
  nonBlackFraction: number;
  width: number;
  height: number;
}

/**
 * Reads the drawing buffer back and summarises it. Only ever called on demand
 * (the Playwright smoke test): `readPixels` is a full pipeline stall.
 */
function readFrameHistogram(
  gl: WebGL2RenderingContext,
  width: number,
  height: number,
): FrameHistogram {
  const pixels = new Uint8Array(width * height * 4);
  gl.readPixels(0, 0, width, height, gl.RGBA, gl.UNSIGNED_BYTE, pixels);
  const colors = new Set<number>();
  let nonBlack = 0;
  for (let i = 0; i < pixels.length; i += 4) {
    const rgb = (pixels[i]! << 16) | (pixels[i + 1]! << 8) | pixels[i + 2]!;
    colors.add(rgb);
    if (rgb !== 0) nonBlack++;
  }
  return { distinct: colors.size, nonBlackFraction: nonBlack / (width * height), width, height };
}

interface FrameStats {
  fps: number;
  frameMs: number;
  frames: number;
  /** Frames rendered since the last `resetFpsWindow()`, and the window's start. */
  windowFrames: number;
  windowStart: number;
}

async function main(): Promise<void> {
  const loading = document.getElementById("loading") as HTMLElement;
  const loadingStatus = document.getElementById("loading-status") as HTMLElement;
  const loadingProgress = document.getElementById("loading-progress") as HTMLProgressElement;
  const diagnosticsEl = document.getElementById("diagnostics") as HTMLElement;
  const statsEl = document.getElementById("stats") as HTMLElement;
  const canvas = document.getElementById("view") as HTMLCanvasElement;
  const overlay = document.getElementById("overlay") as HTMLCanvasElement;

  const say = (message: string, fraction: number): void => {
    loadingStatus.textContent = message;
    loadingProgress.value = Math.round(fraction * 100);
  };

  const caps = await probeStorage(probeCapabilities());
  const profile = chooseProfile(caps);
  renderDiagnostics(diagnosticsEl, caps, profile);

  if (!caps.webgl2.available) {
    fail(loading, loadingStatus, "WebGL2 is required and this browser does not provide it.");
    return;
  }

  say("fetching level + WAD…", 0.02);
  let level: LevelJson;
  let wadBytes: Uint8Array;
  try {
    [level, wadBytes] = await Promise.all([fetchLevel(LEVEL_URL), fetchWad(WAD_URL, say)]);
  } catch (err) {
    fail(
      loading,
      loadingStatus,
      `${(err as Error).message}\n\nRun \`npm run assets\` in client/ to stage freedoom1.wad and the level JSON into public/, or point VITE_WAD_URL / VITE_LEVEL_URL at a hosted copy.`,
    );
    return;
  }

  say("decoding assets…", 0.3);
  // Yield once so the loading text actually paints before the synchronous
  // decode (≈200 ms) blocks the main thread.
  await nextFrame();
  let store: AssetStore;
  try {
    store = buildAssetStore(wadBytes, level, (stage, fraction) => say(stage, 0.3 + fraction * 0.5));
  } catch (err) {
    fail(loading, loadingStatus, `Asset decoding failed: ${(err as Error).message}`);
    return;
  }

  say("building geometry…", 0.85);
  await nextFrame();
  const gl = canvas.getContext("webgl2", { antialias: false, depth: true, alpha: false });
  if (!gl) {
    fail(loading, loadingStatus, "Could not create a WebGL2 context.");
    return;
  }
  let renderer: Renderer;
  try {
    renderer = new Renderer(gl, level, store);
  } catch (err) {
    fail(loading, loadingStatus, `Renderer init failed: ${(err as Error).message}`);
    return;
  }

  // The legacy renderer/prover demonstration is an explicit route.
  const realCairo = new URLSearchParams(location.search).get("sim") !== "demo";
  const cairo = realCairo ? new CairoClient() : null;
  if (cairo) {
    document.body.classList.add("real-play");
    statsEl.hidden = true;
    say("loading real Cairo simulation…", 0.95);
    try { await cairo.init(); }
    catch (error) { cairo.dispose(); fail(loading, loadingStatus, String(error)); return; }
    profile.snapshotTransport = "copied";
    profile.reasons[0] = "Cairo Worker: transferred ArrayBuffers feed a local renderer ring";
    renderDiagnostics(diagnosticsEl, caps, profile);

  }
  const ring = cairo?.ring ?? new SnapshotRing();
  const sim = cairo ? null : createStubSim(level);

  // Proving (P3.2) is attached lazily, on F4: `public/prover/` is 90 MB of
  // gitignored wasm that a plain clone does not have, and nothing about it may
  // cost a frame before the player asks for the queue.
  let prove: import("./prove/session.js").ProveSession | null = null;
  let provePending = false;
  let neutralWord = 0;
  let play: PlaySession | undefined;
  const scheduler = cairo ? new CairoScheduler(cairo,
    () => play!.input.sample(), error => play?.error(error)) : new TicScheduler(ring, (tic) => {
    // Until P2.4 captures real input there is no command to record; the journal
    // takes the neutral one, so the wiring - and only the wiring - is exercised.
    if (prove) prove.recordTic(neutralWord);
    return sim!.stepTic(tic);
  });
  if (cairo && scheduler instanceof CairoScheduler) {
    play = new PlaySession(cairo, scheduler, canvas, document.getElementById("stage")!);
    document.getElementById("help")!.textContent = "WASD / ↑↓ move · ←→ turn · Shift run · Mouse / Ctrl fire · E / Space use · 1–4, 7 weapons · Esc / P pause · Tab map";
  }
  const toggleProofQueue = async (): Promise<void> => {
    if (cairo) {
      diagnosticsEl.hidden = false;
      // Never label the real journal with createStubProgram's executable.
      return;
    }
    if (prove) {
      prove.element.hidden = !prove.element.hidden;
      return;
    }
    if (provePending) return;
    provePending = true;
    try {
      const { ProveSession, NEUTRAL_TICCMD_WORD } = await import("./prove/session.js");
      neutralWord = NEUTRAL_TICCMD_WORD;
      prove = await ProveSession.create({
        host: document.getElementById("stage") as HTMLElement,
        wrapperUrl: import.meta.env?.VITE_WRAPPER_URL ?? null,
      });
      prove.element.classList.add("proof-queue-overlay");
    } catch (error) {
      console.error("proof queue unavailable:", error);
    } finally {
      provePending = false;
    }
  };
  const hud = new Hud(store);
  const dynamicSectors = findDynamicSectors(level);

  const renderOptions: RenderOptions = { flatShading: false, paletteRow: 0, forceColormap: -1 };
  const automapOptions: AutomapOptions = { ...DEFAULT_AUTOMAP };
  let showAutomap = false;
  let showHud = true;

  const frame: FrameStats = { fps: 0, frameMs: 0, frames: 0, windowFrames: 0, windowStart: performance.now() };
  let captureRequest: ((histogram: FrameHistogram) => void) | null = null;

  const overlayCtx = overlay.getContext("2d");
  const resize = (): void => {
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const w = Math.max(1, Math.round(canvas.clientWidth * dpr));
    const h = Math.max(1, Math.round(canvas.clientHeight * dpr));
    if (canvas.width !== w || canvas.height !== h) {
      canvas.width = w;
      canvas.height = h;
      renderer.resize(w, h);
    }
    if (overlay.width !== w || overlay.height !== h) {
      overlay.width = w;
      overlay.height = h;
    }
  };
  window.addEventListener("resize", resize);
  resize();

  window.addEventListener("keydown", (event) => {
    if (event.repeat || (event.target instanceof Element && event.target.closest("input,textarea,select,button,a"))) return;
    switch (event.key) {
      case "F1":
        event.preventDefault();
        diagnosticsEl.hidden = !diagnosticsEl.hidden;
        break;
      case "Tab":
        event.preventDefault();
        showAutomap = !showAutomap;
        break;
      case "F2":
        event.preventDefault();
        showHud = !showHud;
        break;
      case "F3":
        event.preventDefault();
        renderOptions.flatShading = !renderOptions.flatShading;
        break;
      case "F4":
        event.preventDefault();
        void toggleProofQueue();
        break;
      case " ":
        if (cairo) break;
        event.preventDefault();
        if (scheduler.isRunning) scheduler.stop();
        else scheduler.start();
        break;
      case "[":
        if (scheduler instanceof TicScheduler) scheduler.rate = Math.max(0.1, scheduler.rate / 1.5);
        break;
      case "]":
        if (scheduler instanceof TicScheduler) scheduler.rate = Math.min(8, scheduler.rate * 1.5);
        break;
      case "r":
      case "R":
        automapOptions.rotate = !automapOptions.rotate;
        break;
      case "+":
      case "=":
        automapOptions.zoom = Math.max(300, automapOptions.zoom / 1.3);
        break;
      case "-":
        automapOptions.zoom = Math.min(12000, automapOptions.zoom * 1.3);
        break;
    }
  });

  if (!cairo) scheduler.start();
  if (cairo && scheduler instanceof CairoScheduler) bindCairoPageLifecycle(scheduler, cairo);
  loading.hidden = true;

  let lastFrameTime = performance.now();
  const loop = (): void => {
    const now = performance.now();
    frame.frameMs = frame.frameMs === 0 ? now - lastFrameTime : frame.frameMs * 0.9 + (now - lastFrameTime) * 0.1;
    lastFrameTime = now;
    frame.frames++;
    frame.windowFrames++;
    if (now - frame.windowStart >= 500) {
      frame.fps = (frame.windowFrames * 1000) / (now - frame.windowStart);
      frame.windowFrames = 0;
      frame.windowStart = now;
    }

    play?.refresh();
    resize();
    const latest = ring.readLatest();
    const pair = ring.readPair() ?? (latest ? { previous: latest, current: latest } : null);
    if (pair) {
      const view: InterpolatedView = interpolate(pair.previous, pair.current, scheduler.alpha(now));
      renderOptions.paletteRow = selectPalette(
        view.latest.player.damageCount,
        view.latest.player.bonusCount,
        false,
      );
      renderer.render(view, renderOptions);

      // The drawing buffer is discarded once the frame is composited (the
      // context is created without `preserveDrawingBuffer`, which would cost a
      // copy every frame), so a caller that wants to inspect the pixels has to
      // be served here, right after the draw calls.
      if (captureRequest) {
        const request = captureRequest;
        captureRequest = null;
        request(readFrameHistogram(gl, canvas.width, canvas.height));
      }

      if (overlayCtx) {
        overlayCtx.clearRect(0, 0, overlay.width, overlay.height);
        const dpr = overlay.width / Math.max(1, canvas.clientWidth);
        overlayCtx.save();
        overlayCtx.scale(dpr, dpr);
        const cssW = overlay.width / dpr;
        const cssH = overlay.height / dpr;
        if (showAutomap) {
          drawAutomap(overlayCtx, level, view, cssW, cssH, automapOptions, sim?.path ?? [], dynamicSectors);
        }
        if (showHud) hud.draw(overlayCtx, view.latest, cssW, cssH);
        overlayCtx.restore();
      }

      statsEl.textContent = formatStats(frame, scheduler, renderer, store, caps.webgl2.renderer);
    }
    requestAnimationFrame(loop);
  };
  requestAnimationFrame(loop);

  // Exposed for the Playwright smoke test (e2e/render.spec.ts), which reads the
  // fps window and the renderer stats rather than scraping the stats overlay.
  (window as unknown as Record<string, unknown>).hellproof = {
    caps,
    profile,
    frame,
    scheduler,
    renderer,
    store,
    level,
    ring,
    cairo,
    play,
    resetFpsWindow(): void {
      frame.frames = 0;
      frame.windowFrames = 0;
      frame.windowStart = performance.now();
      scheduler.droppedTics = 0;
    },
    /** Resolves with a colour histogram of the next rendered frame. */
    captureFrame(): Promise<FrameHistogram> {
      return new Promise((resolve) => {
        captureRequest = resolve;
      });
    },
    fpsSince(startFrames: number, startMs: number): number {
      return ((frame.frames - startFrames) * 1000) / Math.max(1, performance.now() - startMs);
    },
  };
}

function formatStats(
  frame: FrameStats,
  scheduler: Pick<TicScheduler, "tic" | "rate" | "stepMs" | "droppedTics">,
  renderer: Renderer,
  store: AssetStore,
  gpu: string | null,
): string {
  const s = renderer.stats;
  return [
    `${frame.fps.toFixed(1)} fps   ${frame.frameMs.toFixed(2)} ms/frame`,
    `render cpu ${s.cpuMs.toFixed(2)} ms   ${s.drawCalls} draw calls`,
    `tic ${scheduler.tic}  rate ${scheduler.rate.toFixed(2)}x  sim ${scheduler.stepMs.toFixed(2)} ms  dropped ${scheduler.droppedTics}`,
    `walls ${s.wallQuads} static + ${s.dynamicWallQuads} dynamic   flats ${s.flatTriangles} tris   sprites ${s.sprites}`,
    `atlas ${store.surfaceAtlas.width}² ${(atlasOccupancy(store.surfaceAtlas) * 100).toFixed(0)}%  sprites ${store.spriteAtlas.width}² ${(atlasOccupancy(store.spriteAtlas) * 100).toFixed(0)}%`,
    gpu ?? "",
  ].join("\n");
}

async function fetchLevel(url: string): Promise<LevelJson> {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`Level JSON ${url}: HTTP ${response.status}`);
  return (await response.json()) as LevelJson;
}

async function fetchWad(url: string, say: (m: string, f: number) => void): Promise<Uint8Array> {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`WAD ${url}: HTTP ${response.status}`);
  const total = Number(response.headers.get("content-length") ?? 0);
  if (!response.body || total === 0) return new Uint8Array(await response.arrayBuffer());

  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let received = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    chunks.push(value);
    received += value.length;
    say(`downloading WAD… ${(received / 1e6).toFixed(1)} / ${(total / 1e6).toFixed(1)} MB`, 0.02 + (received / total) * 0.25);
  }
  const out = new Uint8Array(received);
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.length;
  }
  return out;
}

function nextFrame(): Promise<void> {
  return new Promise((resolve) => requestAnimationFrame(() => resolve()));
}

function fail(loading: HTMLElement, status: HTMLElement, message: string): void {
  loading.hidden = false;
  loading.classList.add("error");
  status.textContent = message;
  const progress = document.getElementById("loading-progress");
  if (progress) progress.remove();
  console.error(message);
}

void main();
