<!--
SPDX-FileCopyrightText: 2026 Hellproof contributors
SPDX-License-Identifier: Apache-2.0
-->

# `client/` — Freedoom assets, WebGL2 renderer, proving pipeline, local storage

Roadmap items **P2.1** (Freedoom asset loading), **P2.2** (WebGL renderer),
**P2.5** (IndexedDB persistence, export/import), **P2.7** (COOP/COEP headers,
Memory64/RAM detection) and **P3.2** (segmenter + prover Worker: segments proved
during play, queue, resume). The simulation itself (**P2.3**) is not here yet: a
stub sim fills the same `RenderSnapshot` contract so the renderer can be run and
profiled today, and the proving pipeline proves the `segment_stub10` stand-in
until `doom_run` exists.

## Quick start

```sh
export ASDF_NODEJS_VERSION=22.22.2     # Node >= 22
npm install
npm run assets                          # downloads freedoom1.wad, extracts E1M1 -> public/
npm run prover                          # stages the wasm64 prover -> public/prover/ (optional)
npm run dev                             # http://localhost:5173 (game), /prove.html (pipeline)
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
| `npm run prover` | Stages `@hellproof/prover-wasm` into `public/prover/` (see below) |
| `npm run test:e2e` | Playwright: the renderer smoke test, two proved segments, the leaderboard smoke test, the demo cadence bench, **and** (project `mobile`) the touch-control smoke test on an emulated phone |

Keys: **F1** diagnostics · **Tab** automap · **F2** HUD · **F3** light-only
view · **F4** proof queue · **Space** pause · **[** / **]** sim rate ·
**+** / **−** / **R** automap zoom and rotation. On a phone or tablet the
on-screen controls replace them — see [Mobile](#mobile).

`npm run prover` copies the package's built JS and the two 45 MB wasm64
artifacts into `public/prover/{dist,wasm}/` — gitignored, like the WAD. It does
**not** build them: `prover/wasm/build.sh` does, and it takes a while. Point
`PROVER_WASM_DIST` at a directory that already has them to skip that. Without
them the game still runs and still records a run; only proving is unavailable,
and the queue panel says so (R6-A3: prove later, or elsewhere).

## Dependencies

`@hellproof/wad` (`tools/wad`, an npm workspace) at run time: the browser-safe
WAD directory reader and asset decoders (`Wad`, `parsePlaypal`,
`decodePatch`, ...) - see `tools/wad/README.md`'s "Library" section.

Two further workspace packages are consumed **for their types only**, so nothing
of them is bundled and no build-order coupling exists between the three:

| Package | Why | How it actually arrives |
|---|---|---|
| `@hellproof/prover-wasm` (`prover/wasm/pkg`) | the wasm64 Stwo prover | as static files under `public/prover/`, staged by `npm run prover`; the page loads its Worker by URL |
| `@hellproof/wrapper-client` (`prover/wrapper/client-ts`) | the wrapper's wire schema | `src/wrapper/submitter.ts` implements the upload itself (resumable, streamed) and imports only the types |

`tsconfig.json` maps both names onto those packages' **sources**, so
`npm run typecheck` works in a fresh clone whether or not their `dist/` has been
built. Dev dependencies are Vite, TypeScript, vitest, tsx, fake-indexeddb and
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
  freedoom1.wad ──► @hellproof/wad decode: PLAYPAL, COLORMAP, PNAMES+TEXTUREn,
        │            (tools/wad)   patches, flats, sprite frame tables
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

## Proving a run (P3.2) and keeping it (P2.5)

```
  game loop --> ProveSession.recordTic(word) --> TicLog (7 tics/felt, as `ticcmd`)
                                                    |  flushed to IndexedDB ~1 Hz
  ProofPipeline  (page thread - orchestration only)
      |
      +- plan ---- SegmentPlanner.propose(K) --+
      |                                         v
      |          execute(args) --> resources() --> fits? --no--> shrink, probe again
      |                                              | yes
      +- prove ------------------------------------- +   deadline; hang => kill + 1-thread retry
      +- verify --- in the browser, every proof
      +- chain ---- h_in/h_out, tics, status (D14)
      +- persist -- RunStore: segment + 4.2 MB proof, one transaction, then drop the prover
                      |
   ProofQueuePanel <--+   WrapperSubmitter --> POST /v1/runs --> batch folded
                                                                    |
                          OnChainSubmitter (P4.3) <-- GET /v1/batches/{id}?include=proof
                              prepareSubmission --> CostScreen --> submit / wait / offline
                                                       `-- runSequence (Controller signs)
```

