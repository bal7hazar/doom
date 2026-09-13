# `infra/wrapper` — container image for the wrapper service

Self-hosting the wrapper is decision **D7** (Docker, one 64 GB machine for the MVP) and action
**R8-A4** (anyone can run their own; the contract does not care where a valid root proof comes
from). The service itself is documented in [`prover/wrapper/README.md`](../../prover/wrapper/README.md).

```bash
docker compose -f infra/wrapper/docker-compose.yml up --build
curl -s localhost:8787/healthz
```

## What the image contains

| Path | From |
|---|---|
| `/opt/proving/bin/{leaf-prover,stwo_run_and_prove_recursive_tree,circuit-params}` | `starkware-libs/proving` @ `cd7bc5f` + `prover/wrapper/patches/` (D19: `leaf-prover --cairo_proof`), built in the image (R3-A1) |
| `/opt/proving/data/leaf_simple_bootloader_compiled.json` | the same commit |
| `/opt/hellproof/bin/{hellproof-wrapper,hellproof-leaf-verify}` | this repository |
| `/opt/hellproof/registry/{doom,doom_fold4_min}/registry.json` | `spikes/s4/registry` (S4, S4b) |
| `/opt/hellproof/params/leaf.json` | `prover/wasm/harness/params` — the parameters the browser proves with |
| `/opt/hellproof/wrapper.toml` | `wrapper.docker.toml`, overridable by bind mount or environment |

Three build stages keep the two slow ones cached separately: the monorepo build (~6 min), the
verifier front end (~1 min), the service (seconds).

## What you have to provide

**The programs you are willing to prove.** Compiled Scarb executables go in `infra/wrapper/programs/`
(bind-mounted read-only at `/opt/hellproof/programs`) and are listed in the `[[programs]]` entries
of the configuration. The service refuses to start when a listed executable is missing — that is
deliberate: a wrapper that accepts a program it cannot prove would fail at 32 GB instead of at
startup. Subprocess/from_proof also requires a valid measured `program_hash` for
every task. The default config pins the committed client `segment_stub10` artifact;
copy it to the programs directory. A path does not bind a submitted proof to a
task, because from_proof never reruns that executable. See the service README's
task-identity section before configuring another artifact.

**A real API key.** `WRAPPER_API_KEY` adds an admin key without editing the config file. The baked
`change-me` key is not usable in the open: bind the service to localhost (the compose file does)
and put a TLS terminator in front of it.

## Resources

Measured, not estimated (S4, S4b, and the P3.4 end-to-end run):

| | `doom` (default) | `doom_fold4_min` (production target) |
|---|---|---|
| peak RSS per circuit proof | 32.1–32.5 GB | 21.4–21.9 GB |
| leaf | ~24 s | 13.3 s |
| fold reduction | ~28 s | 13.5 s |
| circuit proofs in parallel on 64 GB | 1 | 2 |
| multiverifier hash | production's — deployed verifier constants hold | different: P4.0 must regenerate them |

`mem_limit: 64g` in the compose file is a floor, not a target: **a 32 GB host cannot run this
pipeline at all**. Swap is disabled on purpose (`memswap_limit` equal to `mem_limit`): a swapping
prover is an order of magnitude slower than a serial one, and the service already serialises
circuit proofs for exactly this reason.

Disk: ~550 kB per leaf proof and ~1.5 MB per root proof, plus the SQLite queue. The `queue` volume
is the resume log — losing it loses in-flight games.

## Status

**Not executed here.** The Docker daemon was not running on the development machine (the CLI is
installed, `docker info` fails), so the image has never been built. The Dockerfile and the compose
file are written and reviewed but unverified; the first person with a working daemon should run
`docker compose up --build` and fix whatever the build surfaces. Everything the image wraps *has*
been run natively on this machine: the pinned binaries, the verifier front end, the service, and
the full end-to-end pipeline.
