//! Target-independent core: the same code path is used by the wasm exports (`lib.rs`) and by the
//! native reference binary (`bin/native.rs`).
//!
//! Pipeline — the recursion route's leaf, as `leaf_prover::prove_leaf` runs it:
//!
//! 1. `execute`: parse the `*.executable.json` produced by `scarb build` (executable target), build
//!    a `Program` from its `Bootloader` entry point
//!    (`cairo_lang_execute_utils::program_and_hints_from_executable`), wrap it in a
//!    `Task::Cairo1Program` and run it under the **leaf simple bootloader**
//!    (`leaf_simple_bootloader_compiled.json` of the monorepo, embedded gzipped in this crate) with
//!    `cairo_program_runner_lib::cairo_run_program` (layout `all_cairo_stwo`, proof mode, no trace
//!    padding, no VM relocation), then `stwo_cairo_adapter::adapt` the finished runner into a
//!    `ProverInput`.
//!
//!    Why the bootloader: at cd7bc5f `adapt()` hardcodes `PublicSegmentContext::bootloader_context()`
//!    (all 11 builtin segments public), so the standalone entry point of an executable — which only
//!    exposes its own builtins — is not adaptable any more (the monorepo's own
//!    `run_and_prove --program_type executable` fails with `Constraints not satisfied` on the same
//!    file). The bootloader is also what the recursion route proves.
//! 2. `prove`: `stwo_cairo_prover::prover::prove_cairo::<MC>` with a `ProverParameters` JSON.
//! 3. `verify`: `cairo_air::verifier::verify_cairo_ex::<MC>`.
//!
//! Proofs are exchanged as `bincode` of the *extended* `CairoProof<H>` (what the monorepo calls
//! `ProofFormat::ExtendedBinary`, minus the bzip2 layer), because it is the only format from which
//! both the Rust verifier input and the cairo-serde felt stream can be derived.

use std::io::Read;
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::OnceLock;

use anyhow::{Context, Result, anyhow, bail};
use cairo_air::CairoProof;
use cairo_air::verifier::verify_cairo_ex;
use cairo_lang_executable::executable::{EntryPointKind, Executable};
use cairo_lang_execute_utils::program_and_hints_from_executable;
use cairo_lang_runner::Arg;
use cairo_program_runner_lib::types::{
    Cairo1Executable, HashFunc, PrivacySimpleBootloaderInput, SimpleBootloaderInput, Task,
    TaskSpec,
};
use cairo_program_runner_lib::utils::get_cairo_run_config;
use cairo_program_runner_lib::{ProgramInput, cairo_run_program};
use cairo_vm::Felt252;
use cairo_vm::types::layout_name::LayoutName;
use cairo_vm::types::program::Program;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use stwo::core::channel::MerkleChannel;
use stwo::core::fri::FriConfig;
use stwo::core::vcs_lifted::blake2_merkle::{Blake2sM31MerkleChannel, Blake2sMerkleChannel};
use stwo::core::vcs_lifted::hasher::Hasher;
use stwo::core::vcs_lifted::merkle_hasher::MerkleHasherLifted;
use stwo::prover::backend::BackendForChannel;
use stwo::prover::backend::simd::SimdBackend;
use stwo_cairo_adapter::ProverInput;
use stwo_cairo_adapter::adapter::adapt;
use cairo_air::components::memory_address_to_id::MEMORY_ADDRESS_TO_ID_SPLIT as ADDRESS_TO_ID_SPLIT;
use stwo_cairo_common::preprocessed_columns::preprocessed_trace::PreProcessedTraceVariant;
use stwo_cairo_prover::prover::{ChannelHash, LiftingSizePolicy, ProverParameters, prove_cairo};
use stwo_cairo_serialize::CairoSerialize;