### The planner's policy

Decision **D1** (revised by S4b and P3.1) says a segment is bounded by the
**largest AIR component**, not by a step count: the leaf registry is keyed on
`trace_log_size`, which stays 20 as long as every component stays under 2^20
rows, and where that happens depends entirely on the program's memory profile
(2.31 M steps for `steps_k`; something else for `doom_run`). So
`src/prove/planner.ts` asks the prover rather than counting:

1. **Two hard constraints.** `next_pow2(count_i) <= 2^20` for every component -
   which is exactly `count_i <= 2^20` on the raw counters `resources()` returns -
   and a step ceiling of **1.5 M with threads** / **2.3 M single-threaded**
   (**R1-A8**: threaded proving hung twice in ~16 runs at >= 2 M steps in Chrome).
2. **A continuous control signal.** `max_component_rows` is already rounded to a
   power of two, so on its own it only ever says "100 %, 50 %, 25 %...". The
   planner recovers the *un-rounded* count from the opcode/builtin/memory
   counters (applying the prover README's own row rules, `/16` for
   `memory_address_to_id` included) and checks `nextPow2(raw) ===
   max_component_rows` on every summary. If that ever fails - a component the
   client does not model - it falls back to the rounded ratio, which is coarser
   and never optimistic.
3. **An affine model, used as an accelerator only.** Rows and steps are both
   affine in K, so a least-squares fit over the segments already measured solves
   for the K that lands at `targetUtilisation` (default **0.8**, i.e. a 20 %
   margin) of the row ceiling and under the step ceiling. With no measurement the
   first guess is `initialTics`; with exactly one, the line is read *through the
   origin*, which understates capacity for any program with a fixed cost (every
   one of them - the leaf bootloader alone is ~4 881 steps) and therefore
   proposes a short segment rather than an impossible one. `maxGrowth` bounds how
   fast it catches up.
4. **Nothing is proved that `resources()` has not just approved.** The proposal
   is verified by a real `execute()` + `resources()`; on a rejection the planner
   returns the factor to shrink by and the pipeline probes again, at most
   `maxProbes` times before halving blindly. Above the ceiling the prover does
   not fail gracefully - it panics inside the constraint framework - so this is a
   gate, not an optimisation.

Mid-game the pipeline **waits** rather than cutting a segment shorter than the
model wants: a leaf proof costs the same fixed 2^21-row trees whatever it
carries, so a half-full segment doubles the work for the same game. `finish()`
lifts that and cuts whatever is left.

### Where each thing runs, and why

Everything expensive is in the prover's own Worker (`execute`, `resources`,
`prove`, `verify`), with `threads = min(4, hardwareConcurrency - 2)` when the
page is `crossOriginIsolated` and 1 otherwise - R6-A1 leaves two cores to the
game, and 4 is where the wasm allocator's spin lock starts winning (P3.1).

The orchestrator stays on the page's thread on purpose. A hung `prove()` is
unobservable from inside the Worker that is hung: the only lever is
`Worker.terminate()` from another thread, so the deadline and the
**single-thread retry** (R1-A8) have to live on the other side of the message
port. What remains on the page is `postMessage`, a few `await`s and the
IndexedDB writes, and each step is handed to `scheduler.postTask({priority:
"background"})` where it exists.

After every segment the prover Worker is dropped (**R1-A7**): a
`WebAssembly.Memory` never shrinks, so the 2-5 GiB a proof peaks at only comes
back with the Worker. Re-instantiating costs ~50 ms - the artifact is already in
the HTTP and code caches.

### What is persisted

`src/store/` keeps five IndexedDB object stores: `runs`, `segments`, `inputs`
(the journal, packed 7 tics to a felt exactly as `cairo/crates/ticcmd` does),
`proofs` (the ~4.2 MB bincode blobs, in their own store so listing a run does not
drag them through structured clone) and `meta`. A segment and its proof are
written in **one transaction**, so no crash can leave a segment marked `proved`
with no proof behind it. On reload, `attach()` re-queues every segment that is
not `proved` and leaves the rest alone - the boundaries are *not* recomputed,
since the planner's decisions depend on the machine that made them.

