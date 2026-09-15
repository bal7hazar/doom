// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * What the *game* needs from a browser, and how to say what is missing.
 *
 * The Cairo simulation runs in one module Worker over a wasm32 cairo-vm; it
 * needs no SharedArrayBuffer, no cross-origin isolation and no Memory64
 * (`CairoClient`'s ring is a plain ArrayBuffer, frames are transferred). Those
 * are the browser prover's requirements, and D35 keeps the prover off phones.
 * What the Worker does need, and what a phone browsing a LAN address lacks, is
 * a **secure context**: `cairoBackend.ts` verifies the artifacts' SHA-256 with
 * WebCrypto, which browsers expose only on https:// and localhost.
 *
 * Both functions are pure over their inputs so they can be unit-tested; the
 * messages are the ones the loading panel shows.
 */

export interface SupportEnvironment {
  worker: boolean;
  webAssembly: boolean;
  secureContext: boolean;
  subtleCrypto: boolean;
}

export function currentEnvironment(g: typeof globalThis = globalThis): SupportEnvironment {
  const crypto = (g as { crypto?: { subtle?: unknown } }).crypto;
  return {
    worker: typeof (g as { Worker?: unknown }).Worker === "function",
    webAssembly: typeof (g as { WebAssembly?: unknown }).WebAssembly === "object",
    secureContext: (g as { isSecureContext?: boolean }).isSecureContext !== false,
    subtleCrypto: typeof crypto?.subtle === "object" && crypto.subtle !== null,
  };
}

export interface SimulationSupport {
  ok: boolean;
  reasons: string[];
}

/** Checked before the Worker is created, so the failure is one sentence rather than a stack. */
export function checkSimulationSupport(env: SupportEnvironment = currentEnvironment()): SimulationSupport {
  const reasons: string[] = [];
  if (!env.worker) reasons.push("This browser has no Web Workers; the Cairo simulation runs in one.");
  if (!env.webAssembly) reasons.push("This browser has no WebAssembly; the Cairo VM is a wasm module.");
  if (!env.secureContext || !env.subtleCrypto) {
    reasons.push(
      "This page is not a secure context (a plain http:// address that is not localhost), so the browser hides WebCrypto and the Worker cannot verify the Cairo artifacts. " +
      "Open the game over https://, or on a phone forward the port so it is http://localhost (Android: chrome://inspect, Port forwarding).",
    );
  }
  return { ok: reasons.length === 0, reasons };
}

/** Turns the Worker's failure into what to do about it. */
export function describeSimulationFailure(error: unknown): string {
  const message = error instanceof Error ? error.message : String(error ?? "");
  const detail = message.replace(/^execution: /, "");
  if (/manifest\.json.*(HTTP 404|not JSON)|prepare-sim|is not valid JSON|<!doctype/i.test(detail)) {
    return "The Cairo simulation is not staged on this server: public/sim/ is missing. Run scripts/prepare-sim.py (see src/sim/README.md), or open the renderer demo with ?sim=demo, which needs no Worker.";
  }
  if (/HTTP \d{3}/.test(detail)) {
    return `A Cairo artifact could not be fetched (${detail}). Check the server's public/sim/ directory and that it sends same-origin resources under the COEP header.`;
  }
  if (/SHA256 mismatch|unsupported simulation manifest|invalid artifact/i.test(detail)) {
    return `The staged Cairo artifacts do not match their manifest (${detail}). Re-run scripts/prepare-sim.py so public/sim/ is consistent.`;
  }
  if (/crypto|subtle|digest/i.test(detail)) {
    return checkSimulationSupport({ worker: true, webAssembly: true, secureContext: false, subtleCrypto: false }).reasons[0]!;
  }
  if (/out of memory|could not allocate|memory access|WebAssembly\.Memory|RangeError|allocation failed/i.test(detail)) {
    return `This browser could not give the Worker the memory the Cairo VM needs (about 450 MiB of wasm linear memory): ${detail}. Close other tabs and apps, or use a device with more RAM.`;
  }
  if (detail === "" || /import|module|Unexpected token|Failed to fetch dynamically|Cannot use import/i.test(detail)) {
    return `The simulation Worker failed to load${detail ? ` (${detail})` : ""}. This browser may not support module Workers (Safari before 15, old Android WebViews), or the server blocked the script.`;
  }
  return `The Cairo simulation could not start: ${detail}`;
}
