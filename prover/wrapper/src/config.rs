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
/// Peak RSS of one circuit proof, when the registry does not say. The `doom` registry measures
/// 32.1–32.5 GB (S4); `doom_fold4_min` measures 21.9 GB (S4b).
fn d_circuit_proof_rss_bytes() -> u64 {
    35_000_000_000
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

/// The circuit registry the wrapper proves against (R3-A2).
///
/// `spikes/s4/registry/doom` is the default: production padding, `fold_step = 1`, multiverifier
/// identical to production, 32.1-32.5 GB and ~24 s per circuit proof (S4). The production target
/// is `spikes/s4/registry/doom_fold4_min` (`fold_step = 4` + minimal padding): **21.9 GB and
/// 13.3 s per leaf, 21.4 GB and 13.5 s per fold** (S4b) - 33 % less memory, so two circuit proofs
/// fit in 64 GB - at the price of new on-chain verifier constants (its multiverifier hash is no
/// longer production's).
#[derive(Debug, Clone, Deserialize, Serialize, Default)]
pub struct RegistryConfig {
    /// `registry.json` produced by `circuit-params --registry`.
    pub path: Option<PathBuf>,
    /// Informational: which definition it was generated from (`doom`, `doom_fold4_min`, ...).
    #[serde(default)]
    pub name: Option<String>,
    /// The multiverifier circuit hash this wrapper must produce (64 hex chars, the eight u32
    /// words concatenated). Checked against `path` at startup: a registry swap that would change
    /// the hash the contract pins fails fast instead of producing unverifiable roots.
    #[serde(default)]
    pub multiverifier_hash: Option<String>,
    /// Same for the leaf circuit hash (there is one per `trace_log_size`; any match passes).
    #[serde(default)]
    pub leaf_circuit_hash: Option<String>,
    /// Measured peak RSS of one circuit proof with this registry; sizes `max_circuit_proofs`.
    #[serde(default = "d_circuit_proof_rss_bytes")]
    pub circuit_proof_rss_bytes: u64,
}

/// A program the wrapper is willing to prove leaves for. Clients never upload code: they name a
/// program id, and the wrapper uses the compiled executable it has pinned on disk.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct ProgramEntry {
    pub id: String,
    /// Absolute path to the Scarb `*.executable.json`.
    pub executable: PathBuf,
    /// Optional: the program hash of the *task* (`preimage[0]`), under `hash_function`. When set,
    /// a submission whose preimage does not start with it is rejected without any proving work.
    #[serde(default)]
    pub program_hash: Option<String>,
    /// Hash the bootloader computes the task's program hash with (G0 D4: `poseidon` in
    /// production, `blake` in the S4/S4b measurements). A submission may not choose another one.
    #[serde(default)]
    pub hash_function: crate::model::HashFunction,
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
    /// The circuit registry this wrapper proves against. Everything downstream — the leaf circuit
    /// hash the contract pins, the multiverifier hash, the memory and time per proof — follows
    /// from it, so it is one configuration item, checked at startup.
    #[serde(default)]
    pub registry: RegistryConfig,
    /// `leaf-prover` from the pinned monorepo.
    pub leaf_prover_bin: Option<PathBuf>,
    /// `stwo_run_and_prove_recursive_tree` from the pinned monorepo.
    pub tree_bin: Option<PathBuf>,
    /// `hellproof-leaf-verify` (this repo, `prover/wrapper/leaf-verify`).
    pub leaf_verify_bin: Option<PathBuf>,
    /// `leaf_simple_bootloader_compiled.json` every leaf runs.
    pub leaf_bootloader: Option<PathBuf>,
    /// The `ProverParameters` the browser proved its segments with, so the verifier is invoked
    /// with the matching channel. Defaults to the leaf format (`blake2s_m31`,
    /// `include_all_preprocessed_columns = true`).
    ///
    /// Note: the registry's own `cairo_prover_params.channel_hash` is **not** usable here —
    /// `leaf_prover::prove_leaf` hardcodes `Blake2sM31MerkleChannel` and ignores that field
    /// (`doom/registry.json` says `blake2s`).
    pub leaf_params_json: Option<PathBuf>,

    /// `subprocess` (the real pipeline) or `stub` (deterministic fake, for tests and load runs).
    #[serde(default)]
    pub backend: Backend,

    // ---- resources ----
    /// Circuit proofs (leaf or fold) allowed to run at once. Omitted = derived from the
    /// registry's `circuit_proof_rss_bytes` and the machine's memory (see
    /// [`Config::effective_max_circuit_proofs`]).
    #[serde(default)]
    pub max_circuit_proofs: Option<usize>,
    /// Physical memory to size against. Omitted = detected.
    #[serde(default)]
    pub machine_memory_bytes: Option<u64>,
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
            registry: RegistryConfig::default(),
            leaf_prover_bin: None,
            tree_bin: None,
            leaf_verify_bin: None,
            leaf_bootloader: None,
            leaf_params_json: None,
            backend: Backend::default(),
            max_circuit_proofs: None,
            machine_memory_bytes: None,
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
            self.registry.path = Some(PathBuf::from(v));
        }
        if let Ok(v) = std::env::var("WRAPPER_MAX_CIRCUIT_PROOFS") {
            if let Ok(n) = v.parse() {
                self.max_circuit_proofs = Some(n);
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

    /// `(channel_hash, include_all_preprocessed_columns)` the submitted segment proofs use.
    pub fn verify_params(&self) -> (String, bool) {
        let default = ("blake2s_m31".to_string(), true);
        let Some(path) = &self.leaf_params_json else { return default };
        let Ok(bytes) = std::fs::read(path) else { return default };
        let Ok(v) = serde_json::from_slice::<serde_json::Value>(&bytes) else { return default };
        (
            v.get("channel_hash").and_then(|c| c.as_str()).unwrap_or("blake2s_m31").to_string(),
            v.get("include_all_preprocessed_columns").and_then(|c| c.as_bool()).unwrap_or(true),
        )
    }

    /// Reads the configured registry and fails if it is not the one the operator pinned.
    pub fn check_registry_hashes(&self) -> anyhow::Result<()> {
        let Some(path) = &self.registry.path else { return Ok(()) };
        let (leaf_hashes, multiverifier) = read_registry_hashes(path)?;
        if let Some(expected) = &self.registry.multiverifier_hash {
            let expected = expected.trim().trim_start_matches("0x").to_lowercase();
            if multiverifier != expected {
                anyhow::bail!(
                    "config: registry {} has multiverifier hash {multiverifier}, not the pinned \
                     {expected}; the on-chain verifier constants would not match",
                    path.display()
                );
            }
        }
        if let Some(expected) = &self.registry.leaf_circuit_hash {
            let expected = expected.trim().trim_start_matches("0x").to_lowercase();
            if !leaf_hashes.contains(&expected) {
                anyhow::bail!(
                    "config: registry {} has leaf circuit hashes {leaf_hashes:?}, none of them \
                     the pinned {expected}",
                    path.display()
                );
            }
        }
        Ok(())
    }

    /// How many circuit proofs may run at once: the operator's number, or what the machine's
    /// memory divided by this registry's measured peak RSS allows (at least one).
    pub fn effective_max_circuit_proofs(&self) -> usize {
        if let Some(n) = self.max_circuit_proofs {
            return n.max(1);
        }
        let memory = self.machine_memory_bytes.or_else(detect_memory_bytes);
        match memory {
            // Keep a margin: the OS, the queue and a verification job also need room.
            Some(bytes) => (((bytes as f64) * 0.92) as u64
                / self.registry.circuit_proof_rss_bytes.max(1))
            .max(1) as usize,
            None => 1,
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
            ("registry.path", &self.registry.path),
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
        // `leaf_prover::prove_leaf` asserts this and panics in 0.02 s otherwise (S4b measurement
        // 1b); the trap is that `circuit-params` accepts the definition and even produces the
        // same leaf circuit hash, so the mistake only surfaces at proving time.
        let (_, include_all) = self.verify_params();
        if !include_all {
            anyhow::bail!(
                "config: `leaf_params_json` sets include_all_preprocessed_columns = false; \
                 leaf-prover requires true"
            );
        }
        self.check_registry_hashes()?;
        Ok(())
    }
}

/// The leaf circuit hashes and the multiverifier hash a registry declares, as lowercase hex of
/// the concatenated u32 words (the form `packed_output.json` and the contracts use).
pub fn read_registry_hashes(path: &Path) -> anyhow::Result<(Vec<String>, String)> {
    let bytes = std::fs::read(path)
        .map_err(|e| anyhow::anyhow!("cannot read registry {}: {e}", path.display()))?;
    let json: serde_json::Value = serde_json::from_slice(&bytes)
        .map_err(|e| anyhow::anyhow!("registry {} is not JSON: {e}", path.display()))?;
    let words = |v: &serde_json::Value| -> Option<String> {
        Some(
            v.as_array()?
                .iter()
                .map(|w| w.as_str().unwrap_or_default().trim_start_matches("0x").to_lowercase())
                .collect::<String>(),
        )
    };
    let leaves = json["leaf_verifiers"]
        .as_array()
        .map(|a| a.iter().filter_map(|l| words(&l["circuit_hash"])).collect::<Vec<_>>())
        .unwrap_or_default();
    let multiverifier = json["multiverifiers"]
        .as_array()
        .and_then(|a| a.first())
        .and_then(|m| words(&m["circuit_hash"]))
        .ok_or_else(|| anyhow::anyhow!("registry {} has no multiverifier", path.display()))?;
    Ok((leaves, multiverifier))
}

/// Physical memory of this machine, for sizing the circuit-proof semaphore.
fn detect_memory_bytes() -> Option<u64> {
    #[cfg(target_os = "macos")]
    {
        let out = std::process::Command::new("sysctl").args(["-n", "hw.memsize"]).output().ok()?;
        return String::from_utf8_lossy(&out.stdout).trim().parse().ok();
    }
    #[cfg(target_os = "linux")]
    {
        let text = std::fs::read_to_string("/proc/meminfo").ok()?;
        let line = text.lines().find(|l| l.starts_with("MemTotal:"))?;
        let kb: u64 = line.split_whitespace().nth(1)?.parse().ok()?;
        return Some(kb * 1024);
    }
    #[allow(unreachable_code)]
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn repo() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
    }

    /// The documented example must stay a valid configuration.
    #[test]
    fn the_example_config_parses() {
        let text =
            std::fs::read_to_string(PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("wrapper.example.toml"))
                .unwrap();
        let cfg: Config = toml::from_str(&text).unwrap();
        assert_eq!(cfg.registry.name.as_deref(), Some("doom"));
        assert_eq!(cfg.batch_max_runs, 8);
        assert_eq!(cfg.batch_max_wait_secs, 600);
        assert_eq!(cfg.programs.len(), 1);
        assert_eq!(cfg.api_keys.len(), 2);
        assert!(cfg.api_keys.iter().any(|k| k.admin));
        // The pinned hashes in the example are the ones S4 published.
        assert_eq!(
            cfg.registry.multiverifier_hash.as_deref(),
            Some("a59897152377c07ac6d1e84454f0a04d8be65a7dfd73c2619078e728973f680f")
        );
    }

    #[test]
    fn reads_the_pinned_registry_hashes() {
        let (leaves, mv) =
            read_registry_hashes(&repo().join("spikes/s4/registry/doom/registry.json")).unwrap();
        assert_eq!(mv, "a59897152377c07ac6d1e84454f0a04d8be65a7dfd73c2619078e728973f680f");
        assert_eq!(
            leaves,
            vec!["2ad52ed04b5464fc0362ff77e47a7cb0adf8f7c8caef9eb38b8774ba9edac7e2".to_string()]
        );
    }

    #[test]
    fn a_registry_swap_that_changes_the_pinned_hash_fails_fast() {
        let mut cfg = Config::default();
        cfg.registry.path = Some(repo().join("spikes/s4/registry/doom/registry.json"));
        cfg.registry.multiverifier_hash =
            Some("a59897152377c07ac6d1e84454f0a04d8be65a7dfd73c2619078e728973f680f".into());
        cfg.check_registry_hashes().unwrap();

        // `doom_fold4_min` is the production target, but it is a *different* multiverifier: the
        // on-chain constants change with it (S4b).
        cfg.registry.path = Some(repo().join("spikes/s4/registry/doom_fold4_min/registry.json"));
        let err = cfg.check_registry_hashes().unwrap_err().to_string();
        assert!(err.contains("not the pinned"), "{err}");
    }

    #[test]
    fn circuit_proof_slots_follow_the_registry() {
        let mut cfg = Config::default();
        cfg.machine_memory_bytes = Some(64 * 1_000_000_000);
        // `doom`: 32.5 GB per proof -> one at a time on 64 GB (S4).
        cfg.registry.circuit_proof_rss_bytes = 32_500_000_000;
        assert_eq!(cfg.effective_max_circuit_proofs(), 1);
        // `doom_fold4_min`: 21.9 GB -> two (S4b).
        cfg.registry.circuit_proof_rss_bytes = 21_900_000_000;
        assert_eq!(cfg.effective_max_circuit_proofs(), 2);
        // An explicit setting always wins.
        cfg.max_circuit_proofs = Some(1);
        assert_eq!(cfg.effective_max_circuit_proofs(), 1);
    }
}