Quota (`src/store/quota.ts`): `navigator.storage.persist()` is requested before
proving starts, and the pipeline projects the remaining proofs forward after each
one, warning while there is still room to export rather than failing on a
`QuotaExceededError` halfway through.

**`.hellproof`** is one run in one file: a 16-byte header, a JSON manifest (the
run record, the packed journal, every segment record, and an index of the
proofs with a SHA-256 each) and then the proof bytes back to back. Base64 inside
the JSON would have cost a third more and forced the whole run through one
string. Import verifies the checksums and renames the run if its id is taken.

**C6** is two switches: a per-run `keepOffline` flag the submitter refuses to
upload past, and a reset that deletes the run, its journal, its segments and its
proofs.

### Submitting to the wrapper - and what the wrapper API lacks

`POST /v1/runs` takes a **whole run** in one JSON body, and `run_id` is the unit
of idempotency. For a 3-minute game that is 25-75 proofs of ~4.2 MB, i.e.
140-420 MB of base64 in a single request, and a partial submission followed by a
fuller one is a `409`, not a resume. `prover/wrapper/client-ts`'s README says
"keep the body streaming rather than building one giant string where you can" -
there is no endpoint that lets a client do better than that.

`src/wrapper/submitter.ts` therefore implements two strategies and picks one:

- **`per-segment`** - `GET /v1/runs/{id}/segments` (what the server already
  holds), `PUT /v1/runs/{id}/segments/{index}`, `POST /v1/runs/{id}/complete`.
  **The wrapper does not implement these**; this is the shape it should add, and
  the client probes for it once. A dropped connection would then cost one proof
  instead of a whole game.
- **`whole-run`** - what works today: one `POST /v1/runs` whose body is a
  `ReadableStream`, so only one proof is base64'd at a time. Where the engine
  cannot stream a request body, the client refuses bodies over
  `maxInlineBodyBytes` (64 MiB) and tells the player to export instead of
  silently trying to allocate half a gigabyte of string.

Either way the wrapper `run_id` is stored locally and reused on every retry, so a
retry is a dedupe rather than a double proof, and `uploadedSegments` is
persisted so a reload knows what is left. `GET /v1/runs/{id}` and
`GET /v1/batches/{id}` are mirrored into the run record (status, batch id, root
felt count); once the batch is `done`, `ProveSession.submit()` continues with
the on-chain leg below.

## On-chain submission (P4.3, D28)

`src/chain/prepareSubmission` selects five verifier transactions by default with the optimized
P4.1 router: FRI cut `[2]`, followed by a separate `DoomRuns` consumer transaction. Explicit
cuts and calldata-cap fallback remain supported. The cost screen simulates the ordered
sequence from the signing account before sending; R7-A1 margins are unchanged.

The chosen FRI cut is saved with checkpoint echoes before the first send. A saved plan is
restored before estimation, including the former six-transaction default. An older active
checkpoint with no saved cut requires the original explicit plan; the shared resume code
refuses to guess it from the FRI tag. The CLI recovery command for the former default is
`--fri-split 1,3`. No extra planning control is added to the game UI.

P4.1 needs its newly deployed router classes; an older deployment still has its historical
costs. Measurements, compatibility and offline regression tests live in
[`infra/submit/README.md`](../infra/submit/README.md).

### Configuration

`src/prove/onchain.ts` reads the settings from Vite variables, each overridable by a query
parameter (the parameter wins, as on the leaderboard page). Nothing is hard-coded: with a value
missing the game still boots, and pressing **Submit…** logs which names to set instead of
failing an RPC call.