/// `crates/stwo_run_and_prove_recursive_tree/test_data/leaf_simple_bootloader_compiled.json` of
/// the monorepo @ cd7bc5f (sha256 5e2befae…82f5 of the JSON), gzip -9. The leaf program of the
/// `canonical_small` circuit registry.
static LEAF_BOOTLOADER_GZ: &[u8] = include_bytes!("../resources/leaf_simple_bootloader_compiled.json.gz");

fn leaf_bootloader_program() -> Result<&'static Program> {
    static PROGRAM: OnceLock<Program> = OnceLock::new();
    if let Some(p) = PROGRAM.get() {
        return Ok(p);
    }
    let _s = tracing::info_span!("load bootloader").entered();
    let mut json = Vec::with_capacity(2 << 20);
    flate2::read::GzDecoder::new(LEAF_BOOTLOADER_GZ)
        .read_to_end(&mut json)
        .context("gunzip leaf bootloader")?;
    let program = Program::from_bytes(&json, Some("main"))
        .map_err(|e| anyhow!("parse leaf bootloader: {e}"))?;
    Ok(PROGRAM.get_or_init(|| program))
}

/// Default prover parameters: the recursion route's leaf format, as far as this spike can match it
/// (`circuit_registry_definitions/canonical_small` + `leaf_prover` requirements) with production
/// security (`pow_bits = 26`, `log_blowup_factor = 1`, `n_queries = 70` = 96 bits).
///
/// * `preprocessed_trace = canonical_small` (max trace 2^20, no Pedersen 2^18 table) — the only
///   variant that fits in a 16 GiB Memory64.
/// * `channel_hash = blake2s_m31` — `leaf_prover` proves with `Blake2sM31MerkleChannel`.
/// * `include_all_preprocessed_columns = true`, `lifting_size_policy = at_least_preprocessed` —
///   asserted by `leaf_prover::prove_leaf`. NOTE: the latter lifts *every* tree to
///   max(trace, preprocessed) = 2^21 rows, so small traces pay the 2^20 preprocessed cost; pass
///   `"lifting_size_policy": "auto"` to measure the trace-proportional cost instead.
pub const DEFAULT_PARAMS_JSON: &str = r#"{
  "channel_hash": "blake2s_m31",
  "channel_salt": 0,
  "preprocessed_trace": "canonical_small",
  "fri_config": {
    "pow_bits": 26,
    "log_blowup_factor": 1,
    "log_last_layer_degree_bound": 0,
    "n_queries": 70,
    "fold_step": 1
  },
  "store_polynomials_coefficients": false,
  "include_all_preprocessed_columns": true,
  "opt_n_id_to_big_components": 16,
  "lifting_size_policy": "at_least_preprocessed"
}"#;

pub fn default_params() -> ProverParameters {
    parse_params("").expect("DEFAULT_PARAMS_JSON is valid")
}

/// Parses a `ProverParameters` JSON; an empty/blank string selects [`DEFAULT_PARAMS_JSON`].
pub fn parse_params(params_json: &str) -> Result<ProverParameters> {
    let src = if params_json.trim().is_empty() { DEFAULT_PARAMS_JSON } else { params_json };
    let params: ProverParameters =
        serde_json::from_str(src).context("invalid prover_params JSON")?;
    let FriConfig { log_blowup_factor, .. } = params.fri_config;
    if !(1..=16).contains(&log_blowup_factor) {
        bail!("log_blowup_factor must be in [1, 16]");
    }
    if matches!(params.preprocessed_trace, PreProcessedTraceVariant::Canonical) {
        tracing::warn!(
            "preprocessed_trace = canonical needs > 16 GiB and cannot fit in Memory64; use \
             canonical_small"
        );
    }
    Ok(params)
}

/// Execution statistics returned next to the `ProverInput`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExecutionStats {
    /// Number of VM steps of the whole run (bootloader + task) = trace length before padding.
    pub n_steps: usize,
    /// Builtin instance counters (name -> count), as reported by cairo-vm.
    pub builtins: Vec<(String, usize)>,
    /// Bootloader output segment (hex felts): the leaf's public output (hashed task output).
    pub output: Vec<String>,
    /// Preimage of the leaf output hash (hex felts): `[n_tasks, output_len, program_hash,
    /// task_outputs…]` — the task's own return values are at the end.
    pub output_preimage: Vec<String>,
    /// Size of the bincode-serialized `ProverInput`.
    pub prover_input_bytes: usize,
}

