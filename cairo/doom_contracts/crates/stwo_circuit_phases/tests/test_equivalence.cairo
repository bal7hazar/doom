// SPDX-License-Identifier: Apache-2.0
//! Equivalence of the optimized phases (vendored verifier + the P4.1 patch series) with the
//! UNMODIFIED vendored verifier (`vendor/stwo_cairo_verifier_ref`, packages `*_ref`), on the
//! real root proofs: the same `fri_answers` row by row, the same accepted proofs with the same
//! output hash (the selected S4 golden and the two proved ten-felt batches of P4.2b), and the
//! same rejections of tampered proofs — one flipped felt in every section of the stream, fed
//! identically to the reference `verify_circuit` and to the phase pipeline.
use snforge_std::fs::{FileTrait, read_txt};
use stwo_circuit_air_ref::claims::column_log_sizes_per_tree as column_log_sizes_per_tree_ref;
use stwo_circuit_air_ref::multiverifier_consts::{
    COMPONENT_LOG_SIZES as COMPONENT_LOG_SIZES_REF,
    PREPROCESSED_COLUMN_LOG_SIZES as PREPROCESSED_COLUMN_LOG_SIZES_REF,
    circuit_pcs_config as circuit_pcs_config_ref,
};
use stwo_circuit_air_ref::{
    CircuitProof as CircuitProofRef, compute_circuit_hash as compute_circuit_hash_ref,
    get_verification_output as get_verification_output_ref,
    verify_circuit as verify_circuit_ref,
};
use stwo_circuit_phases::machine::MerkleState;
use stwo_circuit_phases::sections::{Sections, split};
use stwo_verifier_core::fields::qm31::QM31Serde;
use stwo_verifier_core_ref::Hash as HashRef;
use stwo_verifier_core_ref::circle::CirclePoint as CirclePointRef;
use stwo_verifier_core_ref::fields::m31::M31 as M31Ref;
use stwo_verifier_core_ref::fields::qm31::{QM31 as QM31Ref, QM31Serde as QM31SerdeRef};
use stwo_verifier_core_ref::pcs::quotients::fri_answers as fri_answers_ref;
use stwo_verifier_core_ref::pcs::verifier::{
    CommitmentSchemeVerifier as CommitmentSchemeVerifierRef,
    CommitmentSchemeVerifierImpl as CommitmentSchemeVerifierImplRef,
};
use stwo_verifier_core_ref::utils::SpanExTrait as SpanExTraitRef;
use stwo_verifier_core_ref::vcs::verifier::MerkleVerifier as MerkleVerifierRef;
use super::fixture::{expected_output_hash, load_proof, selected};
use super::helpers::{ans, fri, fri_state, merkle_state};

fn to_felts<T, +Serde<T>>(v: @T) -> Array<felt252> {
    let mut out = array![];
    v.serialize(ref out);
    out
}

fn deser<T, +Serde<T>, +Drop<T>>(felts: Span<felt252>) -> T {
    let mut span = felts;
    let v: T = Serde::deserialize(ref span).expect('deser');
    assert!(span.is_empty(), "trailing");
    v
}

// ---------------------------------------------------------------------------------------------
// The two verifiers over a proof stream
// ---------------------------------------------------------------------------------------------

/// The unmodified vendored `verify_circuit` on a cairo-serde `CircuitProof` stream; returns the
/// output hash.
fn run_reference(values: Span<felt252>) -> [u32; 8] {
    let mut span = values;
    let proof: CircuitProofRef = Serde::deserialize(ref span).expect('proof deser');
    assert!(span.is_empty(), "trailing data");
    let commitments: @Box<[HashRef; 4]> = proof
        .stark_proof
        .commitment_scheme_proof
        .commitments
        .try_into()
        .unwrap();
    let output_values = proof.claim.public_data.output_values.span();
    let [preprocessed_commitment, _, _, _] = commitments.unbox();
    let circuit_hash = compute_circuit_hash_ref(
        proof.stark_proof.commitment_scheme_proof.config.fri_config.log_blowup_factor,
        preprocessed_commitment,
    );
    verify_circuit_ref(:proof, :circuit_hash);
    get_verification_output_ref(:circuit_hash, :output_values).output_hash.hash.unbox()
}