| Setting | Vite variable | URL parameter | Required |
|---|---|---|---|
| Starknet JSON-RPC URL | `VITE_RPC_URL` | `rpc` | yes |
| `StwoCircuitRouter` (P4.1 classes) | `VITE_ROUTER_ADDRESS` | `router` | yes |
| `DoomRuns` | `VITE_DOOM_RUNS_ADDRESS` | `runs` | yes |
| `DoomRuns` version id | `VITE_VERSION_ID` | `version` | yes |
| level id recorded for the run | `VITE_LEVEL_ID` | `level` | no, default `1` |
| router proof id override | `VITE_PROOF_ID` | `proofId` | no, derived from the batch id |
| chain id (skips `starknet_chainId`, seeds the Controller) | `VITE_CHAIN_ID` | `chain` | no |
| season sponsoring (R7-A4) | `VITE_SPONSORED` | `sponsored` | no |
| publish the packed input logs (R10-A3) | `VITE_REPLAY` | `replay` | no |
| wrapper base URL | `VITE_WRAPPER_URL` | `wrapper` | for the upload |

The proof id keys the router's checkpoint (`(caller, proof_id)`), so it must be the same on
every attempt for one batch and different for the next: `proofIdFor(batchId)` derives it from the
wrapper's batch id (a hex id is read as a number, anything else is hashed under 2^250), which
is why a reload resumes without a second piece of state. `?proofId=` exists for the "restart
under a fresh proof id" recovery the resume code sometimes asks for.

### The flow

`ProveSession.submit()` is the whole path, and pressing the button again continues wherever it
stopped:

1. **upload** — as above, unless the run record already carries a batch id;
2. **fold** — `GET /v1/batches/{id}`; a batch that is not `done` yet is reported and the
   button can be pressed again later;
3. **proof** — `WrapperSubmitter.fetchBatchProof` fetches `?include=proof` (the ~94 k root
   felts and the packed tree); nothing of it is stored locally beyond the felt count;
4. **member** — the Controller is connected (session policies = exactly the six submission
   entrypoints, `controllerConnect.ts`), and the batch is mapped onto the player's own run. The
   browser knows one address, so the sequence records one member: `submit_batch` when the run
   is alone in its batch, `register_member` — D20's per-player fallback — when the wrapper
   folded it with other players' games. `checkBatch` refuses a batch the contract would reject
   (chain break, `ABORT`, wrong genesis) *before* anything is paid for;
5. **cost screen** (`ui/costScreen.ts`, C5) — `resumePoint` first, so a sequence that already
   paid for some phases is priced for what is left; then the ordered simulation from the
   signing account, the per-transaction STRK and fiat figures with the quote's timestamp, the
   24 h-median verdict (or "cannot tell" on a fresh device), and the three answers of C6:
   * **Submit now** — `runSequence` with the connected signer and the R7-A1 bounds; the FRI
     cut and every checkpoint echo go to `localStorage` before each send, so a closed tab or a
     wallet that stops half-way resumes from the router's checkpoint with **Resume**, and
     nothing accepted is paid for twice. The fact and `chainStatus: done` land on the run record;
   * **Wait** — the overlay closes, nothing is sent, the run keeps its batch id and
     `chainStatus: waiting`; the next press of **Submit…** skips straight to step 3;
   * **Keep offline** — sets the run's `keepOffline` flag (the one the wrapper submitter refuses
     to upload past); the run, its journal and its proofs stay on this device and remain
     submittable later under the same proof id.

The real-game route (`prove/gameBridge.ts`) keeps its documented offline policy — no wrapper,
`keepOffline` set — so the on-chain leg is reached from `index.html`'s F4 panel (demo route) with
the variables above, and from `infra/submit` for a batch on disk.

## Leaderboard (P4.4)

`leaderboard.html` (`src/leaderboardMain.ts`, `src/leaderboard/`) is the read side of `DoomRuns`:
best-score / best-time boards per version with paging, a player page, and a run detail view with
the on-chain proof of validity (fact, `submit_batch` transaction, a Voyager link on a public
network) and a replay download. Plain TS + CSS, no framework — same convention as `prove.html`.

```
leaderboard.html?indexer=http://localhost:8788                # infra/indexer's read API
leaderboard.html?rpc=http://127.0.0.1:5081/rpc&runs=0x<DoomRuns>  # RPC fallback, no indexer needed
```

Query parameters: `indexer` (base URL of `infra/indexer`; when present it is used), `rpc` /
`runs` (the fallback: `DoomRuns`'s own views — `leaderboard`, `get_run`, `player_runs`, … — called
directly over JSON-RPC, so the page works with nothing but an RPC URL), `network`
(`mainnet`/`sepolia`/anything else means devnet-local, which skips the explorer links), `version`
(default board version). Hash routes: `#/board`, `#/player/<address>`, `#/run/<run_id>`.

