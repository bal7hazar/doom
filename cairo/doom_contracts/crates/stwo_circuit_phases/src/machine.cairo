// SPDX-License-Identifier: Apache-2.0
//! The resumable circuit verifier: `verify_circuit` (vendored `stwo_circuit_air`, proving@cd7bc5f)
//! split into phases that each consume one calldata section and carry a small checkpoint.
//!
//! Every function here is a pure function `(state, section) -> state'`; the router contract
//! (`doom_contracts::router`) stores `poseidon(state)` between transactions. See
//! `docs/design/onchain-verifier.md` for the phase table, the binding argument and the costs.
//!
//! Fidelity: the transcript (Fiat-Shamir channel) is driven exactly as in the monolithic
//! `verify_circuit` → `verify` → `verify_values`: every `mix_*` / `draw_*` happens in the same
//! order with the same bytes, in `begin`. The phases after `begin` do not touch the channel:
//! query positions, random coefficients and folding alphas are checkpointed and the calldata of
//! later phases is either self-authenticating (Merkle/FRI witnesses) or bound by a Poseidon
//! digest taken in `begin` (sampled values) or by the Merkle phase (queried values).
//!
//! Sections after the head arrive **packed** (7 u32 limbs per felt, `pack.cairo`) and are
//! decoded straight into the verifier's types (`decode.cairo`, P4.1): the digests are taken
//! over the packed slots, which determine the decoded values (decoding is a function of the
//! slots and every value is range-checked to its type).
use core::box::BoxImpl;
use core::num::traits::Zero;
use core::poseidon::poseidon_hash_span;
use stwo_circuit_air::circuit_air::CircuitAirNewImpl;
use stwo_circuit_air::claims::{
    CircuitClaim, CircuitClaimImpl, CircuitInteractionClaim, CircuitInteractionClaimImpl,
    column_log_sizes_per_tree, lookup_sum,
};
use stwo_circuit_air::multiverifier_consts::{
    COMPONENT_LOG_SIZES, N_OUTPUTS, PREPROCESSED_COLUMN_LOG_SIZES, circuit_pcs_config,
};
use stwo_circuit_air::{
    INTERACTION_POW_BITS, SECURITY_BITS, compute_circuit_hash, get_verification_output,
    verify_claim,
};
use stwo_constraint_framework::LookupElementsImpl;
use stwo_verifier_core::Hash;
use stwo_verifier_core::channel::{Channel, ChannelTrait};
use stwo_verifier_core::circle::{ChannelGetRandomCirclePointImpl, CirclePoint, CosetImpl};
use stwo_verifier_core::fields::Invertible;
use stwo_verifier_core::fields::m31::{M31, M31Trait};
use stwo_verifier_core::fields::qm31::{QM31, QM31Serde};
use stwo_verifier_core::fri::{
    FriConfigTrait, FriFirstLayerVerifier, FriFirstLayerVerifierImpl, FriInnerLayerVerifier,
    FriInnerLayerVerifierImpl, FriLayerProof, SparseEvaluationImpl,
};
use stwo_verifier_core::pcs::PcsConfigTrait;
use stwo_verifier_core::pcs::quotients::fri_answers;
use stwo_verifier_core::pcs::verifier::{
    CommitmentSchemeVerifier, CommitmentSchemeVerifierImpl, MIN_POW_BITS, mix_sampled_values,
    prepare_preprocessed_query_positions,
};
use stwo_verifier_core::poly::circle::{CanonicCosetImpl, CanonicCosetTrait};
use stwo_verifier_core::poly::line::{LineDomain, LineDomainImpl, LinePoly};
use stwo_verifier_core::queries::{Queries, QueriesImpl};
use stwo_verifier_core::utils::SpanExTrait;
use stwo_verifier_core::vcs::blake2s_hasher::Blake2sMerkleHasher;
use stwo_verifier_core::vcs::verifier::{MerkleDecommitment, MerkleVerifier, MerkleVerifierTrait};
use stwo_verifier_core::verifier::{Air, try_extract_composition_eval};
use crate::decode::{
    end, read_decommitment, read_fri_layers, read_m31_span, read_sampled_values, unpack_limbs,
};
use crate::pack::pack_u32_unchecked;