/// The optimized phases (begin, 4 Merkle trees, answers, the FRI walk in two chunks as the
/// 5-transaction plan) on the same stream; returns the output hash.
fn run_phased(values: Span<felt252>) -> [u32; 8] {
    let sec = split(values);
    let mut state = fri_state(@sec);
    let r = fri(ref state, @sec, 0, 2);
    assert!(r.is_none(), "not done after 2 layers");
    fri(ref state, @sec, 2, 6).expect('fri: not done')
}

// ---------------------------------------------------------------------------------------------
// fri_answers row by row
// ---------------------------------------------------------------------------------------------

/// The reference commitment scheme (tree roots + column geometry) with the `_ref` types.
fn commitment_scheme_ref(tree_roots: Span<felt252>) -> CommitmentSchemeVerifierRef {
    let log_blowup_factor = circuit_pcs_config_ref().fri_config.log_blowup_factor;
    let log_sizes = column_log_sizes_per_tree_ref(COMPONENT_LOG_SIZES_REF);
    let log_sizes_box: @Box<[Span<u32>; 3]> = log_sizes.span().try_into().unwrap();
    let [_, trace_log_sizes, interaction_log_sizes] = log_sizes_box.unbox();
    let trace_bound = *PREPROCESSED_COLUMN_LOG_SIZES_REF.span().max().unwrap();
    let bounds = array![
        PREPROCESSED_COLUMN_LOG_SIZES_REF.span(), trace_log_sizes, interaction_log_sizes,
        [trace_bound; 8].span(),
    ];
    let mut roots = tree_roots;
    let mut trees = array![];
    for column_log_deg_bounds in bounds.span() {
        let root: HashRef = deser(roots.multi_pop_front::<8>().unwrap().unbox().span());
        trees
            .append(
                MerkleVerifierRef {
                    root,
                    tree_height: log_blowup_factor + *(*column_log_deg_bounds).max().unwrap(),
                    column_log_deg_bounds: *column_log_deg_bounds,
                },
            );
    }
    CommitmentSchemeVerifierRef { trees }
}

/// The reference `fri_answers` on the sections, driven by the transcript outputs of the
/// (optimized) `begin` — the transcript is untouched by the patch series.
fn answers_ref(state: @MerkleState, sec: @Sections) -> Array<felt252> {
    let params = state.params;
    let mut roots = array![];
    for r in params.tree_roots.span() {
        roots.append_span(to_felts(r).span());
    }
    let commitment_scheme = commitment_scheme_ref(roots.span());
    let oods_point = CirclePointRef {
        x: deser::<QM31Ref>(to_felts(params.oods_point_x).span()),
        y: deser::<QM31Ref>(to_felts(params.oods_point_y).span()),
    };
    let random_coeff: QM31Ref = deser(to_felts(params.random_coeff).span());
    let sampled: Span<Span<Span<QM31Ref>>> = deser(sec.sampled_values.span());
    let mut queried: Array<Span<M31Ref>> = array![];
    for t in 0..4_u32 {
        queried.append(deser(sec.queried_values.at(t).span()));
    }
    let fri_config = circuit_pcs_config_ref().fri_config;
    let trace_bound = *PREPROCESSED_COLUMN_LOG_SIZES_REF.span().max().unwrap();
    let evals = fri_answers_ref(
        commitment_scheme.column_indices_per_tree_by_degree_bound(),
        fri_config.log_blowup_factor,
        oods_point,
        sampled,
        random_coeff,
        params.query_positions.span(),
        queried,
        trace_bound,
    );
    let mut out = array![];
    for e in evals {
        out.append_span(to_felts(e).span());
    }
    out
}