The replay download reuses `src/store/hellproofFile.ts`'s exact container format and types
(`src/leaderboard/replay.ts`): it reconstructs the run's continuous input journal from the
`Replay` events' per-segment packed logs (each restarts its own 7-tics-per-felt grouping — D13 —
so the leaves cannot just be concatenated) and writes a `.hellproof` file with `proofs: []`,
readable by `parseHellproofFile`/`importRun` unmodified. It is an input log, not a re-provable
run: the chain publishes inputs, never proof bytes.

Without an indexer, `/stats` and full player history are unavailable (no on-chain view enumerates
every run or player) — the RPC fallback still serves the board, run details and a player's own
`player_runs`, just less efficiently (P4.4 exists precisely for the case an indexer answers
better). See `infra/indexer/README.md` for the indexer's API, schema and reorg handling.

### The stand-in program, and how `doom_run` drops in

`src/prove/program.ts` is the whole seam: an id, a hash function, the genesis
`h_in`, `executableJson()` and `encodeArgs(request)`. The output side is fixed
already - `decodeSegmentOutput` reads the **ten felts of D14**
(`[version, h_in, h_out, tic_start, tic_end, status, inputs_commitment, kills,
items, secrets]`), which is `cairo/crates/segment`'s `SegmentOutput` and what
`DoomRuns` consumes. Today the implementation is `createStubProgram()`, wrapping
`spikes/s4/programs/segment_stub10` (committed at
`public/programs/segment_stub10.executable.json`, 36 kB, built with Scarb 2.18).
It returns the real ten felts over a synthetic input log, and its "game" is a
fixed ~2^17-step arithmetic loop, so a segment costs ~171 k steps plus ~49 per
tic. `doom_run` replaces the executable and `encodeArgs`; nothing else moves.

### Measured, end to end

Apple M2 Max, Playwright Chromium, `vite preview` (production bundle and
headers), **single-threaded**, two `segment_stub10` segments of 7 tics each -
`e2e/prove.spec.ts`:

| segment | steps | prove | verify | peak wasm memory | proof |
|---:|---:|---:|---:|---:|---:|
| 0 | 171 587 | 23.9 s | 57 ms | 2.00 GiB | 4.2 MB |
| 1 | 171 619 | 21.0 s | 58 ms | 2.01 GiB | 4.2 MB |

Whole test, including two 45 MB module instantiations, both proofs, both local
verifications, the chain check, a reload, the export and a re-verification of
both stored proofs from IndexedDB: **46.8 s**. The same pipeline in Node 24
proves one of these segments in 23.2 s at 2.00 GiB. Thread scaling is measured in
`prover/wasm/harness`, not here; this test is a regression gate and deliberately
takes the path R1-A8 says never fails.

## Mobile

PLAN C1 (revised by **D35**) wants 35 tics/s **on a mid-range smartphone** with
touch controls, and D35 keeps proving off the phone entirely: the phone plays and
commits its journal, anybody proves. This section is what the client does for
that and how to measure it on a device.

### Touch controls

`src/game/touchInput.ts` (model) and `src/ui/touchControls.ts` (DOM) mount an
overlay when the page runs on a touch screen — a coarse primary pointer, or a
touch screen without hover (`?touch=1` / `?touch=0` force it either way; a
touch-screen laptop with a mouse keeps the keyboard layout). Nothing of it exists
on a desktop.

| Control | Where | Command |
|---|---|---|
| Floating joystick | left half (the base appears under the finger) | forward/back and strafe; full deflection is the keyboard's 25 / 24, the Run toggle makes it 50 / 40, in between is scaled like vanilla's analog joystick and truncated |
| Look zone | right half | turn: 128 BAM per pixel of horizontal drag (≈ 700 px per revolution), consumed once per tic, bounded like the mouse |
| FIRE, USE | bottom right, held | `BT_ATTACK = 1`, `BT_USE = 2` |
| RUN | bottom right, toggle | the Shift tier |
| WPN | bottom right, tap | `BT_CHANGE | code << 3`, cycling pistol → shotgun → chaingun → fist → chainsaw from the weapon held |
| PAUSE, MAP | top right | pause (the central panel takes over: Resume, Save, Export…), automap |