fn parse_felt(v: &serde_json::Value) -> Result<Felt252> {
    match v {
        serde_json::Value::Number(n) => {
            let s = n.to_string();
            Felt252::from_dec_str(&s).map_err(|e| anyhow!("bad felt {s}: {e:?}"))
        }
        serde_json::Value::String(s) => {
            if let Some(hex) = s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")) {
                Felt252::from_hex(hex).map_err(|e| anyhow!("bad hex felt {s}: {e:?}"))
            } else {
                Felt252::from_dec_str(s).map_err(|e| anyhow!("bad felt {s}: {e:?}"))
            }
        }
        other => bail!("argument must be a number or a string, got {other}"),
    }
}

/// Parses program arguments: a JSON array of felts (numbers, decimal strings or `0x` hex strings —
/// the `scarb execute --arguments-file` format).
pub fn parse_args(args_json: &str) -> Result<Vec<Arg>> {
    if args_json.trim().is_empty() {
        return Ok(vec![]);
    }
    let values: Vec<serde_json::Value> =
        serde_json::from_str(args_json).context("invalid args JSON (expected an array)")?;
    values.iter().map(|v| parse_felt(v).map(Arg::Value)).collect()
}

fn hex(f: &Felt252) -> String {
    format!("{f:#x}")
}

/// Runs the executable under the leaf simple bootloader in proof mode and adapts the run for the
/// prover. See the module documentation.
pub fn execute(executable_json: &str, args_json: &str) -> Result<(ProverInput, ExecutionStats)> {
    let _span = tracing::info_span!("execute").entered();

    let executable: Executable = {
        let _s = tracing::info_span!("parse executable").entered();
        serde_json::from_str(executable_json).context("failed to parse executable JSON")?
    };
    let user_args = parse_args(args_json)?;

    // Same as `cairo_program_runner_lib::tasks::create_cairo1_program_task`, from memory.
    let entrypoint = executable
        .entrypoints
        .iter()
        .find(|e| matches!(e.kind, EntryPointKind::Bootloader))
        .context("executable has no Bootloader entry point")?;
    let (program, string_to_hint) = program_and_hints_from_executable(&executable, entrypoint)
        .context("failed to build program from executable")?;
    let task = Task::Cairo1Program(Cairo1Executable { program, user_args, string_to_hint });
    let bootloader_input = PrivacySimpleBootloaderInput {
        simple_bootloader_input: SimpleBootloaderInput {
            fact_topologies_path: None,
            single_page: true,
            tasks: vec![TaskSpec { task: Rc::new(task), program_hash_function: HashFunc::Blake }],
        },
        // Empty path = keep the preimage in the execution scopes only (patch proving-0001).
        output_preimage_dump_path: PathBuf::new(),
    };

    // Same configuration as `leaf_prover::prove_leaf` / `stwo_run_and_prove`: proof mode, no trace
    // padding (redundant for stwo), missing builtins allowed (the bootloader simulates them), no
    // memory relocation (the adapter relocates).
    let cairo_run_config =
        get_cairo_run_config(&None, LayoutName::all_cairo_stwo, true, true, true, false)?;

    let bootloader = leaf_bootloader_program()?;
    let mut runner = {
        let _s = tracing::info_span!("cairo-vm run").entered();
        cairo_run_program(
            bootloader,
            Some(ProgramInput::Value(Box::new(bootloader_input))),
            cairo_run_config,
            None,
        )
        .map_err(|e| anyhow!("cairo-vm run failed: {e}"))?
    };

    let resources = runner.get_execution_resources().map_err(|e| anyhow!("{e}"))?;
    let mut builtins: Vec<(String, usize)> = resources
        .builtin_instance_counter
        .iter()
        .map(|(k, v)| (k.to_string(), *v))
        .collect();
    builtins.sort();

    let output = {
        let mut buf = String::new();
        runner.vm.write_output(&mut buf).map_err(|e| anyhow!("{e}"))?;
        buf.lines()
            .map(|l| Felt252::from_dec_str(l.trim()).map(|f| hex(&f)).unwrap_or_else(|_| l.to_string()))
            .collect::<Vec<_>>()
    };
    let output_preimage: Vec<String> = runner
        .exec_scopes
        .get::<Vec<Felt252>>(cairo_program_runner_lib::vars::OUTPUT_PREIMAGE)
        .map(|v| v.iter().map(hex).collect())
        .unwrap_or_default();

    let prover_input = {
        let _s = tracing::info_span!("adapt").entered();
        adapt(&runner).context("adapter failed")?
    };

    let stats = ExecutionStats {
        n_steps: resources.n_steps,
        builtins,
        output,
        output_preimage,
        prover_input_bytes: 0,
    };
    Ok((prover_input, stats))
}

