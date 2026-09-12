/**
 * Startup capability probe (roadmap P2.7 — "En-têtes COOP/COEP, détection
 * Memory64/RAM", exit criterion "bascule testée").
 *
 * Everything here is a *measurement*, never a policy: `chooseProfile()` turns
 * the measurements into the two switches the rest of the app reads
 *   - `snapshotTransport`: shared (SharedArrayBuffer) vs copied (postMessage)
 *   - `proverProfile`:     wasm64 vs wasm32 vs remote-only
 * so that the toggle can be unit-tested without a browser.
 *
 * No probe is allowed to throw: a browser that lacks a feature must produce
 * `false`, not an exception, because this runs before anything else.
 */

export interface WasmFeatureProbe {
  /** 64-bit linear memory (`memory64` proposal). Required by the Stwo prover build (S2). */
  memory64: boolean;
  /** Fixed-width SIMD — large constant factor for the prover's field arithmetic. */
  simd: boolean;
  /** Shared memory + atomics; also needs cross-origin isolation to be usable. */
  threads: boolean;
  /** `memory.copy`/`memory.fill`; required by every wasm-bindgen artifact we ship. */
  bulkMemory: boolean;
  /** Exception handling — cairo-vm's panic path compiles smaller with it. */
  exceptions: boolean;
}

export interface Capabilities {
  webAssembly: boolean;
  wasm: WasmFeatureProbe;
  /** `window.crossOriginIsolated` — true only when COOP+COEP are both served. */
  crossOriginIsolated: boolean;
  /** The `SharedArrayBuffer` constructor exists *and* can actually allocate. */
  sharedArrayBuffer: boolean;
  /** `Atomics.wait` is only allowed off the main thread, but its presence is a proxy. */
  atomics: boolean;
  /** `navigator.deviceMemory`, in GiB. Chromium-only, quantized and capped at 8. */
  deviceMemoryGiB: number | null;
  /** `navigator.hardwareConcurrency`: logical cores. */
  hardwareConcurrency: number;
  /** `performance.memory.jsHeapSizeLimit` in bytes (Chromium-only fallback RAM hint). */
  jsHeapSizeLimitBytes: number | null;
  /** WebGL2 availability plus the limits the renderer actually depends on. */
  webgl2: Webgl2Probe;
  /** `navigator.storage.estimate()` quota, filled in by `probeStorage()`. */
  storageQuotaBytes: number | null;
  userAgent: string;
}

export interface Webgl2Probe {
  available: boolean;
  maxTextureSize: number;
  maxTextureImageUnits: number;
  maxVertexTextureImageUnits: number;
  /** Unmasked renderer string via WEBGL_debug_renderer_info, when exposed. */
  renderer: string | null;
  /** True when the context reports a software rasterizer (SwiftShader/llvmpipe). */
  softwareRasterizer: boolean;
}

/**
 * The smallest valid wasm module that declares a 64-bit memory.
 *
 *   00 61 73 6d   \0asm
 *   01 00 00 00   version 1
 *   05 03         section 5 (memory), 3 bytes
 *   01            one memory
 *   04            limits flags: bit 2 = "index type is i64" (memory64)
 *   00            minimum 0 pages
 *
 * `WebAssembly.validate` rejects the flag byte `0x04` unless the engine
 * implements the memory64 proposal, so validating this 13-byte module is an
 * exact feature test that costs no compilation.
 */
const WASM64_MODULE = Uint8Array.of(
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x05, 0x03, 0x01, 0x04, 0x00,
);

/** `(module (memory 1 1 shared))` — needs the threads proposal to validate. */
const WASM_THREADS_MODULE = Uint8Array.of(
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x05, 0x04, 0x01, 0x03, 0x01, 0x01,
);

