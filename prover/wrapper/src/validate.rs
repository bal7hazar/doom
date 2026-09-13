// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0

//! Input validation — everything that can reject a submission before a single byte of proving
//! work is scheduled (R8-A1, "reject immediately").

use anyhow::{bail, Result};
use base64::Engine;
use sha2::{Digest, Sha256};

use crate::config::{Config, LeafMode, ProgramEntry};
use crate::felt::{leaf_output_words, output_cells_from_words, Felt};
use crate::model::{HashFunction, ProofBlob, ProofFormat, RunSubmission, SegmentSubmission};

/// A submission that passed validation: felts parsed, proof bytes decoded, leaf keys computed.
#[derive(Debug)]
pub struct ValidSubmission {
    pub run_id: String,
    pub program: ProgramEntry,
    pub hash_function: HashFunction,
    pub segments: Vec<ValidSegment>,
    /// sha256 over the canonical submission (program, segments, args, preimages, proofs).
    pub submission_hash: String,
}

#[derive(Debug)]
pub struct ValidSegment {
    pub index: u32,
    pub args: Vec<Felt>,
    pub preimage: Vec<Felt>,
    /// The two output cells, recomputed from the preimage (and checked against the client's
    /// `public_outputs` when it sent them).
    pub output_cells: [Felt; 2],
    pub proof_format: ProofFormat,
    /// Decoded proof bytes for `bincode_b64`; the raw felt JSON otherwise.
    pub proof_bytes: Vec<u8>,
    pub leaf_key: String,
}

