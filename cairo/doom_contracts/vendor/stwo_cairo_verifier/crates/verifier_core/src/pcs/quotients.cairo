use core::array::ArrayImpl;
use core::num::traits::{One, Zero};
use stwo_verifier_utils::zip_eq::zip_eq;
use crate::circle::{
    CirclePoint, CirclePointIndexImpl, CirclePointIndexTrait, CirclePointQM31AddCirclePointM31Trait,
    CosetImpl, M31_CIRCLE_LOG_ORDER,
};
use crate::fields::cm31::{CM31, CM31Trait, MulByCM31Trait};
use crate::fields::m31::{M31, M31Trait, M31Zero, MulByM31Trait, P};
use crate::fields::qm31::{
    PackedUnreducedQM31, PackedUnreducedQM31Trait, QM31, QM31One, QM31Trait,
    to_packed_unreduced_qm31,
};
use crate::fields::{BatchInvertible, Invertible};
use crate::poly::circle::{
    CanonicCosetImpl, CanonicCosetTrait, CircleDomainImpl, CircleEvaluationImpl,
};
use crate::utils::{
    ArrayImpl as ArrayUtilImpl, ColumnsIndicesPerTreeByLogDegreeBound, SpanExTrait, SpanImpl,
    bit_reverse_index, pack_qm31,
};
use crate::{TreeArray, TreeSpan};
use super::verifier::{QueriedValues, SampledValues};


#[cfg(test)]
mod test;

// (Hellproof patch 0003) The per-query work of `fri_answers` is done on unreduced `felt252`
// limbs: the numerators of every quotient batch are accumulated without reductions (one
// multiplication and one addition per limb and column, no range check), batches sampled at the
// same point — across the degree-bound groups — share one denominator, all the denominators of
// the proof are inverted with a single Montgomery batch inversion of their norms, and each row is
// reduced modulo P once. The batches, their coefficients (`QuotientConstantsImpl::gen`) and the
// denominators (`quotient_denominator`) are the ones of the original code; only the association
// of the sums and the moment of the reductions changed (see the bounds at each step).

/// `P * 2^41`: offset of a numerator accumulator, above the sum of at most 2^9 column terms
/// `alpha_mul_c * value < 2^62`.
const OFF_NUM: felt252 = 0xfffffffe0000000000;
/// `P * 2^105`: offset of the product of a numerator (below 2^73) by an inverse denominator
/// limb (below 2^62).
const OFF_QUOT: felt252 = 0xfffffffe000000000000000000000000000;
/// `P * P * 16` (as in `fields::qm31::naive::unreduced`).
const PP16: felt252 = 0x3fffffff000000010;

