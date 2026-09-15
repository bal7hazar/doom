// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0
import { describe, expect, it } from "vitest";
import { checkSimulationSupport, currentEnvironment, describeSimulationFailure } from "../src/sim/simulationSupport.js";

const fine = { worker: true, webAssembly: true, secureContext: true, subtleCrypto: true };

describe("simulation support", () => {
  it("reads the environment without throwing on a bare global", () => {
    expect(currentEnvironment({} as typeof globalThis)).toEqual({ worker: false, webAssembly: false, secureContext: true, subtleCrypto: false });
    expect(currentEnvironment({ Worker: class {}, WebAssembly: {}, isSecureContext: true, crypto: { subtle: {} } } as unknown as typeof globalThis))
      .toEqual(fine);
  });

  it("accepts a browser with Workers, wasm and a secure context, and needs nothing else", () => {
    expect(checkSimulationSupport(fine)).toEqual({ ok: true, reasons: [] });
  });

  it("explains an insecure LAN address, missing Workers and missing wasm", () => {
    const lan = checkSimulationSupport({ ...fine, secureContext: false, subtleCrypto: false });
    expect(lan.ok).toBe(false);
    expect(lan.reasons).toHaveLength(1);
    expect(lan.reasons[0]).toMatch(/https:\/\//);
    expect(lan.reasons[0]).toMatch(/localhost/);
    const nothing = checkSimulationSupport({ worker: false, webAssembly: false, secureContext: true, subtleCrypto: true });
    expect(nothing.reasons).toHaveLength(2);
    expect(nothing.reasons[0]).toMatch(/Web Workers/);
    expect(nothing.reasons[1]).toMatch(/WebAssembly/);
  });

  it("maps the Worker's failures onto what to do", () => {
    expect(describeSimulationFailure(new Error("/sim/manifest.json: HTTP 404; stage scripts/prepare-sim.py first"))).toMatch(/public\/sim\/ is missing.*\?sim=demo/);
    expect(describeSimulationFailure(new Error("execution: /sim/session.json: HTTP 500"))).toMatch(/could not be fetched \(\/sim\/session\.json: HTTP 500\)/);
    // `vite preview` answers a missing manifest with index.html (SPA fallback), which cairoBackend now names.
    expect(describeSimulationFailure(new Error("manifest.json is not JSON (an HTML page came back): public/sim/ is not staged; run scripts/prepare-sim.py first"))).toMatch(/public\/sim\/ is missing/);
    expect(describeSimulationFailure(new SyntaxError("Unexpected token '<', \"<!doctype \"... is not valid JSON"))).toMatch(/public\/sim\/ is missing/);
    expect(describeSimulationFailure(new Error("artifact SHA256 mismatch: hellproof_sim_bg.wasm"))).toMatch(/do not match their manifest/);
    expect(describeSimulationFailure(new Error("Cannot read properties of undefined (reading 'digest')"))).toMatch(/secure context/);
    expect(describeSimulationFailure(new RangeError("WebAssembly.Memory(): could not allocate memory"))).toMatch(/450 MiB/);
    expect(describeSimulationFailure(new Error(""))).toMatch(/failed to load\. This browser may not support module Workers/);
    expect(describeSimulationFailure(new Error("Failed to fetch dynamically imported module: http://x/sim/hellproof_sim.js"))).toMatch(/failed to load \(Failed to fetch/);
    expect(describeSimulationFailure(new Error("Cairo rejected the initial state"))).toBe("The Cairo simulation could not start: Cairo rejected the initial state");
    expect(describeSimulationFailure(undefined)).toMatch(/failed to load/);
  });
});