/// The optimized `fri_answers` (lazy numerators, shared denominators, one batch inversion)
/// returns the reference's 70 values, row by row.
#[test]
fn answers_match_reference() {
    let sec = split(load_proof().span());
    let state = merkle_state(@sec);
    let reference = answers_ref(@state, @sec);
    let fri_state = ans(state, @sec);
    let ours = to_felts(@fri_state.layer_query_evals);
    // `Array<QM31>` serializes with a length prefix.
    assert!(ours.len() == reference.len() + 1, "answer count");
    let mut i = 0;
    for r in reference.span() {
        assert!(*ours.at(i + 1) == *r, "answer {} differs", i / 4);
        i += 1;
    }
}

// ---------------------------------------------------------------------------------------------
// Accepted proofs: the same output hash on the real root proofs
// ---------------------------------------------------------------------------------------------

/// The two proved ten-felt batches of P4.2b (registry `doom`): `fixtures/unpack.sh` rewrites
/// `crates/recursion_outputs/fixtures/B2*_doom/root.proof.gz` one felt per line; their output
/// hashes are the `verifier_output.json` next to them.
fn b2_fixture(name: ByteArray, n_felts: u32) -> Array<felt252> {
    let mut path: ByteArray = "../../fixtures/";
    path.append(@name);
    let values = read_txt(@FileTrait::new(path));
    assert!(values.len() == n_felts, "fixture length");
    values
}

const B2_DOOM_OUTPUT: [u32; 8] = [
    2217688292, 1296469167, 648244655, 3512905594, 2328469262, 3623408698, 4249123664, 1269122478,
];
const B2_1_DOOM_OUTPUT: [u32; 8] = [
    1672632833, 2042954996, 2890085614, 3347342551, 3941042659, 2239140051, 379882776, 3249511199,
];

#[test]
fn phased_accepts_selected_golden() {
    assert!(run_phased(load_proof().span()) == expected_output_hash(), "output hash");
}

#[test]
fn phased_accepts_b2_doom() {
    if selected() != 1 {
        println!("b2 batches need the `doom` constants (fixtures/selected.txt = 1): skipped");
        return;
    }
    assert!(run_phased(b2_fixture("b2_doom_root_proof.txt", 95985).span()) == B2_DOOM_OUTPUT);
}

#[test]
fn reference_accepts_b2_doom() {
    if selected() != 1 {
        println!("b2 batches need the `doom` constants (fixtures/selected.txt = 1): skipped");
        return;
    }
    assert!(run_reference(b2_fixture("b2_doom_root_proof.txt", 95985).span()) == B2_DOOM_OUTPUT);
}

#[test]
fn phased_accepts_b2_1_doom() {
    if selected() != 1 {
        println!("b2 batches need the `doom` constants (fixtures/selected.txt = 1): skipped");
        return;
    }
    assert!(
        run_phased(b2_fixture("b2_1_doom_root_proof.txt", 95949).span()) == B2_1_DOOM_OUTPUT,
    );
}

#[test]
fn reference_accepts_b2_1_doom() {
    if selected() != 1 {
        println!("b2 batches need the `doom` constants (fixtures/selected.txt = 1): skipped");
        return;
    }
    assert!(
        run_reference(b2_fixture("b2_1_doom_root_proof.txt", 95949).span()) == B2_1_DOOM_OUTPUT,
    );
}

// ---------------------------------------------------------------------------------------------
// Rejected proofs: one flipped felt per section, the same stream to both verifiers
// ---------------------------------------------------------------------------------------------

fn len_at(values: Span<felt252>, pos: u32) -> u32 {
    (*values.at(pos)).try_into().unwrap()
}

/// Offsets, in the cairo-serde `CircuitProof` stream, of one felt of every section (mirrors the
/// stream walk of `tools/emit_calldata.py`).
#[derive(Drop, Copy)]
struct TamperPoints {
    claim_value: u32,
    interaction_claim: u32,
    tree1_root_word: u32,
    sampled_value: u32,
    tree2_witness_word: u32,
    tree1_queried_value: u32,
    queries_pow_nonce: u32,
    first_layer_witness_value: u32,
    first_layer_hash_word: u32,
    inner2_witness_value: u32,
    inner1_commitment_word: u32,
    last_layer_coeff: u32,
    channel_salt: u32,
}

