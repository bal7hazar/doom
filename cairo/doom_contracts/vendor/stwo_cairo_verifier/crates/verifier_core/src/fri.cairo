use core::array::SpanIter;
use core::dict::Felt252Dict;
use core::iter::{IntoIterator, Iterator};
use stwo_verifier_utils::zip_eq::zip_eq;
use crate::Hash;
use crate::channel::{Channel, ChannelTrait};
use crate::circle::{
    CirclePoint, CirclePointIndex, CirclePointIndexImpl, CirclePointIndexTrait,
    CirclePointM31Impl, CosetImpl,
};
use crate::fields::{BatchInvertible, Invertible};
use crate::fields::m31::M31;
use crate::fields::qm31::{QM31, QM31Serde, QM31Trait, QM31_EXTENSION_DEGREE};
use crate::poly::circle::{CanonicCosetImpl, CircleDomain, CircleDomainImpl};
use crate::poly::line::{LineDomain, LineDomainImpl, LineDomainTrait, LineEvaluationImpl, LinePoly};
use crate::poly::utils::fri_fold;
use crate::queries::{Queries, QueriesImpl};
use crate::utils::{ArrayImpl, OptionImpl, SpanExTrait, bit_reverse_index, pow2};
use crate::vcs::MerkleHasher;
use crate::vcs::verifier::{MerkleDecommitment, MerkleVerifier, MerkleVerifierTrait};

/// Lazily-reduced fold arithmetic (Hellproof patch 0002).
mod lazy;
use lazy::{fold_subset, lazy_add_x, lazy_add_y, lazy_double_x, reduce_narrow};

/// Number of QM31 evaluations packed into a single Merkle leaf when `fold_step > 1`.
pub const LOG_PACKED_LEAF_SIZE: u32 = 2;

#[derive(Drop, Serde, Copy, PartialEq)]
pub struct FriConfig {
    pub pow_bits: u32,
    pub log_blowup_factor: u32,
    pub log_last_layer_degree_bound: u32,
    pub n_queries: usize,
    pub fold_step: u32,
}

#[generate_trait]
pub impl FriConfigImpl of FriConfigTrait {
    fn security_bits(self: @FriConfig) -> u32 {
        *self.pow_bits + *self.log_blowup_factor * *self.n_queries
    }
}

#[derive(Drop)]
pub struct FriVerifier {
    pub config: FriConfig,
    pub first_layer: FriFirstLayerVerifier,
    pub inner_layers: Array<FriInnerLayerVerifier>,
    pub last_layer_domain: LineDomain,
    pub last_layer_poly: LinePoly,
}

#[generate_trait]
pub impl FriVerifierImpl of FriVerifierTrait {
    /// Verifies the commitment stage of FRI.
    ///
    /// `log_bound` should be the committed circle polynomial log
    /// degree bound.
    fn commit(
        ref channel: Channel, config: FriConfig, proof: FriProof, log_bound: u32,
    ) -> FriVerifier {
        let FriProof {
            first_layer: first_layer_proof, inner_layers: mut inner_layer_proofs, last_layer_poly,
        } = proof;

        channel.mix_commitment(first_layer_proof.commitment);

        let commitment_domain_log_size = log_bound + config.log_blowup_factor;
        let commitment_domain = CanonicCosetImpl::new(commitment_domain_log_size).circle_domain();

        let first_layer = FriFirstLayerVerifier {
            log_blowup_factor: config.log_blowup_factor,
            log_bound,
            commitment_domain,
            proof: first_layer_proof,
            folding_alpha: channel.draw_secure_felt(),
            // The circle-to-line fold is always equal to `config.fold_step`.
            fold_step: config.fold_step,
        };

        let mut inner_layers = array![];
        let mut layer_log_bound = log_bound - config.fold_step;
        let mut layer_domain = LineDomainImpl::new_unchecked(
            CosetImpl::half_odds(layer_log_bound + config.log_blowup_factor),
        );

        let n_inner_layers = inner_layer_proofs.len();
        for (layer_index, layer_proof) in inner_layer_proofs.into_iter().enumerate() {
            channel.mix_commitment(*layer_proof.commitment);

            // Compute the folding step for this layer.
            let fold_step = if layer_index == n_inner_layers - 1 {
                // At the last inner layer, fold by the amount needed to reach exactly the
                // last layer degree bound.
                let remaining = layer_log_bound - config.log_last_layer_degree_bound;
                assert!(
                    1 <= remaining && remaining <= config.fold_step,
                    "{}",
                    FriVerificationError::InvalidNumFriLayers,
                );
                remaining
            } else {
                config.fold_step
            };

            inner_layers
                .append(
                    FriInnerLayerVerifier {
                        log_degree_bound: layer_log_bound,
                        domain: layer_domain,
                        folding_alpha: channel.draw_secure_felt(),
                        layer_index,
                        proof: layer_proof,
                        fold_step,
                    },
                );

            layer_log_bound -= fold_step;

            layer_domain = layer_domain.repeated_double(fold_step);
        }
        assert!(
            layer_log_bound == config.log_last_layer_degree_bound,
            "{}",
            FriVerificationError::InvalidNumFriLayers,
        );

        assert!(
            last_layer_poly.log_size == config.log_last_layer_degree_bound,
            "{}",
            FriVerificationError::LastLayerDegreeInvalid,
        );

        channel.mix_felts(last_layer_poly.coeffs.span());

        FriVerifier {
            config, first_layer, inner_layers, last_layer_domain: layer_domain, last_layer_poly,
        }
    }

