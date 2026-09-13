use core::array::SpanTrait;
use core::box::BoxTrait;
use core::dict::{Felt252Dict, Felt252DictEntryTrait, Felt252DictTrait, SquashedFelt252DictTrait};
use core::nullable::{FromNullableResult, NullableTrait, match_nullable};
use core::num::traits::BitSize;
use core::traits::{DivRem, PanicDestruct};
use crate::fields::SecureField;
use crate::fields::m31::M31_SHIFT;
use crate::fields::qm31::{QM31, QM31Trait, QM31_EXTENSION_DEGREE};
use crate::{ColumnSpan, TreeSpan};


/// Returns `2^n`, n in range [0, 32).
/// Will panic (with index out of bounds) if n >= 32.
#[inline(always)]
pub fn pow2(n: u32) -> u32 {
    /// Look up table where index `i` stores value `2^i`.
    #[cairofmt::skip]
    const POW_2: [u32; 32] = [
        0b1,
        0b10,
        0b100,
        0b1000,
        0b10000,
        0b100000,
        0b1000000,
        0b10000000,
        0b100000000,
        0b1000000000,
        0b10000000000,
        0b100000000000,
        0b1000000000000,
        0b10000000000000,
        0b100000000000000,
        0b1000000000000000,
        0b10000000000000000,
        0b100000000000000000,
        0b1000000000000000000,
        0b10000000000000000000,
        0b100000000000000000000,
        0b1000000000000000000000,
        0b10000000000000000000000,
        0b100000000000000000000000,
        0b1000000000000000000000000,
        0b10000000000000000000000000,
        0b100000000000000000000000000,
        0b1000000000000000000000000000,
        0b10000000000000000000000000000,
        0b100000000000000000000000000000,
        0b1000000000000000000000000000000,
        0b10000000000000000000000000000000,
    ];

    *POW_2.span()[n]
}

/// Returns `2^n` as a u64, n in range [0, 64).
/// Will panic (with index out of bounds) if n >= 64.
pub fn pow2_u64(n: u32) -> u64 {
    if n < 32 {
        pow2(n).into()
    } else {
        pow2(n - 32).into() * 0x100000000
    }
}

#[generate_trait]
pub impl DictImpl<T, +Felt252DictValue<T>> of DictTrait<T> {
    fn replace<+PanicDestruct<T>>(ref self: Felt252Dict<T>, key: felt252, new_value: T) -> T {
        let (entry, value) = self.entry(key);
        self = entry.finalize(new_value);
        value
    }

    // TODO(andrew): Is there a better way to handle this?
    fn clone_subset<+Copy<T>, +Drop<T>>(
        ref self: Felt252Dict<T>, subset_keys: Span<u32>,
    ) -> Felt252Dict<T> {
        let mut res: Felt252Dict<T> = Default::default();
        for key in subset_keys {
            let key = (*key).into();
            res.insert(key, self.get(key));
        }
        res
    }
}

#[generate_trait]
pub impl OptBoxImpl<T> of OptBoxTrait<T> {
    fn as_unboxed(self: Option<Box<T>>) -> Option<T> {
        match self {
            Some(value) => Some(value.unbox()),
            None => None,
        }
    }
}

#[generate_trait]
pub impl OptionImpl<T> of OptionExTrait<T> {
    /// Converts from `@Option<T>` to `Option<@T>`.
    fn as_snap(self: @Option<T>) -> Option<@T> {
        match self {
            Some(x) => Some(x),
            None => None,
        }
    }
}

#[generate_trait]
pub impl ArrayImpl<T, +Drop<T>> of ArrayExTrait<T> {
    fn max<+Copy<T>, +PartialOrd<T>>(mut self: @Array<T>) -> Option<@T> {
        self.span().max()
    }

    fn new_repeated<+Clone<T>>(n: usize, v: T) -> Array<T> {
        let mut res = array![];
        for _ in 0..n {
            res.append(v.clone());
        }
        res
    }
}

#[generate_trait]
pub impl SpanImpl<T> of SpanExTrait<T> {
    #[inline]
    fn first(mut self: Span<T>) -> Option<@T> {
        self.pop_front()
    }

