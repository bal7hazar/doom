<!--
SPDX-FileCopyrightText: 2026 Hellproof contributors
SPDX-License-Identifier: Apache-2.0
-->

# `client/` — Freedoom assets, WebGL2 renderer, capability detection

Roadmap items **P2.1** (Freedoom asset loading), **P2.2** (WebGL renderer) and
**P2.7** (COOP/COEP headers, Memory64/RAM detection). The simulation itself
(**P2.3**) is not here yet: a stub sim fills the same `RenderSnapshot` contract
so the renderer can be run and profiled today.

## Quick start

```sh
export ASDF_NODEJS_VERSION=22.22.2     # Node >= 22
npm install
npm run assets                          # downloads freedoom1.wad, extracts E1M1 -> public/
npm run dev                             # http://localhost:5173
```

`npm run assets` writes `public/freedoom1.wad` and `public/levels/e1m1.json`.
Both are **gitignored**: Freedoom is BSD-licensed so a production deployment may
ship the WAD, but it must never enter git history. Point `VITE_WAD_URL` and
`VITE_LEVEL_URL` at a hosted copy to serve them from elsewhere.

| Command | What it does |
|---|---|
| `npm run dev` | Vite dev server, COOP/COEP headers on |
| `npm run build` | `tsc --noEmit` then `vite build` into `dist/` |
| `npm run preview` | Serves `dist/` with the same COOP/COEP headers |
| `npm test` | vitest unit tests |
| `npm run fixtures` | Regenerates the WAD-derived test fixtures |
| `npm run test:e2e` | Playwright smoke test (builds + previews first) |

Keys: **F1** diagnostics · **Tab** automap · **F2** HUD · **F3** light-only
view · **Space** pause · **[** / **]** sim rate · **+** / **−** / **R** automap
zoom and rotation.

## Dependencies

None at run time. Dev dependencies are Vite, TypeScript, vitest, tsx and
Playwright.

There is no WebGL library and no framework. The renderer is four shader
programs and five buffers; Doom's look depends on addressing textures in
*palette index* space and resolving colour through `COLORMAP`/`PLAYPAL` at the
last moment, which a scene-graph library does not help with and mostly
obstructs (RGBA textures, linear filtering) — for several hundred kilobytes on
a page that must also ship a cairo-vm wasm module and a Stwo prover. Sector
triangulation needs no earcut either: see "BSP clipping" below.

## Architecture

```
  freedoom1.wad ──► src/wad/       decode: PLAYPAL, COLORMAP, PNAMES+TEXTUREn,
        │                          patches, flats, sprite frame tables
        ▼
  src/assets/      ──► RG8 atlases (R = palette index, G = coverage)
        │               + palette / colormap textures
  e1m1.json ──► src/map/           BSP-clipped subsector polygons, wall quads
   (tools/wad)      │              with vanilla pegging, doomednum -> sprite
        ▼           ▼
  src/sim/snapshot.ts ────────► src/render/renderer.ts ──► WebGL2
   RenderSnapshot + ring            4 programs: sky, flats, walls, sprites
        ▲                                     │
  src/sim/stubSim.ts                          ▼
   (P2.3 replaces this)               src/ui/ HUD + debug automap (canvas 2D)
```

### The `RenderSnapshot` contract (`src/sim/snapshot.ts`)

The one place the sim Worker and the renderer agree on anything. It follows
`docs/spikes/S3.md` §7.2–7.4:

* one buffer, `SharedArrayBuffer` when the document is cross-origin isolated
  and a plain `ArrayBuffer` otherwise, carrying a 16-word header
  (`SEQ`, `PUBLISHED`, `TIC`, `INPUT_HEAD`, `INPUT_TAIL`, `STATE`), a ticcmd
  input ring, and **three** snapshot slots;
* `publish()` writes slot `(published + 1) % 3` then stores `TIC` and
  `PUBLISHED` and increments `SEQ`; `readPair()` is the matching seqlock reader
  and hands back tics *N−1* and *N* together — which is what the third slot is
  for, since the renderer interpolates between them while the sim writes *N+1*;
* units are the Cairo core's: positions and heights are `fixed_t` (16.16),
  angles are 32-bit BAM, light levels 0–255. The Worker fills it with no
  conversions;
* it is **not** the simulation state. S3 §7.2 keeps the ~48 kB of felts inside
  the Worker's wasm linear memory; one snapshot here is ~19 kB and the whole
  ring ~58 kB.

`interpolate(previous, current, t)` blends continuous quantities (positions,
sector heights, angles via shortest-arc BAM) and takes the newer value for
discrete ones (sprite frame, health, blinking light level). Mobjs are matched
by a stable `id`, and a missing or `TELEPORTED` mobj is not blended, so a
teleport does not streak across the map.

### Light model

Colours are not approximated. Every texel in the atlas is a `PLAYPAL` index and
the fragment shader performs vanilla's own two-step lookup,
`index → COLORMAP[row][index] → PLAYPAL[palette][index]`, with the row from the
closed form derived from `R_InitLightTables`:

```
lightnum = clamp(lightLevel >> 4, 0, 15)
row      = clamp(floor((15 - lightnum) * 4 - 1280 / distance), 0, 31)
```

so sector light *and* distance fall-off land on exactly the colormap row the
software renderer would pick, banding included. `distance` is view-space depth,
as in vanilla. Vanilla's "fake contrast" (horizontal walls one level darker,
vertical ones one lighter) is applied per quad.