/// What the prover would have to build for a given `ProverInput`, derived from the adapter's
/// `ExecutionResources` — i.e. *without* generating any trace (milliseconds, no extra memory).
///
/// The client uses this to size segments: a segment is provable by the recursion leaf as long as
/// every AIR component stays within `2^20` rows (the registry's `trace_log_size = 20`), which is
/// **not** the same as "at most 2^20 steps": the steps are spread over one component per opcode.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ResourceSummary {
    /// VM steps = number of state transitions (sum of the per-opcode counters).
    pub n_steps: usize,
    /// Per-opcode instance counts — one AIR component each, `count` rows.
    pub opcodes: Vec<(String, usize)>,
    /// Per-builtin instance counts (after the adapter's padding to a power of two).
    pub builtins: Vec<(String, usize)>,
    /// Unique aggregator inputs per aggregator-backed builtin (pedersen/poseidon).
    pub unique_aggregator_inputs: Vec<(String, usize)>,
    /// Rows of the `memory_address_to_id` component.
    pub memory_address_to_id: usize,
    /// Rows of the `memory_id_to_big` table, *before* the `opt_n_id_to_big_components` split.
    pub memory_id_to_big: usize,
    /// Rows of the `memory_id_to_small` component.
    pub memory_id_to_small: usize,
    /// Rows of the `verify_instruction` component (unique pc values).
    pub verify_instruction: usize,
    /// Largest component row count derivable from the counters above, and the name of the
    /// component that reaches it.
    pub max_component_rows: usize,
    pub max_component: String,
    /// `ceil(log2(max_component_rows))` — the `trace_log_size` the proof will end up with, unless
    /// a component this summary cannot see (padding, range-check/multiplicity components) is
    /// taller. Compare with `ProofStats::max_log_size`, which is exact but only known after
    /// proving.
    pub log_max_component_size: u32,
    /// Whether that fits the leaf registry (`trace_log_size <= 20`).
    pub fits_leaf_registry: bool,
    /// How many `memory_id_to_big` components the table needs; the parameters allow
    /// `opt_n_id_to_big_components` (16 for the leaf), and proving panics above that.
    pub n_memory_id_to_big_components: usize,
}

fn log2_ceil(n: usize) -> u32 {
    if n <= 1 { 0 } else { usize::BITS - (n - 1).leading_zeros() }
}

/// Rows a component with `n` entries actually gets: padded to a power of two, at least one SIMD
/// lane row (`N_LANES = 16`), which is what every witness generator does.
fn component_rows(n: usize) -> usize {
    n.max(16).next_power_of_two()
}