    #[inline]
    fn last(mut self: Span<T>) -> Option<@T> {
        self.pop_back()
    }

    /// Panics if self.len() < n.
    fn pop_front_n(ref self: Span<T>, n: usize) -> Span<T> {
        let (res, remainder) = self.split_at(n);
        self = remainder;
        res
    }

    #[inline]
    fn split_at(self: Span<T>, mid: usize) -> (Span<T>, Span<T>) {
        (self.slice(0, mid), self.slice(mid, self.len() - mid))
    }

    fn next_if_eq<+PartialEq<T>>(ref self: Span<T>, other: @T) -> Option<@T> {
        let mut self_copy = self;
        if let Some(value) = self_copy.pop_front() && value == other {
            self = self_copy;
            return Some(other);
        }
        None
    }

    fn max<+PartialOrd<T>, +Copy<T>>(mut self: Span<T>) -> Option<@T> {
        let mut max = self.pop_front()?;
        while let Some(next) = self.pop_front() {
            if *next > *max {
                max = next;
            }
        }
        Some(max)
    }
}

// Packs a SecureField value into a felt252, injecting `cur` into
// the most significant bits.
// The resulting felt252 is: cur || x0 || x1 || x2 || x3.
pub fn pack_qm31(cur: felt252, secure_felt: SecureField) -> felt252 {
    let [x0, x1, x2, x3] = secure_felt.to_fixed_array();
    (((cur * M31_SHIFT + x0.into()) * M31_SHIFT + x1.into()) * M31_SHIFT + x2.into()) * M31_SHIFT
        + x3.into()
}

/// Takes the first `n_bits` bits of the given index, reverses them, and returns the result.
///
/// (Hellproof patch 0002) Table-driven: the 32-bit reversal of `index` is assembled from four
/// byte reversals and shifted right by `32 - n_bits`, which keeps exactly the reversed low
/// `n_bits` bits of `index` — the value the bit-by-bit loop computed — for ~19 range checks
/// instead of ~6 per bit (~8 when `n_bits <= 8`).
pub fn bit_reverse_index(index: usize, n_bits: u32) -> usize {
    assert!(n_bits <= BitSize::<usize>::bits());
    if n_bits <= 8 {
        let (_, b0) = DivRem::div_rem(index, 0x100);
        let rev8 = *BIT_REVERSE_8.span()[b0];
        return rev8 / pow2(8 - n_bits);
    }
    let (q, b0) = DivRem::div_rem(index, 0x100);
    let (q, b1) = DivRem::div_rem(q, 0x100);
    let (b3, b2) = DivRem::div_rem(q, 0x100);
    let r0: felt252 = (*BIT_REVERSE_8.span()[b0]).into();
    let r1: felt252 = (*BIT_REVERSE_8.span()[b1]).into();
    let r2: felt252 = (*BIT_REVERSE_8.span()[b2]).into();
    let r3: felt252 = (*BIT_REVERSE_8.span()[b3]).into();
    let rev32: u32 = (((r0 * 0x100 + r1) * 0x100 + r2) * 0x100 + r3).try_into().unwrap();
    if n_bits == 32 {
        rev32
    } else {
        rev32 / pow2(32 - n_bits)
    }
}