The contributions land in **the same ticcmd fields as the keyboard and mouse**
and go through the same `quantize()` in `GameInput.sample()`, so a phone journal
is a keyboard journal in nature (D12) — nothing in the journal, the proof or the
chain knows which device played. Every pointer is tracked by id (a moving finger,
a turning finger and a Fire finger coexist); a cancelled or captured-and-lost
pointer, a blur, a hidden tab, a rotation or a pause releases everything held.
Scroll, pinch-zoom, double-tap zoom, text selection and the long-press menu are
suppressed under the game (`touch-action: none`, a non-passive `touchmove`,
`gesturestart`), the viewport is `viewport-fit=cover` with the safe-area insets
applied to the overlay, `#stage` uses the dynamic viewport height, and portrait
shows a dismissible "turn your phone" notice. The HUD status bar scales down
under 720 CSS px so its key labels and the level tally do not collide on a
narrow landscape phone. Pointer lock is never requested on a touch device.

The renderer demo (`?sim=demo`) has no input path, so there the look drag turns
the tour's camera through the same quantization: the controls can be tried
without the Cairo artifacts.

### Cadence bench: measuring 35 tics/s on the device

`/?bench=1` runs the ordinary game loop — Worker, renderer, HUD — with a
scripted input instead of the player's, then shows a panel with a pass/fail
verdict, a table and the JSON to paste back (**Copy JSON**). Procedure for the
sponsor, on an Android and on an iPhone:

1. serve a production build to the phone (below) and open `/?bench=1`;
2. wait: 700 paced tics (20 s) at 35 Hz, then 175 unpaced tics (the Worker's
   raw throughput), then the memory probes — the status line counts;
3. tap **Copy JSON** and paste the result into the issue or the report.

