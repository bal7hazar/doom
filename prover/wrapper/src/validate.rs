// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0

//! Input validation — everything that can reject a submission before a single byte of proving
//! work is scheduled (R8-A1, "reject immediately").

use anyhow::{Result, bail};
use base64::Engine;
use sha2::{Digest, Sha256};

use crate::config::{Config, ProgramEntry};
use crate::felt::{Felt, leaf_output_words, output_cells_from_words};
use crate::model::{ProofFormat, RunSubmission, SegmentSubmission};

/// A submission that passed validation: felts parsed, proof bytes decoded, leaf keys computed.
#[derive(Debug)]
pub struct ValidSubmission {
    pub run_id: String,
    pub program: ProgramEntry,
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

/// Identity of a leaf: the same registry, program and arguments always yield the same leaf proof,
/// so this is the cache key (R8-A3, idempotence by content hash).
pub fn leaf_key(registry_hash: &str, program_id: &str, program_hash: Option<&str>, args: &[Felt]) -> String {
    let mut h = Sha256::new();
    h.update(b"hellproof-leaf-v1\0");
    h.update(registry_hash.as_bytes());
    h.update(b"\0");
    h.update(program_id.as_bytes());
    h.update(b"\0");
    h.update(program_hash.unwrap_or("").as_bytes());
    h.update(b"\0");
    for a in args {
        h.update(a.to_hex().as_bytes());
        h.update(b",");
    }
    hex::encode(h.finalize())
}

pub fn validate(
    sub: &RunSubmission,
    cfg: &Config,
    registry_hash: &str,
) -> Result<ValidSubmission> {
    let program = cfg
        .program(&sub.program)
        .ok_or_else(|| anyhow::anyhow!("unknown program `{}`", sub.program))?
        .clone();

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
        if id.is_empty() || id.len() > 64 || !id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_') {
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
            bail!("segment {i} has index {} (indices must be 0..n contiguous and ordered)", seg.index);
        }
        let valid = validate_segment(seg, cfg, &program, registry_hash)?;

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
        segments,
        submission_hash,
    })
}