fn tamper_points(values: Span<felt252>) -> TamperPoints {
    let mut pos: u32 = 0;
    // claim: Array<QM31>
    let claim_value = pos + 1;
    pos += 1 + 4 * len_at(values, pos);
    // interaction pow
    pos += 1;
    // interaction claim: 11 QM31
    let interaction_claim = pos;
    pos += 44;
    // pcs config
    pos += 5;
    // commitments: Array<Hash>
    let tree1_root_word = pos + 1 + 8;
    pos += 1 + 8 * len_at(values, pos);
    // sampled values: Span<Span<Span<QM31>>>: the first sample of the first sampled column.
    let mut sampled_value = 0;
    let n_trees = len_at(values, pos);
    pos += 1;
    for _ in 0..n_trees {
        let n_cols = len_at(values, pos);
        pos += 1;
        for _ in 0..n_cols {
            let n_samples = len_at(values, pos);
            pos += 1;
            if n_samples != 0 && sampled_value == 0 {
                sampled_value = pos;
            }
            pos += 4 * n_samples;
        }
    }
    // decommitments: Array<MerkleDecommitment>
    let n_dec = len_at(values, pos);
    pos += 1;
    let mut tree2_witness_word = 0;
    for t in 0..n_dec {
        let n_hashes = len_at(values, pos);
        if t == 2 {
            tree2_witness_word = pos + 1;
        }
        pos += 1 + 8 * n_hashes;
    }
    // queried values: Array<Span<M31>>
    let n_qv = len_at(values, pos);
    pos += 1;
    let mut tree1_queried_value = 0;
    for t in 0..n_qv {
        let n = len_at(values, pos);
        if t == 1 {
            tree1_queried_value = pos + 1;
        }
        pos += 1 + n;
    }
    // queries proof of work nonce
    let queries_pow_nonce = pos;
    pos += 1;
    // first layer: witness (QM31s), decommitment (hashes), commitment
    let first_layer_witness_value = pos + 1;
    pos += 1 + 4 * len_at(values, pos);
    let first_layer_hash_word = pos + 1;
    pos += 1 + 8 * len_at(values, pos);
    pos += 8;
    // inner layers
    let n_inner = len_at(values, pos);
    pos += 1;
    let mut inner2_witness_value = 0;
    let mut inner1_commitment_word = 0;
    for l in 0..n_inner {
        if l == 2 {
            inner2_witness_value = pos + 1;
        }
        pos += 1 + 4 * len_at(values, pos);
        pos += 1 + 8 * len_at(values, pos);
        if l == 1 {
            inner1_commitment_word = pos;
        }
        pos += 8;
    }
    // last layer poly: coeffs + log_size
    let last_layer_coeff = pos + 1;
    pos += 1 + 4 * len_at(values, pos);
    pos += 1;
    // salt
    let channel_salt = pos;
    pos += 1;
    assert!(pos == values.len(), "stream walk");
    TamperPoints {
        claim_value,
        interaction_claim,
        tree1_root_word,
        sampled_value,
        tree2_witness_word,
        tree1_queried_value,
        queries_pow_nonce,
        first_layer_witness_value,
        first_layer_hash_word,
        inner2_witness_value,
        inner1_commitment_word,
        last_layer_coeff,
        channel_salt,
    }
}

/// The selected golden with the felt at `index` incremented (a flip of its low bit or a carry —
/// still a valid u32 for every proof felt but 0xFFFFFFFF).
fn tampered(index: u32) -> Array<felt252> {
    let values = load_proof();
    let mut out = array![];
    let mut i = 0;
    for v in values.span() {
        out.append(if i == index {
            *v + 1
        } else {
            *v
        });
        i += 1;
    }
    out
}

fn points() -> TamperPoints {
    tamper_points(load_proof().span())
}

