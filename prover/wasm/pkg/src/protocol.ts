/** Message protocol between the main thread ({@link ../index}) and the prover Worker. */
import type {
  ExecutionStats,
  Felt,
  InitOptions,
  ProofStats,
  ProverEvent,
  ProverInfo,
  ProverParams,
  ResourceSummary,
} from "./types.js";

export type Request =
  | { id: number; op: "init"; opts: InitOptions }
  | { id: number; op: "execute"; executable: string; args: Felt[] | string }
  | { id: number; op: "prove"; input: Uint8Array; params?: ProverParams | string }
  | { id: number; op: "verify"; proof: Uint8Array; params?: ProverParams | string }
  | { id: number; op: "proofToFelts"; proof: Uint8Array; params?: ProverParams | string }
  | { id: number; op: "resources"; input: Uint8Array; params?: ProverParams | string }
  | { id: number; op: "defaultParams" }
  | { id: number; op: "terminate" };

export type Response =
  | { id: number; ok: true; op: "init"; info: ProverInfo }
  | { id: number; ok: true; op: "execute"; input: Uint8Array; stats: ExecutionStats; ms: number }
  | { id: number; ok: true; op: "prove"; proof: Uint8Array; stats: ProofStats; ms: number }
  | { id: number; ok: true; op: "verify"; valid: boolean }
  | { id: number; ok: true; op: "proofToFelts"; felts: Felt[] }
  | { id: number; ok: true; op: "resources"; summary: ResourceSummary }
  | { id: number; ok: true; op: "defaultParams"; params: ProverParams }
  | { id: number; ok: true; op: "terminate" }
  | { id: number; ok: false; error: string }
  | { id: -1; event: ProverEvent };

export function isEvent(m: Response): m is { id: -1; event: ProverEvent } {
  return (m as { event?: unknown }).event !== undefined;
}

/** `Omit` over a union keeps each member's own fields (plain `Omit` collapses them). */
export type DistributiveOmit<T, K extends PropertyKey> = T extends unknown ? Omit<T, K> : never;

/** A request without its correlation id — what the client hands to `send()`. */
export type RequestBody = DistributiveOmit<Request, "id">;