/** `(func (result v128) i32.const 0 i8x16.splat)` — needs fixed-width SIMD. */
const WASM_SIMD_MODULE = Uint8Array.of(
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7b, 0x03,
  0x02, 0x01, 0x00, 0x0a, 0x08, 0x01, 0x06, 0x00, 0x41, 0x00, 0xfd, 0x0f, 0x0b,
);

/** `(memory 1) (func memory.fill …)` — needs bulk-memory operations. */
const WASM_BULK_MEMORY_MODULE = Uint8Array.of(
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04, 0x01, 0x60, 0x00, 0x00, 0x03, 0x02,
  0x01, 0x00, 0x05, 0x03, 0x01, 0x00, 0x01, 0x0a, 0x0d, 0x01, 0x0b, 0x00, 0x41, 0x00, 0x41, 0x00,
  0x41, 0x00, 0xfc, 0x0b, 0x00, 0x0b,
);

/** A function body containing `try_table`/`throw_ref`-era tags — needs exception handling. */
const WASM_EXCEPTIONS_MODULE = Uint8Array.of(
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04, 0x01, 0x60, 0x00, 0x00, 0x0d, 0x03,
  0x01, 0x00, 0x00,
);

function validates(bytes: Uint8Array<ArrayBuffer>): boolean {
  try {
    return typeof WebAssembly !== "undefined" && WebAssembly.validate(bytes);
  } catch {
    return false;
  }
}

export function probeWasmFeatures(): WasmFeatureProbe {
  return {
    memory64: validates(WASM64_MODULE),
    simd: validates(WASM_SIMD_MODULE),
    threads: validates(WASM_THREADS_MODULE),
    bulkMemory: validates(WASM_BULK_MEMORY_MODULE),
    exceptions: validates(WASM_EXCEPTIONS_MODULE),
  };
}

function probeSharedArrayBuffer(): boolean {
  try {
    if (typeof SharedArrayBuffer === "undefined") return false;
    // The constructor can exist while allocation is blocked (non-isolated
    // contexts in some engines), so actually allocate one word.
    const sab = new SharedArrayBuffer(4);
    return sab.byteLength === 4;
  } catch {
    return false;
  }
}

export function probeWebgl2(canvas?: HTMLCanvasElement): Webgl2Probe {
  const unavailable: Webgl2Probe = {
    available: false,
    maxTextureSize: 0,
    maxTextureImageUnits: 0,
    maxVertexTextureImageUnits: 0,
    renderer: null,
    softwareRasterizer: false,
  };
  if (typeof document === "undefined") return unavailable;
  try {
    const c = canvas ?? document.createElement("canvas");
    const gl = c.getContext("webgl2", { failIfMajorPerformanceCaveat: false });
    if (!gl) return unavailable;
    const dbg = gl.getExtension("WEBGL_debug_renderer_info");
    const renderer: string | null = dbg
      ? (gl.getParameter(dbg.UNMASKED_RENDERER_WEBGL) as string)
      : (gl.getParameter(gl.RENDERER) as string);
    return {
      available: true,
      maxTextureSize: gl.getParameter(gl.MAX_TEXTURE_SIZE) as number,
      maxTextureImageUnits: gl.getParameter(gl.MAX_TEXTURE_IMAGE_UNITS) as number,
      maxVertexTextureImageUnits: gl.getParameter(gl.MAX_VERTEX_TEXTURE_IMAGE_UNITS) as number,
      renderer,
      softwareRasterizer: /swiftshader|llvmpipe|software|mesa offscreen/i.test(renderer ?? ""),
    };
  } catch {
    return unavailable;
  }
}