/// Number of commitment trees of a circuit proof (preprocessed, trace, interaction, composition).
pub const N_TREES: u32 = 4;
/// Index of the preprocessed tree (mirrors `verifier_core::pcs::verifier`).
const PREPROCESSED_TRACE_IDX: u32 = 0;
/// `COMPOSITION_SPLIT_FACTOR * QM31_EXTENSION_DEGREE` (mirrors `verifier_core::verifier`).
const N_COMPOSITION_COLUMNS: u32 = 8;

// ---------------------------------------------------------------------------------------------
// Calldata sections
// ---------------------------------------------------------------------------------------------

/// The transcript-relevant part of the FRI proof: what `FriVerifierImpl::commit` mixes.
/// Serialized as `first_commitment ‖ inner_commitments (len-prefixed) ‖ last_layer_poly`.
#[derive(Drop, Serde)]
pub struct FriHead {
    pub first_commitment: Hash,
    pub inner_commitments: Array<Hash>,
    pub last_layer_poly: LinePoly,
}

/// The `begin` section ("head"): every transcript-relevant field of `CircuitProof`, in stream
/// order, with the self-authenticating sections (Merkle decommitments, queried values, FRI
/// witnesses) removed. Built by `tools/emit_calldata.py`.
#[derive(Drop, Serde)]
pub struct Head {
    pub claim: CircuitClaim,
    pub interaction_pow: u64,
    pub interaction_claim: CircuitInteractionClaim,
    pub pcs_config: stwo_verifier_core::pcs::PcsConfig,
    pub commitments: Span<Hash>,
    pub sampled_values: Span<Span<Span<QM31>>>,
    pub proof_of_work_nonce: u64,
    pub fri_head: FriHead,
    pub channel_salt: u32,
}

// ---------------------------------------------------------------------------------------------
// Checkpoints
// ---------------------------------------------------------------------------------------------

/// One FRI layer's transcript-derived parameters.
#[derive(Drop, Copy, Serde)]
pub struct FriLayerParams {
    pub commitment: Hash,
    pub folding_alpha: QM31,
    /// Log degree bound of the polynomial committed in this layer.
    pub log_degree_bound: u32,
    pub fold_step: u32,
}

/// Everything the phases after `begin` need; produced once by `begin`, carried (unchanged) by
/// every later state.
#[derive(Drop, Serde)]
pub struct Params {
    /// `blake2s(log_blowup ‖ component_log_sizes ‖ preprocessed_root)` (transcript-bound).
    pub circuit_hash: [u32; 8],
    /// `blake2s(circuit_hash ‖ outputs)`: the fact material (valid only after the last phase).
    pub output_hash: [u32; 8],
    /// Merkle roots of the 4 trees (transcript-bound in `begin`).
    pub tree_roots: Array<Hash>,
    /// `poseidon(fast-path packed sampled_values section)`: binds the re-supply in `answers`.
    pub d_sampled: felt252,
    pub oods_point_x: QM31,
    pub oods_point_y: QM31,
    /// The `fri_answers` random coefficient (drawn after `mix_sampled_values`).
    pub random_coeff: QM31,
    /// FRI query positions (sorted, deduplicated) over the lifted domain.
    pub query_positions: Array<u32>,
    /// FRI first layer: commitment + alpha; `log_degree_bound` = the circle poly log bound.
    pub fri_first: FriLayerParams,
    pub fri_inner: Array<FriLayerParams>,
    /// The single last-layer coefficient (`log_last_layer_degree_bound == 0`).
    pub fri_last_layer_value: QM31,
}

/// State after `begin`, during the Merkle phase(s).
#[derive(Drop, Serde)]
pub struct MerkleState {
    pub params: Params,
    /// Bit `i` set once tree `i` has been decommitted.
    pub trees_done: u32,
    /// `poseidon(packed queried_values section)` per tree, filled by the Merkle phase.
    pub d_queried: Array<felt252>,
}

/// State after `answers`, during the FRI decommit phase(s).
#[derive(Drop, Serde)]
pub struct FriState {
    pub params: Params,
    /// Layers already decommitted: 0 = none, 1 = first layer, 1 + k = k inner layers too.
    pub layers_done: u32,
    /// Query positions in the current layer's domain (the first-layer answers' positions before
    /// the first layer is done).
    pub layer_query_positions: Array<u32>,
    pub layer_log_domain_size: u32,
    /// Evaluations at `layer_query_positions` (the `fri_answers` before the first layer is done).
    pub layer_query_evals: Array<QM31>,
}

