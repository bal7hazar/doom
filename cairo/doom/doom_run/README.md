# doom_run

Three real Scarb 2.16.0 executables expose the assembled game. The proved
program is `run_segment`; `genesis` and `step_tic` serve the simulation
Worker. All use `enable-gas = false`. Build with:

```sh
ASDF_SCARB_VERSION=2.16.0 scarb --manifest-path cairo/Scarb.toml --profile proving build -p doom_run
```

`proving` enables `unsafe-panic`, as required by D29. The bytecode budget
is **100,000 words**, with a hard ceiling of 120,000; the budget is not
increased when a build misses it. `bench/size.py` checks this and reports
dev/proving sizes. See S8 for the actual integrated measurements.

## Flat felt ABI

| Executable | Arguments | Output |
|---|---|---|
| `genesis` | `[level_u32]` (0 = E1M1) | `[state_len, state..., genesis_hash]` |
| `step_tic` | `[state_len, state..., words_len, words...]` | `[status, state_len, state..., snapshot_len, snapshot...]` |
| `run_segment` | `[state_len, state..., words_len, words..., tic_start, max_tics]` | `[1, h_in, h_out, tic_start, tic_end, status, inputs_commitment, kills, items, secrets]` |

States use `doom_game` schema 2; the segment-output version remains 1.
Status is 0 RUNNING, 1 DEAD, 2 EXIT, 3 ABORT. `step_tic` executes one word
per tic and stops at the first terminal result. An empty word list preserves
the state's terminal status. An invalid command returns status 3 with the
unchanged state/snapshot; malformed state content returns `(3, [], [])`.
Unknown genesis level returns `([], 0)`.

`run_segment` computes `h_in` from the state it actually uses. The client
must provide **the serialized start state**, not only its hash. `tic_start`
must match the state clock; mismatch or malformed state returns a zero-tic
ABORT with `h_in = h_out = Poseidon(supplied_state_felts)`. A segment consumes
at most `min(words_len, max_tics, MAX_TIC - tic_start)`, stopping on terminal
status. The consumed log, including an aborting command, is committed under
D13. The ten public felts are unchanged from the client's existing D14 decoder.

`client/codec.mjs` supplies dependency-free encoders/decoders, with canonical
felt and length checks; test with `node --test
cairo/doom/doom_run/client/codec.test.mjs`. `client/src/prove/program.ts`
still requires its planned real-game adapter: its current request only
carries `hIn`. That integration must retain/recover serialized states at
the planner's actual boundaries. Render snapshot offsets are documented in
`doom_game/src/render.cairo` and are not the existing SAB layout verbatim.

## Native simulation and leaf proof

The actual Scarb 2.16.0 executable loads and executes through
`prover/sim`'s pinned cairo-lang 2.19.4/cairo-vm 3.2.0 runner. This is a
measured ABI result, not a general cross-version promise. The probe
`bench/sim_probe.rs` uses the exact `SimProgram`, canonical 32-byte LE felt
buffers and a cached executable. It accepts one line of hex felts per call
and returns `steps output_felts...`; on the integrated four-tic segment the
native runner uses 693,422 steps versus 693,425 for Scarb standalone, with
identical output felts.

`bench/prove_segment.sh /tmp/doom-leaf fight 4` builds the proving artifact,
executes genesis and a real walking segment, records resources, then proves
and verifies via the leaf simple bootloader using Blake program hashing, matching the current browser prover.
`PROGRAM_HASH_FUNCTION=poseidon` is a comparison mode: D4/D29 historically
prescribed Poseidon, but the actual WASM core already uses Blake. S8 records
the substantial AIR-component difference.
It verifies the pinned `proving@cd7bc5f` clones, holds the shared proof lock,
records its PID, and only releases its own lock. Proofs have a process-group
timeout (`PROOF_TIMEOUT`); failures never count as verified proofs.
`SKIP_PROOF=1` stops after resource collection. Resource fitting, not just
step count, is required before browser proof scheduling (D26).

Raw proof JSON and large execution traces stay in the chosen output/scratch
directory. S8 records the checked output preimage, resources, wall time,
RSS and result; the proof's public preimage is exactly
`[program_hash, ten_segment_output_felts...]`.
