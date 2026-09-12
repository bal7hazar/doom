/**
 * Storage quota (roadmap **P2.5**, risk **R6-A2**).
 *
 * A segment proof is ~4.2 MB of bincode and a 3-minute game is 25–75 of them,
 * so a run is 100–300 MB — well inside a desktop Chrome origin quota (a large
 * fraction of free disk), but *not* inside the ~10 MB some browsers grant an
 * origin whose storage is not persisted, and not inside anything if the disk is
 * nearly full. Two things follow, and both are here:
 *
 * - ask for `navigator.storage.persist()` **once**, before proving starts, so
 *   the origin's data is not evicted under pressure;
 * - project the run's footprint forward and warn while there is still room to
 *   export, rather than failing on a `QuotaExceededError` halfway through.
 */

/** Measured in P3.1: a leaf proof is 4.20 MB of bincode whatever the segment size. */
export const PROOF_BYTES_ESTIMATE = 4_200_000;

export interface StorageStatus {
  usageBytes: number | null;
  quotaBytes: number | null;
  /** `usage / quota`, or `null` when the browser does not report either. */
  ratio: number | null;
  persisted: boolean;
}

export interface QuotaWarning {
  warning: boolean;
  /** Bytes the pending work is expected to add. */
  projectedBytes: number;
  /** Free bytes after the projection, or `null` when the quota is unknown. */
  headroomBytes: number | null;
  message: string;
}

export interface QuotaOptions {
  /** Warn once the projected usage crosses this fraction of the quota. */
  warnRatio?: number;
  /** …or once the projected free space falls under this many bytes. */
  warnHeadroomBytes?: number;
  storage?: StorageManager;
}

export async function readStorageStatus(storage = globalThis.navigator?.storage): Promise<StorageStatus> {
  const status: StorageStatus = { usageBytes: null, quotaBytes: null, ratio: null, persisted: false };
  if (!storage) return status;
  try {
    const estimate = await storage.estimate?.();
    status.usageBytes = estimate?.usage ?? null;
    status.quotaBytes = estimate?.quota ?? null;
    if (status.usageBytes !== null && status.quotaBytes) {
      status.ratio = status.usageBytes / status.quotaBytes;
    }
  } catch {
    /* the estimate is best effort */
  }
  try {
    status.persisted = (await storage.persisted?.()) ?? false;
  } catch {
    status.persisted = false;
  }
  return status;
}

/**
 * Asks for persistent storage. Chrome grants it silently to an engaged origin
 * and refuses it silently otherwise, so the answer is a fact to display, never
 * a reason to stop.
 */
export async function requestPersistence(storage = globalThis.navigator?.storage): Promise<boolean> {
  if (!storage?.persist) return false;
  try {
    if (await storage.persisted?.()) return true;
    return await storage.persist();
  } catch {
    return false;
  }
}

/**
 * Would `pendingProofs` more proofs fit? The answer drives the "export this run
 * and free the space" prompt.
 */
export function projectQuota(
  status: StorageStatus,
  pendingProofs: number,
  options: QuotaOptions = {},
): QuotaWarning {
  const warnRatio = options.warnRatio ?? 0.85;
  const warnHeadroom = options.warnHeadroomBytes ?? 200 * 1024 * 1024;
  const projectedBytes = Math.max(0, pendingProofs) * PROOF_BYTES_ESTIMATE;

  if (status.quotaBytes === null || status.usageBytes === null) {
    return {
      warning: false,
      projectedBytes,
      headroomBytes: null,
      message: "this browser does not report a storage quota; proofs are written without a projection",
    };
  }
  const projectedUsage = status.usageBytes + projectedBytes;
  const headroomBytes = status.quotaBytes - projectedUsage;
  const ratio = projectedUsage / status.quotaBytes;
  const warning = ratio >= warnRatio || headroomBytes <= warnHeadroom;
  const message = warning
    ? `${pendingProofs} proof(s) left to store need ~${mib(projectedBytes)}; that would put this origin at ${Math.round(ratio * 100)} % of its ${mib(status.quotaBytes)} quota. Export the run (.hellproof) or reset it to free space.`
    : `~${mib(projectedBytes)} to store, ${mib(Math.max(0, headroomBytes))} would remain of ${mib(status.quotaBytes)}.`;
  return { warning, projectedBytes, headroomBytes, message };
}

function mib(bytes: number): string {
  if (bytes >= 1024 ** 3) return `${(bytes / 1024 ** 3).toFixed(1)} GiB`;
  return `${Math.round(bytes / 1024 ** 2)} MiB`;
}

/** True for the error a browser raises when the origin is out of quota. */
export function isQuotaExceeded(error: unknown): boolean {
  if (typeof DOMException !== "undefined" && error instanceof DOMException) {
    return error.name === "QuotaExceededError" || error.code === 22;
  }
  return error instanceof Error && /quota/i.test(error.message);
}
