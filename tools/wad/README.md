# tools/wad

Extracts a Doom map (vanilla WAD format, e.g. Freedoom's `freedoom1.wad`
E1M1) into:

- **Output A** - `out/<map>.json`: the full map in plain map units, for the
  TypeScript/WebGL client (rendering, HUD, debug tools). Includes SEGS and
  texture/flat names, which the Cairo output (below) does not.
- **Output B** - `out/<map>.cairo`: a Cairo source file of `const` arrays
  the game core reads at runtime - only what the simulation actually needs
  (see "What v2 changed" below), under a configurable size/speed layout
  (`emit-config.json`).
- **Output C** - `REPORT-<map>.md` (committed, not a build artifact): counts,
  linedef/sector/thing special-type breakdowns that drive the Phase 1
  gameplay-scope decision, the R2-A9 accelerator statistics, and the R2-A12
  bytecode budget report.

This is the **v2** tool (RISKS.md R2-A9/R2-A12, docs/spikes/S1.md, docs/G0.md
D4). See "What v2 changed" for what's different from the original packed-
everything extractor.

## Library

`tools/wad` is also `@hellproof/wad`, a browser-safe library: `src/index.ts`
re-exports the WAD directory reader and every lump/asset decoder (`Wad`,
`BinaryReader`, `parsePlaypal`, `parseColormap`, `decodePatch`, `decodeFlat`,
`composeTexture`, `buildSpriteDefs`, ...), all typed against `Uint8Array` and
reading through a `DataView` - nothing under `src/` (`src/cli.ts` excepted)
imports from `node:*`. `client/` depends on it directly (npm workspace) as
`import { Wad, parsePlaypal, ... } from "@hellproof/wad"` instead of carrying
its own copy of the parsers - see e.g. `client/src/assets/assetStore.ts` and
`client/src/render/renderer.ts`. `package.json`'s `exports` map points
straight at the TypeScript sources
(`"./src/index.ts"`), which both Vite and `tsc`'s `moduleResolution: "bundler"`
resolve directly - no build step is required to consume this package.

The CLI (`src/cli.ts`, `npm run extract`) is the only Node-specific part: it
owns `readFileSync`/`writeFileSync` and the map-extraction pipeline (JSON/
Cairo/report outputs) that only the build step needs.

## Usage

```sh
export ASDF_NODEJS_VERSION=22.22.2   # Node >= 22
npm install
./scripts/fetch-freedoom.sh          # downloads freedoom1.wad to a scratch dir; never commit WADs
npm run extract -- --wad <path/to/freedoom1.wad> --map E1M1 --out out/ --report REPORT-e1m1.md
```

`npm run extract` exits with **3** (after still writing `out/<map>.json` and
`out/<map>.cairo`, and the report if `--report` was given, so you can inspect
what was too big) when the emitted Cairo constants exceed the bytecode
budget - see "Bytecode budget" below. Pass `--no-budget-gate` to keep the
exit code 0 in that case (the overrun is still logged to stderr); this is
what `client/scripts/prepare-assets.sh` relies on implicitly by not caring
about the exit code, since it only needs the JSON output.

Other scripts:

```sh
npm test           # vitest (hermetic unit tests always run; real-WAD tests skip if freedoom1.wad is absent)
npm run typecheck
npm run verify:cairo [map-name-lowercase]   # copies out/<map>.cairo into cairo-check/ and runs `scarb build`
```

CLI flags:

| Flag | Default | Meaning |
|---|---|---|
| `--wad` | (required) | Path to the WAD file. |
| `--map` | (required) | Map lump name, e.g. `E1M1`. |
| `--out` | (required) | Output directory for `<map>.json`/`<map>.cairo`. |
| `--config` | `tools/wad/emit-config.json` | Layout config file (see below). |
| `--max-words` | `12000` | Bytecode-word budget for the emitted Cairo constants (R2-A12); extract exits 3 above this (unless `--no-budget-gate`). |
| `--report` | (none - no report written) | Path to write `REPORT-<map>.md` (Output C) to. Decoupled from `--out` on purpose: `--out` alone never writes or overwrites a report, so pointing `--out` at a scratch directory (as `client/scripts/prepare-assets.sh` does) can never clobber the committed `tools/wad/REPORT-<map>.md`. Pass `--report REPORT-e1m1.md` (from `tools/wad/`) to regenerate the committed report. |
| `--no-budget-gate` | off | Still computes and logs the bytecode budget, and still writes every file, but exits 0 even if the budget is exceeded. |