    /// Verifies the decommitment stage of FRI.
    fn decommit(self: FriVerifier, queries: Queries, first_layer_query_evals: Span<QM31>) {
        let first_layer_sparse_evals = decommit_first_layer(
            @self, queries, first_layer_query_evals,
        );

        let inner_layer_queries = queries.fold(self.config.fold_step);

        let (last_layer_queries, last_layer_query_evals) = decommit_inner_layers(
            @self, inner_layer_queries, first_layer_sparse_evals,
        );

        decommit_last_layer(self, last_layer_queries, last_layer_query_evals)
    }

    /// Samples and returns query positions mapped by column log size.
    ///
    /// Output is of the form `(unique_log_sizes, queries_by_log_size)`.
    fn sample_query_positions(self: @FriVerifier, ref channel: Channel) -> Queries {
        let query_domain_log_size = self.first_layer.commitment_domain.log_size();
        let n_queries = *self.config.n_queries;
        let queries = QueriesImpl::generate(ref channel, query_domain_log_size, n_queries);
        queries
    }
}

/// Verifies the first layer decommitment.
///
/// Returns the queries and first layer folded column evaluations needed for
/// verifying the remaining layers.
fn decommit_first_layer(
    verifier: @FriVerifier, queries: Queries, first_layer_query_evals: Span<QM31>,
) -> SparseEvaluation {
    verifier.first_layer.verify(queries, first_layer_query_evals)
}

/// Verifies all inner layer decommitments.
///
/// Returns the queries and query evaluations needed for verifying the last FRI layer.
fn decommit_inner_layers(
    verifier: @FriVerifier, queries: Queries, mut first_layer_sparse_eval: SparseEvaluation,
) -> (Queries, Array<QM31>) {
    let mut layer_query_evals = first_layer_sparse_eval
        .fold_circle(
            *verifier.first_layer.folding_alpha,
            *verifier.first_layer.commitment_domain,
            *verifier.config.fold_step,
        );

    let mut layer_queries = queries;
    for layer in verifier.inner_layers.span() {
        let (folded_queries, mut folded_query_evals) = layer
            .verify_and_fold(queries: layer_queries, evals_at_queries: layer_query_evals.span());

        layer_queries = folded_queries;
        layer_query_evals = folded_query_evals;
    }

    (layer_queries, layer_query_evals)
}

/// Verifies the last layer.
#[inline]
fn decommit_last_layer(verifier: FriVerifier, mut queries: Queries, mut query_evals: Array<QM31>) {
    let FriVerifier { last_layer_poly, .. } = verifier;

    let single_value_box: Box<[QM31; 1]> = *last_layer_poly
        .coeffs
        .span()
        .try_into()
        .unwrap_or_else(|| panic!("{}", FriVerificationError::LastLayerLogDegreeMustBeZero));
    let [expected_last_layer_value] = single_value_box.unbox();

    for query_eval in query_evals {
        assert!(
            query_eval == expected_last_layer_value,
            "{}",
            FriVerificationError::LastLayerEvaluationsInvalid,
        );
    }
}

