// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0

//! Wire types (what the TypeScript client in `client-ts/` mirrors) and internal states.

use serde::{Deserialize, Serialize};

/// Which hash the leaf simple bootloader uses to compute the task's program hash
/// (`output_preimage[0]`).
///
/// `blake` is what S4 measured; **`poseidon` is the production choice** (G0 D4, S4b measurement 2:
/// the bootloader overhead drops from `2340 + 14.75 x words` to `1969 + 5.50 x words` steps, i.e.
/// -294 k steps on a 31.8 k-word program, with the `doom` registry unchanged). The two produce
/// different program hashes, so this is part of a leaf's identity.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum HashFunction {
    #[default]
    Blake,
    Poseidon,
}

impl HashFunction {
    pub fn as_str(self) -> &'static str {
        match self {
            HashFunction::Blake => "blake",
            HashFunction::Poseidon => "poseidon",
        }
    }
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "blake" => Some(HashFunction::Blake),
            "poseidon" => Some(HashFunction::Poseidon),
            _ => None,
        }
    }
}

/// How a segment proof was encoded by the client.
///
/// `Bincode` is the only form the Rust verifier can read: `CairoProof` derives `CairoSerialize`
/// but **not** `CairoDeserialize`, and the monorepo's own loader panics with "Deserialization
/// from a Cairo-serialized proof is not supported" (`cairo_air::utils`, `cd7bc5f`). A felt stream
/// is therefore accepted for the record (and for on-chain reuse) but cannot be verified; with
/// `require_verifiable_proof = true` (the default) such a submission is rejected.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProofFormat {
    /// Base64 of the bincode-serialized extended `CairoProof` (`prover/wasm`'s `prove` output).
    BincodeB64,
    /// The cairo-serde felt stream (`proof_to_felts`): JSON array of hex felt strings.
    CairoSerdeFelts,
}

impl ProofFormat {
    pub fn as_str(self) -> &'static str {
        match self {
            ProofFormat::BincodeB64 => "bincode_b64",
            ProofFormat::CairoSerdeFelts => "cairo_serde_felts",
        }
    }
    pub fn verifiable(self) -> bool {
        matches!(self, ProofFormat::BincodeB64)
    }
}

/// One segment proof as submitted.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SegmentSubmission {
    /// Position of the segment in the game, 0-based and contiguous. Also the fold order.
    pub index: u32,
    /// The segment program's user arguments, as felts (hex `0x…` or decimal strings).
    ///
    /// Required only with `leaf_mode = "rerun"`, where the server replays the segment from them.
    /// With the default `"from_proof"` the submitted proof is what gets folded, so they are
    /// optional — send them and they are recorded (and still part of the leaf cache key in
    /// `"rerun"`), omit them and nothing is lost.
    #[serde(default)]
    pub args: Vec<String>,
    /// `[task_program_hash, task_output…]` — what the leaf simple bootloader dumps
    /// (`output_preimage_dump_path`). The tree hashes this into the leaf's public output.
    pub output_preimage: Vec<String>,
    /// The two bootloader output cells (the 256-bit digest, 128 bits per cell), as felts.
    /// Optional: the wrapper recomputes them from `output_preimage` and, when the proof is
    /// verifiable, compares with the proof's own public output.
    #[serde(default)]
    pub public_outputs: Vec<String>,
    pub proof: ProofBlob,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProofBlob {
    pub format: ProofFormat,
    /// Base64 string for `bincode_b64`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub data: Option<String>,
    /// Felt array for `cairo_serde_felts`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub felts: Option<Vec<String>>,
}

/// `POST /v1/runs` body: one game.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RunSubmission {
    /// Client-chosen id, used for idempotency. Omitted = the server allocates one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub run_id: Option<String>,
    /// The player this run belongs to (Starknet account address). Informational for now; it
    /// becomes the signer once Controller session auth replaces the API key.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub player: Option<String>,
    /// Program id from the wrapper's pinned program list (clients never upload code).
    pub program: String,
    /// Which hash the browser ran the bootloader task with. Omitted = the program's configured
    /// default. It has to match, because it decides `output_preimage[0]`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub program_hash_function: Option<HashFunction>,
    /// Wrap this run on its own, immediately, instead of waiting for the batch (D6: the
    /// "submit alone now" option, at the displayed cost).
    #[serde(default)]
    pub solo: bool,
    pub segments: Vec<SegmentSubmission>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RunStatus {
    /// Accepted, segment proofs being verified (seconds).
    Verifying,
    /// A segment proof was rejected, or validation failed. Terminal.
    Rejected,
    /// Verified, leaves queued/proving, waiting for its batch to close.
    Queued,
    /// The batch is closed and folding.
    Wrapping,
    /// The batch produced a root proof. Terminal.
    Done,
    /// The pipeline failed. Terminal.
    Failed,
}