/// Computes the OOD quotients at the query positions.
///
/// # Arguments
///
/// * `column_indices_per_tree_by_degree_bound`: The column indices grouped by tree and by log
/// degree bound.
/// * `log_blowup_factor`: The FRI log blowup factor parameter.
/// * `oods_point`: The OOD point.
/// * `sample_values_per_column_per_tree`: OOD samples (only the eval) for each column in each tree.
/// * `random_coeff`: Verifier randomness for folding multiple columns' quotients together.
/// * `query_positions`: Query positions, as indices in the largest LDE domain (i.e. the lifting
/// domain), in ascending order.
/// * `queried_values_per_tree`: For each tree, contains all queried trace values.
/// * `max_log_degree_bound`: The max log degree of a committed polynomial.
pub fn fri_answers(
    mut column_indices_per_tree_by_degree_bound: ColumnsIndicesPerTreeByLogDegreeBound,
    log_blowup_factor: u32,
    oods_point: CirclePoint<QM31>,
    sample_values_per_column_per_tree: SampledValues,
    random_coeff: QM31,
    query_positions: Span<usize>,
    queried_values_per_tree: QueriedValues,
    max_log_degree_bound: u32,
) -> Span<QM31> {
    // Note that `log_size` is equal to 1 + largest log size of a trace column (the additional 1
    // comes from calling `len()` on `column_indices_per_tree_by_degree_bound`).
    // Check that the largest log size of a trace column is <= `M31_CIRCLE_LOG_ORDER` - 1.
    assert!(
        max_log_degree_bound + log_blowup_factor <= M31_CIRCLE_LOG_ORDER, "log_size is too large",
    );
    let n_trees = queried_values_per_tree.len();
    // Add to each sample value the corresponding random coefficient power.
    let samples_with_randomness: Span<Span<Span<(QM31, QM31)>>> = build_samples_with_randomness(
        sample_values_per_column_per_tree, random_coeff,
    );
    // The quotient constants of every degree bound: for i ∈ [0, max_log_degree_bound],
    // `groups[i]` holds the batches of the columns of log degree bound i (their point, their
    // per-column coefficients in row order, their per-batch sums).
    let mut groups: Array<GroupQuotients> = array![];
    let lifting_log_size = max_log_degree_bound + log_blowup_factor;
    let lifting_domain = CanonicCosetImpl::new(lifting_log_size);
    let lifting_domain_step = lifting_domain.coset.step.mul(1).to_point();

    let trace_step = CanonicCosetImpl::new(max_log_degree_bound).coset.step.mul(1).to_point();
    let prev_oods_point = oods_point.add_circle_point_m31(-trace_step);
    // For a column of log degree bound k, its periodicity samples are evaluated at the point
    // `oods_point + lifting_domain_step.repeated_double(k + log_blowup_factor)`. Here,
    // we initialize `periodicity_generator` to
    // `lifting_domain_step.repeated_double(log_blowup_factor)`.
    // Then when iterating over log_degree_bounds we double the periodicity step at the end of each
    // iteration.
    let mut periodicity_generator = lifting_domain_step;
    for _ in 0..log_blowup_factor {
        periodicity_generator = periodicity_generator + periodicity_generator;
    }
    let mut any_prev = false;
    for column_indices_per_tree_for_degree_bound in column_indices_per_tree_by_degree_bound {
        let (sample_batches, n_cols_per_tree) = sample_batches_for_degree_bound(
            column_indices_per_tree_for_degree_bound,
            samples_with_randomness,
            oods_point,
            prev_oods_point,
            periodicity_generator,
        );
        let quotient_constants = QuotientConstantsImpl::gen(sample_batches);
        let group = GroupQuotientsImpl::new(
            sample_batches, n_cols_per_tree, quotient_constants, oods_point, prev_oods_point,
        );
        any_prev = any_prev || group.prev.is_some();
        groups.append(group);
        periodicity_generator = periodicity_generator + periodicity_generator;
    }
    let groups = groups.span();

    // The sample points, in the order of the per-row class sums: the OODS point, the previous
    // point (if any column has two mask items), then the periodicity point of every group having
    // one. Batches at the same point share the denominator `quotient_denominator(point, domain
    // point)`: the sum of their numerators is multiplied by its inverse once.
    let mut class_points: Array<CirclePoint<QM31>> = array![oods_point];
    if any_prev {
        class_points.append(prev_oods_point);
    }
    for group in groups {
        if let Some((point, _, _)) = group.per {
            class_points.append(*point);
        }
    }
    let class_points = class_points.span();

    // Pass 1: per query, the domain point, the class sums of the numerators and the denominators
    // (reduced, with their norms).
    let mut queried_values_per_tree = queried_values_per_tree;
    let mut rows: Array<RowQuotients> = array![];
    let mut norms: Array<M31> = array![];
    for pos in query_positions {
        let domain_point = lifting_domain
            .circle_domain()
            .at(bit_reverse_index(*pos, lifting_log_size));
        let dx: felt252 = domain_point.x.into();
        let dy: felt252 = domain_point.y.into();

        let mut oods_sum = LazyImpl::offset(OFF_NUM);
        let mut prev_sum = LazyImpl::offset(OFF_NUM);
        let mut per_sums: Array<Lazy> = array![];
        for group in groups {
            let mut per_sum = LazyImpl::offset(OFF_NUM);
            // The row values of this group: `n_columns_per_tree[t]` next values of every tree,
            // in tree order (what `tree_take_n` returned).
            let mut new_trees = array![];
            let mut columns = group.columns.span();
            for (values, n) in zip_eq(queried_values_per_tree.span(), group.n_columns_per_tree.span()) {
                let mut values = *values;
                for _ in 0..*n {
                    let v: felt252 = (*values.pop_front().unwrap()).into();
                    let column = columns.pop_front().unwrap();
                    if *column.kind != 0 {
                        oods_sum = oods_sum.sub_mul(column.oods, v);
                        if *column.kind == 3 {
                            prev_sum = prev_sum.sub_mul(column.prev, v);
                            per_sum = per_sum.sub_mul(column.per, v);
                        }
                    }
                }
                new_trees.append(values);
            }
            assert!(columns.is_empty());
            queried_values_per_tree = new_trees;
            if let Some((a_sum, b_sum)) = group.oods {
                oods_sum = oods_sum.add_line(a_sum, b_sum, dy);
            }
            if let Some((a_sum, b_sum)) = group.prev {
                prev_sum = prev_sum.add_line(a_sum, b_sum, dy);
            }
            if let Some((_, a_sum, b_sum)) = group.per {
                per_sums.append(per_sum.add_line(a_sum, b_sum, dy));
            }
        }
        let mut class_sums = array![oods_sum];
        if any_prev {
            class_sums.append(prev_sum);
        }
        class_sums.append_span(per_sums.span());

        let mut denominators = array![];
        for point in class_points {
            let den = quotient_denominator(*point.x, *point.y, dx, dy);
            let a: felt252 = den.a.into();
            let b: felt252 = den.b.into();
            norms.append(reduce_narrow(a * a + b * b));
            denominators.append((a, P - b));
        }
        rows.append(RowQuotients { class_sums, denominators });
    }
    for queried_values in queried_values_per_tree {
        assert!(queried_values.is_empty())
    }

    // One inversion for all the denominators: `1 / (a + b i) = (a - b i) / (a^2 + b^2)`.
    let mut inv_norms = BatchInvertible::batch_inverse(norms).span();

    // Pass 2: `-(sum over the classes of class_sum * denominator^-1)`, reduced once per row.
    let mut answers: Array<QM31> = array![];
    for row in rows {
        let RowQuotients { class_sums, denominators } = row;
        let mut acc = LazyImpl::offset(0);
        for (class_sum, (conj_a, conj_b)) in zip_eq(class_sums, denominators) {
            let inv: felt252 = (*inv_norms.pop_front().unwrap()).into();
            acc = acc.add_mul_cm31(class_sum, conj_a * inv, conj_b * inv);
        }
        answers.append(-acc.reduce_wide());
    }
    assert!(inv_norms.is_empty());
    answers.span()
}

