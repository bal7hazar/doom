# `submit-batch` — the on-chain submission CLI (P4.3)

**Does**: takes a wrapper batch, builds **five verifier transactions plus one `DoomRuns`
transaction** by default with the optimized P4.1 router (D28), **estimates them before signing anything**, and
plays them — resuming wherever the router's checkpoint says the last attempt stopped.

It is the same code as the browser: everything lives in
[`client/src/chain/`](../../client/src/chain/) and this package only adds a devnet `Signer`,
file-backed stores and a text rendering of the cost screen. That is the point of D20 — the
wrapper submits whole batches, and the wrapper is not a browser. Design, measurements and the
open questions: [`docs/design/submission.md`](../../docs/design/submission.md).

**Devnet only.** `assertLocalRpc` refuses any RPC host but `127.0.0.1` / `localhost`, and there
is no flag that lifts it. The only private key this package ever sees is a devnet one.

## Use

```bash
cd infra/submit && npm install          # node 22.22.2, starknet.js 10.8.0

# 1. a local devnet at the P4.2b prices, and an sncast account for the deploy script
starknet-devnet --seed 42 --port 5081 --accounts 3 --state-archive-capacity full \
  --initial-balance 100000000000000000000000 \
  --gas-price 1054411845 --gas-price-fri 92599658875965 \
  --data-gas-price 426840 --data-gas-price-fri 37485578886 \
  --l2-gas-price 347016 --l2-gas-price-fri 30475398907
sncast --accounts-file .work/accounts.json account import --url http://127.0.0.1:5081/rpc \
  --name devnet42 --type oz --address <addr> --private-key <key>

# 2. the router and DoomRuns (declare + deploy half of tools/e2e_10felt_drive.py)
scripts/devnet_setup.sh .work/accounts.json http://127.0.0.1:5081/rpc .work/deployment.json

# 3. the cost screen — simulates the whole ordered sequence, sends nothing
npm run submit-batch -- --rpc http://127.0.0.1:5081/rpc --account <addr>:<key> \
  --batch ../../cairo/doom_contracts/crates/recursion_outputs/fixtures/B2-1_doom \
  --router <router> --runs <doom_runs> --replay --dry-run

# 4. pin the season once (owner), then submit
npm run submit-batch -- … --setup-version --dry-run
npm run submit-batch -- … --send
```

`--help` lists every flag. The ones that matter:

| flag | what it changes |
|---|---|
| `--dry-run` (default) | stop after the cost screen; nothing is signed |
| `--send` | play the sequence, resuming from the router's checkpoint |
| `--proof-id <n>` | the router slot; a **fresh id restarts** a sequence, the same id resumes it |
| `--fri-split a,b` | explicit FRI cut, preserved exactly. Default `2` (5 verifier tx); use the original cut for a legacy resume |
| `--fewest-tx` | compatibility flag; five verifier transactions is already the default |
| `--replay` | publish the packed input logs (R10-A3) |
| `--single <run_id>` | `register_member` for one run instead of `submit_batch` for the batch |
| `--verifier-only` | stop once the fact is registered |
| `--setup-version` | owner-only: `add_version` + `set_genesis` from the batch's own values |
| `--no-live-price` | no CoinGecko call; the S5 snapshot is used and labelled as such |

## Default with the optimized P4.1 verifier (D28)

`planPhasesAuto` starts with cut `[2]`: `begin`, `merkle`, `answers`, `fri1` (layers 0–1),
`fri2` (layers 2–5). `submit_batch` or `register_member` is a separate sixth transaction;
`--verifier-only` sends five. Existing explicit cuts take precedence. If calldata exceeds
4,990 felts, automatic planning tries `[1,3]`, then `[1,2,4]`. If simulation finds an R7-A1
bound over the invoke cap, a fresh automatic CLI sequence can try `[1,2,4]`, then `[1,2,3,4]`,
**simulating every candidate again**. Replanning preserves the consumer, `--single`, and replay.

The P4.1 drive on local devnet 0.10.0 / Starknet 0.14.4 recorded the following on the `n4` root
([receipts](../../cairo/doom_contracts/results/p41_receipts.json)):

| tx | observed L2 gas | R7-A1 ×1.15 applied to that consumption |
|---|---:|---:|
| `begin` | 302 485 920 | 347 858 808 |
| `merkle` | 233 506 880 | 268 532 912 |
| `answers` | 466 418 880 | 536 381 712 |
| `fri1` | 294 609 600 | 338 801 040 |
| `fri2` | 243 213 200 | 279 695 180 |
| **total observed** | **1 540 234 480** | |

The worst observed transaction uses 38.55 % of the 1.21e9 cap; the largest derived ×1.15
amount is 44.33 %. The right column is a calculation from recorded consumption, **not a new
simulation or the historical transaction bounds** (the Python drive sent fixed 1.15e9 bounds).
That drive paid 46.93932136478046 STRK for the verifier at its recorded devnet prices; it does
not quote the next submission. The CLI still simulates the ordered sequence from the account
that will sign and retains R7-A1: L2 ×1.15, L1 data ×1.30, L1 gas 100,000 and prices ×2.
An over-cap bound blocks sending; historical receipts never replace the live estimate.