/// Computes a [`ResourceSummary`] from a `ProverInput`. `opt_n_id_to_big_components` of the
/// parameters is taken into account (it splits the `memory_id_to_big` table into that many
/// components).
pub fn resources(input: &ProverInput, params: &ProverParameters) -> ResourceSummary {
    let _s = tracing::info_span!("resources").entered();
    let r = stwo_cairo_adapter::ExecutionResources::from_prover_input(input);
    let mut opcodes: Vec<(String, usize)> =
        r.opcodes_instance_counter.iter().map(|(k, v)| (k.clone(), *v)).collect();
    opcodes.sort();
    let mut builtins: Vec<(String, usize)> =
        r.builtin_instance_counter.iter().map(|(k, v)| (k.clone(), *v)).collect();
    builtins.sort();
    let mut unique_aggregator_inputs: Vec<(String, usize)> =
        r.unique_aggregator_inputs.iter().map(|(k, v)| (k.clone(), *v)).collect();
    unique_aggregator_inputs.sort();

    // How many rows each component ends up with, from the witness generators:
    //
    // * one component per opcode, `next_pow2(count)` rows, and the same for `verify_instruction`;
    // * `memory_address_to_id` splits its table over `MEMORY_ADDRESS_TO_ID_SPLIT` (= 16) column
    //   groups, so `next_pow2(len / 16)` rows;
    // * `memory_id_to_small` is a single component of `next_pow2(len)` rows;
    // * `memory_id_to_big` is cut into chunks of at most the preprocessed max size (2^20 with
    //   `canonical_small`), at most `opt_n_id_to_big_components` of them;
    // * builtins: one component per builtin, `next_pow2(instances)` rows (the adapter has already
    //   padded the segments to powers of two).
    let big_chunk_rows = 1usize << params.preprocessed_trace.max_log_trace_size();
    let big_len = r.memory_tables_sizes.memory_id_to_big;
    let id_to_big_rows = component_rows(big_len.min(big_chunk_rows));
    let n_id_to_big_components = big_len.div_ceil(big_chunk_rows).max(1);

    let mut candidates: Vec<(String, usize)> =
        opcodes.iter().map(|(k, v)| (k.clone(), component_rows(*v))).collect();
    candidates.extend(builtins.iter().map(|(k, v)| (k.clone(), component_rows(*v))));
    candidates.push((
        "memory_address_to_id".into(),
        component_rows(r.memory_tables_sizes.memory_address_to_id.div_ceil(ADDRESS_TO_ID_SPLIT)),
    ));
    candidates.push(("memory_id_to_big".into(), id_to_big_rows));
    candidates.push((
        "memory_id_to_small".into(),
        component_rows(r.memory_tables_sizes.memory_id_to_small),
    ));
    candidates.push(("verify_instruction".into(), component_rows(r.verify_instruction)));
    let (max_component, max_component_rows) = candidates
        .into_iter()
        .max_by_key(|(_, v)| *v)
        .unwrap_or_else(|| ("none".to_string(), 0));

    let log_max_component_size = log2_ceil(max_component_rows);
    ResourceSummary {
        n_steps: opcodes.iter().map(|(_, v)| *v).sum(),
        opcodes,
        builtins,
        unique_aggregator_inputs,
        memory_address_to_id: r.memory_tables_sizes.memory_address_to_id,
        memory_id_to_big: r.memory_tables_sizes.memory_id_to_big,
        memory_id_to_small: r.memory_tables_sizes.memory_id_to_small,
        verify_instruction: r.verify_instruction,
        max_component_rows,
        max_component,
        log_max_component_size,
        fits_leaf_registry: log_max_component_size <= 20
            && n_id_to_big_components <= params.opt_n_id_to_big_components.unwrap_or(usize::MAX),
        n_memory_id_to_big_components: n_id_to_big_components,
    }
}

pub fn prover_input_to_bytes(input: &ProverInput) -> Result<Vec<u8>> {
    let _s = tracing::info_span!("serialize prover_input").entered();
    bincode::serialize(input).context("bincode(ProverInput)")
}

