// Synthetic "steps_k" benchmark program for spike S2.
//
// A felt-first loop (CONTEXT.md §4.3: additions/multiplications on felt252 cost ~1-3 steps, the
// only comparison is the loop counter) whose step count is linear in `n`, so that
// `args/k<K>.json` selects a trace of ≈ 2^K steps (see harness/programs/steps_k/args/README.md
// for the calibration). All values written to memory stay far below 2^128 and no bitwise
// builtin is used (S0 provisional design rule).
#[executable]
fn main(n: u32) -> felt252 {
    let mut i: u32 = 0;
    let mut acc: felt252 = 0;
    while i != n {
        let f: felt252 = i.into();
        acc = acc + f * f + 1;
        i += 1;
    }
    acc
}