// ---------------------------------------------------------------------------------------------
// Fixed circuit geometry (from the hardcoded multiverifier constants)
// ---------------------------------------------------------------------------------------------

/// Column log degree bounds of every tree, in tree order.
fn tree_column_log_bounds() -> Array<Span<u32>> {
    let log_sizes = column_log_sizes_per_tree(COMPONENT_LOG_SIZES);
    let log_sizes_box: @Box<[Span<u32>; 3]> = log_sizes.span().try_into().unwrap();
    let [_, trace_log_sizes, interaction_log_sizes] = log_sizes_box.unbox();
    let trace_log_degree_bound = *PREPROCESSED_COLUMN_LOG_SIZES.span().max().unwrap();
    array![
        PREPROCESSED_COLUMN_LOG_SIZES.span(), trace_log_sizes, interaction_log_sizes,
        [trace_log_degree_bound; N_COMPOSITION_COLUMNS].span(),
    ]
}

/// Log degree bound of the trace (23 for the multiverifier).
fn trace_log_degree_bound() -> u32 {
    *PREPROCESSED_COLUMN_LOG_SIZES.span().max().unwrap()
}

/// Rebuilds the commitment-scheme verifier (tree roots + column geometry) without touching a
/// channel.
fn rebuild_commitment_scheme(tree_roots: Span<Hash>) -> CommitmentSchemeVerifier {
    let log_blowup_factor = circuit_pcs_config().fri_config.log_blowup_factor;
    let mut trees = array![];
    for (root, column_log_deg_bounds) in stwo_verifier_utils::zip_eq::zip_eq(
        tree_roots, tree_column_log_bounds().span(),
    ) {
        let max_log_degree_bound = *(*column_log_deg_bounds).max().unwrap();
        trees
            .append(
                MerkleVerifier {
                    root: *root,
                    tree_height: log_blowup_factor + max_log_degree_bound,
                    column_log_deg_bounds: *column_log_deg_bounds,
                },
            );
    }
    CommitmentSchemeVerifier { trees }
}

// ---------------------------------------------------------------------------------------------
// Phase 1: `begin`
// ---------------------------------------------------------------------------------------------