/// `BIT_REVERSE_8[b]` is the 8-bit reversal of the byte `b`.
#[cairofmt::skip]
const BIT_REVERSE_8: [u32; 256] = [
    0x00, 0x80, 0x40, 0xc0, 0x20, 0xa0, 0x60, 0xe0,
    0x10, 0x90, 0x50, 0xd0, 0x30, 0xb0, 0x70, 0xf0,
    0x08, 0x88, 0x48, 0xc8, 0x28, 0xa8, 0x68, 0xe8,
    0x18, 0x98, 0x58, 0xd8, 0x38, 0xb8, 0x78, 0xf8,
    0x04, 0x84, 0x44, 0xc4, 0x24, 0xa4, 0x64, 0xe4,
    0x14, 0x94, 0x54, 0xd4, 0x34, 0xb4, 0x74, 0xf4,
    0x0c, 0x8c, 0x4c, 0xcc, 0x2c, 0xac, 0x6c, 0xec,
    0x1c, 0x9c, 0x5c, 0xdc, 0x3c, 0xbc, 0x7c, 0xfc,
    0x02, 0x82, 0x42, 0xc2, 0x22, 0xa2, 0x62, 0xe2,
    0x12, 0x92, 0x52, 0xd2, 0x32, 0xb2, 0x72, 0xf2,
    0x0a, 0x8a, 0x4a, 0xca, 0x2a, 0xaa, 0x6a, 0xea,
    0x1a, 0x9a, 0x5a, 0xda, 0x3a, 0xba, 0x7a, 0xfa,
    0x06, 0x86, 0x46, 0xc6, 0x26, 0xa6, 0x66, 0xe6,
    0x16, 0x96, 0x56, 0xd6, 0x36, 0xb6, 0x76, 0xf6,
    0x0e, 0x8e, 0x4e, 0xce, 0x2e, 0xae, 0x6e, 0xee,
    0x1e, 0x9e, 0x5e, 0xde, 0x3e, 0xbe, 0x7e, 0xfe,
    0x01, 0x81, 0x41, 0xc1, 0x21, 0xa1, 0x61, 0xe1,
    0x11, 0x91, 0x51, 0xd1, 0x31, 0xb1, 0x71, 0xf1,
    0x09, 0x89, 0x49, 0xc9, 0x29, 0xa9, 0x69, 0xe9,
    0x19, 0x99, 0x59, 0xd9, 0x39, 0xb9, 0x79, 0xf9,
    0x05, 0x85, 0x45, 0xc5, 0x25, 0xa5, 0x65, 0xe5,
    0x15, 0x95, 0x55, 0xd5, 0x35, 0xb5, 0x75, 0xf5,
    0x0d, 0x8d, 0x4d, 0xcd, 0x2d, 0xad, 0x6d, 0xed,
    0x1d, 0x9d, 0x5d, 0xdd, 0x3d, 0xbd, 0x7d, 0xfd,
    0x03, 0x83, 0x43, 0xc3, 0x23, 0xa3, 0x63, 0xe3,
    0x13, 0x93, 0x53, 0xd3, 0x33, 0xb3, 0x73, 0xf3,
    0x0b, 0x8b, 0x4b, 0xcb, 0x2b, 0xab, 0x6b, 0xeb,
    0x1b, 0x9b, 0x5b, 0xdb, 0x3b, 0xbb, 0x7b, 0xfb,
    0x07, 0x87, 0x47, 0xc7, 0x27, 0xa7, 0x67, 0xe7,
    0x17, 0x97, 0x57, 0xd7, 0x37, 0xb7, 0x77, 0xf7,
    0x0f, 0x8f, 0x4f, 0xcf, 0x2f, 0xaf, 0x6f, 0xef,
    0x1f, 0x9f, 0x5f, 0xdf, 0x3f, 0xbf, 0x7f, 0xff,
];

/// Assumes all values are reduced mod M31 and packs them into QM31 elements.
pub fn pack_into_qm31s(mut values: Span<u32>) -> Span<QM31> {
    let mut res = array![];

    while let Some(chunk) = values.multi_pop_front::<QM31_EXTENSION_DEGREE>() {
        append_chunk(ref res, chunk.unbox());
    }

    if !values.is_empty() {
        let mut chunk = array![];
        let chunk_size = values.len();
        chunk.append_span(values);
        for _ in chunk_size..QM31_EXTENSION_DEGREE {
            chunk.append(0_u32);
        }
        let fixed_arr: [u32; QM31_EXTENSION_DEGREE] = (*chunk.span().try_into().unwrap()).unbox();
        append_chunk(ref res, fixed_arr);
    }

    res.span()
}

fn append_chunk(ref array: Array<QM31>, chunk: [u32; QM31_EXTENSION_DEGREE]) {
    let [v0, v1, v2, v3] = chunk;
    let new_qm31 = QM31Trait::from_fixed_array(
        [
            v0.try_into().unwrap(), v1.try_into().unwrap(), v2.try_into().unwrap(),
            v3.try_into().unwrap(),
        ],
    );
    array.append(new_qm31);
}

/// A span in which each element relates (by index) to the log 2 of a degree bound.
pub type LogDegreeBoundSpan<T> = Span<T>;