pub fn prover_input_from_bytes(bytes: &[u8]) -> Result<ProverInput> {
    let _s = tracing::info_span!("deserialize prover_input").entered();
    bincode::deserialize(bytes).context("bincode(ProverInput)")
}

/// Statistics returned next to the proof.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProofStats {
    /// Size of the bincode-serialized extended proof.
    pub proof_bytes: usize,
    /// Number of felt252 in the cairo-serde encoding (the on-chain / Cairo verifier format).
    pub proof_felts: usize,
    /// `PcsConfig` lifting sizes actually used (trace, preprocessed).
    pub trace_lifting_log_size: u32,
    pub preprocessed_lifting_log_size: u32,
    /// `trace_lifting_log_size - log_blowup_factor` — **the** `trace_log_size` the recursion leaf
    /// reads off the proof to pick its verifier circuit (`registry.leaf_verifiers[trace_log_size]`,
    /// 20 for the `doom` registry).
    pub trace_log_size: u32,
    /// Largest *base trace* component of the claim, in log2 rows. This is the quantity a segment
    /// must keep ≤ 20: above it the whole proof lifts to 2^21 and the registry rejects it. It is
    /// the exact counterpart of [`ResourceSummary::log_max_component_size`].
    pub max_trace_component_log_size: u32,
    /// Max log size over *every* tree of the claim, the preprocessed one included — with
    /// `canonical_small` this is 20 for any trace, so it says nothing about the segment size.
    /// Kept because S2 reported it.
    pub max_log_size: u32,
    /// Log size of every base-trace component, descending.
    pub component_log_sizes: Vec<u32>,
}

fn prove_generic<MC>(input: ProverInput, params: ProverParameters) -> Result<(Vec<u8>, ProofStats)>
where
    MC: MerkleChannel,
    SimdBackend: BackendForChannel<MC>,
    MC::H: MerkleHasherLifted + Serialize,
    <MC::H as Hasher>::Hash: CairoSerialize,
{
    let proof: CairoProof<MC::H> =
        prove_cairo::<MC>(input, params).map_err(|e| anyhow!("proving failed: {e}"))?;
    let n_felts = {
        let _s = tracing::info_span!("cairo-serde proof").entered();
        let mut felts: Vec<starknet_ff::FieldElement> = Vec::new();
        CairoSerialize::serialize(&proof, &mut felts);
        felts.len()
    };
    let cfg = proof.extended_stark_proof.proof.config;
    // `TreeVec` = [preprocessed columns used, base trace, interaction trace]. Only the base trace
    // says how big the segment is; the preprocessed entries are the fixed 2^20 of
    // `canonical_small`, which is why `max_log_size` alone cannot be used to size a segment.
    let log_sizes = proof.claim.log_sizes();
    let max_log_size = log_sizes.iter().flatten().copied().max().unwrap_or(0);
    let mut component_log_sizes: Vec<u32> =
        log_sizes.get(1).map(|t| t.to_vec()).unwrap_or_default();
    component_log_sizes.sort_unstable_by(|a, b| b.cmp(a));
    let max_trace_component_log_size = component_log_sizes.first().copied().unwrap_or(0);
    let trace_log_size = cfg.trace_lifting_log_size - cfg.fri_config.log_blowup_factor;
    let bytes = {
        let _s = tracing::info_span!("serialize proof").entered();
        bincode::serialize(&proof).context("bincode(CairoProof)")?
    };
    let stats = ProofStats {
        proof_bytes: bytes.len(),
        proof_felts: n_felts,
        trace_lifting_log_size: cfg.trace_lifting_log_size,
        preprocessed_lifting_log_size: cfg.preprocessed_lifting_log_size,
        trace_log_size,
        max_trace_component_log_size,
        max_log_size,
        component_log_sizes,
    };
    Ok((bytes, stats))
}

