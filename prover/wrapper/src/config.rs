// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0

//! Configuration: a TOML file, with a few environment overrides for containers.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

fn d_bind() -> String {
    "127.0.0.1:8787".into()
}
fn d_data_dir() -> PathBuf {
    PathBuf::from("./data")
}
fn d_max_circuit_proofs() -> usize {
    // S4: every circuit proof (leaf or fold) peaks at 32.5 GB RSS. Two do not fit in 64 GB.
    1
}
fn d_max_verify_jobs() -> usize {
    4
}
fn d_batch_max_runs() -> usize {
    8
}
fn d_batch_max_wait_secs() -> u64 {
    600
}
fn d_max_segments_per_run() -> usize {
    64
}
fn d_max_proof_bytes() -> usize {
    8 * 1024 * 1024
}
fn d_max_body_bytes() -> usize {
    512 * 1024 * 1024
}
fn d_job_max_attempts() -> u32 {
    3
}
fn d_scheduler_tick_ms() -> u64 {
    250
}
fn d_true() -> bool {
    true
}

/// A program the wrapper is willing to prove leaves for. Clients never upload code: they name a
/// program id, and the wrapper uses the compiled executable it has pinned on disk.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct ProgramEntry {
    pub id: String,
    /// Absolute path to the Scarb `*.executable.json`.
    pub executable: PathBuf,
    /// Optional: the blake2s program hash of the *task* (`preimage[0]`). When set, a submission
    /// whose preimage does not start with it is rejected without any proving work.
    #[serde(default)]
    pub program_hash: Option<String>,
}

/// One API key (R8-A2). The Controller session-signature scheme that will replace this is
/// documented in `README.md`; this is the implemented stub.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct ApiKey {
    pub key: String,
    /// Identity this key acts for (a Starknet account address, once Controller auth lands).
    pub account: String,
    #[serde(default)]
    pub admin: bool,
    /// Maximum runs accepted per rolling 24 h. 0 = unlimited.
    #[serde(default)]
    pub daily_run_quota: u32,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct Config {
    #[serde(default = "d_bind")]
    pub bind: String,
    #[serde(default = "d_data_dir")]
    pub data_dir: PathBuf,

    // ---- pinned pipeline binaries and data (R3-A1: monorepo @ cd7bc5f) ----
    /// `circuit_registry_definitions/doom/registry.json` (S4). Its hash identifies every leaf.
    pub registry_json: Option<PathBuf>,
    /// `leaf-prover` from the pinned monorepo.
    pub leaf_prover_bin: Option<PathBuf>,
    /// `stwo_run_and_prove_recursive_tree` from the pinned monorepo.
    pub tree_bin: Option<PathBuf>,
    /// `hellproof-leaf-verify` (this repo, `prover/wrapper/leaf-verify`).
    pub leaf_verify_bin: Option<PathBuf>,
    /// `leaf_simple_bootloader_compiled.json` every leaf runs.
    pub leaf_bootloader: Option<PathBuf>,

    /// `subprocess` (the real pipeline) or `stub` (deterministic fake, for tests and load runs).
    #[serde(default)]
    pub backend: Backend,

    // ---- resources ----
    /// Circuit proofs (leaf or fold) allowed to run at once. 32.5 GB each (S4).
    #[serde(default = "d_max_circuit_proofs")]
    pub max_circuit_proofs: usize,
    #[serde(default = "d_max_verify_jobs")]
    pub max_verify_jobs: usize,
    /// Optional cross-process lock directory (`mkdir` mutex), for machines shared with other
    /// proving jobs. Empty = no external lock.
    #[serde(default)]
    pub proof_lock_dir: Option<PathBuf>,

    // ---- batching policy (D6 / R7-A3) ----
    #[serde(default = "d_batch_max_runs")]
    pub batch_max_runs: usize,
    #[serde(default = "d_batch_max_wait_secs")]
    pub batch_max_wait_secs: u64,

    // ---- limits ----
    #[serde(default = "d_max_segments_per_run")]
    pub max_segments_per_run: usize,
    #[serde(default = "d_max_proof_bytes")]
    pub max_proof_bytes: usize,
    #[serde(default = "d_max_body_bytes")]
    pub max_body_bytes: usize,
    #[serde(default = "d_job_max_attempts")]
    pub job_max_attempts: u32,
    #[serde(default = "d_scheduler_tick_ms")]
    pub scheduler_tick_ms: u64,
    /// Reject a submission whose proofs cannot be cryptographically verified (i.e. that were sent
    /// as a cairo-serde felt stream only — that encoding is one-way at `cd7bc5f`).
    #[serde(default = "d_true")]
    pub require_verifiable_proof: bool,
    /// Check `blake2s(cairo0_encode(preimage))` against the proof's output cells before proving.
    #[serde(default = "d_true")]
    pub check_preimage_binding: bool,

    #[serde(default)]
    pub programs: Vec<ProgramEntry>,
    #[serde(default)]
    pub api_keys: Vec<ApiKey>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum Backend {
    #[default]
    Subprocess,
    /// No proving at all: leaves and folds produce deterministic placeholder files. Used by the
    /// unit tests and by the load-test stub.
    Stub,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            bind: d_bind(),
            data_dir: d_data_dir(),
            registry_json: None,
            leaf_prover_bin: None,
            tree_bin: None,
            leaf_verify_bin: None,
            leaf_bootloader: None,
            backend: Backend::default(),
            max_circuit_proofs: d_max_circuit_proofs(),
            max_verify_jobs: d_max_verify_jobs(),
            proof_lock_dir: None,
            batch_max_runs: d_batch_max_runs(),
            batch_max_wait_secs: d_batch_max_wait_secs(),
            max_segments_per_run: d_max_segments_per_run(),
            max_proof_bytes: d_max_proof_bytes(),
            max_body_bytes: d_max_body_bytes(),
            job_max_attempts: d_job_max_attempts(),
            scheduler_tick_ms: d_scheduler_tick_ms(),
            require_verifiable_proof: d_true(),
            check_preimage_binding: d_true(),
            programs: vec![],
            api_keys: vec![],
        }
    }
}