/// Runs the whole transcript: `verify_circuit`'s prologue, the OODS composition check, the
/// sampled-values mix, the FRI commitment phase, the queries proof of work and the query
/// sampling. Panics on any failure. Returns the checkpoint for the Merkle phase.
pub fn begin(head: Span<felt252>) -> MerkleState {
    let mut span = head;
    // The sampled-values digest is taken over the raw section felts: locate them while
    // deserializing (they sit between `commitments` and `proof_of_work_nonce`).
    let claim: CircuitClaim = Serde::deserialize(ref span).expect('head: claim');
    let interaction_pow: u64 = Serde::deserialize(ref span).expect('head: interaction pow');
    let interaction_claim: CircuitInteractionClaim = Serde::deserialize(ref span)
        .expect('head: interaction claim');
    let pcs_config: stwo_verifier_core::pcs::PcsConfig = Serde::deserialize(ref span)
        .expect('head: pcs config');
    let commitments: Span<Hash> = Serde::deserialize(ref span).expect('head: commitments');
    let sampled_start = head.len() - span.len();
    let sampled_values: Span<Span<Span<QM31>>> = Serde::deserialize(ref span)
        .expect('head: sampled values');
    let sampled_len = head.len() - span.len() - sampled_start;
    // Digest of the section as `answers` receives it: its fast-path packing (`pack_u32`,
    // the emitter packs every section independently).
    let d_sampled = poseidon_hash_span(
        pack_u32_unchecked(head.slice(sampled_start, sampled_len)).span(),
    );
    let proof_of_work_nonce: u64 = Serde::deserialize(ref span).expect('head: pow nonce');
    let fri_head: FriHead = Serde::deserialize(ref span).expect('head: fri head');
    let channel_salt: u32 = Serde::deserialize(ref span).expect('head: salt');
    assert(span.is_empty(), 'head: trailing data');

    // ---- verify_circuit (vendored stwo_circuit_air) ----
    let preprocessed_column_log_sizes = PREPROCESSED_COLUMN_LOG_SIZES;
    assert!(claim.public_data.output_values.len() == N_OUTPUTS);
    assert!(pcs_config == circuit_pcs_config(), "unexpected proof pcs config");
    let component_log_sizes = COMPONENT_LOG_SIZES;
    verify_claim(component_log_sizes);

    let mut channel: Channel = Default::default();
    let channel_salt_as_felt: QM31 = M31Trait::reduce_u32(channel_salt).into();
    channel.mix_felts([channel_salt_as_felt].span());
    pcs_config.mix_into(ref channel);
    let mut commitment_scheme = CommitmentSchemeVerifierImpl::new();

    let commitments_box: @Box<[Hash; 4]> = commitments.try_into().unwrap();
    let [
        preprocessed_commitment, trace_commitment, interaction_trace_commitment,
        composition_commitment,
    ] =
        commitments_box
        .unbox();

    let log_sizes = column_log_sizes_per_tree(component_log_sizes);
    let log_sizes_box: @Box<[Span<u32>; 3]> = log_sizes.span().try_into().unwrap();
    let [_, trace_log_sizes, interaction_trace_log_sizes] = log_sizes_box.unbox();
    let log_blowup_factor = pcs_config.fri_config.log_blowup_factor;

    // The circuit hash (also the first word block of the fact material).
    let circuit_hash = compute_circuit_hash(log_blowup_factor, preprocessed_commitment);

    commitment_scheme
        .commit(
            preprocessed_commitment,
            preprocessed_column_log_sizes.span(),
            ref channel,
            log_blowup_factor,
        );
    channel.mix_commitment(circuit_hash);
    claim.mix_into(ref channel);
    commitment_scheme.commit(trace_commitment, trace_log_sizes, ref channel, log_blowup_factor);

    assert!(
        channel.verify_pow_nonce(INTERACTION_POW_BITS, interaction_pow),
        "Interaction Proof Of Work verification failed",
    );
    channel.mix_u64(interaction_pow);

    let common_lookup_elements = LookupElementsImpl::draw(ref channel);
    assert!(
        lookup_sum(@claim, @common_lookup_elements, @interaction_claim).is_zero(),
        "Logup sum is not zero",
    );

    interaction_claim.mix_into(ref channel);
    commitment_scheme
        .commit(
            interaction_trace_commitment,
            interaction_trace_log_sizes,
            ref channel,
            log_blowup_factor,
        );

    let trace_log_degree_bound = *preprocessed_column_log_sizes.span().max().unwrap();
    let circuit_air = CircuitAirNewImpl::new(
        component_log_sizes, @common_lookup_elements, @interaction_claim,
    );

    // ---- verifier_core::verify ----
    assert!(
        pcs_config.fri_config.security_bits() >= SECURITY_BITS, "Security bits are too low",
    );
    let composition_random_coeff = channel.draw_secure_felt();
    commitment_scheme
        .commit(
            composition_commitment,
            [trace_log_degree_bound; N_COMPOSITION_COLUMNS].span(),
            ref channel,
            log_blowup_factor,
        );
    let ood_point = channel.get_random_point();
    let composition_oods_eval = try_extract_composition_eval(
        sampled_values, ood_point, trace_log_degree_bound,
    )
        .expect('Invalid sampled_values');
    let numerator = circuit_air
        .eval_composition_polynomial_at_point(ood_point, sampled_values, composition_random_coeff);
    let max_trace_domain = CanonicCosetImpl::new(trace_log_degree_bound);
    let denominator_inv = max_trace_domain.eval_vanishing(ood_point).inverse();
    assert!(composition_oods_eval == numerator * denominator_inv, "Invalid OODS eval");

    // ---- verify_values, up to the query sampling ----
    mix_sampled_values(sampled_values, ref channel);
    let random_coeff = channel.draw_secure_felt();
    let fri_config = pcs_config.fri_config;

    // FRI commitment phase (mirrors `FriVerifierImpl::commit`, over the head only).
    let FriHead { first_commitment, inner_commitments, last_layer_poly } = fri_head;
    channel.mix_commitment(first_commitment);
    let log_bound = trace_log_degree_bound;
    let fri_first = FriLayerParams {
        commitment: first_commitment,
        folding_alpha: channel.draw_secure_felt(),
        log_degree_bound: log_bound,
        fold_step: fri_config.fold_step,
    };
    let mut fri_inner = array![];
    let mut layer_log_bound = log_bound - fri_config.fold_step;
    let n_inner_layers = inner_commitments.len();
    let mut layer_index = 0;
    for commitment in inner_commitments.span() {
        channel.mix_commitment(*commitment);
        let fold_step = if layer_index == n_inner_layers - 1 {
            let remaining = layer_log_bound - fri_config.log_last_layer_degree_bound;
            assert!(
                1 <= remaining && remaining <= fri_config.fold_step, "Invalid number of FRI layers",
            );
            remaining
        } else {
            fri_config.fold_step
        };
        fri_inner
            .append(
                FriLayerParams {
                    commitment: *commitment,
                    folding_alpha: channel.draw_secure_felt(),
                    log_degree_bound: layer_log_bound,
                    fold_step,
                },
            );
        layer_log_bound -= fold_step;
        layer_index += 1;
    }
    assert!(
        layer_log_bound == fri_config.log_last_layer_degree_bound, "Invalid number of FRI layers",
    );
    assert!(
        last_layer_poly.log_size == fri_config.log_last_layer_degree_bound,
        "Invalid last layer degree",
    );
    channel.mix_felts(last_layer_poly.coeffs.span());
    let last_layer_box: Box<[QM31; 1]> = *last_layer_poly
        .coeffs
        .span()
        .try_into()
        .expect('Last layer log degree != 0');
    let [fri_last_layer_value] = last_layer_box.unbox();

    // Queries proof of work + query sampling.
    assert!(fri_config.pow_bits >= MIN_POW_BITS);
    assert!(
        channel.verify_pow_nonce(fri_config.pow_bits, proof_of_work_nonce),
        "Proof Of Work verification failed",
    );
    channel.mix_u64(proof_of_work_nonce);
    let query_domain_log_size = log_bound + fri_config.log_blowup_factor;
    let queries = QueriesImpl::generate(ref channel, query_domain_log_size, fri_config.n_queries);
    // The channel is not used past this point: nothing of it needs checkpointing.

    let mut query_positions = array![];
    for p in queries.positions {
        query_positions.append(*p);
    }
    let mut tree_roots = array![];
    for tree in commitment_scheme.trees.span() {
        tree_roots.append(*tree.root);
    }
    let output_hash = get_verification_output(
        circuit_hash, claim.public_data.output_values.span(),
    )
        .output_hash
        .hash
        .unbox();

    MerkleState {
        params: Params {
            circuit_hash: circuit_hash.hash.unbox(),
            output_hash,
            tree_roots,
            d_sampled,
            oods_point_x: ood_point.x,
            oods_point_y: ood_point.y,
            random_coeff,
            query_positions,
            fri_first,
            fri_inner,
            fri_last_layer_value,
        },
        trees_done: 0,
        d_queried: array![0, 0, 0, 0],
    }
}