/// The per-row data of pass 1: the numerator sums of every class and the denominators
/// `(a, P - b)` of `a + b i` (reduced limbs).
#[derive(Drop)]
struct RowQuotients {
    class_sums: Array<Lazy>,
    denominators: Array<(felt252, felt252)>,
}

/// An unreduced QM31 `(a + b i) + (c + d i) u` with non-negative integer limbs in `felt252`s.
#[derive(Copy, Drop)]
struct Lazy {
    a: felt252,
    b: felt252,
    c: felt252,
    d: felt252,
}

#[generate_trait]
impl LazyImpl of LazyTrait {
    /// `off` in every limb (a multiple of P: zero modulo P).
    #[inline]
    fn offset(off: felt252) -> Lazy {
        Lazy { a: off, b: off, c: off, d: off }
    }

    /// `self - coeff * v` for a reduced coefficient and a reduced `v` (each product below
    /// 2^62).
    #[inline]
    fn sub_mul(self: Lazy, coeff: @[felt252; 4], v: felt252) -> Lazy {
        let [c0, c1, c2, c3] = coeff;
        Lazy {
            a: self.a - *c0 * v, b: self.b - *c1 * v, c: self.c - *c2 * v, d: self.d - *c3 * v,
        }
    }

    /// `self + a_sum * y + b_sum` for reduced `a_sum`, `b_sum` (QM31) and `y` (M31): the
    /// `alpha_mul_a_sum.mul_m31(domain_point_y) + alpha_mul_b_sum` of a batch.
    #[inline]
    fn add_line(self: Lazy, a_sum: @[felt252; 4], b_sum: @[felt252; 4], y: felt252) -> Lazy {
        let [a0, a1, a2, a3] = a_sum;
        let [b0, b1, b2, b3] = b_sum;
        Lazy {
            a: self.a + *a0 * y + *b0,
            b: self.b + *a1 * y + *b1,
            c: self.c + *a2 * y + *b2,
            d: self.d + *a3 * y + *b3,
        }
    }

    /// `self + s * (x + y i)` for limbs of `s` below 2^73 and `x`, `y` below 2^62:
    /// `(s_a + s_b i)(x + y i) = (s_a x - s_b y) + (s_a y + s_b x) i` on both CM31 halves, each
    /// difference offset by `OFF_QUOT >= 2^135`.
    #[inline]
    fn add_mul_cm31(self: Lazy, s: Lazy, x: felt252, y: felt252) -> Lazy {
        Lazy {
            a: self.a + s.a * x - s.b * y + OFF_QUOT,
            b: self.b + s.a * y + s.b * x,
            c: self.c + s.c * x - s.d * y + OFF_QUOT,
            d: self.d + s.c * y + s.d * x,
        }
    }

    /// Reduces limbs below 2^248 (`x = hi 2^128 + lo`, `2^128 ≡ 16 (mod P)`).
    fn reduce_wide(self: Lazy) -> QM31 {
        QM31Trait::from_fixed_array(
            [reduce_wide(self.a), reduce_wide(self.b), reduce_wide(self.c), reduce_wide(self.d)],
        )
    }
}

/// Reduces a limb below `2^128`.
#[inline]
fn reduce_narrow(x: felt252) -> M31 {
    M31Trait::reduce_u128(x.try_into().unwrap())
}

/// Reduces a limb below `2^248`.
#[inline]
fn reduce_wide(x: felt252) -> M31 {
    let u256 { low, high } = x.into();
    let lo = M31Trait::reduce_u128(low);
    let hi = M31Trait::reduce_u128(high);
    hi * m31_sixteen() + lo
}