/// Returns the column query positions needed for verification.
///
/// The column log sizes must be unique and in descending order.
/// Returned column query positions are mapped by their log size.
fn get_query_positions_by_log_size(
    mut queries: Queries, mut unique_column_log_sizes: Span<u32>,
) -> Felt252Dict<Nullable<Span<usize>>> {
    let mut query_positions_by_log_size: Felt252Dict<Nullable<Span<usize>>> = Default::default();

    for column_log_size in unique_column_log_sizes {
        let n_folds = queries.log_domain_size - *column_log_size;

        if n_folds != 0 {
            queries = queries.fold(n_folds);
        }

        query_positions_by_log_size
            .insert((*column_log_size).into(), NullableTrait::new(queries.positions));
    }

    query_positions_by_log_size
}

/// A FRI proof.
#[derive(Drop, Serde)]
pub struct FriProof {
    pub first_layer: FriLayerProof,
    pub inner_layers: Span<FriLayerProof>,
    pub last_layer_poly: LinePoly,
}

#[derive(Drop)]
pub struct FriFirstLayerVerifier {
    /// The log blowup factor for all the columns in the first layer.
    pub log_blowup_factor: u32,
    /// The degree bound of the circle polynomial committed in the first layer.
    pub log_bound: u32,
    /// The commitment domain of the circle polynomial committed in the first layer.
    pub commitment_domain: CircleDomain,
    pub folding_alpha: QM31,
    pub proof: FriLayerProof,
    pub fold_step: u32,
}

#[generate_trait]
pub impl FriFirstLayerVerifierImpl of FriFirstLayerVerifierTrait {
    /// Verifies the first layer's Merkle decommitment, and returns the evaluations needed for
    /// folding the columns to their corresponding layer.
    ///
    /// # Panics
    ///
    /// Panics if:
    /// * The proof doesn't store enough evaluations.
    /// * The queries are sampled on the wrong domain.
    /// * There are an invalid number of provided column evals.
    /// * The Merkle decommitment is invalid.
    fn verify(
        self: @FriFirstLayerVerifier, queries: Queries, mut query_evals: Span<QM31>,
    ) -> SparseEvaluation {
        let log_size = self.commitment_domain.log_size();
        assert!(queries.log_domain_size == log_size);

        let mut fri_witness = (*self.proof.fri_witness).into_iter();
        // For decommitment, each QM31 col must be split into its constituent M31 coordinate cols.
        let mut decommitted_values = array![];

        let (folded_query_positions, sparse_evaluation) =
            compute_decommitment_positions_and_rebuild_evals(
            queries, query_evals, ref fri_witness, *self.fold_step,
        );

        for subset_eval in sparse_evaluation.subset_evals.span() {
            for eval in subset_eval.span() {
                // Split the QM31 into its M31 coordinate values.
                let [v0, v1, v2, v3] = (*eval).to_fixed_array();
                decommitted_values.append(v0);
                decommitted_values.append(v1);
                decommitted_values.append(v2);
                decommitted_values.append(v3);
            };
        }

        // Check all proof evals have been consumed.
        assert!(
            fri_witness.next().is_none(), "{}", FriVerificationError::FirstLayerEvaluationsInvalid,
        );

        let leaf_log_size: u32 = if self.commitment_domain.log_size() >= LOG_PACKED_LEAF_SIZE
            && *self.fold_step > 1 {
            LOG_PACKED_LEAF_SIZE
        } else {
            0
        };
        let merkle_positions = merkle_positions_of_subsets(
            folded_query_positions, pow2(*self.fold_step - leaf_log_size),
        );
        let n_columns = QM31_EXTENSION_DEGREE * pow2(leaf_log_size);
        let degree_bound_by_column = ArrayImpl::new_repeated(n: n_columns, v: *self.log_bound);
        let merkle_verifier = MerkleVerifier {
            root: *self.proof.commitment,
            tree_height: log_size - leaf_log_size,
            column_log_deg_bounds: degree_bound_by_column.span(),
        };

        merkle_verifier
            .verify(merkle_positions, decommitted_values.span(), self.proof.decommitment.clone());

        sparse_evaluation
    }
}

#[derive(Drop, Debug)]
pub struct FriInnerLayerVerifier {
    pub log_degree_bound: u32,
    pub domain: LineDomain,
    pub folding_alpha: QM31,
    pub layer_index: usize,
    pub proof: @FriLayerProof,
    pub fold_step: u32,
}