/// What makes two segments the same leaf, which depends on how the leaf is produced.
#[derive(Debug, Clone, Copy)]
pub enum LeafIdentity<'a> {
    /// `leaf_mode = "rerun"`: the server replays the segment, so the same registry, program and
    /// **arguments** always yield the same leaf proof.
    Args(&'a [Felt]),
    /// `leaf_mode = "from_proof"`: the server folds whatever proof was submitted, and there is no
    /// canonical proof for a segment (two runs of the same code give two different, equally valid
    /// proofs). What a leaf contributes to the root is its **output preimage** — the tree hashes
    /// exactly that, and the fold re-verifies the leaf proof in circuit — so two leaves with the
    /// same preimage are interchangeable, and that is the cache key.
    Preimage(&'a [Felt]),
}

/// Identity of a leaf, and therefore its cache key (R8-A3, idempotence by content hash).
pub fn leaf_key(
    registry_hash: &str,
    program_id: &str,
    program_hash: Option<&str>,
    hash_function: HashFunction,
    identity: LeafIdentity<'_>,
) -> String {
    let (tag, felts) = match identity {
        LeafIdentity::Args(a) => ("args", a),
        LeafIdentity::Preimage(p) => ("preimage", p),
    };
    let mut h = Sha256::new();
    h.update(b"hellproof-leaf-v1\0");
    h.update(registry_hash.as_bytes());
    h.update(b"\0");
    h.update(program_id.as_bytes());
    h.update(b"\0");
    h.update(program_hash.unwrap_or("").as_bytes());
    h.update(b"\0");
    h.update(hash_function.as_str().as_bytes());
    h.update(b"\0");
    h.update(tag.as_bytes());
    h.update(b"\0");
    for a in felts {
        h.update(a.to_hex().as_bytes());
        h.update(b",");
    }
    hex::encode(h.finalize())
}

pub fn validate(sub: &RunSubmission, cfg: &Config, registry_hash: &str) -> Result<ValidSubmission> {
    let program = cfg
        .program(&sub.program)
        .ok_or_else(|| anyhow::anyhow!("unknown program `{}`", sub.program))?
        .clone();

    // The hash function decides `output_preimage[0]`, so the client and the server must agree on
    // it before anything is proven.
    let hash_function = sub.program_hash_function.unwrap_or(program.hash_function);
    if hash_function != program.hash_function {
        bail!(
            "program `{}` is configured for program_hash_function `{}`, not `{}`",
            program.id,
            program.hash_function.as_str(),
            hash_function.as_str()
        );
    }

    if sub.segments.is_empty() {
        bail!("a run needs at least one segment");
    }
    if sub.segments.len() > cfg.max_segments_per_run {
        bail!(
            "{} segments exceeds the limit of {}",
            sub.segments.len(),
            cfg.max_segments_per_run
        );
    }
    if let Some(id) = &sub.run_id {
        if id.is_empty()
            || id.len() > 64
            || !id
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
        {
            bail!("run_id must be 1..64 chars of [A-Za-z0-9_-]");
        }
    }
    if let Some(p) = &sub.player {
        Felt::parse(p).map_err(|e| anyhow::anyhow!("player is not a felt: {e}"))?;
    }

    let mut segments = Vec::with_capacity(sub.segments.len());
    let mut prev_h_out: Option<Felt> = None;
    for (i, seg) in sub.segments.iter().enumerate() {
        if seg.index as usize != i {
            bail!(
                "segment {i} has index {} (indices must be 0..n contiguous and ordered)",
                seg.index
            );
        }
        let valid = validate_segment(seg, cfg, &program, hash_function, registry_hash)?;

        // Chain check: `h_in[i+1] == h_out[i]` (PLAN Phase 3 task 3). The preimage is
        // `[program_hash, h_in, h_out, …]` for our segment programs; only enforced when the
        // preimage is long enough to carry the chain.
        if valid.preimage.len() >= 3 {
            if let Some(prev) = prev_h_out {
                if valid.preimage[1] != prev {
                    bail!(
                        "segment {i}: h_in {} does not continue the previous segment's h_out {}",
                        valid.preimage[1].to_hex(),
                        prev.to_hex()
                    );
                }
            }
            prev_h_out = Some(valid.preimage[2]);
        }
        segments.push(valid);
    }

    let mut h = Sha256::new();
    h.update(b"hellproof-run-v1\0");
    h.update(sub.program.as_bytes());
    h.update(hash_function.as_str().as_bytes());
    for s in &segments {
        h.update(s.leaf_key.as_bytes());
        for f in &s.preimage {
            h.update(f.to_hex().as_bytes());
        }
        h.update(Sha256::digest(&s.proof_bytes));
    }
    let submission_hash = hex::encode(h.finalize());

    Ok(ValidSubmission {
        run_id: sub.run_id.clone().unwrap_or_else(crate::new_id),
        program,
        hash_function,
        segments,
        submission_hash,
    })
}

fn validate_segment(
    seg: &SegmentSubmission,
    cfg: &Config,
    program: &ProgramEntry,
    hash_function: HashFunction,
    registry_hash: &str,
) -> Result<ValidSegment> {
    let proof_bytes = decode_proof_bytes(&seg.proof, seg.index)?;
    let shaped = shape_segment(
        seg.index,
        &seg.args,
        &seg.output_preimage,
        &seg.public_outputs,
        seg.proof.format,
        proof_bytes,
        cfg,
    )?;
    let leaf_key = bind_segment_to_program(
        seg.index,
        &shaped.args,
        &shaped.preimage,
        cfg,
        program,
        hash_function,
        registry_hash,
    )?;
    Ok(ValidSegment {
        index: seg.index,
        args: shaped.args,
        preimage: shaped.preimage,
        output_cells: shaped.output_cells,
        proof_format: seg.proof.format,
        proof_bytes: shaped.proof_bytes,
        leaf_key,
    })
}

/// Decodes a submitted proof blob into bytes, whatever its wire format. Shared by the whole-run
/// `POST` and the resumable `PUT` endpoint.
pub fn decode_proof_bytes(proof: &ProofBlob, index: u32) -> Result<Vec<u8>> {
    match proof.format {
        ProofFormat::BincodeB64 => {
            let data = proof
                .data
                .as_ref()
                .ok_or_else(|| anyhow::anyhow!("segment {index}: proof.data is required"))?;
            base64::engine::general_purpose::STANDARD
                .decode(data)
                .map_err(|e| anyhow::anyhow!("segment {index}: proof.data is not base64: {e}"))
        }
        ProofFormat::CairoSerdeFelts => {
            let felts = proof
                .felts
                .as_ref()
                .ok_or_else(|| anyhow::anyhow!("segment {index}: proof.felts is required"))?;
            if felts.is_empty() {
                bail!("segment {index}: proof.felts is empty");
            }
            // Parse them so a malformed stream is rejected here, and store the canonical form.
            let parsed: Vec<Felt> = felts
                .iter()
                .map(|f| Felt::parse(f))
                .collect::<Result<_>>()
                .map_err(|e| anyhow::anyhow!("segment {index}: bad proof felt: {e}"))?;
            let hexes: Vec<String> = parsed.iter().map(|f| f.to_hex()).collect();
            Ok(serde_json::to_vec(&hexes)?)
        }
    }
}

/// A segment shaped and checked without knowing which program it belongs to.
pub struct ShapedSegment {
    pub args: Vec<Felt>,
    pub preimage: Vec<Felt>,
    pub output_cells: [Felt; 2],
    pub proof_bytes: Vec<u8>,
}

/// Everything about one segment that can be checked before its program is known: felt parsing,
/// the output-cells/preimage cross-check, the proof-format policy and the size limit. This is
/// what `PUT /v1/runs/{id}/segments/{index}` runs immediately (the resumable upload protocol does
/// not require a program until `/complete`); the whole-run `POST` runs it too, as the first half
/// of [`validate_segment`].
#[allow(clippy::too_many_arguments)]
pub fn shape_segment(
    index: u32,
    args: &[String],
    output_preimage: &[String],
    public_outputs: &[String],
    proof_format: ProofFormat,
    proof_bytes: Vec<u8>,
    cfg: &Config,
) -> Result<ShapedSegment> {
    // `args` are what the server replays in `rerun` mode; in `from_proof` mode it folds the
    // submitted proof and never needs them (D19).
    if args.is_empty() && cfg.leaf_mode == LeafMode::Rerun {
        bail!("segment {index}: no args (required with leaf_mode = \"rerun\")");
    }
    let args: Vec<Felt> = args
        .iter()
        .map(|a| Felt::parse(a))
        .collect::<Result<_>>()
        .map_err(|e| anyhow::anyhow!("segment {index}: bad arg: {e}"))?;

    if output_preimage.is_empty() {
        bail!("segment {index}: output_preimage is required (it is what the tree hashes)");
    }
    let preimage: Vec<Felt> = output_preimage
        .iter()
        .map(|a| Felt::parse(a))
        .collect::<Result<_>>()
        .map_err(|e| anyhow::anyhow!("segment {index}: bad output_preimage felt: {e}"))?;

    // The digest the leaf circuit will output, recomputed from the preimage.
    let words = leaf_output_words(&preimage);
    let output_cells = output_cells_from_words(&words);
    if !public_outputs.is_empty() {
        let claimed: Vec<Felt> = public_outputs
            .iter()
            .map(|a| Felt::parse(a))
            .collect::<Result<_>>()
            .map_err(|e| anyhow::anyhow!("segment {index}: bad public_outputs felt: {e}"))?;
        if claimed.len() != 2 {
            bail!(
                "segment {index}: the leaf format requires exactly 2 output cells, got {}",
                claimed.len()
            );
        }
        if claimed[0] != output_cells[0] || claimed[1] != output_cells[1] {
            bail!("segment {index}: public_outputs do not match blake2s(encode(output_preimage))");
        }
    }

    if cfg.require_verifiable_proof && !proof_format.verifiable() {
        bail!(
            "segment {index}: proof format `{}` cannot be verified (the cairo-serde felt stream \
             is one-way at cd7bc5f); submit the bincode CairoProof",
            proof_format.as_str()
        );
    }
    // In `from_proof` mode the proof is not merely checked, it is folded — and only the bincode
    // form can be read back into a `CairoProof` at all, whatever `require_verifiable_proof` says.
    if cfg.leaf_mode == LeafMode::FromProof && !proof_format.verifiable() {
        bail!(
            "segment {index}: proof format `{}` cannot be folded (leaf_mode = \"from_proof\" \
             needs the bincode CairoProof); set leaf_mode = \"rerun\" to accept it",
            proof_format.as_str()
        );
    }
    if proof_bytes.len() > cfg.max_proof_bytes {
        bail!(
            "segment {index}: proof is {} bytes, over the {} byte limit",
            proof_bytes.len(),
            cfg.max_proof_bytes
        );
    }

    Ok(ShapedSegment {
        args,
        preimage,
        output_cells,
        proof_bytes,
    })
}

/// The other half of [`validate_segment`]: what needs the program (pinned program hash and the
/// leaf cache key). Applied immediately for a whole-run `POST`; deferred to `/complete` for a
/// resumable upload, where the program is not known until then.
pub fn bind_segment_to_program(
    index: u32,
    args: &[Felt],
    preimage: &[Felt],
    cfg: &Config,
    program: &ProgramEntry,
    hash_function: HashFunction,
    registry_hash: &str,
) -> Result<String> {
    // `preimage[0]` is the task's program hash: it pins which program ran.
    if let Some(expected) = &program.program_hash {
        let expected = Felt::parse(expected)?;
        if preimage[0] != expected {
            bail!(
                "segment {index}: output_preimage[0] = {} is not the pinned program hash {} of \
                 `{}`",
                preimage[0].to_hex(),
                expected.to_hex(),
                program.id
            );
        }
    }
    Ok(leaf_key(
        registry_hash,
        &program.id,
        program.program_hash.as_deref(),
        hash_function,
        match cfg.leaf_mode {
            LeafMode::Rerun => LeafIdentity::Args(args),
            LeafMode::FromProof => LeafIdentity::Preimage(preimage),
        },
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::ProofBlob;

    fn cfg() -> Config {
        let mut c = Config::default();
        c.programs.push(ProgramEntry {
            id: "segment_stub".into(),
            executable: "/dev/null".into(),
            program_hash: None,
            hash_function: HashFunction::Blake,
        });
        c
    }

    fn seg(index: u32, h_in: &str, h_out: &str) -> SegmentSubmission {
        SegmentSubmission {
            index,
            args: vec![h_in.into(), "0xfa".into()],
            output_preimage: vec![
                "0x5".into(),
                h_in.into(),
                h_out.into(),
                "0xfa".into(),
                "0x0".into(),
            ],
            public_outputs: vec![],
            proof: ProofBlob {
                format: ProofFormat::BincodeB64,
                data: Some(base64::engine::general_purpose::STANDARD.encode(b"proof bytes")),
                felts: None,
            },
        }
    }

    fn run(segments: Vec<SegmentSubmission>) -> RunSubmission {
        RunSubmission {
            run_id: None,
            player: None,
            program: "segment_stub".into(),
            program_hash_function: None,
            solo: false,
            segments,
            expected_segments: None,
        }
    }

    #[test]
    fn accepts_a_chained_run() {
        let sub = run(vec![seg(0, "0x1", "0x2"), seg(1, "0x2", "0x3")]);
        let v = validate(&sub, &cfg(), "reg").unwrap();
        assert_eq!(v.segments.len(), 2);
        assert_ne!(v.segments[0].leaf_key, v.segments[1].leaf_key);
    }

    #[test]
    fn rejects_a_broken_chain() {
        let sub = run(vec![seg(0, "0x1", "0x2"), seg(1, "0x9", "0x3")]);
        let err = validate(&sub, &cfg(), "reg").unwrap_err().to_string();
        assert!(err.contains("does not continue"), "{err}");
    }

    #[test]
    fn rejects_out_of_order_indices() {
        let sub = run(vec![seg(1, "0x1", "0x2")]);
        assert!(validate(&sub, &cfg(), "reg")
            .unwrap_err()
            .to_string()
            .contains("indices"));
    }

    #[test]
    fn rejects_unknown_program() {
        let mut sub = run(vec![seg(0, "0x1", "0x2")]);
        sub.program = "doom_run".into();
        assert!(validate(&sub, &cfg(), "reg")
            .unwrap_err()
            .to_string()
            .contains("unknown program"));
    }

    #[test]
    fn rejects_felt_only_proofs_by_default() {
        let mut sub = run(vec![seg(0, "0x1", "0x2")]);
        sub.segments[0].proof = ProofBlob {
            format: ProofFormat::CairoSerdeFelts,
            data: None,
            felts: Some(vec!["0x1".into(), "0x2".into()]),
        };
        let err = validate(&sub, &cfg(), "reg").unwrap_err().to_string();
        assert!(err.contains("cannot be verified"), "{err}");

        // Waiving verification is not enough to *fold* a felt stream: it cannot be deserialized.
        let mut c = cfg();
        c.require_verifiable_proof = false;
        let err = validate(&sub, &c, "reg").unwrap_err().to_string();
        assert!(err.contains("cannot be folded"), "{err}");

        c.leaf_mode = LeafMode::Rerun;
        assert!(validate(&sub, &c, "reg").is_ok());
    }

    #[test]
    fn args_are_optional_in_from_proof_mode_and_required_in_rerun() {
        let mut sub = run(vec![seg(0, "0x1", "0x2")]);
        sub.segments[0].args.clear();
        assert!(
            validate(&sub, &cfg(), "reg").is_ok(),
            "from_proof folds the submitted proof, it never replays the segment"
        );

        let mut c = cfg();
        c.leaf_mode = LeafMode::Rerun;
        let err = validate(&sub, &c, "reg").unwrap_err().to_string();
        assert!(err.contains("no args"), "{err}");
    }

    #[test]
    fn rejects_public_outputs_that_do_not_match_the_preimage() {
        let mut sub = run(vec![seg(0, "0x1", "0x2")]);
        sub.segments[0].public_outputs = vec!["0x1".into(), "0x2".into()];
        let err = validate(&sub, &cfg(), "reg").unwrap_err().to_string();
        assert!(err.contains("do not match"), "{err}");
    }

    #[test]
    fn accepts_public_outputs_recomputed_from_the_preimage() {
        let mut sub = run(vec![seg(0, "0x1", "0x2")]);
        let v = validate(&sub, &cfg(), "reg").unwrap();
        let cells = v.segments[0].output_cells;
        sub.segments[0].public_outputs = vec![cells[0].to_hex(), cells[1].to_hex()];
        assert!(validate(&sub, &cfg(), "reg").is_ok());
    }

    #[test]
    fn rejects_a_wrong_pinned_program_hash() {
        let mut c = cfg();
        c.programs[0].program_hash = Some("0x7".into());
        let sub = run(vec![seg(0, "0x1", "0x2")]);
        let err = validate(&sub, &c, "reg").unwrap_err().to_string();
        assert!(err.contains("pinned program hash"), "{err}");
    }

    #[test]
    fn rejects_oversized_runs_and_proofs() {
        let mut c = cfg();
        c.max_segments_per_run = 1;
        let sub = run(vec![seg(0, "0x1", "0x2"), seg(1, "0x2", "0x3")]);
        assert!(validate(&sub, &c, "reg")
            .unwrap_err()
            .to_string()
            .contains("exceeds the limit"));

        let mut c = cfg();
        c.max_proof_bytes = 4;
        let sub = run(vec![seg(0, "0x1", "0x2")]);
        assert!(validate(&sub, &c, "reg")
            .unwrap_err()
            .to_string()
            .contains("over the"));
    }

    #[test]
    fn leaf_key_is_content_addressed() {
        let one = [Felt::parse("0x1").unwrap()];
        let args = LeafIdentity::Args(&one);
        let a = leaf_key("reg", "p", None, HashFunction::Blake, args);
        let b = leaf_key(
            "reg",
            "p",
            None,
            HashFunction::Blake,
            LeafIdentity::Args(&[Felt::parse("1").unwrap()]),
        );
        let c = leaf_key("reg2", "p", None, HashFunction::Blake, args);
        let d = leaf_key("reg", "p", None, HashFunction::Poseidon, args);
        let e = leaf_key(
            "reg",
            "p",
            None,
            HashFunction::Blake,
            LeafIdentity::Preimage(&one),
        );
        assert_eq!(a, b, "the same args in any notation are the same leaf");
        assert_ne!(a, c, "a different registry is a different circuit");
        assert_ne!(
            a, d,
            "a different program hash function is a different leaf output"
        );
        assert_ne!(a, e, "the two leaf modes never share a cache entry");
    }

    #[test]
    fn rejects_a_hash_function_the_program_is_not_configured_for() {
        let mut sub = run(vec![seg(0, "0x1", "0x2")]);
        sub.program_hash_function = Some(HashFunction::Poseidon);
        let err = validate(&sub, &cfg(), "reg").unwrap_err().to_string();
        assert!(err.contains("program_hash_function"), "{err}");

        // Configure the program for poseidon and the same submission is accepted.
        let mut c = cfg();
        c.programs[0].hash_function = HashFunction::Poseidon;
        assert!(validate(&sub, &c, "reg").is_ok());
    }
}