#[inline]
fn m31_sixteen() -> M31 {
    M31Trait::new(16)
}

/// The quotient constants of one degree-bound group, in the shape pass 1 consumes them.
#[derive(Drop)]
struct GroupQuotients {
    /// Number of columns of the group in each tree (the row layout of `tree_take_n`).
    n_columns_per_tree: TreeArray<usize>,
    /// Per column of the group, in row order (tree by tree, column index ascending): its number
    /// of mask items (0: not sampled, 1: OODS only, 3: periodicity + previous + OODS) and its
    /// `alpha_mul_c` coefficient in each batch (reduced limbs; zero where absent).
    columns: Array<ColumnCoeffs>,
    /// `(alpha_mul_a_sum, alpha_mul_b_sum)` of the OODS batch.
    oods: Option<([felt252; 4], [felt252; 4])>,
    /// The same for the previous-point batch.
    prev: Option<([felt252; 4], [felt252; 4])>,
    /// The periodicity batch: its point and sums.
    per: Option<(CirclePoint<QM31>, [felt252; 4], [felt252; 4])>,
}

#[derive(Drop)]
struct ColumnCoeffs {
    kind: felt252,
    oods: [felt252; 4],
    prev: [felt252; 4],
    per: [felt252; 4],
}

#[generate_trait]
impl GroupQuotientsImpl of GroupQuotientsTrait {
    /// Reshapes the batches of `sample_batches_for_degree_bound` and the constants of
    /// `QuotientConstantsImpl::gen` (in the same order) by point: the batch at `oods_point` is
    /// the OODS batch, the one at `prev_oods_point` the previous-point batch, any other one the
    /// periodicity batch. (A group whose periodicity point coincides with the OODS point — the
    /// largest columns — gets its periodicity batch merged into the OODS class, which changes
    /// nothing: same denominator.)
    fn new(
        sample_batches: Span<ColumnSampleBatch>,
        n_columns_per_tree: TreeArray<usize>,
        constants: QuotientConstants,
        oods_point: CirclePoint<QM31>,
        prev_oods_point: CirclePoint<QM31>,
    ) -> GroupQuotients {
        let mut n_columns: usize = 0;
        for n in n_columns_per_tree.span() {
            n_columns += *n;
        }
        let mut oods: Option<([felt252; 4], [felt252; 4])> = None;
        let mut prev: Option<([felt252; 4], [felt252; 4])> = None;
        let mut per: Option<(CirclePoint<QM31>, [felt252; 4], [felt252; 4])> = None;
        // Per column index: the coefficient in each batch, as merged sorted lists. Two batches
        // can sit at the OODS point (the periodicity batch of the largest columns): both go to
        // the OODS class, their sums and coefficients added.
        let mut oods_coeffs: Span<(usize, QM31)> = array![].span();
        let mut oods2_coeffs: Span<(usize, QM31)> = array![].span();
        let mut prev_coeffs: Span<(usize, QM31)> = array![].span();
        let mut per_coeffs: Span<(usize, QM31)> = array![].span();
        for (batch, point_constants) in zip_eq(sample_batches, constants.point_constants.span()) {
            let a_sum = limbs(*point_constants.alpha_mul_a_sum);
            let b_sum = limbs(*point_constants.alpha_mul_b_sum);
            let coeffs = point_constants.indexed_alpha_mul_c.span();
            if *batch.point == oods_point {
                match oods {
                    None => {
                        oods = Some((a_sum, b_sum));
                        oods_coeffs = coeffs;
                    },
                    Some((a0, b0)) => {
                        assert!(oods2_coeffs.is_empty());
                        oods = Some((add_limbs(a0, a_sum), add_limbs(b0, b_sum)));
                        oods2_coeffs = coeffs;
                    },
                }
            } else if *batch.point == prev_oods_point {
                assert!(prev.is_none());
                prev = Some((a_sum, b_sum));
                prev_coeffs = coeffs;
            } else {
                assert!(per.is_none());
                per = Some((*batch.point, a_sum, b_sum));
                per_coeffs = coeffs;
            }
        }
        let zero4: [felt252; 4] = [0, 0, 0, 0];
        let mut columns = array![];
        for index in 0..n_columns {
            let mut kind: felt252 = 0;
            let mut c_oods = zero4;
            let mut c_prev = zero4;
            let mut c_per = zero4;
            if let Some((i, coeff)) = oods_coeffs.first() && *i == index {
                let _ = oods_coeffs.pop_front();
                kind = 1;
                c_oods = limbs(*coeff);
            }
            if let Some((i, coeff)) = oods2_coeffs.first() && *i == index {
                let _ = oods2_coeffs.pop_front();
                kind = 1;
                c_oods = add_limbs(c_oods, limbs(*coeff));
            }
            if let Some((i, coeff)) = prev_coeffs.first() && *i == index {
                let _ = prev_coeffs.pop_front();
                kind = 3;
                c_prev = limbs(*coeff);
            }
            if let Some((i, coeff)) = per_coeffs.first() && *i == index {
                let _ = per_coeffs.pop_front();
                kind = 3;
                c_per = limbs(*coeff);
            }
            columns.append(ColumnCoeffs { kind, oods: c_oods, prev: c_prev, per: c_per });
        }
        assert!(oods2_coeffs.is_empty());
        assert!(oods_coeffs.is_empty() && prev_coeffs.is_empty() && per_coeffs.is_empty());
        GroupQuotients { n_columns_per_tree, columns, oods, prev, per }
    }
}