#[generate_trait]
pub impl FriInnerLayerVerifierImpl of FriInnerLayerVerifierTrait {
    /// Verifies the layer's Merkle decommitment and returns the the folded queries and query evals.
    ///
    /// # Panics
    ///
    /// Panics if the Merkle decommitment is invalid.
    fn verify_and_fold(
        self: @FriInnerLayerVerifier, queries: Queries, evals_at_queries: Span<QM31>,
    ) -> (Queries, Array<QM31>) {
        assert!(queries.log_domain_size == self.domain.log_size());

        let mut fri_witness = (**self.proof.fri_witness).into_iter();

        let (folded_query_positions, sparse_evaluation) =
            compute_decommitment_positions_and_rebuild_evals(
            queries, evals_at_queries, ref fri_witness, *self.fold_step,
        );

        // Check all proof evals have been consumed.
        assert!(
            fri_witness.next().is_none(), "{}", FriVerificationError::InnerLayerEvaluationsInvalid,
        );

        let mut decommitted_values = array![];
        for subset_eval in sparse_evaluation.subset_evals.span() {
            for eval in subset_eval.span() {
                // Split the QM31 into its M31 coordinate values.
                let [v0, v1, v2, v3] = (*eval).to_fixed_array();
                decommitted_values.append(v0);
                decommitted_values.append(v1);
                decommitted_values.append(v2);
                decommitted_values.append(v3);
            };
        }

        let column_log_size = self.domain.log_size();
        let leaf_log_size: u32 = if self.domain.log_size() >= LOG_PACKED_LEAF_SIZE
            && *self.fold_step > 1 {
            LOG_PACKED_LEAF_SIZE
        } else {
            0
        };
        let merkle_positions = merkle_positions_of_subsets(
            folded_query_positions, pow2(*self.fold_step - leaf_log_size),
        );
        let n_columns = QM31_EXTENSION_DEGREE * pow2(leaf_log_size);
        let degree_bound_by_column = ArrayImpl::new_repeated(
            n: n_columns, v: *self.log_degree_bound,
        );
        let merkle_verifier = MerkleVerifier {
            root: **self.proof.commitment,
            tree_height: column_log_size - leaf_log_size,
            column_log_deg_bounds: degree_bound_by_column.span(),
        };

        merkle_verifier
            .verify(
                merkle_positions, decommitted_values.span(), (*self.proof.decommitment).clone(),
            );

        // The folded queries of `queries.fold(fold_step)`, already computed above.
        let folded_queries = Queries {
            positions: folded_query_positions,
            log_domain_size: queries.log_domain_size - *self.fold_step,
        };
        let folded_evals = sparse_evaluation
            .fold_line(*self.folding_alpha, *self.domain, *self.fold_step);

        (folded_queries, folded_evals)
    }
}

/// Returns the folded query positions (the index of each queried subset) and re-builds the
/// evaluations needed by the verifier for folding and decommitment.
///
/// (Hellproof patch 0002) Returns the folded positions instead of the flat decommitment
/// positions: the subsets' Merkle positions follow from them arithmetically
/// (`merkle_positions_of_subsets`) and the caller reuses them as the next layer's queries. The
/// decommitment positions of a subset are generated as `subset_start + offset` from a per-layer
/// offset span (one range check each) instead of a range iterator (two each).
///
/// # Panics
///
/// Panics if the number of queries doesn't match the number of query evals.
fn compute_decommitment_positions_and_rebuild_evals(
    queries: Queries,
    mut query_evals: Span<QM31>,
    ref witness_evals_iter: SpanIter<QM31>,
    fold_step: u32,
) -> (Span<usize>, SparseEvaluation) {
    let fold_factor = pow2(fold_step);
    let mut subset_offsets = array![];
    for offset in 0..fold_factor {
        subset_offsets.append(offset);
    }
    let subset_offsets = subset_offsets.span();

    let mut subset_evals = array![];
    let mut subset_domain_start_indices = array![];

    let mut query_positions = queries.positions;
    let folded_query_positions = queries.fold(fold_step).positions;

    for folded_query_position in folded_query_positions {
        let subset_start = *folded_query_position * fold_factor;
        let mut subset_eval = array![];

        // Extract the subset eval: if the decommitment position is a query position, take the
        // value from `query_evals`, else take it from `witness_evals`.
        for offset in subset_offsets {
            let decommitment_position = subset_start + *offset;
            subset_eval
                .append(
                    *match query_positions.next_if_eq(@decommitment_position) {
                        Some(_) => query_evals.pop_front().unwrap(),
                        None => witness_evals_iter.next().unwrap(),
                    },
                );
        }

        subset_evals.append(subset_eval);

        subset_domain_start_indices
            .append(bit_reverse_index(subset_start, queries.log_domain_size));
    }

    // Sanity check all the values have been consumed.
    assert!(query_positions.is_empty());
    assert!(query_evals.is_empty());

    let sparse_evaluation = SparseEvaluationImpl::new(
        subset_evals, subset_domain_start_indices.span(),
    );

    (folded_query_positions, sparse_evaluation)
}