/// Holds the columns indices by log degree bound.
///
/// column_indices_by_degree_bound[log_degree_bound] is a span of the columns indices with degree
/// bound `degree_bound`.
/// The indices in each tree are 0-based.
///
pub type ColumnsIndicesByLogDegreeBound = LogDegreeBoundSpan<Span<usize>>;

/// Given a span of column log degree bounds, Return a span of the column indices grouped by their
/// log degree bound.
///
/// # Arguments
///
/// * `log_degree_bound_by_column`: The degree bounds of the columns.
///
/// # Returns
///
/// * `columns_by_log_degree_bound`: A span where the i'th element is a span of the column indices
/// of size 2**i.
pub fn group_columns_by_degree_bound(
    log_degree_bound_by_column: ColumnSpan<u32>,
) -> ColumnsIndicesByLogDegreeBound {
    let mut column_by_degree_bound: Felt252Dict<Nullable<Array<u32>>> = Default::default();
    let mut col_index = 0_usize;
    for column_log_degree_bound in log_degree_bound_by_column {
        let (column_by_degree_bound_entry, value) = column_by_degree_bound
            .entry((*column_log_degree_bound).into());
        let mut column_indices = match match_nullable(value) {
            FromNullableResult::Null => array![],
            FromNullableResult::NotNull(value) => value.unbox(),
        };
        column_indices.append(col_index);
        column_by_degree_bound = column_by_degree_bound_entry
            .finalize(NullableTrait::new(column_indices));
        col_index += 1;
    }

    let mut res = array![];
    for (column_degree_bound, _, column_indices) in column_by_degree_bound.squash().into_entries() {
        /// Add empty spans for missing degree bounds.
        while res.len().into() != column_degree_bound {
            res.append(array![].span());
        }
        res.append(column_indices.deref().span());
    }
    res.span()
}

/// Holds the columns indices per tree by degree bound.
///
/// columns_indices_per_tree_by_log_degree_bound[log_degree_bound][tree] is a span of the columns
/// indices with degree bound `log_degree_bound` in the tree `tree`.
/// The indices in each tree are 0-based.
///
pub type ColumnsIndicesPerTreeByLogDegreeBound = LogDegreeBoundSpan<TreeSpan<Span<usize>>>;

/// Pads all the trees in `columns_by_log_degree_bound_per_tree` to the length of the longest tree
/// and transposes the arrays from [tree][log_degree_bound][column] to
/// [log_degree_bound][tree][column].
///
/// # Arguments
///
/// * `columns_by_log_degree_bound_per_tree`: The columns by log size per tree.
///
/// # Returns
///
/// * `columns_per_tree_by_log_degree_bound`: The columns per tree by log degree bound.
pub fn pad_and_transpose_columns_by_log_deg_bound_per_tree(
    mut columns_by_log_deg_bound_per_tree: TreeSpan<ColumnsIndicesByLogDegreeBound>,
) -> ColumnsIndicesPerTreeByLogDegreeBound {
    let mut columns_per_tree_by_log_deg_bound = array![];

    loop {
        // In each iteration we pop the the columns corresponding to `log_degree_bound` from each
        // tree, so we need to prepare `next_columns_by_log_deg_bound_per_tree` for the next
        // iteration.
        let mut next_columns_by_log_deg_bound_per_tree = array![];

        let mut done = true;
        let mut columns_per_tree = array![];
        for columns_by_log_deg_bound in columns_by_log_deg_bound_per_tree {
            let mut columns_by_log_deg_bound = *columns_by_log_deg_bound;
            let column_indices = match columns_by_log_deg_bound.pop_front() {
                Some(column_indices) => {
                    done = false;
                    *column_indices
                },
                None => array![].span(),
            };
            columns_per_tree.append(column_indices);

            next_columns_by_log_deg_bound_per_tree.append(columns_by_log_deg_bound);
        }

        if done {
            break;
        }

        columns_by_log_deg_bound_per_tree = next_columns_by_log_deg_bound_per_tree.span();
        columns_per_tree_by_log_deg_bound.append(columns_per_tree.span());
    }

    columns_per_tree_by_log_deg_bound.span()
}