One deliberate deviation: walls use this *z* table rather than `scalelight[]`,
which vanilla indexes by the wall's projected scale. The two agree to within
one row outside extreme grazing angles, and using one table keeps a single code
path for walls, flats and sprites. `wad/colormap.ts` carries the CPU twin of
the same function, which the unit tests pin.

### BSP clipping instead of earcut

Sector floors and ceilings are triangulated per **subsector**, and each
subsector's convex polygon is recovered by clipping a starting rectangle down
the BSP tree with `R_PointOnSide`'s own sidedness test.

Earcut over sector edge loops cannot work directly: `SSECTORS` omits the
implicit edges the node builder introduced, so a subsector's segs describe an
*open* boundary. Clipping is exact — the leaf region is by construction the
intersection of the half-planes on the path from the root — it yields convex
polygons (so triangulation is a fan), and it needs no dependency. The unit test
checks that the polygon areas sum to exactly the starting rectangle, which any
gap, overlap or sign error would break.

### What is static and what is rebuilt each frame

| Data | Where it lives | Why |
|---|---|---|
| floor/ceiling **z**, light levels | one RGBA32F texel per sector, sampled in the **vertex** shader | a moving door or a strobing light then touches no vertex buffer |
| flats (floor/ceiling triangles) | static VBO, x/y only | z comes from the sector texture |
| walls of static sectors | static VBO (1 262 quads on E1M1) | nothing about them moves |
| walls of dynamic sectors | rebuilt on the CPU each frame (≈100 quads) | a wall's texture *V* depends on the heights through the pegging rules |
| sprites | rebuilt each frame | billboards |

"Dynamic" is over-approximated by `findDynamicSectors()`: any sector with a tag,
any sector a tagged linedef special addresses, any back sector of a tagless
special, and the light-special sectors. Over-approximating costs a few extra
quads per frame; under-approximating would freeze a door.

### Wall pegging

All four vanilla cases collapse to one number per quad, `worldTopZ` — the world
height of texture row 0 — so `v = (worldTopZ - z) / texHeight` covers uppers,
lowers, one-sided middles and clipped two-sided middles alike. The sidedef's
row offset is *added* to it, because `dc_texturemid` is measured from the eye
and a positive offset raises the texture. `test/geometry.test.ts` exercises
every row of the table in `map/walls.ts`.

## What is rendered, and what is not yet

**Rendered.** Sector floors and ceilings with per-sector light and moving
heights; walls (upper / lower / one-sided middle / masked two-sided middle)
with correct pegging, x/y offsets, fake contrast and the two-sided sky hack;
sky as a full-screen pass reproducing `ANGLETOSKYSHIFT`'s four repeats per
revolution; sprites as camera-facing billboards with `R_ProjectSprite`'s
rotation pick, mirrored lump names, patch offsets, full-bright frames and a
spectre stand-in; the palette flashes (`damageCount`/`bonusCount`) and the
invulnerability colormap; interpolation between two snapshots; a HUD with
health, armour, ammo, keys and a weapon sprite; a debug top-down automap.

**Not yet.** Animated flats and switch textures (`ANIMDEFS`-style cycling);
scrolling walls (linedef special 48); vanilla's real `fuzzcolumn` for spectres;
`scalelight` for walls (see above); the status bar's own graphics (`STBAR`,
`STTNUM*`) — the HUD draws text instead; weapon firing/bobbing states, which
need P2.4's ticcmds; title, intermission and prover-queue screens (P2.6); any
culling beyond the depth buffer — the whole level is submitted every frame,
which is cheap enough at E1M1's scale and would need the BSP walk again to
improve.

## Measured performance

Apple M2 Max, Chromium 153 via the Browser pane, 800×1205 CSS px at
devicePixelRatio 2: **60 fps** (vsync-capped), renderer CPU time
**0.17–0.87 ms/frame**, 5 draw calls, sim 0.03–0.05 ms/tic, 0 dropped tics.
E1M1 submits 1 262 static + ~100 dynamic wall quads, 2 463 flat triangles and
209 sprites; the surface atlas is 2048² at 34 % occupancy and the sprite atlas
1024² at 87 %.

Headless Chromium on SwiftShader (no GPU), 640×400, the Playwright smoke test:
**48–49 fps** over a 2 s window, 71 tics in 2 005 ms, **0 dropped tics**,
assets decoded in 19 ms.

## Tests

`npm test` — 79 vitest tests: pegging (all four vanilla cases and the row
offset), wall quad generation (including that it follows moving heights),
BSP clipping and fan triangulation, dynamic sector detection, picture/flat
decoding cross-checked against `tools/wad`'s independent decoder *and* against
the raw post structure of the lump, `PLAYPAL`/`COLORMAP` parsing and the light
ramp, sprite rotation selection, the snapshot codec and ring, interpolation,
the capability toggle, and the stub sim on the real E1M1.

Tests that need the WAD skip themselves when `test/fixtures/generated/` or
`public/levels/e1m1.json` is absent, so a clone without the IWAD is still
green. `npm run fixtures` regenerates them.

`npm run test:e2e` — Playwright, against `vite preview` so the *production*
bundle and headers are exercised: the COOP/COEP headers and
`crossOriginIsolated`, a 2 s frame-rate window with the geometry counts and the
drop rate, a drawing-buffer histogram (read inside the render loop, since the
context has no `preserveDrawingBuffer`), and the diagnostics panel. Screenshots
land in `e2e/artifacts/`.