/// Foldable subsets of evaluations on a circle polynomial or univariate polynomial.
#[derive(Drop)]
pub struct SparseEvaluation {
    // TODO(andrew): Perhaps subset isn't the right word. Coset, Subgroup?
    pub subset_evals: Array<Array<QM31>>,
    pub subset_domain_initial_indexes: Span<usize>,
}

#[generate_trait]
pub impl SparseEvaluationImpl of SparseEvaluationTrait {
    fn new(
        subset_evals: Array<Array<QM31>>, subset_domain_initial_indexes: Span<usize>,
    ) -> SparseEvaluation {
        assert!(subset_evals.len() == subset_domain_initial_indexes.len());
        SparseEvaluation { subset_evals, subset_domain_initial_indexes }
    }

    /// Folds evaluations of a degree `d` univariate polynomial into evaluations of a degree
    /// `d / 2^fold_step` univariate polynomial.
    ///
    /// (Hellproof patch 0002) Same folds as before — level `l` of a subset pairs consecutive
    /// values with `fri_fold(v0, v1, 1/x, alpha^(2^l))`, `x` running over the fold domain's
    /// x-coordinates in bit-reversed order then their repeated doublings — computed as:
    /// per layer, the step multiples of the fold domain (in the twiddle order) and the alpha
    /// powers; per subset, the twiddles from a single `to_point` (the other x-coordinates are
    /// `x(p0 + k G)` with reduced `p0` and constant `k G`, one reduction each); one Montgomery
    /// batch inversion of all the layer's twiddles; then the lazily-reduced subset folds.
    fn fold_line(
        self: @SparseEvaluation, fold_alpha: QM31, source_domain: LineDomain, fold_step: u32,
    ) -> Array<QM31> {
        let half = pow2(fold_step) / 2;
        let step_multiples = step_multiples_bit_reversed(
            CirclePointIndexImpl::subgroup_gen(fold_step), fold_step,
        );
        let alpha_powers = alpha_powers(fold_alpha, fold_step);

        let mut twiddles: Array<M31> = array![];
        for subset_domain_initial_index in *self.subset_domain_initial_indexes {
            let fold_domain_initial = source_domain.coset.index_at(*subset_domain_initial_index);
            let p0 = fold_domain_initial.to_point();
            let mut x_coords = line_x_coords(p0, step_multiples.span(), half);
            append_doubling_levels(ref twiddles, x_coords);
        }
        let mut itwiddles = BatchInvertible::batch_inverse(twiddles).span();

        let mut folded_eval = array![];
        for subset_eval in self.subset_evals.span() {
            folded_eval.append(fold_subset(subset_eval.span(), ref itwiddles, alpha_powers.span()));
        }
        assert!(itwiddles.is_empty());
        folded_eval
    }

