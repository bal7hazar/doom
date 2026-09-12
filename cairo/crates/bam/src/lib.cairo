// SPDX-License-Identifier: Apache-2.0

use fixed::Fixed;

/// Binary Angle Measurement: the full `u32` range represents one full turn,
/// matching Doom's `angle_t`. Arithmetic on `Angle` always wraps.
pub type Angle = u32;

pub const ANG0: Angle = 0;
pub const ANG90: Angle = 0x40000000;
pub const ANG180: Angle = 0x80000000;
pub const ANG270: Angle = 0xC0000000;

/// Wrapping addition modulo a full turn (2^32).
pub fn add(a: Angle, b: Angle) -> Angle {
    let wide: u64 = a.into() + b.into();
    let modulus: u64 = 0x100000000;
    (wide % modulus).try_into().unwrap()
}

/// Wrapping subtraction modulo a full turn (2^32).
pub fn sub(a: Angle, b: Angle) -> Angle {
    let modulus: u64 = 0x100000000;
    let wide: u64 = a.into() + modulus - b.into();
    (wide % modulus).try_into().unwrap()
}

/// Coarse quadrant-based sine approximation: piecewise-linear between the
/// four reference points (0, 90, 180, 270 degrees) mapped to (0, 1, 0, -1).
/// A placeholder for the full `finesine` table planned for Phase 1.
pub fn sin_quadrant(angle: Angle) -> Fixed {
    let quadrant: u32 = angle / ANG90;
    let remainder: u32 = angle % ANG90;

    let remainder_wide: u64 = remainder.into();
    let ang90_wide: u64 = ANG90.into();
    let one_wide: u64 = 65536;
    let raw_fraction_u64: u64 = (remainder_wide * one_wide) / ang90_wide;
    let raw_fraction: i64 = raw_fraction_u64.try_into().unwrap();
    let one: i64 = fixed::ONE;

    if quadrant == 0 {
        Fixed { raw: raw_fraction }
    } else if quadrant == 1 {
        Fixed { raw: one - raw_fraction }
    } else if quadrant == 2 {
        Fixed { raw: -raw_fraction }
    } else {
        Fixed { raw: raw_fraction - one }
    }
}

#[cfg(test)]
mod tests {
    use fixed::from_int;
    use super::{ANG0, ANG180, ANG270, ANG90, add, sin_quadrant, sub};

    #[test]
    fn test_sin_wraps_exactly_at_a_full_turn() {
        // 270 + 90 degrees wraps exactly to 0 degrees (2^32 mod 2^32).
        let wrapped = add(ANG270, ANG90);
        assert(wrapped == ANG0, 'wraps to angle 0');
        assert(sin_quadrant(wrapped) == sin_quadrant(ANG0), 'sin wraps at a full turn');
    }

    #[test]
    fn test_wrapping_add() {
        // A full turn brings us back to the start.
        assert(add(ANG0, 0xFFFFFFFF) == 0xFFFFFFFF, 'identity add');
        assert(add(0xFFFFFFFF, 1) == 0, 'wraps at max');
    }

    #[test]
    fn test_wrapping_sub() {
        assert(sub(0, 1) == 0xFFFFFFFF, 'wraps below zero');
        assert(sub(ANG90, ANG90) == 0, 'self sub is zero');
    }

    #[test]
    fn test_add_sub_are_inverses() {
        let a: u32 = 123456789;
        let b: u32 = 987654321;
        assert(sub(add(a, b), b) == a, 'add then sub inverse');
    }

    #[test]
    fn test_sin_reference_values() {
        assert(sin_quadrant(ANG0) == from_int(0), 'sin(0)=0');
        assert(sin_quadrant(ANG90) == from_int(1), 'sin(90)=1');
        assert(sin_quadrant(ANG180) == from_int(0), 'sin(180)=0');
        assert(sin_quadrant(ANG270) == from_int(-1), 'sin(270)=-1');
    }
}
