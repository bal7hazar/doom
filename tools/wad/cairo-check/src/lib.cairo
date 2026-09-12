// Throwaway compile-check crate root (roadmap P0.2). `e1m1` is a copy of
// tools/wad/out/e1m1.cairo, placed here by scripts/verify-cairo.sh (or
// `npm run verify:cairo`) right before `scarb build`. It is not committed:
// see tools/wad/.gitignore.
pub mod e1m1;

// Touches a handful of the generated constants so a successful `scarb
// build` also exercises basic indexing/typing of each array kind, not just
// parsing of the const declarations.
pub fn sanity_check() -> felt252 {
    let v0: u32 = *e1m1::VERTEXES.span()[0];
    let t0: felt252 = *e1m1::THINGS.span()[0];
    let l0: felt252 = *e1m1::LINEDEFS.span()[0];
    let s0: felt252 = *e1m1::SEGS.span()[0];
    let sec0: felt252 = *e1m1::SECTORS_MAIN.span()[0];
    let rej0: felt252 = *e1m1::REJECT_ROWS.span()[0];
    let bw0: u32 = *e1m1::BLOCKMAP_WORDS.span()[0];
    t0 + l0 + s0 + sec0 + rej0 + v0.into() + bw0.into()
}

#[cfg(test)]
mod tests {
    use super::sanity_check;

    #[test]
    fn constants_are_reachable() {
        // Only asserts the generated constants link and index correctly;
        // the actual field-level packing round-trip is tested in
        // tools/wad/test/packing.test.ts (TypeScript side, where the
        // pack/unpack pair lives).
        let _ = sanity_check();
    }

    #[test]
    fn counts_match_array_lengths() {
        assert!(super::e1m1::VERTEXES.span().len() == super::e1m1::NUM_VERTEXES);
        assert!(super::e1m1::THINGS.span().len() == super::e1m1::NUM_THINGS);
        assert!(super::e1m1::LINEDEFS.span().len() == super::e1m1::NUM_LINEDEFS);
        assert!(super::e1m1::SECTORS_MAIN.span().len() == super::e1m1::NUM_SECTORS);
    }
}
