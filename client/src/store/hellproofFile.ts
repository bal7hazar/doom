/**
 * The `.hellproof` file — one run, in one file (roadmap **P2.5**, risk
 * **R6-A2**: "export `.doomrun` (journal + proofs) and import", and **R6-A3**'s
 * "prove later, possibly on another machine").
 *
 * A run is a small JSON manifest and 25–75 proofs of ~4.2 MB. Base64-ing the
 * proofs into the JSON would cost a third of the size and force the whole run
 * through one string; so the container is a header, the manifest, then the proof
 * bytes back to back, and the manifest says where each one starts:
 *
 * ```text
 *   0   "HELLPROOF"        9 bytes, ASCII
 *   9   u8  version        1
 *  10   u16 LE reserved    0
 *  12   u32 LE manifest length
 *  16   manifest, UTF-8 JSON
 *   …   proof payloads, in manifest order
 * ```
 *
 * The manifest carries the whole `RunRecord`, the packed journal and every
 * `SegmentRecord`, so an import restores a run that is indistinguishable from
 * one proved locally — including the segment boundaries, which cannot be
 * recomputed (the planner's decisions depend on the machine it ran on).
 */
import type { RunRecord, SegmentRecord } from "../prove/types.js";
import type { InputRecord, RunStore } from "./runStore.js";

export const HELLPROOF_MAGIC = "HELLPROOF";
export const HELLPROOF_FILE_VERSION = 1;
const HEADER_BYTES = 16;

export interface ProofIndexEntry {
  index: number;
  /** Offset from the start of the payload region. */
  offset: number;
  length: number;
  /** Lower-case hex SHA-256 of the bytes, when the environment could compute one. */
  sha256?: string;
}

export interface HellproofManifest {
  format: "hellproof";
  version: number;
  exportedAt: number;
  /** Free-form producer string, for support. */
  producer: string;
  run: RunRecord;
  inputs: InputRecord;
  segments: SegmentRecord[];
  proofs: ProofIndexEntry[];
}

export interface ExportOptions {
  /** Compute a SHA-256 per proof (default: yes when WebCrypto is available). */
  checksums?: boolean;
  producer?: string;
}

async function sha256Hex(bytes: Uint8Array): Promise<string | undefined> {
  const subtle = globalThis.crypto?.subtle;
  if (!subtle) return undefined;
  const view = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
  const digest = new Uint8Array(await subtle.digest("SHA-256", view));
  return Array.from(digest, (b) => b.toString(16).padStart(2, "0")).join("");
}

/** Serialises one run — journal, boundaries, proofs, submission state — to bytes. */
export async function exportRun(
  store: RunStore,
  runId: string,
  options: ExportOptions = {},
): Promise<Uint8Array<ArrayBuffer>> {
  const run = await store.getRun(runId);
  if (!run) throw new Error(`no such run: ${runId}`);
  const segments = await store.listSegments(runId);
  const inputs = await store.getInputs(runId);
  const wantChecksums = options.checksums ?? true;

  const payloads: Uint8Array[] = [];
  const index: ProofIndexEntry[] = [];
  let offset = 0;
  for (const segment of segments) {
    const proof = await store.getProof(runId, segment.index);
    if (!proof) continue;
    const checksum = wantChecksums ? await sha256Hex(proof) : undefined;
    index.push({
      index: segment.index,
      offset,
      length: proof.byteLength,
      ...(checksum ? { sha256: checksum } : {}),
    });
    payloads.push(proof);
    offset += proof.byteLength;
  }

  const manifest: HellproofManifest = {
    format: "hellproof",
    version: HELLPROOF_FILE_VERSION,
    exportedAt: Date.now(),
    producer: options.producer ?? "@hellproof/client",
    run,
    inputs,
    segments,
    proofs: index,
  };
  const manifestBytes = new TextEncoder().encode(JSON.stringify(manifest));

  const total = HEADER_BYTES + manifestBytes.byteLength + offset;
  const out = new Uint8Array(new ArrayBuffer(total));
  const view = new DataView(out.buffer);
  for (let i = 0; i < HELLPROOF_MAGIC.length; i++) out[i] = HELLPROOF_MAGIC.charCodeAt(i);
  view.setUint8(9, HELLPROOF_FILE_VERSION);
  view.setUint16(10, 0, true);
  view.setUint32(12, manifestBytes.byteLength, true);
  out.set(manifestBytes, HEADER_BYTES);
  let cursor = HEADER_BYTES + manifestBytes.byteLength;
  for (const payload of payloads) {
    out.set(payload, cursor);
    cursor += payload.byteLength;
  }
  return out;
}

