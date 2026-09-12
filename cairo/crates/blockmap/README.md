# blockmap

**Does**: maps a `geom2d::Point` to its blockmap cell coordinates
(`try_block_of`) and a cell coordinate pair to a linear storage index
(`cell_index`), given a `BlockMap` (origin, fixed square cell size, grid
width/height) — the spatial acceleration structure `P_TryMove` and
`P_PathTraverse` iterate over instead of scanning every line/thing.

**Does not**: store or iterate the actual per-cell line/thing lists (that
data comes from `tools/wad` and is owned by `doom_map`); it does not (yet)
implement the cell-by-cell traversal along an arbitrary segment (the
`P_PathTraverse`-style walk) — that is a Phase 1 addition once `doom_map`
exists to provide real cell contents to traverse.

**Invariants**: `try_block_of` returns `Option::None` for any point outside
the blockmap's bounding box (never a wrapped/clamped index) and
`Option::Some((cx, cy))` with `cx < width` and `cy < height` otherwise;
`cell_index` is injective over the valid `(cx, cy)` range (`cy * width +
cx`), so distinct cells never alias to the same storage index.
