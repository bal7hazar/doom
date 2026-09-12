// Spike S1 - primitive cost benchmark.
//
// `main(op, n)` runs a tight loop of `n` iterations executing one primitive per
// iteration.  The cost of a primitive is obtained by differencing two runs
// (n = N and n = 2N) so that all fixed overhead (bootstrap, table setup,
// serialization) cancels:   cost = (steps(2N) - steps(N)) / N.
//
// op 0 is the bare loop; every other op is "bare loop + primitive", so the
// primitive's own cost is  cost(op) - cost(0).

pub mod tables;

use core::dict::{Felt252Dict, Felt252DictTrait};
use core::poseidon::{hades_permutation, poseidon_hash_span};
use tables::{FINESINE, RNDTABLE, TANTOANGLE};

/// Half-plane coefficients of a made-up line, in the felt-first non-negative
/// form the prototype uses (A, B, C each split into positive/negative parts).
const LAP: felt252 = 128;
const LAN: felt252 = 0;
const LBP: felt252 = 0;
const LBN: felt252 = 64;
const LCP: felt252 = 274877906944;
const LCN: felt252 = 0;

/// Bias large enough to keep any difference of two half-plane sums positive.
const CMP_BIAS: felt252 = 0x100000000000000000000000000; // 2^104

/// `a >= b` for two non-negative felts known to be < 2^104.
#[inline(always)]
pub fn felt_ge(a: felt252, b: felt252) -> bool {
    let d: u128 = (a - b + CMP_BIAS).try_into().unwrap();
    d >= 0x100000000000000000000000000_u128
}

/// point_on_side with precomputed, sign-split line coefficients: no division.
#[inline(always)]
pub fn point_on_side(x: felt252, y: felt252) -> bool {
    let pos = LAP * y + LBP * x + LCP;
    let neg = LAN * y + LBN * x + LCN;
    felt_ge(pos, neg)
}

/// 16.16 multiply of two non-negative magnitudes.
pub fn fixed_mul(a: felt252, b: felt252) -> felt252 {
    let p: u128 = (a * b).try_into().unwrap();
    (p / 65536_u128).into()
}

/// 16.16 divide of two non-negative magnitudes (b != 0).
pub fn fixed_div(a: felt252, b: felt252) -> felt252 {
    let na: u128 = a.try_into().unwrap();
    let nb: u128 = b.try_into().unwrap();
    ((na * 65536_u128) / nb).into()
}

