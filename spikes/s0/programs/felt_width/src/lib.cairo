//! Same instruction stream, two memory-value widths — isolates the cost of
//! writing "big" felts (>= 2^72) rather than "small" ones.
//!
//! The adapter classifies a memory cell as `MemoryValue::Small(u128)` iff the felt
//! is `< 2^72` (`MemoryConfig::default().small_max = (1 << 72) - 1`, and
//! `adapter/src/memory.rs::value_from_felt252`); anything above takes the
//! `MemoryValue::F252` path, which feeds `memory_id_to_big` and the
//! `range_check_9_9_*` / `range_check_20_*` components.
//!
//! Arguments: `(n, shift)`. The multiplier is a *runtime argument*, so the opcode
//! stream is byte-identical between the two runs and only the stored values differ:
//!
//!   shift = 0x1                      -> values around 2^52  (small path)
//!   shift = 0x100000000000000000000  -> the same values * 2^80 (F252 path)

#[executable]
fn main(n: u32, shift: felt252) -> felt252 {
    let mut buf: Array<felt252> = ArrayTrait::new();
    let mut v: felt252 = 0xfedcba9876543;
    let mut i: u32 = 0;
    while i != n {
        v = v + 0x1234567;
        buf.append(v * shift);
        i += 1;
    }
    let mut j: u32 = 0;
    let mut acc: felt252 = 0;
    while j != buf.len() {
        acc = acc + *buf.at(j);
        j += 1;
    }
    acc
}