/// Proves a `ProverInput` with the given parameters. Returns the bincode extended proof.
pub fn prove(input: ProverInput, params: ProverParameters) -> Result<(Vec<u8>, ProofStats)> {
    let _span = tracing::info_span!("prove").entered();
    match params.channel_hash {
        ChannelHash::Blake2s => prove_generic::<Blake2sMerkleChannel>(input, params),
        ChannelHash::Blake2sM31 => prove_generic::<Blake2sM31MerkleChannel>(input, params),
        ChannelHash::Poseidon252 => bail!("poseidon252 channel is not supported (wasm targets)"),
    }
}

fn verify_generic<MC>(proof_bytes: &[u8], params: ProverParameters) -> Result<()>
where
    MC: MerkleChannel,
    SimdBackend: BackendForChannel<MC>,
    MC::H: MerkleHasherLifted + DeserializeOwned,
{
    let proof: CairoProof<MC::H> = {
        let _s = tracing::info_span!("deserialize proof").entered();
        bincode::deserialize(proof_bytes).context("bincode(CairoProof)")?
    };
    verify_cairo_ex::<MC>(proof.into(), params.include_all_preprocessed_columns)
        .map_err(|e| anyhow!("verification failed: {e}"))
}

/// Verifies a bincode extended proof. `Ok(true)` = valid, `Err` = invalid (with the reason).
pub fn verify(proof_bytes: &[u8], params: ProverParameters) -> Result<bool> {
    let _span = tracing::info_span!("verify").entered();
    match params.channel_hash {
        ChannelHash::Blake2s => verify_generic::<Blake2sMerkleChannel>(proof_bytes, params)?,
        ChannelHash::Blake2sM31 => verify_generic::<Blake2sM31MerkleChannel>(proof_bytes, params)?,
        ChannelHash::Poseidon252 => bail!("poseidon252 channel is not supported (wasm targets)"),
    }
    Ok(true)
}

fn felts_generic<H>(proof_bytes: &[u8]) -> Result<Vec<String>>
where
    H: MerkleHasherLifted + DeserializeOwned,
    H::Hash: CairoSerialize,
{
    let proof: CairoProof<H> = bincode::deserialize(proof_bytes).context("bincode(CairoProof)")?;
    let mut felts: Vec<starknet_ff::FieldElement> = Vec::new();
    CairoSerialize::serialize(&proof, &mut felts);
    Ok(felts.into_iter().map(|f| format!("0x{f:x}")).collect())
}

/// Converts a bincode extended proof to the cairo-serde felt stream (`ProofFormat::CairoSerde`,
/// what `scarb verify` / the Cairo verifier consume), as hex strings.
pub fn proof_to_felts(proof_bytes: &[u8], params: ProverParameters) -> Result<Vec<String>> {
    let _span = tracing::info_span!("proof_to_felts").entered();
    match params.channel_hash {
        ChannelHash::Blake2s => {
            felts_generic::<<Blake2sMerkleChannel as MerkleChannel>::H>(proof_bytes)
        }
        ChannelHash::Blake2sM31 => {
            felts_generic::<<Blake2sM31MerkleChannel as MerkleChannel>::H>(proof_bytes)
        }
        ChannelHash::Poseidon252 => bail!("poseidon252 channel is not supported (wasm targets)"),
    }
}

/// Human-readable summary of the effective parameters (for logs / result tables).
pub fn describe_params(p: &ProverParameters) -> String {
    let lifting = match p.lifting_size_policy {
        LiftingSizePolicy::Auto => "auto".to_string(),
        LiftingSizePolicy::Fixed(n) => format!("fixed({n})"),
        LiftingSizePolicy::AtLeastPreprocessed => "at_least_preprocessed".to_string(),
    };
    format!(
        "{:?}/{:?} pow={} blowup={} queries={} fold={} all_pp={} lifting={}",
        p.channel_hash,
        p.preprocessed_trace,
        p.fri_config.pow_bits,
        p.fri_config.log_blowup_factor,
        p.fri_config.n_queries,
        p.fri_config.fold_step,
        p.include_all_preprocessed_columns,
        lifting
    )
}
