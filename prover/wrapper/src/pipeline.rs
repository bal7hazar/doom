// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0

//! Driving the pinned monorepo binaries (`starkware-libs/proving` @ `cd7bc5f`, R3-A1).
//!
//! The wrapper owns no proving code: it runs `leaf-prover` and
//! `stwo_run_and_prove_recursive_tree` as subprocesses with the `doom` circuit registry, exactly
//! as `spikes/s4/scripts/run_pipeline.sh` does, and `hellproof-leaf-verify` (this repo) as the
//! cheap admission gate. Wall time and peak RSS of every child are measured here and exported.
//!
//! All calls block; the scheduler runs them on `spawn_blocking` threads under a semaphore.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};

use crate::config::{Backend, Config};
use crate::felt::Felt;

/// Wall time and peak RSS of one child process.
#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize)]
pub struct Resources {
    pub duration_ms: f64,
    pub max_rss_bytes: u64,
}

/// A `mkdir`-based mutex shared with anything else proving on the machine (the spikes use the
/// same convention). Held for the whole child process.
struct ExternalLock(Option<PathBuf>);

impl ExternalLock {
    fn acquire(dir: Option<&Path>) -> Self {
        let Some(dir) = dir else {
            return ExternalLock(None);
        };
        loop {
            match fs::create_dir(dir) {
                Ok(()) => return ExternalLock(Some(dir.to_path_buf())),
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
                    std::thread::sleep(Duration::from_secs(5));
                }
                Err(e) => {
                    tracing::warn!("proof lock {}: {e}; continuing without it", dir.display());
                    return ExternalLock(None);
                }
            }
        }
    }
}

impl Drop for ExternalLock {
    fn drop(&mut self) {
        if let Some(dir) = &self.0 {
            let _ = fs::remove_dir(dir);
        }
    }
}

/// Runs a child to completion, sampling its RSS. Returns (stdout, stderr, resources).
fn run_child(mut cmd: Command, lock_dir: Option<&Path>) -> Result<(String, String, Resources)> {
    let _lock = ExternalLock::acquire(lock_dir);
    let started = Instant::now();
    cmd.stdout(Stdio::piped()).stderr(Stdio::piped());
    let child = cmd.spawn().context("cannot spawn")?;
    let pid = child.id();

    let peak = Arc::new(AtomicU64::new(0));
    let sampler_peak = Arc::clone(&peak);
    let stop = Arc::new(AtomicU64::new(0));
    let sampler_stop = Arc::clone(&stop);
    let sampler = std::thread::spawn(move || {
        while sampler_stop.load(Ordering::Relaxed) == 0 {
            if let Some(rss) = rss_bytes(pid) {
                sampler_peak.fetch_max(rss, Ordering::Relaxed);
            }
            std::thread::sleep(Duration::from_millis(250));
        }
    });

    let out = child.wait_with_output().context("child failed")?;
    stop.store(1, Ordering::Relaxed);
    let _ = sampler.join();

    let resources = Resources {
        duration_ms: started.elapsed().as_secs_f64() * 1e3,
        max_rss_bytes: peak.load(Ordering::Relaxed),
    };
    let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
    let stderr = String::from_utf8_lossy(&out.stderr).into_owned();
    if !out.status.success() {
        let code = out.status.code().unwrap_or(-1);
        // Keep the tail of stderr: these binaries log a lot.
        let tail: String = stderr
            .lines()
            .rev()
            .take(15)
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .collect::<Vec<_>>()
            .join("\n");
        bail!("exit {code}: {tail}\n{stdout}");
    }
    Ok((stdout, stderr, resources))
}

/// Resident set size of a live process, via `ps` (portable across macOS and Linux, and correct
/// for a child we do not `wait` on yet).
fn rss_bytes(pid: u32) -> Option<u64> {
    let out = Command::new("ps")
        .args(["-o", "rss=", "-p", &pid.to_string()])
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&out.stdout);
    text.trim().parse::<u64>().ok().map(|kb| kb * 1024)
}

// ---- leaf verification (R8-A1) ---------------------------------------------------------------

