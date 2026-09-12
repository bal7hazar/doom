import type { Capabilities, RuntimeProfile } from "../caps/capabilities.js";

/** Formats the capability probe + chosen runtime profile as the F1 panel (roadmap P2.7). */
export function renderDiagnostics(
  el: HTMLElement,
  caps: Capabilities,
  profile: RuntimeProfile,
  extra: Record<string, string> = {},
): void {
  const rows: [string, string, boolean | null][] = [
    ["COOP/COEP isolated", yesNo(caps.crossOriginIsolated), caps.crossOriginIsolated],
    ["SharedArrayBuffer", yesNo(caps.sharedArrayBuffer), caps.sharedArrayBuffer],
    ["Atomics", yesNo(caps.atomics), caps.atomics],
    ["WebAssembly", yesNo(caps.webAssembly), caps.webAssembly],
    ["· memory64", yesNo(caps.wasm.memory64), caps.wasm.memory64],
    ["· simd128", yesNo(caps.wasm.simd), caps.wasm.simd],
    ["· threads", yesNo(caps.wasm.threads), caps.wasm.threads],
    ["· bulk-memory", yesNo(caps.wasm.bulkMemory), caps.wasm.bulkMemory],
    ["· exceptions", yesNo(caps.wasm.exceptions), caps.wasm.exceptions],
    [
      "navigator.deviceMemory",
      caps.deviceMemoryGiB === null ? "unavailable (Firefox/Safari)" : `${caps.deviceMemoryGiB} GiB reported`,
      caps.deviceMemoryGiB === null ? null : caps.deviceMemoryGiB >= 8,
    ],
    ["hardwareConcurrency", `${caps.hardwareConcurrency} logical cores`, null],
    [
      "JS heap limit",
      caps.jsHeapSizeLimitBytes === null ? "unavailable" : gib(caps.jsHeapSizeLimitBytes),
      null,
    ],
    ["storage quota", caps.storageQuotaBytes === null ? "unavailable" : gib(caps.storageQuotaBytes), null],
    ["WebGL2", yesNo(caps.webgl2.available), caps.webgl2.available],
    ["· renderer", caps.webgl2.renderer ?? "unknown", !caps.webgl2.softwareRasterizer],
    ["· MAX_TEXTURE_SIZE", String(caps.webgl2.maxTextureSize), null],
    ["· vertex texture units", String(caps.webgl2.maxVertexTextureImageUnits), caps.webgl2.maxVertexTextureImageUnits > 0],
  ];

  const profileRows: [string, string, boolean | null][] = [
    ["snapshot transport", profile.snapshotTransport, profile.snapshotTransport === "shared"],
    ["prover profile", profile.proverProfile, profile.proverProfile !== "remote-only"],
    ["prover workers", String(profile.proverWorkers), null],
    ...Object.entries(extra).map(([k, v]) => [k, v, null] as [string, string, null]),
  ];

  el.innerHTML =
    `<h2>Capabilities</h2>${table(rows)}` +
    `<h2 style="margin-top:12px">Runtime profile</h2>${table(profileRows)}` +
    `<p class="note">${profile.reasons.map(escapeHtml).join("<br>")}</p>` +
    `<p class="note">${escapeHtml(caps.userAgent)}</p>`;
}

function table(rows: [string, string, boolean | null][]): string {
  return (
    "<table>" +
    rows
      .map(
        ([k, v, ok]) =>
          `<tr><td>${escapeHtml(k)}</td><td class="${ok === null ? "" : ok ? "yes" : "no"}">${escapeHtml(v)}</td></tr>`,
      )
      .join("") +
    "</table>"
  );
}

function yesNo(v: boolean): string {
  return v ? "yes" : "no";
}

function gib(bytes: number): string {
  return `${(bytes / 1024 ** 3).toFixed(2)} GiB`;
}

function escapeHtml(s: string): string {
  return s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]!);
}