    /// Folds evaluations of a degree `d` circle polynomial into evaluations of a
    /// degree `d / 2^fold_step` univariate polynomial.
    ///
    /// (Hellproof patch 0002) As `fold_line`: the first level folds with `1/y` of the circle
    /// fold domain's points (bit-reversed order of the half coset) and `alpha`, the next levels
    /// with `1/x` of every other of those points, their doublings, and `alpha^2, alpha^4, ...`.
    fn fold_circle(
        self: @SparseEvaluation, fold_alpha: QM31, source_domain: CircleDomain, fold_step: u32,
    ) -> Array<QM31> {
        let mut folded_eval = array![];

        if fold_step == 1 {
            for (subset_eval, subset_domain_initial_index) in zip_eq(
                self.subset_evals.span(), *self.subset_domain_initial_indexes,
            ) {
                let boxed_pair: Box<[QM31; 2]> = *subset_eval.span().try_into().unwrap();
                let [v0, v1] = boxed_pair.unbox();
                let circle_point = source_domain.at(*subset_domain_initial_index);
                folded_eval.append(fri_fold(v0, v1, circle_point.y.inverse(), fold_alpha));
            }
            return folded_eval;
        }

        // The circle fold domain of a subset is `p0 + <G>`, `G` the generator of order
        // `2^(fold_step - 1)` (the half coset of `CircleDomainImpl::new(CosetImpl::new(
        // fold_domain_initial, fold_step - 1))`); its points are visited at the indices
        // `bit_reverse_index(j, fold_step)`, `j` even, all below `2^(fold_step - 1)`.
        let half = pow2(fold_step) / 2;
        let step_multiples = step_multiples_bit_reversed(
            CirclePointIndexImpl::subgroup_gen(fold_step - 1), fold_step,
        );
        let alpha_powers = alpha_powers(fold_alpha, fold_step);

        let mut twiddles: Array<M31> = array![];
        for subset_domain_initial_index in *self.subset_domain_initial_indexes {
            let fold_domain_initial = source_domain.index_at(*subset_domain_initial_index);
            let p0 = fold_domain_initial.to_point();
            let px: felt252 = p0.x.into();
            let py: felt252 = p0.y.into();
            // Level 0: 1/y of every point.
            let mut x_coords: Array<M31> = array![];
            let mut first = true;
            let mut take_x = true;
            for m in step_multiples.span() {
                if first {
                    twiddles.append(p0.y);
                    x_coords.append(p0.x);
                    first = false;
                } else {
                    let mx: felt252 = (*m.x).into();
                    let my: felt252 = (*m.y).into();
                    twiddles.append(reduce_narrow(lazy_add_y(px, py, mx, my)));
                    if take_x {
                        x_coords.append(reduce_narrow(lazy_add_x(px, py, mx, my)));
                    }
                }
                take_x = !take_x;
            }
            assert!(x_coords.len() == half / 2);
            // Levels 1..: 1/x of every other point, then the doublings.
            append_doubling_levels(ref twiddles, x_coords);
        }
        let mut itwiddles = BatchInvertible::batch_inverse(twiddles).span();

        for subset_eval in self.subset_evals.span() {
            folded_eval.append(fold_subset(subset_eval.span(), ref itwiddles, alpha_powers.span()));
        }
        assert!(itwiddles.is_empty());
        folded_eval
    }
}

/// The points `k * step` for `k = bit_reverse_index(j, fold_step)`, `j = 0, 2, .., 2^fold_step - 2`
/// (the order in which the folds visit a subset's domain; the first one is the neutral point).
fn step_multiples_bit_reversed(step: CirclePointIndex, fold_step: u32) -> Array<CirclePoint<M31>> {
    let fold_factor = pow2(fold_step);
    let mut multiples = array![];
    let mut j = 0;
    while j != fold_factor {
        multiples.append(step.mul(bit_reverse_index(j, fold_step)).to_point());
        j += 2;
    }
    multiples
}

/// `alpha, alpha^2, alpha^4, ..., alpha^(2^(n - 1))`: the folding factor of each level.
fn alpha_powers(alpha: QM31, n: u32) -> Array<QM31> {
    let mut powers = array![];
    let mut power = alpha;
    for _ in 0..n {
        powers.append(power);
        power = power * power;
    }
    powers
}

/// The x-coordinates `x(p0 + m)` for the step multiples `m` (the first one being `p0` itself).
fn line_x_coords(
    p0: CirclePoint<M31>, mut step_multiples: Span<CirclePoint<M31>>, n: u32,
) -> Array<M31> {
    let px: felt252 = p0.x.into();
    let py: felt252 = p0.y.into();
    let mut x_coords = array![p0.x];
    let _ = step_multiples.pop_front();
    for m in step_multiples {
        x_coords.append(reduce_narrow(lazy_add_x(px, py, (*m.x).into(), (*m.y).into())));
    }
    assert!(x_coords.len() == n);
    x_coords
}

/// Appends to `out` the twiddles of a line fold tree in the order `fold_subset` consumes them:
/// `x_coords`, then the doublings of every other one, and so on down to a single value (the
/// `next_x_coords.append(double_x(x0))` of the original `fold_coset`).
fn append_doubling_levels(ref out: Array<M31>, mut level: Array<M31>) {
    loop {
        out.append_span(level.span());
        if level.len() == 1 {
            break;
        }
        let mut next = array![];
        let mut it = level.span();
        while let Some(x0) = it.pop_front() {
            let _ = it.pop_front();
            next.append(reduce_narrow(lazy_double_x((*x0).into())));
        }
        level = next;
    }
}