## What v2 changed

The original extractor packed every lump into one `felt252`/`u32` per
record, unconditionally, and emitted every lump verbatim (including SEGS and
texture names) into the Cairo output. docs/spikes/S1.md measured that this
is wrong on both counts for a Cairo core proved through the bootloader
route:

1. **Packing is a net loss for data read often, a net win for data read
   rarely.** A `const` array read costs 11 steps regardless of layout
   (§5.1), so unpacking a record costs extra steps for nothing if it's read
   dozens of times per tic - but *bytecode size* (1 word per constant felt,
   §5.9) is itself a per-segment bootloader cost (`2 340 + 14.7 * words`
   steps, docs/spikes/S0.md §5.2), which dominates for large tables read a
   handful of times per tic. v2 makes this a per-group config choice instead
   of a single fixed layout - see "Layout config" below.
2. **The simulation doesn't need SEGS or texture names at all.** Geometry
   for collision is precomputed into half-plane predicate coefficients
   (below), and subsector -> sector is resolved once at extraction time
   (`derive.ts#computeSubsectorSectors`) instead of walked through
   SEGS/LINEDEFS/SIDEDEFS at runtime. Both are dropped from the Cairo
   output and kept only in the JSON output, for the client's renderer.

### Half-plane predicates (R2-A4)

For every linedef and BSP node partition, the extractor precomputes the
three biased coefficients `(Ab, Bb, Cb)` of `cross = A*y_f + B*x_f + C`
(`side = 1 iff cross >= 0`), so the Cairo core never recomputes a cross
product from raw vertices - see `src/predicates.ts` for the exact derivation
and bias constants (ported from the validated prototype in
`spikes/s1/proto`), and `PRED_HK`/`PRED_BIGC`/`PRED_OFF`/`PRED_FRACUNIT` in
the generated file for the constants a Cairo consumer's `hoist()` function
needs. Linedefs also get a `diag` bit (`P_BoxOnLineSide`'s corner selector).

### Cell -> subsector accelerator (R2-A9)

For every blockmap cell, `src/accelerator.ts` lists the subsectors whose
geometry can overlap that cell (`ACCEL_START`/`ACCEL_COUNT`/
`ACCEL_SUBSECTORS[_PACKED]`), so the Cairo core can answer "which subsector
is this point in" without a full BSP descent (or SEGS) in the common case.

**Method**: a subsector's bounding box is the union of the vertex
coordinates of its SEGS (the node builder always closes a subsector's
polygon with SEGS, wall and internal-partition segs alike). A subsector is
listed for a cell whenever the two boxes intersect.

**Why it's conservative** (never omits the true subsector of a point in the
cell): every point inside any polygon has x/y coordinates between the
min/max of that polygon's own vertices (a point inside a polygon is a
convex combination of its vertices), so a polygon is always a subset of its
own bounding box. If point `p` is in subsector `S` and cell `C`, then `p` is
in `bbox(S)` and in `bbox(C)`, so the two boxes intersect and `S` is listed
for `C`. It can list extra subsectors whose bbox reaches a cell without
their polygon doing so, but never omit the true one.
`test/accelerator.test.ts` checks this by sampling points across every cell
of a synthetic map and of real E1M1, and comparing against a ground-truth
BSP descent (`accelerator.ts#locateSubsector`). REPORT-e1m1.md reports the
average/max candidate-list length and how many cells resolve to a single
subsector.

### Layout config (`emit-config.json`)