#[derive(Debug, Clone, Deserialize)]
pub struct VerifyReport {
    pub ok: bool,
    #[serde(default)]
    pub error: Option<String>,
    #[serde(default)]
    pub verify_ms: f64,
    #[serde(default)]
    pub program_hash: Option<String>,
    #[serde(default)]
    pub output: Option<Vec<String>>,
    #[serde(default)]
    pub trace_log_size: Option<u32>,
}

/// Verifies one submitted segment proof. `expected_cells` is what the submitted preimage hashes
/// to: the proof must commit to exactly those two output cells, which is what binds the preimage
/// (and therefore the leaf's contribution to the root) to the proof.
pub fn verify_segment_proof(
    cfg: &Config,
    proof_path: &Path,
    expected_cells: &[Felt; 2],
) -> Result<VerifyReport> {
    if cfg.backend == Backend::Stub {
        return Ok(VerifyReport {
            ok: true,
            error: None,
            verify_ms: 0.0,
            program_hash: None,
            output: Some(expected_cells.iter().map(|c| c.to_hex()).collect()),
            trace_log_size: Some(20),
        });
    }
    let bin = cfg
        .leaf_verify_bin
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("leaf_verify_bin is not configured"))?;
    let (channel_hash, include_all) = cfg.verify_params();
    let mut cmd = Command::new(bin);
    cmd.arg("--proof")
        .arg(proof_path)
        .arg("--channel-hash")
        .arg(channel_hash)
        .arg("--include-all-preprocessed-columns")
        .arg(include_all.to_string());
    // Verification is cheap but not free; it does not take the circuit-proof lock.
    let report: VerifyReport = match run_child(cmd, None) {
        Ok((stdout, _, _)) => serde_json::from_str(stdout.trim())
            .with_context(|| format!("cannot parse verifier output: {stdout}"))?,
        Err(e) => {
            // Exit code 2 still prints a report on stdout; anything else is an infrastructure
            // problem the caller should retry.
            let msg = e.to_string();
            if let Some(json) = msg.lines().find(|l| l.trim_start().starts_with('{')) {
                serde_json::from_str(json).unwrap_or(VerifyReport {
                    ok: false,
                    error: Some(msg.clone()),
                    verify_ms: 0.0,
                    program_hash: None,
                    output: None,
                    trace_log_size: None,
                })
            } else {
                return Err(e);
            }
        }
    };
    if !report.ok {
        return Ok(report);
    }

    let outputs = report.output.clone().unwrap_or_default();
    if outputs.len() != 2 {
        return Ok(VerifyReport {
            ok: false,
            error: Some(format!(
                "the proof has {} output cells; the leaf format requires exactly 2",
                outputs.len()
            )),
            ..report
        });
    }
    let got: Vec<Felt> = outputs
        .iter()
        .map(|s| Felt::parse(s))
        .collect::<Result<_>>()?;
    if got[0] != expected_cells[0] || got[1] != expected_cells[1] {
        return Ok(VerifyReport {
            ok: false,
            error: Some(format!(
                "the proof's output cells ({}, {}) are not blake2s(encode(output_preimage)) \
                 ({}, {}): the submitted preimage does not belong to this proof",
                got[0].to_hex(),
                got[1].to_hex(),
                expected_cells[0].to_hex(),
                expected_cells[1].to_hex()
            )),
            ..report
        });
    }
    Ok(report)
}

// ---- leaves ------------------------------------------------------------------------------------

/// A leaf proof plus the preimage the bootloader dumped while producing it.
pub struct LeafOutcome {
    pub proof_path: PathBuf,
    pub preimage: Vec<String>,
    pub resources: Resources,
}