// ---------------------------------------------------------------------------------------------
// Phase 2: `merkle` (one call per tree; a transaction may carry several trees)
// ---------------------------------------------------------------------------------------------

/// Verifies the Merkle decommitment of tree `tree_idx` at the checkpointed query positions and
/// records `poseidon(queried_values slots)` for the `answers` phase. `queried_values` /
/// `decommitment`: the fast-path packed cairo-serde `Span<M31>` / `MerkleDecommitment` sections
/// of `n_qv` / `n_dec` felts.
pub fn merkle(
    ref state: MerkleState,
    tree_idx: u32,
    queried_values: Span<felt252>,
    n_qv: u32,
    decommitment: Span<felt252>,
    n_dec: u32,
) {
    assert!(tree_idx < N_TREES, "merkle: bad tree index");
    let bit = pow2_u32(tree_idx);
    assert!(state.trees_done & bit == 0, "merkle: tree already done");

    let mut qv_limbs = unpack_limbs(queried_values, n_qv);
    let values = read_m31_span(ref qv_limbs);
    end(qv_limbs);
    let mut dec_limbs = unpack_limbs(decommitment, n_dec);
    let decommitment_parsed = read_decommitment(ref dec_limbs);
    end(dec_limbs);

    let commitment_scheme = rebuild_commitment_scheme(state.params.tree_roots.span());
    let tree = commitment_scheme.trees.span().at(tree_idx);
    let query_positions = state.params.query_positions.span();
    let positions = if tree_idx == PREPROCESSED_TRACE_IDX {
        let lifting_log_size = trace_log_degree_bound()
            + circuit_pcs_config().fri_config.log_blowup_factor;
        prepare_preprocessed_query_positions(query_positions, lifting_log_size, *tree.tree_height)
    } else {
        query_positions
    };
    tree.verify(positions, values, decommitment_parsed);

    // Record the binding digest and the done bit.
    let d = poseidon_hash_span(queried_values);
    let mut d_queried = array![];
    let mut i = 0;
    for old in state.d_queried.span() {
        d_queried.append(if i == tree_idx {
            d
        } else {
            *old
        });
        i += 1;
    }
    state.d_queried = d_queried;
    state.trees_done = state.trees_done | bit;
}