/// The four coordinates of a reduced QM31 as felts.
#[inline]
fn limbs(v: QM31) -> [felt252; 4] {
    let [a, b, c, d] = v.to_fixed_array();
    [a.into(), b.into(), c.into(), d.into()]
}

/// Limb-wise sum of two reduced limb arrays (the two OODS-point batches of a group: below 2^32).
#[inline]
fn add_limbs(x: [felt252; 4], y: [felt252; 4]) -> [felt252; 4] {
    let [x0, x1, x2, x3] = x;
    let [y0, y1, y2, y3] = y;
    [x0 + y0, x1 + y1, x2 + y2, x3 + y3]
}

/// Gathers sample batches and column counts for a given degree bound.
fn sample_batches_for_degree_bound(
    column_indices_per_tree: @TreeSpan<Span<usize>>,
    sample_values_with_rand: Span<Span<Span<(QM31, QM31)>>>,
    oods_point: CirclePoint<QM31>,
    prev_oods_point: CirclePoint<QM31>,
    periodicity_generator: CirclePoint<M31>,
) -> (Span<ColumnSampleBatch>, TreeArray<usize>) {
    /// The triples (column index, evaluation, random coefficient) at the out of domain point 'Z'.
    let mut col_eval_coeff_triples_at_point = array![];
    /// The triples (column index, evaluation, random coefficient) at the point `Z-g`.
    let mut col_eval_coeff_triples_at_prev_point = array![];
    ///  The (column index, evaluation) pairs at the point `Z + periodicity_generator`.
    let mut col_eval_coeff_triples_at_point_plus_periodicity = array![];

    let mut n_columns_per_tree = array![];
    let mut index = 0;
    for (column_indices, samples_per_column) in zip_eq(
        *column_indices_per_tree, sample_values_with_rand,
    ) {
        for column_idx in column_indices {
            // Note that samples_per_column[*column] can be an empty array.
            let mut sample_values_at_column = *samples_per_column[*column_idx];

            if let Some(tuple_box) = sample_values_at_column.try_into() {
                let [
                    (periodicity_point_sample, periodicity_point_rand),
                    (prev_point_sample, prev_point_rand),
                    (point_sample, point_rand),
                ]: [(QM31, QM31); 3] =
                    (*tuple_box)
                    .unbox();

                col_eval_coeff_triples_at_point_plus_periodicity
                    .append((index, periodicity_point_sample, periodicity_point_rand));
                col_eval_coeff_triples_at_prev_point
                    .append((index, prev_point_sample, prev_point_rand));
                col_eval_coeff_triples_at_point.append((index, point_sample, point_rand));
            } else if let Some(point_box) = sample_values_at_column.try_into() {
                let [(point_sample, rand)]: [(QM31, QM31); 1] = (*point_box).unbox();

                col_eval_coeff_triples_at_point.append((index, point_sample, rand));
            } else {
                assert!(sample_values_at_column.is_empty(), "Unexpected number of samples");
            }
            index += 1;
        }

        n_columns_per_tree.append(column_indices.len());
    }

    let mut sample_batches_by_point: Array<ColumnSampleBatch> = array![];
    if !col_eval_coeff_triples_at_point_plus_periodicity.is_empty() {
        let point_plus_periodicity = oods_point.add_circle_point_m31(periodicity_generator);
        sample_batches_by_point
            .append(
                ColumnSampleBatch {
                    point: point_plus_periodicity,
                    cols_vals_and_pows: col_eval_coeff_triples_at_point_plus_periodicity,
                },
            );
    }
    if !col_eval_coeff_triples_at_prev_point.is_empty() {
        sample_batches_by_point
            .append(
                ColumnSampleBatch {
                    point: prev_oods_point,
                    cols_vals_and_pows: col_eval_coeff_triples_at_prev_point,
                },
            );
    }
    if !col_eval_coeff_triples_at_point.is_empty() {
        sample_batches_by_point
            .append(
                ColumnSampleBatch {
                    point: oods_point, cols_vals_and_pows: col_eval_coeff_triples_at_point,
                },
            );
    }

    (sample_batches_by_point.span(), n_columns_per_tree)
}