/// `leaf-prover`: runs the segment program under the leaf simple bootloader, proves it, verifies
/// that proof inside the leaf circuit and proves the circuit. 22 s / 32.5 GB (S4).
///
/// The written file is a `LeafInput`: the `SerializedLeafProof` with the dumped
/// `output_preimage` injected (decimal felts), which is what the tree consumes.
pub fn prove_leaf(
    cfg: &Config,
    program_executable: &Path,
    hash_function: crate::model::HashFunction,
    args: &[Felt],
    work_dir: &Path,
    out_path: &Path,
) -> Result<LeafOutcome> {
    fs::create_dir_all(work_dir)?;
    let args_path = work_dir.join("args.json");
    let hexes: Vec<String> = args.iter().map(|a| a.to_hex()).collect();
    fs::write(&args_path, serde_json::to_vec(&hexes)?)?;
    let preimage_path = work_dir.join("preimage.json");
    let raw_path = work_dir.join("leaf.raw.json");

    if cfg.backend == Backend::Stub {
        // Deterministic placeholder: enough for the queue, batching and API tests.
        let preimage: Vec<String> = hexes
            .iter()
            .map(|h| Felt::parse(h).unwrap().to_hex())
            .collect();
        let leaf = serde_json::json!({
            "circuit_preprocessed_root": vec!["0x0"; 8],
            "circuit_hash": vec!["0x0"; 8],
            "proof": "",
            "output_preimage": preimage,
            "stub": true,
        });
        if let Some(parent) = out_path.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(out_path, serde_json::to_vec(&leaf)?)?;
        return Ok(LeafOutcome {
            proof_path: out_path.to_path_buf(),
            preimage,
            resources: Resources {
                duration_ms: 0.0,
                max_rss_bytes: 0,
            },
        });
    }

    let bootloader = cfg
        .leaf_bootloader
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("leaf_bootloader is not configured"))?;
    let registry = cfg
        .registry
        .path
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("registry.path is not configured"))?;
    let leaf_prover = cfg
        .leaf_prover_bin
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("leaf_prover_bin is not configured"))?;

    // `PrivacySimpleBootloaderInput` (S0 §"bootloader task input", S4 §1).
    let bl_input = serde_json::json!({
        "tasks": [{
            "type": "Cairo1Executable",
            "path": program_executable,
            "user_args_file": args_path,
            "program_hash_function": hash_function.as_str(),
        }],
        "fact_topologies_path": serde_json::Value::Null,
        "single_page": true,
        "output_preimage_dump_path": preimage_path,
    });
    let bl_path = work_dir.join("bl_input.json");
    fs::write(&bl_path, serde_json::to_vec_pretty(&bl_input)?)?;

    let mut cmd = Command::new(leaf_prover);
    cmd.arg("--program")
        .arg(bootloader)
        .arg("--program_input")
        .arg(&bl_path)
        .arg("--circuit_registry_json")
        .arg(registry)
        .arg("--output_path")
        .arg(&raw_path);
    let (_, _, resources) = run_child(cmd, cfg.proof_lock_dir.as_deref())?;

    // Inject the dumped preimage, as `spikes/s4/scripts/inject_preimage.py` does: the tree wants
    // decimal felts under `output_preimage`.
    let preimage_hex: Vec<String> = serde_json::from_slice(&fs::read(&preimage_path)?)
        .context("cannot read the dumped output preimage")?;
    let mut leaf: serde_json::Value = serde_json::from_slice(&fs::read(&raw_path)?)?;
    let decimals: Vec<String> = preimage_hex
        .iter()
        .map(|h| -> Result<String> { Ok(felt_to_decimal(&Felt::parse(h)?)) })
        .collect::<Result<_>>()?;
    leaf["output_preimage"] = serde_json::json!(decimals);
    if let Some(parent) = out_path.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::write(out_path, serde_json::to_vec(&leaf)?)?;

    Ok(LeafOutcome {
        proof_path: out_path.to_path_buf(),
        preimage: preimage_hex
            .iter()
            .map(|h| Felt::parse(h).map(|f| f.to_hex()))
            .collect::<Result<_>>()?,
        resources,
    })
}

/// Decimal rendering of a felt (what the tree's `LeafInput` expects).
fn felt_to_decimal(f: &Felt) -> String {
    // Repeated division by 10^9 over the eight little-endian limbs.
    let mut limbs = f.0;
    let mut out: Vec<String> = vec![];
    loop {
        let mut rem: u64 = 0;
        let mut nonzero = false;
        for limb in limbs.iter_mut().rev() {
            let cur = (rem << 32) | (*limb as u64);
            *limb = (cur / 1_000_000_000) as u32;
            rem = cur % 1_000_000_000;
            if *limb != 0 {
                nonzero = true;
            }
        }
        if nonzero {
            out.push(format!("{rem:09}"));
        } else {
            out.push(format!("{rem}"));
            break;
        }
    }
    out.reverse();
    out.concat()
}