Every group of Cairo constants below can be emitted `"planar"` (one `const`
array per field - cheap to read, one bytecode word per felt per field) or
`"packed"` (fields bit-packed into fewer felts - more expensive to read,
fewer bytecode words). `emit-config.json` (loaded by `--config`, defaulting
to the one at the root of this package) sets the layout per group; a group
left out of the file falls back to the built-in default in
`src/emitConfig.ts`, which follows docs/spikes/S1.md's sizing rule
(`src/emitConfig.ts`'s doc comment has the exact reasoning for every group):

| Group | Default | What it covers |
|---|---|---|
| `vertices` | planar | VERTEXES x/y |
| `nodePredicates` | planar | BSP node half-plane coefficients |
| `nodeChildren` | planar | BSP node left/right child (node index or leaf subsector) |
| `linedefPredicates` | planar | Linedef half-plane coefficients + `P_BoxOnLineSide` diagonal bit |
| `linedefBBox` | packed | Linedef bounding box (biased-fixed, same domain as the predicate) |
| `linedefFlags` | planar | Linedef blocking/block-monsters/two-sided bits |
| `linedefSides` | packed | Linedef front/back sidedef index |
| `sectorHeights` | planar | Sector floor/ceiling height |
| `blockmap` | planar | Blockmap header/offsets/words |
| `accelerator` | packed | R2-A9 cell -> subsector candidate lists |
| `reject` | packed | REJECT visibility bit matrix |
| `things` | packed | THINGS (spawn position/angle/type/flags) |
| `linedefSpecial` | packed | Linedef special type + sector tag |
| `sidedefSector` | packed | Sidedef -> sector index |
| `subsectorSector` | packed | Subsector -> sector index (task item 1) |
| `sectorMeta` | packed | Sector light level/special type/tag |

Edit `emit-config.json` (or pass `--config <path>`) to try a different mix;
`ALL_PLANAR_CONFIG`/`ALL_PACKED_CONFIG` in `src/emitConfig.ts` are the two
extremes used for the size-comparison table in the report.

### Bytecode budget (R2-A12)

`src/bytecodeBudget.ts` applies S1's measured "1 word of bytecode per
`const` array element" rule to every array the emitter writes (approximated
uniformly across `felt252`/`u32` - see that file's header for the caveat),
sums it, and `cli.ts` fails (non-zero exit, after still writing the files)
when the total exceeds `--max-words` (default 12 000, a slice of docs/G0.md
D4's 16 000-word budget for the whole `doom_run` program - this tool only
emits level data, not the rest of the core's code). REPORT-e1m1.md's
"Bytecode budget" section has the full per-array table and a
planar/packed/recommended size comparison. **On real Freedoom E1M1, even
the all-packed extreme exceeds the 12 000-word default** - a genuine
finding (parallel to S1's own "steps/tic" budget overrun), not a bug: E1M1
is a dense map (1175 linedefs, 682 subsectors), and this is exactly the kind
of number the R2-A12 gate exists to surface before it reaches a real
`doom_run` build.

## Testing

`npm test` runs hermetically by default (synthetic in-memory WADs built by
`test/testWad.ts`); tests that need the real `freedoom1.wad`
(`test/realWad.ts#hasRealWad`) skip automatically if it isn't present at
`$FREEDOOM_DIR/freedoom1.wad` (`./scripts/fetch-freedoom.sh`'s default
output location). Notable v2 test files:

- `test/predicates.test.ts` - half-plane predicate coefficients vs. a float
  re-implementation of `P_PointOnLineSide`, random-sampled, plus the S1 §7
  documented vanilla-vs-general-formula divergence at a vertical line
  through `v1.x`.
- `test/accelerator.test.ts` - R2-A9 conservativeness: every sampled point's
  true (BSP ground-truth) subsector is listed in its cell's candidates, on
  both a synthetic map and real E1M1.
- `test/subsectorSector.test.ts` - subsector -> sector correctness against
  an independent SEGS -> LINEDEF -> SIDEDEF walk.
- `test/bytecodeBudget.test.ts` - word counting, the budget-exceeded error,
  and planar >= recommended >= packed on real E1M1.
- `test/v2Packing.test.ts` - round-trips every new packed record layout.

`scripts/verify-cairo.sh` (`npm run verify:cairo`) proves the generated
`.cairo` file actually compiles under Scarb (`cairo-check/`, a throwaway
package); `cairo-check/src/lib.cairo` touches one representative constant
from every group so a `scarb build` failure would catch a layout mistake
before it reaches a real crate.
