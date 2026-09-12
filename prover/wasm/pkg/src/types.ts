/**
 * Public types of `@hellproof/prover-wasm`.
 *
 * Everything crossing the wasm boundary is plain JSON or `Uint8Array`; the proof and the prover
 * input are opaque bincode blobs (`ProverInput` / `Proof`) that only this package produces and
 * consumes — except {@link proofToFelts}, which returns the cairo-serde felt stream the Cairo
 * verifier and the recursion leaf take.
 */

/** Number of felts to size buffers with; see the README for the measured values. */
export type Felt = string;

/** A `ProverInput`, bincode-serialized by `execute()`. Opaque. */
export type ProverInput = Uint8Array;

/** An extended `CairoProof`, bincode-serialized by `prove()`. Opaque. */
export type Proof = Uint8Array;

/** FRI parameters (`stwo::core::fri::FriConfig`). */
export interface FriConfig {
  pow_bits: number;
  log_blowup_factor: number;
  log_last_layer_degree_bound: number;
  n_queries: number;
  /** 1 with the `doom` registry; 4 with the future `doom_fold4_min` one. */
  fold_step: number;
}

/**
 * `stwo_cairo_prover::prover::ProverParameters`. The defaults of this package are the recursion
 * leaf's (see README §Parameters); `prove_leaf` asserts `include_all_preprocessed_columns` and
 * `lifting_size_policy`, and always proves with the `blake2s_m31` channel.
 */
export interface ProverParams {
  channel_hash: "blake2s" | "blake2s_m31" | "poseidon252";
  channel_salt: number;
  preprocessed_trace: "canonical" | "canonical_small";
  fri_config: FriConfig;
  store_polynomials_coefficients: boolean;
  /** Must be `true` for the leaf circuit. */
  include_all_preprocessed_columns: boolean;
  opt_n_id_to_big_components: number | null;
  lifting_size_policy: "auto" | "at_least_preprocessed" | { fixed: number };
}

/** Statistics returned by {@link Prover.execute}. */
export interface ExecutionStats {
  /** VM steps of the whole run (leaf bootloader included). */
  n_steps: number;
  /** Builtin instance counters reported by cairo-vm, `[name, count]`. */
  builtins: [string, number][];
  /** Bootloader output cells (hex felts): the 256-bit blake2s digest in two 128-bit cells. */
  output: Felt[];
  /** Preimage of that digest: `[program_hash, task_output…]` (hex felts). */
  output_preimage: Felt[];
  /** Size of the bincode `ProverInput`. */
  prover_input_bytes: number;
}

/** Statistics returned by {@link Prover.prove}. */
export interface ProofStats {
  proof_bytes: number;
  /** Number of felt252 of the cairo-serde encoding — what {@link Prover.proofToFelts} returns. */
  proof_felts: number;
  trace_lifting_log_size: number;
  preprocessed_lifting_log_size: number;
  /** `trace_lifting_log_size - log_blowup_factor`: the size the leaf registry is keyed on (20). */
  trace_log_size: number;
  /** Largest base-trace component, log2 rows — must stay ≤ 20; exact counterpart of
   * {@link ResourceSummary.log_max_component_size}. */
  max_trace_component_log_size: number;
  /** Max over every tree, preprocessed included: always 20 with `canonical_small`. */
  max_log_size: number;
  /** Log size of every base-trace component, descending. */
  component_log_sizes: number[];
}

/**
 * What {@link Prover.resources} returns: everything the client needs to decide whether one more
 * tic fits in the current segment, computed from the adapter's counters without generating a
 * trace.
 */
export interface ResourceSummary {
  n_steps: number;
  opcodes: [string, number][];
  builtins: [string, number][];
  unique_aggregator_inputs: [string, number][];
  memory_address_to_id: number;
  memory_id_to_big: number;
  memory_id_to_small: number;
  verify_instruction: number;
  max_component_rows: number;
  max_component: string;
  /** `ceil(log2(max_component_rows))`; compare with {@link ProofStats.max_log_size}. */
  log_max_component_size: number;
  /** `log_max_component_size <= 20`. */
  fits_leaf_registry: boolean;
}

/** Progress/telemetry event emitted while a call runs. */
export type ProverEvent =
  | { type: "stage"; stage: StageName; phase: "start" | "end"; ms?: number; memoryBytes: number }
  | { type: "span"; stage: StageName; name: string; ms: number; memoryBytes: number }
  | { type: "log"; level: "error" | "warn" | "info" | "debug"; message: string };

export type StageName = "execute" | "prove" | "verify" | "proof_to_felts" | "resources";

/** Options of {@link createProver} / {@link ProverCore.init}. */
export interface InitOptions {
  /**
   * Number of rayon worker threads. `"auto"` = `hardwareConcurrency - 2` clamped to `[1, 8]`
   * (R6-A1: leave room for the game loop), `1` = no pool. Ignored — with a warning — when the
   * page is not cross-origin isolated, where only the single-threaded artifact can run.
   */
  threads?: number | "auto";
  /** URL of the single-threaded artifact. Defaults to `../wasm/hellproof_prover_wasm.wasm`. */
  wasmUrl?: string | URL;
  /** URL of the threaded artifact. Defaults to `../wasm/hellproof_prover_wasm.threads.wasm`. */
  threadedWasmUrl?: string | URL;
  /** Initial linear memory, in wasm pages of 64 KiB (threaded build only). Default 512 (32 MiB). */
  initialPages?: number;
  /** Maximum linear memory, in pages. Default 262144 (16 GiB, V8's Memory64 cap). */
  maximumPages?: number;
  /** Shadow stack of each worker thread, in bytes. Default 16 MiB (the main thread's). */
  threadStackBytes?: number;
}

/** What {@link Prover.init} reports back. */
export interface ProverInfo {
  /** Threads rayon will actually use (1 = single-threaded fallback). */
  threads: number;
  /** Whether the threaded artifact was loaded. */
  threaded: boolean;
  /** Whether the environment is cross-origin isolated (required for `SharedArrayBuffer`). */
  crossOriginIsolated: boolean;
  /** Artifact actually loaded. */
  wasmUrl: string;
  instantiateMs: number;
  memoryBytes: number;
}