// TODO(Leo): think about merging the loop in this function with the loop in
// [`sample_batches_for_degree_bound`].
fn build_samples_with_randomness(
    sample_values_per_column_per_tree: SampledValues, random_coeff: QM31,
) -> Span<Span<Span<(QM31, QM31)>>> {
    let mut samples_with_randomness_per_tree = array![];
    let mut random_pow: QM31 = One::one();
    for sample_values_per_column in sample_values_per_column_per_tree {
        let mut new_samples_per_col = array![];
        for sample_values in sample_values_per_column {
            let mut new_samples = array![];
            // If the column is sampled at OOD point and its neighbor, we add a periodicity sample.
            // Notice that we add it also when the column is of maximal size, in which case we have
            // `(periodicity_point, periodicity_sample) == (ood_point, ood_sample)`.
            if let Some(tuple_box) = (*sample_values).try_into() {
                let [prev_sample, ood_sample]: [QM31; 2] = (*tuple_box).unbox();
                // Add periodicity sample.
                new_samples.append((ood_sample, random_pow));
                random_pow *= random_coeff;

                new_samples.append((prev_sample, random_pow));
                random_pow *= random_coeff;

                new_samples.append((ood_sample, random_pow));
                random_pow *= random_coeff;
            } else if let Some(point_box) = (*sample_values).try_into() {
                let [ood_sample]: [QM31; 1] = (*point_box).unbox();
                new_samples.append((ood_sample, random_pow));
                random_pow *= random_coeff;
            } else {
                assert!(sample_values.is_empty(), "Unexpected number of samples");
            }
            new_samples_per_col.append(new_samples.span());
        }
        samples_with_randomness_per_tree.append(new_samples_per_col.span());
    }
    samples_with_randomness_per_tree.span()
}

/// Computes the OOD quotients for a single query and single column size (the reference
/// per-row formula, kept for the tests; `fri_answers` computes the same sums lazily).
///
/// # Arguments
///
/// * `sampled_batches`: OOD column samples grouped by eval point.
/// * `query_evals_by_column`: Sampled query evals by trace column.
/// * `query_index`: The index of the query to compute the quotients for.
/// * `domain_point`: The domain point the query corresponds to.
fn accumulate_row_quotients(
    sample_batches_by_point: Span<ColumnSampleBatch>,
    queried_values_at_row: Span<M31>,
    quotient_constants: @QuotientConstants,
    domain_point: CirclePoint<M31>,
) -> QM31 {
    let denominator_inverses = quotient_denominator_inverses(sample_batches_by_point, domain_point);
    let domain_point_y: M31 = domain_point.y;
    let mut quotient_accumulator: QM31 = Zero::zero();

    for (point_constants, denom_inv) in zip_eq(
        quotient_constants.point_constants, denominator_inverses,
    ) {
        let PointQuotientConstants {
            alpha_mul_a_sum, alpha_mul_b_sum, indexed_alpha_mul_c,
        } = point_constants;

        // `minus_numerator` is offset by `PackedUnreducedQM31Trait::large_zero()`. This ensures
        // the subtraction below does not underflow.
        let mut minus_numerator = to_packed_unreduced_qm31(*alpha_mul_a_sum)
            .mul_m31(domain_point_y)
            + to_packed_unreduced_qm31(*alpha_mul_b_sum)
            + PackedUnreducedQM31Trait::large_zero();

        for (column_index, alpha_mul_c) in indexed_alpha_mul_c.span() {
            let query_eval_at_column = *queried_values_at_row.at(*column_index);

            // The numerator is a line equation passing through
            //   (sample_point.y, sample_value), (conj(sample_point.y), conj(sample_value))
            // evaluated at (domain_point.y, value).
            // When substituting a polynomial in this line equation, we get a polynomial
            // with a root at sample_point and conj(sample_point) if the original polynomial
            // had the values sample_value and conj(sample_value) at these points.
            minus_numerator -= to_packed_unreduced_qm31(*alpha_mul_c).mul_m31(query_eval_at_column);
        }

        let minus_quotient = minus_numerator.reduce().mul_cm31(denom_inv);
        quotient_accumulator = quotient_accumulator - minus_quotient;
    }

    quotient_accumulator
}