Without `public/sim/` the page says so; `/?sim=demo&bench=1` measures the
renderer's demo stand-in instead and labels the result **"DEMO SIMULATOR — not
the Cairo VM"** everywhere (its "VM time" is the stub's JavaScript step). Query
parameters: `tics=` (paced tics, default 700), `burst=` (unpaced tics, Cairo
only, default 175, `0` disables), `journal=<url>` (replay a saved game's
**Export** file instead of the built-in script, which cycles ten seconds of
idle, walk, turn, walk while firing, strafe, use and run while turning with the
keyboard's own words).

The JSON (`format: hellproof-cadence-bench/1`) carries: `paced` — tics, elapsed,
**tics/s**, dropped tics, `vmMs` (the Worker's time per tic including the
checkpoint every 32 inputs; p50/p95/max/mean), `roundTripMs` (request to
acknowledged frame on the main thread), `overBudget` (round trips over
28.57 ms), Cairo steps per tic; `burst` — the same for the unpaced phase;
`render` — fps, renderer CPU ms per frame and frame-to-frame ms (p50/p95/max);
`memory` — the Worker's peak wasm linear memory, the page's JS heap
(`performance.memory`, Chromium) and `performance.measureUserAgentSpecificMemory()`
(Chromium, cross-origin isolated documents only; `null` elsewhere);
`environment` — user agent, platform, cores, `deviceMemory`, viewport and
`devicePixelRatio`, GPU string, isolation, touch. `verdict.sustained35` is true
when every planned tic ran, at ≥ 34 tics/s, with under 5 % of round trips over
budget and under 1 % dropped. The desktop reference figures are in
[`src/sim/README.md`](src/sim/README.md).

### Serving the game to a phone

The game needs **no SharedArrayBuffer, no cross-origin isolation and no
Memory64**: `CairoClient`'s ring is a plain `ArrayBuffer` and frames are
transferred (`src/sim/README.md`, "with and without isolation"); those are the
browser prover's requirements, and D35 keeps the prover off phones. The COOP/COEP
headers `vite preview` and `vite dev` send are still correct on a phone (all
resources are same-origin) and are what lets `measureUserAgentSpecificMemory()`
work; without them only the demo's shared ring falls back to copies.

What the Worker *does* need is a **secure context**: it verifies the four Cairo
artifacts' SHA-256 with WebCrypto, which browsers expose only on `https://` and
`localhost`. `npm run preview -- --host` on `http://192.168.x.y:4173` is
therefore not enough — the page says so before creating the Worker
(`src/sim/simulationSupport.ts`) rather than failing on `crypto.subtle`. Two
ways that work:

* **Android over USB**: `chrome://inspect` → *Port forwarding* → `4173` to
  `localhost:4173`; the phone then opens `http://localhost:4173/`, which is a
  secure context. Chrome's remote DevTools also give the console and the
  performance panel on the phone.
* **Any phone**: put the preview behind HTTPS — a tunnel (`cloudflared tunnel
  --url http://localhost:4173`, `ngrok http 4173`) or the deployment itself.
  iOS Safari has no port-forwarding equivalent, so it needs this.

Other failures are reported in one sentence too: artifacts not staged
(`public/sim/` missing, with the `?sim=demo` alternative), an artifact that
fails its manifest hash, a browser that cannot allocate the ~450 MiB of wasm
memory, or one without module Workers (Safari < 15, old WebViews).

### Validating without a phone

`npm run test:e2e -- --project mobile` runs `e2e/mobile.spec.ts` in an emulated
Pixel 7 (landscape, touch emulation, SwiftShader): the controls appear on
`/?sim=demo`, three simultaneous touch points (stick, look drag, Fire) are
injected through CDP and read back from the model and the applied turn, the
overlay's Pause stops the scheduler, a portrait Pixel 7 gets the orientation
notice, a desktop viewport gets no controls, and without `public/sim/` the real
route explains what is missing — all with no page error. `e2e/bench.spec.ts`
runs the demo bench for 70 tics in the production bundle and checks the
labelled JSON (the Cairo variant runs when `public/sim/` is staged).
`test/touchInput.test.ts` pins the touch → ticcmd translation (bounds, return to
zero, multi-touch, the merge with the keyboard) and `test/cadenceBench.test.ts`
the bench's accounting. What none of this measures is a real phone's Worker
cadence: that is what the bench is for.

## What is rendered, and what is not yet

The current default Cairo route uses the numeric `sprite` and `frame` from the
same acknowledged tic, joined by actor id. All 49 source sprite families are
loaded, including missiles, blood, puff and barrel explosions. Only the validated
`player.mo` actor is excluded; FULLBRIGHT and SHADOW come from Cairo. Missing
resources stop rendering explicitly. Compact weapon 4 is the chainsaw, with no
current-ammo counter; the explicit `?sim=demo` route retains classic weapon ids.
The source sprite-name asset and its GPL-2.0-only license ship together; no client
state machine consumes the source state tables. See [the simulation notes](src/sim/README.md)
for the live v2 weapon/flash animation and the remaining approximate visual effects.
Legacy v1/demo snapshots keep their static weapon fallback. The historical demonstration measurements below are
not measurements of the real Cairo simulation.

**Rendered.** Sector floors and ceilings with per-sector light and moving
heights; walls (upper / lower / one-sided middle / masked two-sided middle)
with correct pegging, x/y offsets, fake contrast and the two-sided sky hack;
sky as a full-screen pass reproducing `ANGLETOSKYSHIFT`'s four repeats per
revolution; sprites as camera-facing billboards with `R_ProjectSprite`'s
rotation pick, mirrored lump names, patch offsets, full-bright frames and a
spectre stand-in; the palette flashes (`damageCount`/`bonusCount`) and the
invulnerability colormap; interpolation between two snapshots; a HUD with
health, armour, ammo, keys and a weapon sprite; a debug top-down automap.

**Proving.** F4 opens the proof queue on the game page; `/prove.html` is the
same pipeline without the renderer (the page `e2e/prove.spec.ts` drives). Until
P2.4 captures real input the journal records the neutral `ticcmd` each tic - the
wiring is what is exercised, not the content.

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

`npm test` — 301 vitest tests (10 skip themselves without the staged prover).

*Renderer and assets* (79): pegging (all four vanilla cases and the row offset),
wall quad generation (including that it follows moving heights), BSP clipping and
fan triangulation, dynamic sector detection, picture/flat decoding cross-checked
against `tools/wad`'s independent decoder *and* against the raw post structure of
the lump, `PLAYPAL`/`COLORMAP` parsing and the light ramp, sprite rotation
selection, the snapshot codec and ring, interpolation, the capability toggle, and
the stub sim on the real E1M1.

*Proving and persistence* (59):

| File | What it pins |
|---|---|
| `planner.test.ts` | fit/no-fit decisions from mocked `resources()` answers: the un-rounded row recovery and its fallback, the 80 % row target, the 1.5 M/2.3 M step ceilings, the `memory_id_to_big` cap, "impossible", and the model — one observation read through the origin, two fitted affinely, growth bounded |
| `chain.test.ts` | every rule of `segment::continues` and D14: genesis, `h_out → h_in`, tic continuity, `ABORT` refused, terminal status only on the last segment, counters that never go backwards, and the ten-felt decoder |
| `ticcmd.test.ts` | the 32-bit word over each field's full range, `quantize`'s demo-format rounding, 7-tics-per-felt packing for every length 0–15, and `TicLog` ≡ `packLog` |
| `store.test.ts` | IndexedDB round trips, segment+proof atomicity, reopen, `deleteRun`, and `.hellproof` export/import including the renaming collision, a corrupted payload caught by its checksum, and the quota projections |
| `pipeline.test.ts` | the pipeline against a fake prover: planning and shrinking, the step ceiling, a hung threaded prove killed and retried single-threaded, a segment that fails for good, the prover dropped between segments, resume after a simulated reload (exactly one segment re-proved), waiting mid-game vs cutting at the end, and the event stream |
| `wrapper.test.ts` | the submitter against a fake server: the per-segment probe and its fallback, skipping what the server holds, retries under the same `run_id`, `keepOffline` refused, gaps refused, failures recorded locally, and the status/batch mirror |
| `onchain.test.ts` (jsdom) | the on-chain leg on the real `B2-1_doom` fixture against a mocked node and wallet: the configuration reader (missing names listed, URL overrides, malformed values, the derived proof id), the cost screen's six rows and totals in STRK and fiat, "wait" and "keep offline" sending nothing, "submit" playing `begin → merkle → answers → fri → fri → register_member` in order and recording the fact, a wallet interruption between two transactions resumed from the saved D28 cut and `localStorage` echoes (the remaining phases re-priced, no trace round trip), a batch refused before paying, `?include=proof`, and `ProveSession.submit()` with no configuration touching no network |

*Mobile* (`touchInput.test.ts`, `cadenceBench.test.ts`, `simulationSupport.test.ts`): the touch → ticcmd
translation and the overlay's pointer wiring, the cadence bench's script, accounting, verdict and panel,
and the one-sentence Worker failure messages — see [Mobile](#mobile).

*Leaderboard* (`leaderboard.test.ts`, jsdom): every render function against fixtures (board rows,
ranking, empty state, pager edges, run detail with/without replay, an attempt vs a finished run,
Voyager links on sepolia vs the devnet hint), route parsing and `configFromLocation`'s
indexer/RPC-fallback choice, and the replay journal reconstruction (per-segment repacking, the
`.hellproof` container's magic/manifest/no-proof-bytes shape).

Tests that need the WAD skip themselves when `test/fixtures/generated/` or
`public/levels/e1m1.json` is absent, so a clone without the IWAD is still
green. `npm run fixtures` regenerates them.

`npm run test:e2e` — Playwright, against `vite preview` so the *production*
bundle and headers are exercised.

`render.spec.ts`: the COOP/COEP headers and `crossOriginIsolated`, a 2 s
frame-rate window with the geometry counts and the drop rate, a drawing-buffer
histogram (read inside the render loop, since the context has no
`preserveDrawingBuffer`), and the diagnostics panel. Screenshots land in
`e2e/artifacts/`.

`prove.spec.ts`: two `segment_stub10` segments proved end to end in headless
Chromium against the real wasm64 prover (single-threaded, K = 7), each proof
verified *in the browser*, the `h_in`/`h_out` chain checked, both persisted —
then the page is **reloaded** and both are still there, the chain re-checked from
IndexedDB, the run exported and every stored proof re-verified by a prover that
never saw it produced. It skips itself, rather than failing, when
`public/prover/` has not been staged.

`leaderboard.spec.ts`: the leaderboard page against a tiny in-process stub of `infra/indexer`'s
read API — the board renders and pages, the score/time tabs switch, a run detail view shows the
fact and a Voyager link, and the replay download fires with the right `.hellproof` filename.
Screenshots land in `e2e/artifacts/` alongside `render.spec.ts`'s.