/// Merkle tree positions of the leaves covering the subsets `folded_positions` (ascending,
/// distinct), `leaves_per_subset = fold_factor / leaf_size` per subset.
///
/// (Hellproof patch 0002) Replaces the shift-and-deduplicate pass over the flat decommitment
/// positions: those are exactly the runs `[f * fold_factor, (f + 1) * fold_factor)` of the
/// folded positions `f`, so, shifted right by `leaf_log_size` and deduplicated, they are exactly
/// `f * leaves_per_subset + m` for `m < leaves_per_subset`, in the same ascending order. With
/// `leaf_size = 1` (`leaves_per_subset = fold_factor`) this is the identity on the decommitment
/// positions, as before.
fn merkle_positions_of_subsets(folded_positions: Span<u32>, leaves_per_subset: u32) -> Span<u32> {
    let mut leaf_offsets = array![];
    for m in 0..leaves_per_subset {
        leaf_offsets.append(m);
    }
    let leaf_offsets = leaf_offsets.span();
    let mut merkle_positions = array![];
    for f in folded_positions {
        let start = *f * leaves_per_subset;
        for m in leaf_offsets {
            merkle_positions.append(start + *m);
        }
    }
    merkle_positions.span()
}

/// Folds `2^n` evaluations into a single evaluation using precomputed twiddles.
///
/// (Hellproof patch 0002) The tree of `fri_fold`s is now `lazy::fold_subset` over the batch-
/// inverted twiddles (`x_coords`, then the doublings of every other one, level by level).
///
/// # Arguments
///
/// * `eval` - evaluations of length `2^n` on a coset domain.
/// * `x_coords` - x-coordinates of the even-index coset points, of length `2^{n-1}`.
/// * `alpha` - the random folding factor.
pub fn fold_coset(eval: Span<QM31>, x_coords: Span<M31>, alpha: QM31) -> QM31 {
    assert!(eval.len() == 2 * x_coords.len());
    let mut n_levels = 0;
    let mut size = 1;
    while size != eval.len() {
        size *= 2;
        n_levels += 1;
    }
    let mut level = array![];
    level.append_span(x_coords);
    let mut twiddles = array![];
    append_doubling_levels(ref twiddles, level);
    let mut itwiddles = BatchInvertible::batch_inverse(twiddles).span();
    let folded = fold_subset(eval, ref itwiddles, alpha_powers(alpha, n_levels).span());
    assert!(itwiddles.is_empty());
    folded
}

/// Proof of an individual FRI layer.
#[derive(Drop, Clone, Debug, Serde)]
pub struct FriLayerProof {
    /// Values that the verifier needs but cannot deduce from previous computations, in the
    /// order they are needed. This complements the values that were queried. These must be
    /// supplied directly to the verifier.
    pub fri_witness: Span<QM31>,
    pub decommitment: MerkleDecommitment<MerkleHasher>,
    pub commitment: Hash,
}

#[derive(Debug, Drop)]
pub enum FriVerificationError {
    InvalidNumFriLayers,
    FirstLayerEvaluationsInvalid,
    InnerLayerEvaluationsInvalid,
    LastLayerDegreeInvalid,
    LastLayerEvaluationsInvalid,
    LastLayerLogDegreeMustBeZero,
}

impl FriVerificationErrorDisplay of core::fmt::Display<FriVerificationError> {
    fn fmt(
        self: @FriVerificationError, ref f: core::fmt::Formatter,
    ) -> Result<(), core::fmt::Error> {
        match self {
            FriVerificationError::InvalidNumFriLayers => write!(f, "Invalid number of FRI layers"),
            FriVerificationError::FirstLayerEvaluationsInvalid => write!(
                f, "Invalid First layer evaluations",
            ),
            FriVerificationError::InnerLayerEvaluationsInvalid => write!(
                f, "Invalid inner layer evaluations",
            ),
            FriVerificationError::LastLayerDegreeInvalid => write!(f, "Invalid last layer degree"),
            FriVerificationError::LastLayerEvaluationsInvalid => write!(
                f, "Invalid last layer evaluations",
            ),
            FriVerificationError::LastLayerLogDegreeMustBeZero => write!(
                f, "Last layer log degree must be zero",
            ),
        }
    }
}