/// Computes the denominators of the FRI quotients for a given `domain_point`
/// (corresponding to a query index).
///
/// For each `sample_point` the value at `domain_point` of the line
/// passing through `(sample_point, conj(sample_point))`.
///
/// Conjugation is taken coordinate-wise conjugation with respect to CM31.
fn quotient_denominator_inverses(
    sample_batches: Span<ColumnSampleBatch>, domain_point: CirclePoint<M31>,
) -> Array<CM31> {
    let mut denominators = array![];

    for sample_batch in sample_batches {
        // For a sample point `P: CirclePoint<QM31>` domain point `D: CirclePoint<M31>`, the
        // denominator is given by
        //   (Pr.x - D.x) * Pi.y - (Pr.y - D.y) * Py.x
        // where Pr, Pi are the real and imaginary parts of P, both of type `CirclePoint<CM31>`.
        let denominator = QM31Trait::fused_quotient_denominator(
            *sample_batch.point.x, *sample_batch.point.y, domain_point.x, domain_point.y,
        );
        denominators.append(denominator);
    }

    BatchInvertible::batch_inverse(denominators)
}

/// `QM31Trait::fused_quotient_denominator(px, py, dx, dy)` with the domain point given as felts:
/// `Im((py - dy) * conj(px - dx))` as a CM31.
fn quotient_denominator(px: QM31, py: QM31, dx: felt252, dy: felt252) -> CM31 {
    let [px_aa, px_ab, px_ba, px_bb] = limbs(px);
    let [py_aa, py_ab, py_ba, py_bb] = limbs(py);
    let px_aa = px_aa - dx;
    let py_aa = py_aa - dy;
    // px.a * py.b - px.b * py.a
    let a = (px_aa * py_ba - px_ab * py_bb) - (px_ba * py_aa - px_bb * py_ab) + PP16;
    let b = (px_aa * py_bb + px_ab * py_ba) - (px_ba * py_ab + px_bb * py_aa) + PP16;
    CM31Trait::pack(reduce_narrow(a), reduce_narrow(b))
}

/// Holds the precomputed constant values used in each quotient evaluation, grouped evaluation
/// point.
#[derive(Debug, Drop)]
pub struct QuotientConstants {
    /// The constants for each mask item.
    pub point_constants: Array<PointQuotientConstants>,
}

/// Constants associated with a batch of samples for a given evaluation point and domain size.
///
/// # Overview
/// To prove that `F(p) = value`, we apply *two-point quotienting* at `p`
/// and its conjugate `conj(p)`. The numerator of the quotient is:
///
///     c * F(q) - a * q.y - b
///
/// where `(a, b, c)` are the coefficients of the line through
/// `(p.y, value)` and `(conj(p.y), conj(value))`, ensuring the numerator
/// vanishes at both `p` and `conj(p)`.
///
/// Since `F` is a polynomial over the base field, we also have:
///
///     F(conj(p)) = conj(F(p))
///
/// # Batched Evaluation Proofs
/// In batched evaluation proof verification, the verifier computes a pseudo-random
/// linear combination of these quotients:
///
///     Σ (α^i * (c_i * F_i(q) - a_i * q.y - b_i))
///
/// which expands to:
///
///     Σ (α^i * c_i * F_i(q)) - q.y * Σ (α^i * a_i) - Σ (α^i * b_i)
///
/// To evaluate this expression efficiently at the query point `q`, we compute
/// the following for each batch:
///
/// - `alpha_mul_a_sum`: Σ (α^i * a_i)
/// - `alpha_mul_b_sum`: Σ (α^i * b_i)
/// - `indexed_alpha_mul_c`: list of `(column index, α^i * c_i)` pairs
///
/// where i ∈ [index_of_first_sample_in_the_batch, index_of_first_sample_in_the_next_batch).
///
/// (Hellproof patch 0003) The sums and coefficients are stored reduced.
#[derive(Debug, Drop)]
pub struct PointQuotientConstants {
    /// Σ (α^i * a_i) across all samples in the batch.
    pub alpha_mul_a_sum: QM31,
    /// Σ (α^i * b_i) across all samples in the batch.
    pub alpha_mul_b_sum: QM31,
    /// Pairs of `(column index, α^i * c_i)` for every sample.
    pub indexed_alpha_mul_c: Array<(usize, QM31)>,
}