// ---- folding -----------------------------------------------------------------------------------

pub struct FoldOutcome {
    pub root_path: PathBuf,
    pub packed_path: PathBuf,
    pub program_output: serde_json::Value,
    pub root_felt_count: usize,
    pub resources: Resources,
}

/// `stwo_run_and_prove_recursive_tree`: folds the leaves left to right into one root proof.
/// N − 1 reductions (1 for N = 1: the leaf is folded with itself), ~30 s each (S4).
pub fn fold_batch(cfg: &Config, leaf_paths: &[PathBuf], out_dir: &Path) -> Result<FoldOutcome> {
    fs::create_dir_all(out_dir)?;
    if leaf_paths.is_empty() {
        bail!("cannot fold an empty batch");
    }
    let leaves_path = out_dir.join("leaves.json");
    fs::write(
        &leaves_path,
        serde_json::to_vec(&serde_json::json!({ "leaves": leaf_paths }))?,
    )?;
    let root_path = out_dir.join("root.proof");
    let packed_path = out_dir.join("packed_output.json");
    let program_output_path = out_dir.join("program_output.json");

    if cfg.backend == Backend::Stub {
        let felts: Vec<String> = (0..8).map(|i| format!("0x{i:x}")).collect();
        fs::write(&root_path, serde_json::to_vec(&felts)?)?;
        let packed = serde_json::json!({
            "Composite": {
                "circuit_hash": vec!["0x0"; 8],
                "subtasks": leaf_paths.iter().map(|_| serde_json::json!({"Plain": {"output_preimage": []}})).collect::<Vec<_>>(),
            }
        });
        fs::write(&packed_path, serde_json::to_vec(&packed)?)?;
        let program_output = serde_json::json!([0, 0, 0, 0, 0, 0, 0, 0]);
        fs::write(&program_output_path, serde_json::to_vec(&program_output)?)?;
        return Ok(FoldOutcome {
            root_path,
            packed_path,
            program_output,
            root_felt_count: felts.len(),
            resources: Resources::default(),
        });
    }

    let registry = cfg
        .registry
        .path
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("registry.path is not configured"))?;
    let tree_bin = cfg
        .tree_bin
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("tree_bin is not configured"))?;

    let mut cmd = Command::new(tree_bin);
    cmd.arg("--program_input")
        .arg(&leaves_path)
        .arg("--circuit_registry_json")
        .arg(registry)
        .arg("--proof_path")
        .arg(&root_path)
        .arg("--program_output")
        .arg(&program_output_path)
        .arg("--packed_output_path")
        .arg(&packed_path);
    let (_, _, resources) = run_child(cmd, cfg.proof_lock_dir.as_deref())?;

    let root: Vec<String> = serde_json::from_slice(&fs::read(&root_path)?)
        .context("the tree did not write a felt array")?;
    let program_output: serde_json::Value =
        serde_json::from_slice(&fs::read(&program_output_path)?)?;
    Ok(FoldOutcome {
        root_path,
        packed_path,
        program_output,
        root_felt_count: root.len(),
        resources,
    })
}

/// sha256 of the registry file — part of every leaf key, so a registry change invalidates the
/// leaf cache instead of silently mixing circuits.
pub fn registry_hash(cfg: &Config) -> String {
    use sha2::{Digest, Sha256};
    match cfg.registry.path.as_ref().and_then(|p| fs::read(p).ok()) {
        Some(bytes) => hex::encode(Sha256::digest(bytes)),
        None => "no-registry".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decimal_rendering_matches_hex() {
        assert_eq!(felt_to_decimal(&Felt::parse("0x0").unwrap()), "0");
        assert_eq!(felt_to_decimal(&Felt::parse("0x1").unwrap()), "1");
        assert_eq!(felt_to_decimal(&Felt::parse("0xfa").unwrap()), "250");
        assert_eq!(
            felt_to_decimal(&Felt::parse("0x10000000000000000").unwrap()),
            "18446744073709551616"
        );
        let big = "3618502788666131213697322783095070105623107215331596699973092056135872020480";
        assert_eq!(felt_to_decimal(&Felt::parse(big).unwrap()), big);
    }
}
