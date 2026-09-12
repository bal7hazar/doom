// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0
//! `hellproof-leaf-verify` — the cheap admission gate of the wrapper service (R8-A1).
//!
//! The browser (`prover/wasm`) produces a **bincode-serialized extended `CairoProof`** for each
//! segment. Before the wrapper spends 22 s and 32.5 GB on a leaf circuit proof, it runs this
//! binary on the submitted proof: `cairo_air::verifier::verify_cairo_ex` takes ~0.05 s and tells
//! us whether the proof is real, which program it proves, and what that program output.
//!
//! Output: one JSON object on stdout. Exit code 0 = accepted, 2 = rejected (with `error`),
//! 1 = usage/IO problem.
//!
//! Note on formats (measured against the pinned monorepo, `cd7bc5f`): the **cairo-serde felt
//! stream is one-way**. `CairoProof` derives `CairoSerialize` but not `CairoDeserialize`, and
//! `cairo_air::utils::deserialize_proof_from_file` panics with "Deserialization from a
//! Cairo-serialized proof is not supported" for `ProofFormat::CairoSerde`. A proof submitted as
//! felts therefore cannot be verified here — only the bincode form can. The wrapper reflects that
//! in its API (see `prover/wrapper/README.md`).

use std::path::PathBuf;
use std::process::ExitCode;
use std::time::Instant;

use anyhow::{Context, Result, anyhow, bail};
use cairo_air::CairoProof;
use cairo_air::utils::get_verification_output;
use cairo_air::verifier::verify_cairo_ex;
use clap::Parser;
use serde::de::DeserializeOwned;
use stwo::core::channel::MerkleChannel;
use stwo::core::vcs_lifted::blake2_merkle::{Blake2sM31MerkleChannel, Blake2sMerkleChannel};
use stwo::core::vcs_lifted::merkle_hasher::MerkleHasherLifted;

#[derive(Parser, Debug)]
#[command(
    about = "Verify a bincode-serialized Cairo segment proof and print its public output as JSON"
)]
struct Cli {
    /// Path to the bincode extended `CairoProof` (what `prover/wasm`'s `prove` returns).
    #[arg(long)]
    proof: PathBuf,
    /// Channel hash the proof was produced with. The leaf format uses `blake2s_m31`.
    #[arg(long, default_value = "blake2s_m31")]
    channel_hash: String,
    /// Must match the prover parameters (`include_all_preprocessed_columns`); the leaf format
    /// sets it to true.
    #[arg(long, default_value_t = true, action = clap::ArgAction::Set)]
    include_all_preprocessed_columns: bool,
    /// Optional: fail unless the program hash in the proof's public memory equals this felt
    /// (hex or decimal). This is what pins *which* program the segment ran.
    #[arg(long)]
    expect_program_hash: Option<String>,
}

/// What the wrapper reads back.
#[derive(serde::Serialize)]
struct Report {
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
    verify_ms: f64,
    /// Blake2s program hash of the proven program, from the public memory.
    #[serde(skip_serializing_if = "Option::is_none")]
    program_hash: Option<String>,
    /// The program's output cells, as felts. The leaf format requires exactly 2 (the 256-bit
    /// digest of the bootloader output preimage, 128 bits per cell).
    #[serde(skip_serializing_if = "Option::is_none")]
    output: Option<Vec<String>>,
    /// `trace_log_size` the registry's leaf verifier is selected by
    /// (`trace_lifting_log_size - log_blowup_factor`).
    #[serde(skip_serializing_if = "Option::is_none")]
    trace_log_size: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    proof_bytes: Option<usize>,
}

fn verify_generic<MC>(bytes: &[u8], include_all: bool, expect_program_hash: Option<&str>) -> Result<Report>
where
    MC: MerkleChannel,
    MC::H: MerkleHasherLifted + DeserializeOwned,
{
    let proof: CairoProof<MC::H> =
        bincode::deserialize(bytes).context("not a bincode extended CairoProof")?;

    let cfg = proof.extended_stark_proof.proof.0.config;
    let trace_log_size = cfg.trace_lifting_log_size - cfg.fri_config.log_blowup_factor;
    let vo = get_verification_output(&proof.claim.public_data.public_memory);
    let program_hash = format!("0x{:x}", vo.program_hash);
    let output: Vec<String> = vo.output.iter().map(|f| format!("0x{f:x}")).collect();

    if let Some(expected) = expect_program_hash {
        let expected = parse_felt(expected)?;
        if expected != vo.program_hash {
            bail!("program hash mismatch: proof has {program_hash}, expected 0x{expected:x}");
        }
    }

    let t = Instant::now();
    verify_cairo_ex::<MC>(proof.into(), include_all).map_err(|e| anyhow!("{e}"))?;
    let verify_ms = t.elapsed().as_secs_f64() * 1e3;

    Ok(Report {
        ok: true,
        error: None,
        verify_ms,
        program_hash: Some(program_hash),
        output: Some(output),
        trace_log_size: Some(trace_log_size),
        proof_bytes: Some(bytes.len()),
    })
}

fn parse_felt(s: &str) -> Result<starknet_ff::FieldElement> {
    let s = s.trim();
    if let Some(hex) = s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")) {
        starknet_ff::FieldElement::from_hex_be(hex).context("not a felt (hex)")
    } else {
        starknet_ff::FieldElement::from_dec_str(s).context("not a felt (decimal)")
    }
}

fn run(cli: &Cli) -> Result<Report> {
    let bytes = std::fs::read(&cli.proof)
        .with_context(|| format!("cannot read {}", cli.proof.display()))?;
    let expect = cli.expect_program_hash.as_deref();
    match cli.channel_hash.as_str() {
        "blake2s_m31" | "Blake2sM31" => {
            verify_generic::<Blake2sM31MerkleChannel>(&bytes, cli.include_all_preprocessed_columns, expect)
        }
        "blake2s" | "Blake2s" => {
            verify_generic::<Blake2sMerkleChannel>(&bytes, cli.include_all_preprocessed_columns, expect)
        }
        other => bail!("unsupported channel hash {other} (blake2s_m31 | blake2s)"),
    }
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    match run(&cli) {
        Ok(report) => {
            println!("{}", serde_json::to_string(&report).unwrap());
            ExitCode::SUCCESS
        }
        Err(err) => {
            let report = Report {
                ok: false,
                error: Some(format!("{err:#}")),
                verify_ms: 0.0,
                program_hash: None,
                output: None,
                trace_log_size: None,
                proof_bytes: None,
            };
            println!("{}", serde_json::to_string(&report).unwrap());
            // 2 = the proof was read but rejected; the wrapper turns this into a run rejection.
            ExitCode::from(2)
        }
    }
}