impl Config {
    pub fn load(path: &Path) -> anyhow::Result<Self> {
        let text = std::fs::read_to_string(path)
            .map_err(|e| anyhow::anyhow!("cannot read config {}: {e}", path.display()))?;
        let mut cfg: Config = toml::from_str(&text)?;
        cfg.apply_env();
        Ok(cfg)
    }

    /// Environment overrides, so the container image needs no config edit.
    pub fn apply_env(&mut self) {
        if let Ok(v) = std::env::var("WRAPPER_BIND") {
            self.bind = v;
        }
        if let Ok(v) = std::env::var("WRAPPER_DATA_DIR") {
            self.data_dir = PathBuf::from(v);
        }
        if let Ok(v) = std::env::var("WRAPPER_REGISTRY_JSON") {
            self.registry_json = Some(PathBuf::from(v));
        }
        if let Ok(v) = std::env::var("WRAPPER_MAX_CIRCUIT_PROOFS") {
            if let Ok(n) = v.parse() {
                self.max_circuit_proofs = n;
            }
        }
        if let Ok(v) = std::env::var("WRAPPER_BATCH_MAX_RUNS") {
            if let Ok(n) = v.parse() {
                self.batch_max_runs = n;
            }
        }
        if let Ok(v) = std::env::var("WRAPPER_BATCH_MAX_WAIT_SECS") {
            if let Ok(n) = v.parse() {
                self.batch_max_wait_secs = n;
            }
        }
        if let Ok(v) = std::env::var("WRAPPER_API_KEY") {
            // Single-key convenience for `docker run`.
            self.api_keys.push(ApiKey {
                key: v,
                account: "0x0".into(),
                admin: true,
                daily_run_quota: 0,
            });
        }
    }

    pub fn program(&self, id: &str) -> Option<&ProgramEntry> {
        self.programs.iter().find(|p| p.id == id)
    }

    pub fn keys_by_secret(&self) -> BTreeMap<&str, &ApiKey> {
        self.api_keys.iter().map(|k| (k.key.as_str(), k)).collect()
    }

    /// Fails fast on a configuration that cannot run the real pipeline.
    pub fn check_runnable(&self) -> anyhow::Result<()> {
        if self.backend == Backend::Stub {
            return Ok(());
        }
        for (name, p) in [
            ("registry_json", &self.registry_json),
            ("leaf_prover_bin", &self.leaf_prover_bin),
            ("tree_bin", &self.tree_bin),
            ("leaf_bootloader", &self.leaf_bootloader),
        ] {
            let p = p
                .as_ref()
                .ok_or_else(|| anyhow::anyhow!("config: `{name}` is required with backend=subprocess"))?;
            if !p.exists() {
                anyhow::bail!("config: `{name}` points at a missing file: {}", p.display());
            }
        }
        if self.require_verifiable_proof && self.leaf_verify_bin.is_none() {
            anyhow::bail!(
                "config: `leaf_verify_bin` is required when require_verifiable_proof = true"
            );
        }
        if self.programs.is_empty() {
            anyhow::bail!("config: at least one [[programs]] entry is required");
        }
        for p in &self.programs {
            if !p.executable.exists() {
                anyhow::bail!(
                    "config: program `{}` executable missing: {}",
                    p.id,
                    p.executable.display()
                );
            }
        }
        Ok(())
    }
}
