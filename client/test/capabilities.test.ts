import { describe, expect, it } from "vitest";
import {
  chooseProfile,
  probeWasmFeatures,
  type Capabilities,
} from "../src/caps/capabilities.js";

/** A probe result with everything off; each test turns on only what it needs. */
function baseline(overrides: Partial<Capabilities> = {}): Capabilities {
  return {
    webAssembly: true,
    wasm: { memory64: false, simd: false, threads: false, bulkMemory: true, exceptions: false },
    crossOriginIsolated: false,
    sharedArrayBuffer: false,
    atomics: true,
    deviceMemoryGiB: null,
    hardwareConcurrency: 8,
    jsHeapSizeLimitBytes: null,
    webgl2: {
      available: true,
      maxTextureSize: 16384,
      maxTextureImageUnits: 16,
      maxVertexTextureImageUnits: 16,
      renderer: "test",
      softwareRasterizer: false,
    },
    storageQuotaBytes: null,
    userAgent: "test",
    ...overrides,
  };
}

describe("wasm feature probes", () => {
  it("detects Memory64 on an engine that supports it", () => {
    // Node 22 implements every proposal probed here, so a `false` would mean
    // the hand-assembled module bytes are wrong, not that the engine is old.
    const features = probeWasmFeatures();
    expect(features.memory64).toBe(true);
    expect(features.simd).toBe(true);
    expect(features.threads).toBe(true);
    expect(features.bulkMemory).toBe(true);
    expect(features.exceptions).toBe(true);
  });

  it("never throws, whatever WebAssembly is", () => {
    const original = globalThis.WebAssembly;
    try {
      // @ts-expect-error deliberately breaking the global for the test
      delete globalThis.WebAssembly;
      expect(probeWasmFeatures()).toEqual({
        memory64: false,
        simd: false,
        threads: false,
        bulkMemory: false,
        exceptions: false,
      });
    } finally {
      globalThis.WebAssembly = original;
    }
  });
});

describe("chooseProfile (the P2.7 toggle)", () => {
  it("uses the shared ring only when isolation, SAB and Atomics are all present", () => {
    expect(
      chooseProfile(baseline({ crossOriginIsolated: true, sharedArrayBuffer: true })).snapshotTransport,
    ).toBe("shared");
    expect(
      chooseProfile(baseline({ crossOriginIsolated: false, sharedArrayBuffer: true })).snapshotTransport,
    ).toBe("copied");
    expect(
      chooseProfile(baseline({ crossOriginIsolated: true, sharedArrayBuffer: false })).snapshotTransport,
    ).toBe("copied");
    expect(
      chooseProfile(baseline({ crossOriginIsolated: true, sharedArrayBuffer: true, atomics: false }))
        .snapshotTransport,
    ).toBe("copied");
  });

  it("explains which of the two conditions failed", () => {
    const noHeaders = chooseProfile(baseline({ sharedArrayBuffer: true }));
    expect(noHeaders.reasons.join(" ")).toMatch(/COOP\/COEP/);
    const noSab = chooseProfile(baseline({ crossOriginIsolated: true }));
    expect(noSab.reasons.join(" ")).toMatch(/SharedArrayBuffer unavailable/);
  });

  it("picks the wasm64 prover only with memory64 and >= 8 GiB reported", () => {
    const wasm = { memory64: true, simd: true, threads: true, bulkMemory: true, exceptions: true };
    expect(chooseProfile(baseline({ wasm, deviceMemoryGiB: 8 })).proverProfile).toBe("wasm64");
    expect(chooseProfile(baseline({ wasm, deviceMemoryGiB: 4 })).proverProfile).toBe("wasm32");
    // Firefox and Safari do not implement navigator.deviceMemory: be conservative.
    expect(chooseProfile(baseline({ wasm, deviceMemoryGiB: null })).proverProfile).toBe("wasm32");
    expect(chooseProfile(baseline({ deviceMemoryGiB: 16 })).proverProfile).toBe("wasm32");
  });

  it("falls back to remote proving without WebAssembly at all", () => {
    const profile = chooseProfile(baseline({ webAssembly: false }));
    expect(profile.proverProfile).toBe("remote-only");
    expect(profile.reasons.join(" ")).toMatch(/remote prover/);
  });

  it("leaves two cores for the main thread and the sim Worker (S3 §7.4)", () => {
    expect(chooseProfile(baseline({ hardwareConcurrency: 12 })).proverWorkers).toBe(10);
    expect(chooseProfile(baseline({ hardwareConcurrency: 2 })).proverWorkers).toBe(1);
    expect(chooseProfile(baseline({ hardwareConcurrency: 1 })).proverWorkers).toBe(1);
    expect(chooseProfile(baseline({ hardwareConcurrency: 0 })).proverWorkers).toBe(1);
  });
});
