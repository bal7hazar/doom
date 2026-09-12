// SPDX-License-Identifier: Apache-2.0

/// Deterministic 256-period byte sequence generator, standing in for the
/// original `rndtable` (see README.md). `value(index)` is a pure function.
pub fn value(index: u8) -> u8 {
    let i: u32 = index.into();
    // Small deterministic mixing function: period-256 by construction since
    // it only ever reads `index` (a u8) and multiplies/adds modulo 256.
    let mixed: u32 = (i * 167 + 61) % 256;
    mixed.try_into().unwrap()
}

/// Draw the next byte and the next index (wraps modulo 256, never panics).
pub fn next(index: u8) -> (u8, u8) {
    let v = value(index);
    let next_index: u8 = if index == 255 {
        0
    } else {
        index + 1
    };
    (v, next_index)
}

#[cfg(test)]
mod tests {
    use super::{next, value};

    #[test]
    fn test_deterministic() {
        assert(value(0) == value(0), 'pure function');
        assert(next(42) == next(42), 'next is deterministic');
    }

    #[test]
    fn test_wraps_at_255() {
        let (_, next_index) = next(255);
        assert(next_index == 0, 'wraps to zero');
    }

    #[test]
    fn test_increments_normally() {
        let (_, next_index) = next(10);
        assert(next_index == 11, 'increments by one');
    }

    #[test]
    fn test_full_period_returns_to_start() {
        let mut index: u8 = 7;
        let mut i: u32 = 0;
        loop {
            if i == 256 {
                break;
            }
            let (_, next_index) = next(index);
            index = next_index;
            i += 1;
        }
        assert(index == 7, 'full period returns to start');
    }

    #[test]
    fn test_values_are_bytes() {
        // Property: value(i) is always a valid u8 (trivially true by type,
        // but this also exercises every branch of the modulo arithmetic).
        let mut i: u8 = 0;
        loop {
            let _ = value(i);
            if i == 255 {
                break;
            }
            i += 1;
        }
    }
}