fn validate_segment(
    seg: &SegmentSubmission,
    cfg: &Config,
    program: &ProgramEntry,
    registry_hash: &str,
) -> Result<ValidSegment> {
    if seg.args.is_empty() {
        bail!("segment {}: no args", seg.index);
    }
    let args: Vec<Felt> = seg
        .args
        .iter()
        .map(|a| Felt::parse(a))
        .collect::<Result<_>>()
        .map_err(|e| anyhow::anyhow!("segment {}: bad arg: {e}", seg.index))?;

    if seg.output_preimage.is_empty() {
        bail!("segment {}: output_preimage is required (it is what the tree hashes)", seg.index);
    }
    let preimage: Vec<Felt> = seg
        .output_preimage
        .iter()
        .map(|a| Felt::parse(a))
        .collect::<Result<_>>()
        .map_err(|e| anyhow::anyhow!("segment {}: bad output_preimage felt: {e}", seg.index))?;

    // `preimage[0]` is the task's program hash: it pins which program ran.
    if let Some(expected) = &program.program_hash {
        let expected = Felt::parse(expected)?;
        if preimage[0] != expected {
            bail!(
                "segment {}: output_preimage[0] = {} is not the pinned program hash {} of `{}`",
                seg.index,
                preimage[0].to_hex(),
                expected.to_hex(),
                program.id
            );
        }
    }

    // The digest the leaf circuit will output, recomputed from the preimage.
    let words = leaf_output_words(&preimage);
    let output_cells = output_cells_from_words(&words);
    if !seg.public_outputs.is_empty() {
        let claimed: Vec<Felt> = seg
            .public_outputs
            .iter()
            .map(|a| Felt::parse(a))
            .collect::<Result<_>>()
            .map_err(|e| anyhow::anyhow!("segment {}: bad public_outputs felt: {e}", seg.index))?;
        if claimed.len() != 2 {
            bail!(
                "segment {}: the leaf format requires exactly 2 output cells, got {}",
                seg.index,
                claimed.len()
            );
        }
        if claimed[0] != output_cells[0] || claimed[1] != output_cells[1] {
            bail!(
                "segment {}: public_outputs do not match blake2s(encode(output_preimage))",
                seg.index
            );
        }
    }

    if cfg.require_verifiable_proof && !seg.proof.format.verifiable() {
        bail!(
            "segment {}: proof format `{}` cannot be verified (the cairo-serde felt stream is \
             one-way at cd7bc5f); submit the bincode CairoProof",
            seg.index,
            seg.proof.format.as_str()
        );
    }

    let proof_bytes = match seg.proof.format {
        ProofFormat::BincodeB64 => {
            let data = seg
                .proof
                .data
                .as_ref()
                .ok_or_else(|| anyhow::anyhow!("segment {}: proof.data is required", seg.index))?;
            base64::engine::general_purpose::STANDARD
                .decode(data)
                .map_err(|e| anyhow::anyhow!("segment {}: proof.data is not base64: {e}", seg.index))?
        }
        ProofFormat::CairoSerdeFelts => {
            let felts = seg
                .proof
                .felts
                .as_ref()
                .ok_or_else(|| anyhow::anyhow!("segment {}: proof.felts is required", seg.index))?;
            if felts.is_empty() {
                bail!("segment {}: proof.felts is empty", seg.index);
            }
            // Parse them so a malformed stream is rejected here, and store the canonical form.
            let parsed: Vec<Felt> = felts
                .iter()
                .map(|f| Felt::parse(f))
                .collect::<Result<_>>()
                .map_err(|e| anyhow::anyhow!("segment {}: bad proof felt: {e}", seg.index))?;
            let hexes: Vec<String> = parsed.iter().map(|f| f.to_hex()).collect();
            serde_json::to_vec(&hexes)?
        }
    };
    if proof_bytes.len() > cfg.max_proof_bytes {
        bail!(
            "segment {}: proof is {} bytes, over the {} byte limit",
            seg.index,
            proof_bytes.len(),
            cfg.max_proof_bytes
        );
    }

    let leaf_key = leaf_key(registry_hash, &program.id, program.program_hash.as_deref(), &args);

    Ok(ValidSegment {
        index: seg.index,
        args,
        preimage,
        output_cells,
        proof_format: seg.proof.format,
        proof_bytes,
        leaf_key,
    })
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
        });
        c
    }

    fn seg(index: u32, h_in: &str, h_out: &str) -> SegmentSubmission {
        SegmentSubmission {
            index,
            args: vec![h_in.into(), "0xfa".into()],
            output_preimage: vec!["0x5".into(), h_in.into(), h_out.into(), "0xfa".into(), "0x0".into()],
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
            solo: false,
            segments,
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
        assert!(validate(&sub, &cfg(), "reg").unwrap_err().to_string().contains("indices"));
    }

    #[test]
    fn rejects_unknown_program() {
        let mut sub = run(vec![seg(0, "0x1", "0x2")]);
        sub.program = "doom_run".into();
        assert!(validate(&sub, &cfg(), "reg").unwrap_err().to_string().contains("unknown program"));
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

        let mut c = cfg();
        c.require_verifiable_proof = false;
        assert!(validate(&sub, &c, "reg").is_ok());
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
        assert!(validate(&sub, &c, "reg").unwrap_err().to_string().contains("exceeds the limit"));

        let mut c = cfg();
        c.max_proof_bytes = 4;
        let sub = run(vec![seg(0, "0x1", "0x2")]);
        assert!(validate(&sub, &c, "reg").unwrap_err().to_string().contains("over the"));
    }

    #[test]
    fn leaf_key_is_content_addressed() {
        let a = leaf_key("reg", "p", None, &[Felt::parse("0x1").unwrap()]);
        let b = leaf_key("reg", "p", None, &[Felt::parse("1").unwrap()]);
        let c = leaf_key("reg2", "p", None, &[Felt::parse("0x1").unwrap()]);
        assert_eq!(a, b, "the same args in any notation are the same leaf");
        assert_ne!(a, c, "a different registry is a different circuit");
    }
}