/** A `Blob` the page can hand to a download link. */
export async function exportRunBlob(
  store: RunStore,
  runId: string,
  options: ExportOptions = {},
): Promise<Blob> {
  return new Blob([await exportRun(store, runId, options)], { type: "application/octet-stream" });
}

/** A name a player can recognise six months later. */
export function exportFileName(run: RunRecord): string {
  const stamp = new Date(run.createdAt).toISOString().replace(/[:.]/g, "-").slice(0, 19);
  return `${run.program}-${stamp}-${run.id.slice(0, 8)}.hellproof`;
}

export interface ParsedHellproofFile {
  manifest: HellproofManifest;
  /** Proof bytes by segment index, as views into the file. */
  proofs: Map<number, Uint8Array>;
}

/** Reads a `.hellproof` container without touching the database. */
export function parseHellproofFile(data: ArrayBuffer | Uint8Array): ParsedHellproofFile {
  const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);
  if (bytes.byteLength < HEADER_BYTES) throw new Error("not a .hellproof file: too short");
  for (let i = 0; i < HELLPROOF_MAGIC.length; i++) {
    if (bytes[i] !== HELLPROOF_MAGIC.charCodeAt(i)) throw new Error("not a .hellproof file: bad magic");
  }
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const version = view.getUint8(9);
  if (version !== HELLPROOF_FILE_VERSION) {
    throw new Error(`unsupported .hellproof version ${version} (this client reads ${HELLPROOF_FILE_VERSION})`);
  }
  const manifestLength = view.getUint32(12, true);
  const manifestEnd = HEADER_BYTES + manifestLength;
  if (manifestEnd > bytes.byteLength) throw new Error("truncated .hellproof file: manifest overruns it");
  const manifest = JSON.parse(
    new TextDecoder().decode(bytes.subarray(HEADER_BYTES, manifestEnd)),
  ) as HellproofManifest;
  if (manifest.format !== "hellproof") throw new Error("not a .hellproof manifest");

  const proofs = new Map<number, Uint8Array>();
  for (const entry of manifest.proofs) {
    const start = manifestEnd + entry.offset;
    const end = start + entry.length;
    if (end > bytes.byteLength) {
      throw new Error(`truncated .hellproof file: proof ${entry.index} overruns it`);
    }
    proofs.set(entry.index, bytes.subarray(start, end));
  }
  return { manifest, proofs };
}

export interface ImportOptions {
  /** Give the imported run a new id instead of failing when one already exists. */
  renameOnConflict?: boolean;
  /** Verify the manifest's SHA-256 for every proof that carries one. */
  verifyChecksums?: boolean;
}

export interface ImportResult {
  runId: string;
  segments: number;
  proofs: number;
  /** True when the run was given a new id because the original was taken. */
  renamed: boolean;
}

/** Writes a parsed container into the local database. */
export async function importRun(
  store: RunStore,
  data: ArrayBuffer | Uint8Array,
  options: ImportOptions = {},
): Promise<ImportResult> {
  const { manifest, proofs } = parseHellproofFile(data);
  if (options.verifyChecksums ?? true) {
    for (const entry of manifest.proofs) {
      if (!entry.sha256) continue;
      const bytes = proofs.get(entry.index);
      if (!bytes) throw new Error(`proof ${entry.index} is listed but absent`);
      const actual = await sha256Hex(bytes);
      if (actual && actual !== entry.sha256) {
        throw new Error(`proof ${entry.index} does not match its checksum: the file is corrupt`);
      }
    }
  }

  let runId = manifest.run.id;
  let renamed = false;
  if (await store.getRun(runId)) {
    if (!(options.renameOnConflict ?? true)) throw new Error(`run ${runId} already exists locally`);
    runId = `${runId.slice(0, 24)}-i${Date.now().toString(36)}`;
    renamed = true;
  }

  const run: RunRecord = { ...manifest.run, id: runId, updatedAt: Date.now() };
  const inputs: InputRecord = { ...manifest.inputs, runId };
  const segments = manifest.segments.map((s) => ({ ...s, runId }));

  await store.importRun(run, inputs, segments, proofs);
  return { runId, segments: segments.length, proofs: proofs.size, renamed };
}