impl RunStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            RunStatus::Verifying => "verifying",
            RunStatus::Rejected => "rejected",
            RunStatus::Queued => "queued",
            RunStatus::Wrapping => "wrapping",
            RunStatus::Done => "done",
            RunStatus::Failed => "failed",
        }
    }
    pub fn parse(s: &str) -> Self {
        match s {
            "verifying" => RunStatus::Verifying,
            "rejected" => RunStatus::Rejected,
            "wrapping" => RunStatus::Wrapping,
            "done" => RunStatus::Done,
            "failed" => RunStatus::Failed,
            _ => RunStatus::Queued,
        }
    }
    pub fn terminal(self) -> bool {
        matches!(
            self,
            RunStatus::Rejected | RunStatus::Done | RunStatus::Failed
        )
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BatchStatus {
    /// Accepting runs (D6: until M runs or T minutes).
    Open,
    /// Closed, waiting for every leaf of every member run.
    Closed,
    /// The recursive tree is running.
    Folding,
    Done,
    Failed,
}

impl BatchStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            BatchStatus::Open => "open",
            BatchStatus::Closed => "closed",
            BatchStatus::Folding => "folding",
            BatchStatus::Done => "done",
            BatchStatus::Failed => "failed",
        }
    }
    pub fn parse(s: &str) -> Self {
        match s {
            "open" => BatchStatus::Open,
            "folding" => BatchStatus::Folding,
            "done" => BatchStatus::Done,
            "failed" => BatchStatus::Failed,
            _ => BatchStatus::Closed,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum JobKind {
    /// Verify one submitted segment proof with the Rust verifier (R8-A1). Cheap.
    Verify,
    /// Prove one leaf circuit (`leaf-prover`). 22 s / 32.5 GB (S4).
    Leaf,
    /// Fold a closed batch's leaves (`stwo_run_and_prove_recursive_tree`). ~30 s per reduction.
    Fold,
}

impl JobKind {
    pub fn as_str(self) -> &'static str {
        match self {
            JobKind::Verify => "verify",
            JobKind::Leaf => "leaf",
            JobKind::Fold => "fold",
        }
    }
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "verify" => Some(JobKind::Verify),
            "leaf" => Some(JobKind::Leaf),
            "fold" => Some(JobKind::Fold),
            _ => None,
        }
    }
    /// Whether this job needs a 32.5 GB circuit-proof slot.
    pub fn is_circuit_proof(self) -> bool {
        matches!(self, JobKind::Leaf | JobKind::Fold)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum JobState {
    Queued,
    Running,
    Done,
    Failed,
}

impl JobState {
    pub fn as_str(self) -> &'static str {
        match self {
            JobState::Queued => "queued",
            JobState::Running => "running",
            JobState::Done => "done",
            JobState::Failed => "failed",
        }
    }
}

/// A queued unit of work as the scheduler sees it.
#[derive(Debug, Clone)]
pub struct Job {
    pub id: i64,
    pub kind: JobKind,
    pub run_id: Option<String>,
    pub seg_index: Option<u32>,
    pub batch_id: Option<String>,
    pub attempts: u32,
}

// ---- responses -----------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SubmitResponse {
    pub run_id: String,
    pub status: String,
    pub segments: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub batch_id: Option<String>,
    /// True when this run was deduplicated onto an existing one (same `run_id` and content).
    #[serde(default)]
    pub duplicate: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SegmentStatus {
    pub index: u32,
    pub leaf_key: String,
    pub verified: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub verify_ms: Option<f64>,
    /// `queued` | `running` | `done` | `failed` | `cached`
    pub leaf_state: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub leaf_ms: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub leaf_max_rss_bytes: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cached: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RunStatusResponse {
    pub run_id: String,
    pub status: String,
    pub program: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub player: Option<String>,
    pub solo: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub batch_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub batch_status: Option<String>,
    pub created_at_ms: i64,
    pub updated_at_ms: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    pub progress: Progress,
    pub segments: Vec<SegmentStatus>,
    pub timings: Timings,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Progress {
    pub segments: usize,
    pub verified: usize,
    pub leaves_done: usize,
    /// Leaves served from the content-hash cache instead of being proven again.
    pub leaves_cached: usize,
}

/// Per-stage wall times, in milliseconds.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Timings {
    pub verify_ms_total: f64,
    pub leaf_ms_total: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fold_ms: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub queued_ms: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub total_ms: Option<f64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BatchLeafRef {
    /// Position in the fold order (left to right).
    pub position: u32,
    pub run_id: String,
    pub segment_index: u32,
    pub leaf_key: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BatchResponse {
    pub batch_id: String,
    pub status: String,
    pub runs: Vec<String>,
    pub leaves: Vec<BatchLeafRef>,
    pub created_at_ms: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub closed_at_ms: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub finished_at_ms: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fold_ms: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fold_max_rss_bytes: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    /// The root proof as the felt stream the Cairo circuit verifier consumes
    /// (`--arguments-file`). ~94 k felts (S4). Omitted unless `?include=proof`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub root_proof_felts: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub root_proof_felt_count: Option<usize>,
    /// The root node's eight raw output words.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub program_output: Option<serde_json::Value>,
    /// The digest tree (`Composite`/`Plain`) the consumer recomposes on-chain.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub packed_output: Option<serde_json::Value>,
}
