// Throwaway compile-check crate root (roadmap P0.2, WAD tool v2). `e1m1` is
// a copy of tools/wad/out/e1m1.cairo, placed here by scripts/verify-cairo.sh
// (or `npm run verify:cairo`) right before `scarb build`. It is not
// committed: see tools/wad/.gitignore.
pub mod e1m1;

// Touches a representative constant from every group v2 can emit, under
// BOTH layouts (see tools/wad/src/emitConfig.ts): whichever layout
// emit-config.json actually chose for the copied file compiles, and the
// group's differently-named const (the other layout's name) is simply
// absent, which is fine - this function only needs to compile against
// *some* fixed emit-config.json, not every possible one. Re-run
// `npm run verify:cairo` after editing emit-config.json's groups that
// change which of these names exist (see the comment on each line).
pub fn sanity_check() -> felt252 {
    // vertices: planar by default -> VERTEX_X/VERTEX_Y (u32).
    let v0: u32 = *e1m1::VERTEX_X.span()[0];
    let vy0: u32 = *e1m1::VERTEX_Y.span()[0];
    // nodePredicates / nodeChildren: planar by default -> NODE_AB/BB/CB (felt252), NODE_CHILD0/1 (u32).
    let n_ab0: felt252 = *e1m1::NODE_AB.span()[0];
    let n_bb0: felt252 = *e1m1::NODE_BB.span()[0];
    let n_cb0: felt252 = *e1m1::NODE_CB.span()[0];
    let n_c0: u32 = *e1m1::NODE_CHILD0.span()[0];
    // linedefPredicates: planar by default -> LINEDEF_AB/BB/CB (felt252), LINEDEF_DIAG (u32).
    let l_ab0: felt252 = *e1m1::LINEDEF_AB.span()[0];
    let l_bb0: felt252 = *e1m1::LINEDEF_BB.span()[0];
    let l_cb0: felt252 = *e1m1::LINEDEF_CB.span()[0];
    let l_diag0: u32 = *e1m1::LINEDEF_DIAG.span()[0];
    // linedefBBox: packed by default -> LINEDEF_BBOX_LR/BT (felt252).
    let l_bbox_lr0: felt252 = *e1m1::LINEDEF_BBOX_LR.span()[0];
    let l_bbox_bt0: felt252 = *e1m1::LINEDEF_BBOX_BT.span()[0];
    // linedefFlags: planar by default -> LINEDEF_BLOCKING/BLOCK_MONSTERS/TWO_SIDED (u32).
    let l_blocking0: u32 = *e1m1::LINEDEF_BLOCKING.span()[0];
    let l_blockmonst0: u32 = *e1m1::LINEDEF_BLOCK_MONSTERS.span()[0];
    let l_twosided0: u32 = *e1m1::LINEDEF_TWO_SIDED.span()[0];
    // linedefSides: packed by default -> LINEDEF_SIDES (u32).
    let l_sides0: u32 = *e1m1::LINEDEF_SIDES.span()[0];
    // linedefSpecial: packed by default -> LINEDEF_SPECIAL (u32).
    let l_special0: u32 = *e1m1::LINEDEF_SPECIAL.span()[0];
    // sidedefSector: packed by default -> SIDEDEF_SECTOR_PACKED (felt252).
    let sd_sector0: felt252 = *e1m1::SIDEDEF_SECTOR_PACKED.span()[0];
    // subsectorSector: packed by default -> SS_SECTOR_PACKED (felt252).
    let ss_sector0: felt252 = *e1m1::SS_SECTOR_PACKED.span()[0];
    // sectorHeights: planar by default -> SECTOR_FLOOR/CEILING (u32).
    let s_floor0: u32 = *e1m1::SECTOR_FLOOR.span()[0];
    let s_ceil0: u32 = *e1m1::SECTOR_CEILING.span()[0];
    // sectorMeta: packed by default -> SECTOR_META (felt252).
    let s_meta0: felt252 = *e1m1::SECTOR_META.span()[0];
    // reject: packed by default -> REJECT_ROWS (felt252).
    let rej0: felt252 = *e1m1::REJECT_ROWS.span()[0];
    // things: packed by default -> THINGS (felt252).
    let t0: felt252 = *e1m1::THINGS.span()[0];
    // blockmap: planar by default -> BLOCKMAP_ORIGIN_X/Y/COLUMNS/ROWS (u32) + OFFSETS/WORDS (u32[]).
    let bm_ox: u32 = e1m1::BLOCKMAP_ORIGIN_X;
    let bm_oy: u32 = e1m1::BLOCKMAP_ORIGIN_Y;
    let bm_cols: u32 = e1m1::BLOCKMAP_COLUMNS;
    let bm_rows: u32 = e1m1::BLOCKMAP_ROWS;
    let bm_off0: u32 = *e1m1::BLOCKMAP_OFFSETS.span()[0];
    let bm_words0: u32 = *e1m1::BLOCKMAP_WORDS.span()[0];
    // cellNode (R2-A9/D22): planar by default -> CELL_NODE (u32). The R2-A9
    // candidate-list arrays (ACCEL_START/COUNT/SUBSECTORS[_PACKED]) are off
    // by default (emitConfig.ts#emitAccelCandidates) and so are not emitted
    // into this copy of e1m1.cairo at all.
    let cell_node0: u32 = *e1m1::CELL_NODE.span()[0];
    // predicate bias constants the geom core's `hoist` function needs.
    let hk: felt252 = e1m1::PRED_HK;
    let bigc: felt252 = e1m1::PRED_BIGC;
    let off: felt252 = e1m1::PRED_OFF;
    let fracunit: felt252 = e1m1::PRED_FRACUNIT;

    v0.into() + vy0.into() + n_ab0 + n_bb0 + n_cb0 + n_c0.into() + l_ab0 + l_bb0 + l_cb0
        + l_diag0.into() + l_bbox_lr0 + l_bbox_bt0 + l_blocking0.into() + l_blockmonst0.into()
        + l_twosided0.into() + l_sides0.into() + l_special0.into() + sd_sector0 + ss_sector0
        + s_floor0.into() + s_ceil0.into() + s_meta0 + rej0 + t0 + bm_ox.into() + bm_oy.into()
        + bm_cols.into() + bm_rows.into() + bm_off0.into() + bm_words0.into() + cell_node0.into()
        + hk + bigc + off + fracunit
}

#[cfg(test)]
mod tests {
    use super::sanity_check;

    #[test]
    fn constants_are_reachable() {
        // Only asserts the generated constants link and index correctly;
        // the actual field-level packing round-trip is tested in
        // tools/wad/test/v2Packing.test.ts and test/packing.test.ts
        // (TypeScript side, where the pack/unpack pairs live).
        let _ = sanity_check();
    }

    #[test]
    fn counts_match_array_lengths() {
        assert!(super::e1m1::VERTEX_X.span().len() == super::e1m1::NUM_VERTEXES);
        assert!(super::e1m1::VERTEX_Y.span().len() == super::e1m1::NUM_VERTEXES);
        assert!(super::e1m1::LINEDEF_AB.span().len() == super::e1m1::NUM_LINEDEFS);
        assert!(super::e1m1::NODE_AB.span().len() == super::e1m1::NUM_NODES);
        assert!(super::e1m1::SECTOR_FLOOR.span().len() == super::e1m1::NUM_SECTORS);
        assert!(super::e1m1::CELL_NODE.span().len() == super::e1m1::BLOCKMAP_COLUMNS * super::e1m1::BLOCKMAP_ROWS);
    }
}