/// Sanity: the walk lands on the sections it names, in stream order.
#[test]
fn tamper_points_walk_the_stream() {
    let p = points();
    assert!(p.claim_value == 1 && p.interaction_claim > 1 && p.tree1_root_word > 50);
    assert!(p.sampled_value > p.tree1_root_word && p.tree2_witness_word > p.sampled_value);
    assert!(p.tree1_queried_value > p.tree2_witness_word);
    assert!(p.queries_pow_nonce > p.tree1_queried_value);
    assert!(p.first_layer_witness_value == p.queries_pow_nonce + 2);
    assert!(p.first_layer_hash_word > p.first_layer_witness_value);
    assert!(p.inner1_commitment_word > p.first_layer_hash_word);
    assert!(p.inner2_witness_value > p.inner1_commitment_word);
    assert!(p.last_layer_coeff > p.inner2_witness_value && p.channel_salt > p.last_layer_coeff);
}

#[test]
#[should_panic]
fn tamper_claim_phased() {
    run_phased(tampered(points().claim_value).span());
}
#[test]
#[should_panic]
fn tamper_claim_reference() {
    run_reference(tampered(points().claim_value).span());
}

#[test]
#[should_panic]
fn tamper_interaction_claim_phased() {
    run_phased(tampered(points().interaction_claim).span());
}
#[test]
#[should_panic]
fn tamper_interaction_claim_reference() {
    run_reference(tampered(points().interaction_claim).span());
}

#[test]
#[should_panic]
fn tamper_tree_root_phased() {
    run_phased(tampered(points().tree1_root_word).span());
}
#[test]
#[should_panic]
fn tamper_tree_root_reference() {
    run_reference(tampered(points().tree1_root_word).span());
}

#[test]
#[should_panic]
fn tamper_sampled_value_phased() {
    run_phased(tampered(points().sampled_value).span());
}
#[test]
#[should_panic]
fn tamper_sampled_value_reference() {
    run_reference(tampered(points().sampled_value).span());
}

#[test]
#[should_panic]
fn tamper_merkle_witness_phased() {
    run_phased(tampered(points().tree2_witness_word).span());
}
#[test]
#[should_panic]
fn tamper_merkle_witness_reference() {
    run_reference(tampered(points().tree2_witness_word).span());
}

#[test]
#[should_panic]
fn tamper_queried_value_phased() {
    run_phased(tampered(points().tree1_queried_value).span());
}
#[test]
#[should_panic]
fn tamper_queried_value_reference() {
    run_reference(tampered(points().tree1_queried_value).span());
}

#[test]
#[should_panic]
fn tamper_pow_nonce_phased() {
    run_phased(tampered(points().queries_pow_nonce).span());
}
#[test]
#[should_panic]
fn tamper_pow_nonce_reference() {
    run_reference(tampered(points().queries_pow_nonce).span());
}

#[test]
#[should_panic]
fn tamper_fri_first_witness_phased() {
    run_phased(tampered(points().first_layer_witness_value).span());
}
#[test]
#[should_panic]
fn tamper_fri_first_witness_reference() {
    run_reference(tampered(points().first_layer_witness_value).span());
}

#[test]
#[should_panic]
fn tamper_fri_hash_witness_phased() {
    run_phased(tampered(points().first_layer_hash_word).span());
}
#[test]
#[should_panic]
fn tamper_fri_hash_witness_reference() {
    run_reference(tampered(points().first_layer_hash_word).span());
}

#[test]
#[should_panic]
fn tamper_fri_inner_witness_phased() {
    run_phased(tampered(points().inner2_witness_value).span());
}
#[test]
#[should_panic]
fn tamper_fri_inner_witness_reference() {
    run_reference(tampered(points().inner2_witness_value).span());
}

#[test]
#[should_panic]
fn tamper_fri_commitment_phased() {
    run_phased(tampered(points().inner1_commitment_word).span());
}
#[test]
#[should_panic]
fn tamper_fri_commitment_reference() {
    run_reference(tampered(points().inner1_commitment_word).span());
}

#[test]
#[should_panic]
fn tamper_last_layer_phased() {
    run_phased(tampered(points().last_layer_coeff).span());
}
#[test]
#[should_panic]
fn tamper_last_layer_reference() {
    run_reference(tampered(points().last_layer_coeff).span());
}

#[test]
#[should_panic]
fn tamper_salt_phased() {
    run_phased(tampered(points().channel_salt).span());
}
#[test]
#[should_panic]
fn tamper_salt_reference() {
    run_reference(tampered(points().channel_salt).span());
}