P4.1 uses new phase classes and requires a new router deployment
([recorded class hashes](../../cairo/doom_contracts/results/p41_receipts_deployment.json)).
An old P4.0 router retains its old gas cost; changing the client default does not upgrade it.
The finer cuts and cap checks remain available, with no claim that a fixed cut always fits
for every account or deployment.

### Resuming across the default change

The exact cut is saved **before the first send**, in a versioned metadata entry at reserved
phase index `-1` in the existing echo store, bound to `(router, caller, proof_id)`. The CLI
reloads it before planning; the shared browser sequence restores it before estimation. A saved
six-transaction `[1,3]` plan therefore remains six transactions. An explicitly conflicting cut
is rejected; gas fallback never changes a sequence that has started.

Older echo files have no cut metadata. Checkpoint tags and `Step` counts cannot distinguish all
FRI splits, so an active legacy sequence without an explicit cut is refused before sending.
Resume the former default with `--fri-split 1,3` (or the actual original cut if customized).
A missing local plan is never inferred from a shared FRI tag. Finished facts still skip the
verifier. No old echo or persisted game is rewritten by a refused resume.

## Historical P4.0 drive (devnet 0.10.0, Starknet 0.14.4, S5 prices)

`B2-1_doom`, 3 leaves / 2 games, replay on, 6-transaction plan, from the devnet's OZ account
class `0x05b4b537…e43564`. `results/devnet_B2-1_doom.json`:

| tx | estimated L2 gas | receipt | gap | % of the 1.21e9 cap | bound (×1.15) |
|---|---:|---:|---:|---:|---:|
| `begin` | 459 145 440 | 459 195 680 | −0.011 % | 37.9 | 528 017 256 |
| `merkle` | 390 766 400 | 390 816 640 | −0.013 % | 32.3 | 449 381 360 |
| `answers` | 861 288 640 | 861 338 880 | −0.006 % | 71.2 | 990 481 936 |
| `fri1` (layer 0) | 565 529 280 | 565 579 520 | −0.009 % | 46.7 | 650 358 672 |
| `fri2` (layers 1–2) | 1 021 952 320 | 1 022 002 560 | −0.005 % | 84.5 | 1 175 245 168 |
| `fri3` (layers 3–5) | 527 635 920 | 527 686 160 | −0.010 % | 43.6 | 606 781 308 |
| `submit_batch` | 16 164 080 | 16 334 320 | −1.042 % | 1.3 | 18 588 692 |
| **total** | **3 842 482 080** | **3 842 953 760** | **−0.012 %** | | **117.12 STRK paid** |

**C5 is met with three orders of magnitude to spare**: the worst per-transaction gap is 1.04 %
against a 20 % target, and the sequence total is off by 0.012 % — in the conservative direction
(the estimate is *below* the receipt, which is why the margin exists).

The fact the router registered, `0x53ae959a…8c3c40`, is the one `results/e2e_10felt_receipts.json`
recorded for this batch in P4.2b: the TypeScript emitter produces the same calldata as the Python
one, byte for byte, on every field (`test/calldata.test.ts`).

### Why the former P4.0 default used six verifier transactions

The P4.0 plan puts `fri1` at 90.3 % of the per-invoke cap. A *bound* is what the sequencer
checks, so ×1.15 asks for 1 257 075 488 — **3.9 % over the cap**, refused before execution
(`results/dryrun_B2-1_doom_5tx.json`). The 5-tx plan is only sendable with a margin below ×1.107,
which is not a margin. Hence the former default used the 6-transaction plan; `--fri-split 1,2,4` (7
verifier transactions, `results/dryrun_B2-1_doom_7tx.json`) keeps every *bound* under 90 % of the
cap — the full R7-A5 rule — for +0.3 % total gas.

| plan | verifier tx | worst consumption | worst bound | total L2 gas | |
|---|---:|---:|---:|---:|---|
| `--fri-split 2` (P4.0, 5 tx) | 5 | 90.3 % | **103.9 % — refused** | 3.81e9 | estimated only |
| `--fri-split 1,3` (former default, 6 tx) | 6 | 84.5 % | 97.1 % | 3.843e9 | sent, 117.12 STRK |
| `--fri-split 1,2,4` (7 tx) | 7 | 75.3 % | **86.5 %** | 3.854e9 | sent, 117.46 STRK |

Both historical sent plans register the same fact and land within 0.014 % of their estimate
(`results/devnet_B2-1_doom.json`, `results/devnet_B2-1_doom_7tx.json`).

## Tests

```bash
npm test                    # calldata vs the Python emitter, bounds, median, resume, selectors
SUBMIT_TEST_RPC=http://127.0.0.1:5081/rpc SUBMIT_TEST_ROUTER=0x… SUBMIT_TEST_RUNS=0x… \
  SUBMIT_TEST_ACCOUNT=0x…:0x… npm test    # + the devnet integration test
```

Without `SUBMIT_TEST_RPC` the integration test skips itself, so a clone with no devnet still has
a green `npm test`. The integration test expects an optimized P4.1 router. Offline tests
compare complete calldata against the independent Python emitter and `calldata_for` on the
`n4`, `B2-1_doom`, and `B2_doom` roots, and cover cap fallback and legacy resume refusal/restoration.