#[executable]
fn main(op: u32, n: u32) -> felt252 {
    let mut acc: felt252 = 0;
    let mut i: u32 = 0;
    let x: felt252 = 4295098368; // 2^32 + 65536*8
    let y: felt252 = 4295360512;

    if op == 0 {
        // bare loop
        while i != n {
            i += 1;
        }
    } else if op == 1 {
        // felt252 addition
        while i != n {
            acc = acc + x;
            i += 1;
        }
    } else if op == 2 {
        // felt252 multiplication
        while i != n {
            acc = acc * 3 + 1;
            i += 1;
        }
    } else if op == 3 {
        // u32 comparison
        while i != n {
            if i < 0xFFFF_u32 {
                acc = acc + 1;
            }
            i += 1;
        }
    } else if op == 4 {
        // felt252 -> u128 conversion
        while i != n {
            let v: u128 = (x + i.into()).try_into().unwrap();
            acc = acc + v.into();
            i += 1;
        }
    } else if op == 5 {
        // felt252 -> u32 conversion
        while i != n {
            let v: u32 = (i.into() + 7_felt252).try_into().unwrap();
            acc = acc + v.into();
            i += 1;
        }
    } else if op == 6 {
        // span index into a 10240-entry const array
        let s = FINESINE.span();
        while i != n {
            acc = acc + *s.at(i);
            i += 1;
        }
    } else if op == 7 {
        // span index into a 256-entry const array
        let s = RNDTABLE.span();
        while i != n {
            acc = acc + *s.at(i);
            i += 1;
        }
    } else if op == 8 {
        // span index into a 2049-entry const array
        let s = TANTOANGLE.span();
        while i != n {
            acc = acc + *s.at(i);
            i += 1;
        }
    } else if op == 9 {
        // span index into a dynamically built array (built once, outside loop)
        let mut a: Array<felt252> = array![];
        let mut k: u32 = 0;
        while k != 4096 {
            a.append(k.into());
            k += 1;
        }
        let s = a.span();
        while i != n {
            acc = acc + *s.at(i);
            i += 1;
        }
    } else if op == 10 {
        // point_on_side (felt-first, no division)
        while i != n {
            if point_on_side(x + i.into(), y) {
                acc = acc + 1;
            }
            i += 1;
        }
    } else if op == 11 {
        // fixed_mul
        while i != n {
            acc = acc + fixed_mul(65536 + i.into(), 32768);
            i += 1;
        }
    } else if op == 12 {
        // fixed_div
        while i != n {
            acc = acc + fixed_div(65536 + i.into(), 32768);
            i += 1;
        }
    } else if op == 13 {
        // hades_permutation (one poseidon builtin application)
        let mut s0: felt252 = 1;
        let mut s1: felt252 = 2;
        let mut s2: felt252 = 3;
        while i != n {
            let (a, b, c) = hades_permutation(s0, s1, s2);
            s0 = a;
            s1 = b;
            s2 = c;
            i += 1;
        }
        acc = s0;
    } else if op == 14 {
        // poseidon_hash_span of a single felt (array built each iteration)
        while i != n {
            acc = acc + poseidon_hash_span(array![acc + i.into()].span());
            i += 1;
        }
    } else if op == 15 {
        // u128 comparison
        let a: u128 = 123456789;
        while i != n {
            if a > i.into() {
                acc = acc + 1;
            }
            i += 1;
        }
    } else if op == 16 {
        // felt_ge alone (conversion + u128 compare)
        while i != n {
            if felt_ge(x + i.into(), y) {
                acc = acc + 1;
            }
            i += 1;
        }
    } else if op == 17 {
        // unpack 5 x 16-bit fields from one packed felt (representation A)
        let packed: felt252 = 0x000A000B000C000D000E;
        while i != n {
            let p: u128 = (packed + i.into()).try_into().unwrap();
            let f0 = p % 65536;
            let p1 = p / 65536;
            let f1 = p1 % 65536;
            let p2 = p1 / 65536;
            let f2 = p2 % 65536;
            let p3 = p2 / 65536;
            let f3 = p3 % 65536;
            let f4 = p3 / 65536;
            acc = acc + (f0 + f1 + f2 + f3 + f4).into();
            i += 1;
        }
    } else if op == 18 {
        // u32 division
        while i != n {
            acc = acc + ((i + 1000) / 128).into();
            i += 1;
        }
    } else if op == 19 {
        // dictionary (Felt252Dict) write+read, for "visited" set costing
        let mut d: Felt252Dict<u32> = Default::default();
        while i != n {
            d.insert(i.into(), i);
            acc = acc + Felt252DictTrait::get(ref d, i.into()).into();
            i += 1;
        }
        d.squash();
    } else if op == 20 {
        // u64 comparison
        let a: u64 = 123456789;
        while i != n {
            if a > i.into() {
                acc = acc + 1;
            }
            i += 1;
        }
    } else if op == 21 {
        // felt252 -> u64
        while i != n {
            let v: u64 = (i.into() + 7_felt252).try_into().unwrap();
            acc = acc + v.into();
            i += 1;
        }
    } else if op == 22 {
        // match-style lookup: 16-entry binary-search if-tree
        while i != n {
            acc = acc + lookup16(i % 16);
            i += 1;
        }
    } else if op == 23 {
        // baseline for op 22: the `i % 16` alone
        while i != n {
            acc = acc + (i % 16).into();
            i += 1;
        }
    } else if op == 24 {
        // `.span()` of a const array, taken inside the loop
        while i != n {
            let s = FINESINE.span();
            acc = acc + *s.at(0);
            i += 1;
        }
    } else if op == 25 {
        // two span indexes into the same const array
        let s = FINESINE.span();
        while i != n {
            acc = acc + *s.at(i) + *s.at(i + 1);
            i += 1;
        }
    } else if op == 26 {
        // Array append
        let mut a: Array<felt252> = array![];
        while i != n {
            a.append(i.into());
            i += 1;
        }
        acc = a.len().into();
    } else if op == 27 {
        // five span indexes into five planar const arrays (representation B
        // read of a 5-field record) -- compare against op 17 (packed).
        let s0 = FINESINE.span();
        let s1 = TANTOANGLE.span();
        let s2 = RNDTABLE.span();
        while i != n {
            let j = i % 256;
            acc = acc
                + *s0.at(i)
                + *s0.at(i + 1)
                + *s1.at(j)
                + *s1.at(j + 1)
                + *s2.at(j);
            i += 1;
        }
    } else if op == 28 {
        // poseidon_hash_span over a 3000-felt span (state-hash estimate for
        // ~150 mobjs), with the span built once outside the loop
        let mut v: Array<felt252> = array![];
        let mut k: u32 = 0;
        while k != 3000 {
            v.append(k.into() + 7);
            k += 1;
        }
        let sp = v.span();
        while i != n {
            acc = acc + poseidon_hash_span(sp);
            i += 1;
        }
    } else if op == 29 {
        // building a 3000-felt array (the serialization half of a state hash)
        while i != n {
            let mut v: Array<felt252> = array![];
            let mut k: u32 = 0;
            while k != 3000 {
                v.append(k.into() + acc);
                k += 1;
            }
            acc = acc + v.len().into();
            i += 1;
        }
    }

    acc + i.into()
}

/// 16-entry lookup implemented as a binary-search if-tree (the "match-based
/// lookup function" alternative to a const array + span index).
fn lookup16(k: u32) -> felt252 {
    if k < 8 {
        if k < 4 {
            if k < 2 {
                if k == 0 {
                    11
                } else {
                    22
                }
            } else if k == 2 {
                33
            } else {
                44
            }
        } else if k < 6 {
            if k == 4 {
                55
            } else {
                66
            }
        } else if k == 6 {
            77
        } else {
            88
        }
    } else if k < 12 {
        if k < 10 {
            if k == 8 {
                99
            } else {
                110
            }
        } else if k == 10 {
            121
        } else {
            132
        }
    } else if k < 14 {
        if k == 12 {
            143
        } else {
            154
        }
    } else if k == 14 {
        165
    } else {
        176
    }
}