export function probeCapabilities(): Capabilities {
  const nav = typeof navigator === "undefined" ? undefined : navigator;
  const perfMemory = (
    globalThis.performance as Performance & { memory?: { jsHeapSizeLimit: number } } | undefined
  )?.memory;
  return {
    webAssembly: typeof WebAssembly !== "undefined",
    wasm: probeWasmFeatures(),
    crossOriginIsolated: globalThis.crossOriginIsolated === true,
    sharedArrayBuffer: probeSharedArrayBuffer(),
    atomics: typeof Atomics !== "undefined",
    deviceMemoryGiB:
      typeof (nav as Navigator & { deviceMemory?: number })?.deviceMemory === "number"
        ? (nav as Navigator & { deviceMemory: number }).deviceMemory
        : null,
    hardwareConcurrency: nav?.hardwareConcurrency ?? 1,
    jsHeapSizeLimitBytes: perfMemory ? perfMemory.jsHeapSizeLimit : null,
    webgl2: probeWebgl2(),
    storageQuotaBytes: null,
    userAgent: nav?.userAgent ?? "unknown",
  };
}

/** Async part of the probe; merged into an existing `Capabilities` in place. */
export async function probeStorage(caps: Capabilities): Promise<Capabilities> {
  try {
    const estimate = await navigator.storage?.estimate?.();
    caps.storageQuotaBytes = estimate?.quota ?? null;
  } catch {
    caps.storageQuotaBytes = null;
  }
  return caps;
}

export type SnapshotTransport = "shared" | "copied";
export type ProverProfile = "wasm64" | "wasm32" | "remote-only";

export interface RuntimeProfile {
  snapshotTransport: SnapshotTransport;
  proverProfile: ProverProfile;
  /** Worker count reserved for background proving (S3 §7.4: leave 2 cores). */
  proverWorkers: number;
  /** Human-readable reasons, shown on the diagnostics panel. */
  reasons: string[];
}

/**
 * Turns the probe into the two runtime switches.
 *
 * Prover profile thresholds come from S2/S0: the wasm64 prover needs more than
 * 4 GiB of addressable heap for the larger `log_n_instances`, so we only pick
 * it when memory64 validates *and* the device reports >= 8 GiB. Chromium caps
 * `deviceMemory` at 8, so ">= 8" really means "8 or more". Absent the API
 * (Firefox, Safari) we fall back on wasm32, which is the conservative choice.
 */
export function chooseProfile(caps: Capabilities): RuntimeProfile {
  const reasons: string[] = [];

  const snapshotTransport: SnapshotTransport =
    caps.crossOriginIsolated && caps.sharedArrayBuffer && caps.atomics ? "shared" : "copied";
  if (snapshotTransport === "shared") {
    reasons.push("cross-origin isolated: snapshot ring uses SharedArrayBuffer + Atomics");
  } else if (!caps.crossOriginIsolated) {
    reasons.push("not cross-origin isolated (COOP/COEP missing): snapshots fall back to postMessage copies");
  } else {
    reasons.push("SharedArrayBuffer unavailable despite isolation: snapshots fall back to postMessage copies");
  }

  let proverProfile: ProverProfile;
  if (!caps.webAssembly) {
    proverProfile = "remote-only";
    reasons.push("no WebAssembly: local proving impossible, remote prover only");
  } else if (caps.wasm.memory64 && (caps.deviceMemoryGiB ?? 0) >= 8) {
    proverProfile = "wasm64";
    reasons.push(`memory64 validated and deviceMemory=${caps.deviceMemoryGiB} GiB: wasm64 prover`);
  } else if (caps.wasm.memory64) {
    proverProfile = "wasm32";
    reasons.push(
      caps.deviceMemoryGiB === null
        ? "memory64 validated but navigator.deviceMemory unavailable: wasm32 prover (conservative)"
        : `memory64 validated but only ${caps.deviceMemoryGiB} GiB reported: wasm32 prover`,
    );
  } else {
    proverProfile = "wasm32";
    reasons.push("memory64 not supported by this engine: wasm32 prover");
  }

  // S3 §7.4: sim Worker + main thread keep a core each.
  const proverWorkers = Math.max(1, (caps.hardwareConcurrency || 2) - 2);

  return { snapshotTransport, proverProfile, proverWorkers, reasons };
}
