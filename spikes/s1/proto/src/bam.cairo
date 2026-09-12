//! BAM angles (32-bit binary angle measure) and the generated trig tables.
//!
//! `FINESINE` holds 10240 entries biased by +FRACUNIT so that no negative felt
//! is ever stored; the sign is recovered with one comparison.

use crate::fixed::{FRACUNIT, Sf, felt_ge};
use crate::tables::{FINESINE, TANTOANGLE};

/// Wrapping BAM addition.  u32 arithmetic in Cairo panics on overflow, so the
/// wrap is done explicitly (this is one of the few places a u32 division is
/// unavoidable -- the real `bam` crate should store angles as felt252 and
/// reduce once per tic instead).
#[inline(always)]
pub fn angle_add(a: u32, b: u32) -> u32 {
    let s: u64 = a.into() + b.into();
    (s % 0x100000000_u64).try_into().unwrap()
}

#[inline(always)]
pub fn angle_sub(a: u32, b: u32) -> u32 {
    let s: u64 = a.into() + 0x100000000_u64 - b.into();
    (s % 0x100000000_u64).try_into().unwrap()
}

/// `finesine[(angle >> ANGLETOFINESHIFT) & FINEMASK]`, returned as (mag, sign).
pub fn sine(angle: u32) -> Sf {
    let idx = (angle / 0x80000_u32) % 8192_u32; // >> 19, & 8191
    let v = *FINESINE.span().at(idx);
    if felt_ge(v, FRACUNIT) {
        Sf { m: v - FRACUNIT, neg: 0 }
    } else {
        Sf { m: FRACUNIT - v, neg: 1 }
    }
}

/// `finecosine[i] == finesine[i + 2048]`.
pub fn cosine(angle: u32) -> Sf {
    let idx = (angle / 0x80000_u32) % 8192_u32 + 2048_u32;
    let v = *FINESINE.span().at(idx);
    if felt_ge(v, FRACUNIT) {
        Sf { m: v - FRACUNIT, neg: 0 }
    } else {
        Sf { m: FRACUNIT - v, neg: 1 }
    }
}

/// Raw table lookup, for the "cost of one table lookup" measurement.
pub fn finesine_raw(idx: u32) -> felt252 {
    *FINESINE.span().at(idx)
}

/// R_PointToAngle-like approximation from a signed delta pair.
///
/// Doom uses `tantoangle[SlopeDiv(y, x)]` with a 2048-entry table and eight
/// octant cases.  The division is the expensive part in Cairo (55 steps), so
/// the octant reduction is done first and only one division survives.
pub fn point_to_angle(dx: Sf, dy: Sf) -> u32 {
    if dx.m == 0 && dy.m == 0 {
        return 0;
    }
    let ax: u128 = dx.m.try_into().unwrap();
    let ay: u128 = dy.m.try_into().unwrap();
    // octant index within the quadrant: 0 when |dy| <= |dx|
    let (num, den, swapped) = if ay <= ax {
        (ay, ax, false)
    } else {
        (ax, ay, true)
    };
    let slope: u32 = if den == 0 {
        2048
    } else {
        let s = (num * 2048) / den;
        if s > 2048 {
            2048
        } else {
            s.try_into().unwrap()
        }
    };
    let base: felt252 = *TANTOANGLE.span().at(slope);
    let a: u32 = base.try_into().unwrap();
    let oct: u32 = if swapped {
        0x40000000_u32 - a
    } else {
        a
    };
    // fold into the right quadrant
    if dx.neg == 0 && dy.neg == 0 {
        oct
    } else if dx.neg == 1 && dy.neg == 0 {
        0x80000000_u32 - oct
    } else if dx.neg == 1 && dy.neg == 1 {
        angle_add(0x80000000_u32, oct)
    } else {
        angle_sub(0, oct)
    }
}