fn pow2_u32(n: u32) -> u32 {
    let mut r = 1;
    for _ in 0..n {
        r *= 2;
    }
    r
}

// ---------------------------------------------------------------------------------------------
// Phase 3: `answers` (FRI first-layer query answers from the OODS quotients)
// ---------------------------------------------------------------------------------------------

/// Computes the FRI first-layer evaluations at the query positions from the (digest-bound)
/// sampled values and the (Merkle-verified, digest-bound) queried values of every tree.
/// `sampled_values`: the fast-path packed sampled-values section of `n_sampled` felts;
/// `queried_values_per_tree` / `n_qv`: the 4 packed per-tree cairo-serde `Span<M31>` sections
/// and their felt counts, in tree order.
pub fn answers(
    state: MerkleState,
    sampled_values: Span<felt252>,
    n_sampled: u32,
    queried_values_per_tree: Span<Span<felt252>>,
    n_qv: Span<u32>,
) -> FriState {
    let MerkleState { params, trees_done, d_queried } = state;
    assert!(trees_done == pow2_u32(N_TREES) - 1, "answers: merkle phase incomplete");
    assert!(poseidon_hash_span(sampled_values) == params.d_sampled, "answers: sampled digest");
    assert!(queried_values_per_tree.len() == N_TREES, "answers: need 4 trees");
    assert!(n_qv.len() == N_TREES, "answers: need 4 lengths");

    let mut sv_limbs = unpack_limbs(sampled_values, n_sampled);
    let sampled = read_sampled_values(ref sv_limbs);
    end(sv_limbs);

    let mut queried: Array<Span<M31>> = array![];
    let mut i = 0;
    for section in queried_values_per_tree {
        assert!(poseidon_hash_span(*section) == *d_queried.at(i), "answers: queried digest");
        let mut limbs = unpack_limbs(*section, *n_qv.at(i));
        queried.append(read_m31_span(ref limbs));
        end(limbs);
        i += 1;
    }

    let commitment_scheme = rebuild_commitment_scheme(params.tree_roots.span());
    let fri_config = circuit_pcs_config().fri_config;
    let oods_point = CirclePoint { x: params.oods_point_x, y: params.oods_point_y };
    let first_layer_evals = fri_answers(
        commitment_scheme.column_indices_per_tree_by_degree_bound(),
        fri_config.log_blowup_factor,
        oods_point,
        sampled,
        params.random_coeff,
        params.query_positions.span(),
        queried,
        trace_log_degree_bound(),
    );

    let mut layer_query_evals = array![];
    for e in first_layer_evals {
        layer_query_evals.append(*e);
    }
    let mut layer_query_positions = array![];
    for p in params.query_positions.span() {
        layer_query_positions.append(*p);
    }
    let layer_log_domain_size = trace_log_degree_bound() + fri_config.log_blowup_factor;
    FriState {
        params, layers_done: 0, layer_query_positions, layer_log_domain_size, layer_query_evals,
    }
}

// ---------------------------------------------------------------------------------------------
// Phase 4..: `fri_layers` (the decommit walk, chunked at layer boundaries)
// ---------------------------------------------------------------------------------------------