#[generate_trait]
pub impl QuotientConstantsImpl of QuotientConstantsTrait {
    fn gen(sample_batches_by_point: Span<ColumnSampleBatch>) -> QuotientConstants {
        let mut point_constants = array![];

        for sample_batch in sample_batches_by_point {
            assert!(
                *sample_batch.point.y != (*sample_batch.point.y).complex_conjugate(),
                "Cannot evaluate a line with a single point ({:?}).",
                sample_batch.point,
            );

            // The coefficients (a_i, b_i, c_i) are the coefficients of the line
            //   c_i * F(q) - a_i * q.y - b_i through
            // through (p.y, v_i) and (conj(p.y), conj(v_i)) are:
            //   c_i =               conj(p.y) - p.y = -2u * Im(p.y),
            //   a_i =               conj(v_i) - v_i = -2u * Im(v_i),
            //   b_i = conj(p.y)*v_i - conj(v_i)*p.y = -2u * (Re(v_i)*Im(p.y) - Re(p.y)*Im(v_i)).
            // Note that c_i = c depends only on p.y and not on the value v_i.
            // We have to compute and store c * α^i for each i; we compute these directly,
            // without calculating each α^i. We use these to accumulate the sums
            //   Σ_i (c * α^i) * Im(v_i)
            //   Σ_i (c * α^i) * Re(v_i)
            // From these sums we then construct `alpha_mul_a_sum` and `alpha_mul_b_sum` by
            //   `alpha_mul_a_sum` = (Σ_i (c * α^i) * Im(v_i)) / Im(p.y)
            //   `alpha_mul_b_sum` = (Σ_i (c * α^i) * Re(v_i)) - (`alpha_mul_a_sum` * Re(p.y)).

            let [re_py_a, re_py_b, im_py_a, im_py_b] = sample_batch.point.y.to_fixed_array();
            let re_py = CM31Trait::pack(re_py_a, re_py_b);
            let im_py_inv = CM31Trait::pack(im_py_a, im_py_b).inverse();

            let c = QM31Trait::from_fixed_array(
                [M31Zero::zero(), M31Zero::zero(), im_py_a, im_py_b],
            );
            let minus_two_c = -(c + c);
            let mut alpha_mul_c_mul_im_sum = PackedUnreducedQM31Trait::large_zero();
            let mut alpha_mul_c_mul_re_sum = PackedUnreducedQM31Trait::large_zero();
            let mut indexed_alpha_mul_c: Array<(usize, QM31)> = array![];

            for (column_idx, sample_value, random_pow) in sample_batch.cols_vals_and_pows.span() {
                let [re_cv_a, re_cv_b, im_cv_a, im_cv_b] = sample_value.to_fixed_array();
                let alpha_mul_c = minus_two_c * *random_pow;
                let re_cv = CM31Trait::pack(re_cv_a, re_cv_b);
                let im_cv = CM31Trait::pack(im_cv_a, im_cv_b);
                let alpha_mul_c_packed = to_packed_unreduced_qm31(alpha_mul_c);

                alpha_mul_c_mul_re_sum += alpha_mul_c_packed.mul_cm31(re_cv);
                alpha_mul_c_mul_im_sum += alpha_mul_c_packed.mul_cm31(im_cv);
                indexed_alpha_mul_c.append((*column_idx, alpha_mul_c));
            }

            let alpha_mul_c_mul_im_sum_reduced = to_packed_unreduced_qm31(
                alpha_mul_c_mul_im_sum.reduce(),
            );
            let alpha_mul_a_sum = alpha_mul_c_mul_im_sum_reduced.mul_cm31(im_py_inv);
            let alpha_mul_b_sum = alpha_mul_c_mul_re_sum - alpha_mul_a_sum.mul_cm31(re_py);

            // The packed sums are only reducible once offset by `large_zero()`: a packed
            // lane of `mul_cm31` may be negative (borrowed across the 2^128 lane boundary),
            // which the original code absorbed by adding `alpha_mul_b_sum` (itself offset)
            // before its single `reduce()`.
            let large_zero = PackedUnreducedQM31Trait::large_zero();
            point_constants
                .append(
                    PointQuotientConstants {
                        alpha_mul_a_sum: (alpha_mul_a_sum + large_zero).reduce(),
                        alpha_mul_b_sum: (alpha_mul_b_sum + large_zero).reduce(),
                        indexed_alpha_mul_c,
                    },
                );
        }

        QuotientConstants { point_constants }
    }
}

/// A batch of column samplings at a point.
#[derive(Debug, Drop, PartialEq)]
pub struct ColumnSampleBatch {
    /// The point at which the columns are sampled.
    pub point: CirclePoint<QM31>,
    /// The sampled column indices and their values at the point.
    pub cols_vals_and_pows: Array<(usize, QM31, QM31)>,
}

/// A circle point encoding to index into [`Felt252Dict`].
#[generate_trait]
pub impl CirclePointQM31Key of CirclePointQM31KeyTrait {
    fn encode(key: @CirclePoint<QM31>) -> felt252 {
        let encoded_y = pack_qm31(Zero::zero(), *key.y);
        pack_qm31(encoded_y, *key.x)
    }
}

/// Pops `ns[i]` elements from the `trees[i]` and returns them as a flat array.
fn tree_take_n<T, +Clone<T>, +Drop<T>>(
    ref trees: TreeSpan<Span<T>>, mut ns: TreeSpan<usize>,
) -> Array<T> {
    let mut res: Array<T> = array![];
    let mut new_trees = array![];
    for (values, n) in zip_eq(trees, ns) {
        let mut values = *values;
        res.append_span(values.pop_front_n(*n));
        new_trees.append(values);
    }

    trees = new_trees.span();
    res
}