/// Decommits and folds the next `layers` (the fast-path packed cairo-serde
/// `Array<FriLayerProof>` of `n_values` felts, in layer order, starting at layer
/// `state.layers_done`: index 0 is the first (circle) layer, 1.. the inner layers). Each layer's
/// commitment must equal the transcript-bound one in the checkpoint. When the last inner layer
/// is folded, the last-layer check runs and the function returns `Some(output_hash)`: the proof
/// is valid.
pub fn fri_layers(ref state: FriState, layers: Span<felt252>, n_values: u32) -> Option<[u32; 8]> {
    let mut limbs = unpack_limbs(layers, n_values);
    let layer_proofs = read_fri_layers(ref limbs);
    end(limbs);
    assert!(layer_proofs.len() > 0, "fri: empty chunk");

    let fri_config = circuit_pcs_config().fri_config;
    let n_layers_total = 1 + state.params.fri_inner.len();
    let mut positions = state.layer_query_positions.span();
    let mut evals = state.layer_query_evals.span();
    let mut log_domain_size = state.layer_log_domain_size;
    let mut layers_done = state.layers_done;
    // The first (circle) layer's folded evaluations before the inner walk.
    let mut layer_query_evals: Array<QM31> = array![];
    for e in evals {
        layer_query_evals.append(*e);
    }

    for layer_proof in layer_proofs.span() {
        assert!(layers_done < n_layers_total, "fri: too many layers");
        let queries = Queries { positions, log_domain_size };
        if layers_done == 0 {
            // First layer (mirrors `decommit_first_layer` + the `fold_circle` of
            // `decommit_inner_layers`).
            let p = state.params.fri_first;
            assert!(*layer_proof.commitment == p.commitment, "fri: first commitment");
            let commitment_domain = CanonicCosetImpl::new(
                p.log_degree_bound + fri_config.log_blowup_factor,
            )
                .circle_domain();
            let verifier = FriFirstLayerVerifier {
                log_blowup_factor: fri_config.log_blowup_factor,
                log_bound: p.log_degree_bound,
                commitment_domain,
                folding_alpha: p.folding_alpha,
                proof: layer_proof.clone(),
                fold_step: p.fold_step,
            };
            let sparse = verifier.verify(queries, layer_query_evals.span());
            layer_query_evals = sparse
                .fold_circle(p.folding_alpha, commitment_domain, p.fold_step);
            let folded = queries.fold(p.fold_step);
            positions = folded.positions;
            log_domain_size = folded.log_domain_size;
        } else {
            let inner_idx = layers_done - 1;
            let p = *state.params.fri_inner.at(inner_idx);
            assert!(*layer_proof.commitment == p.commitment, "fri: inner commitment");
            let verifier = FriInnerLayerVerifier {
                log_degree_bound: p.log_degree_bound,
                domain: inner_layer_domain(p.log_degree_bound),
                folding_alpha: p.folding_alpha,
                layer_index: inner_idx,
                proof: layer_proof,
                fold_step: p.fold_step,
            };
            let (folded_queries, folded_evals) = verifier
                .verify_and_fold(queries, layer_query_evals.span());
            positions = folded_queries.positions;
            log_domain_size = folded_queries.log_domain_size;
            layer_query_evals = folded_evals;
        }
        layers_done += 1;
    }

    // Persist the walk.
    let mut new_positions = array![];
    for p in positions {
        new_positions.append(*p);
    }
    state.layer_query_positions = new_positions;
    state.layer_log_domain_size = log_domain_size;
    state.layers_done = layers_done;

    if layers_done < n_layers_total {
        state.layer_query_evals = layer_query_evals;
        return None;
    }
    // Last layer (mirrors `decommit_last_layer`).
    for query_eval in layer_query_evals.span() {
        assert!(
            *query_eval == state.params.fri_last_layer_value, "Invalid last layer evaluations",
        );
    }
    state.layer_query_evals = array![];
    Some(state.params.output_hash)
}

/// Domain of the inner layer whose polynomial has `log_degree_bound` (mirrors the domain
/// walk of `FriVerifierImpl::commit`: `half_odds(log_bound - fold_step + blowup)` repeatedly
/// doubled by each previous layer's fold step — i.e. simply `half_odds(log_degree_bound +
/// blowup)`).
fn inner_layer_domain(log_degree_bound: u32) -> LineDomain {
    let log_blowup_factor = circuit_pcs_config().fri_config.log_blowup_factor;
    LineDomainImpl::new_unchecked(CosetImpl::half_odds(log_degree_bound + log_blowup_factor))
}
