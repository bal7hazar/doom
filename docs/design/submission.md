# Submission — orchestrating the on-chain transactions and showing what they cost (P4.3)

> Design + measured implementation for **C5**/**C6** and RISKS.md **R7-A1**, **R7-A2**, **R7-A4**,
> **R7-A5**, on top of the P4.0 router ([`onchain-verifier.md`](onchain-verifier.md)) and the P4.2
> consumer ([`doomruns.md`](doomruns.md)). Code: [`client/src/chain/`](../../client/src/chain/)
> (the orchestrator, dependency-free), [`client/src/ui/costScreen.ts`](../../client/src/ui/costScreen.ts)
> (the screen), [`infra/submit/`](../../infra/submit/) (the CLI and the drives). Everything
> quantified below is **measured on starknet-devnet 0.10.0** (Starknet 0.14.4) against a router
> and a `DoomRuns` deployed for the occasion, on the real proved batches `B2-1_doom` and
> `B2_doom`. No transaction was sent to a public network.

## 0. Verdict

**D28 update (2026-09-13, `b00c90b`)**: the client and CLI now default to five verifier
transactions (`--fri-split 2`) with the optimized P4.1 classes, plus one separate consumer.
P4.1 receipts total 1,540,234,480 L2 gas; the worst consumption is 38.55 % of the invoke cap,
or 44.33 % after applying the unchanged ×1.15 margin. Those derived bounds are not new receipts.
Every actual deployment/account is still simulated before sending. The P4.0 measurements below
remain historical. A saved FRI cut is restored before estimating a resumed sequence; legacy
resumes without a known original cut fail before sending. The checkpoint tag alone is ambiguous.

| Target | Result |
|---|---|
| **C5** — estimate within 20 % of the receipt | **−0.012 %** on the sequence total, **−1.04 %** on the worst of the **16 transactions** sent across three plans and two batches |
| R7-A1 — simulate the ordered sequence, from the signing account, bounds ×1.15 / ×1.30 | done; the whole gap is a **constant 50 240 gas per transaction** (§4.2) |
| R7-A2 — STRK + timestamped fiat, per transaction, "> 2× the 24 h median" warning | done, with a documented limitation: a fresh client has no history and says so (§5) |
| R7-A5 — every transaction under 90 % of the invoke cap | D28 defaults to five with P4.1; worst derived ×1.15 bound 44.33 %. The older P4.0 deployment needs the finer cuts measured in §4.3 |
| **C6** — submit now / wait / keep offline | the three answers are the cost screen's three buttons (§6) |
| resumable by `proof_id` | verified by killing the process mid-sequence *and* deleting the local state (§3) |
| D20 — the wrapper submits whole batches | one `Signer` interface, same orchestrator in the browser and in `infra/submit` (§8) |
| R7-A4 — sponsored path | `Signer.sponsored`; the cost screen shows the full cost with the payer named (§7.3) |

The TypeScript calldata emitter is **byte-identical** to `tools/emit_calldata.py` on every field of
every transaction, and the facts the router registered from it — `0x53ae959a…8c3c40` for
`B2-1_doom`, `0x805cc03b…c307e` for `B2_doom` — are the ones P4.2b recorded for those batches.

## 1. Where it sits

```
browser                                           wrapper (D20)
  play → prove → GET /v1/batches/{id}               folds the batch, holds the root proof
        │                                                   │
        └──────────► client/src/chain ◄────────────────────┘
                     (plan, estimate, resume, submit)
                            │                 same code, two Signers
              ┌─────────────┴──────────────┐
   client/src/ui/costScreen.ts        infra/submit (CLI)
   Cartridge Controller session       devnet key, devnet only
                            │
                     StwoCircuitRouter ×5–7  →  fact
                     DoomRuns.submit_batch ×1 →  runs, leaderboard, replay
```

`client/src/chain/` has **no runtime dependency**. It builds calldata, speaks JSON-RPC over
`fetch`, and hands signing to a `Signer`. That is what lets the wrapper reuse it (D20) and keeps
starknet.js — which the browser needs only for signing, and the Controller brings its own — out of
the game bundle. The one non-arithmetic primitive, the entrypoint selector, is a small keccak in
[`selector.ts`](../../client/src/chain/selector.ts), checked against starknet.js in the tests.

## 2. The sequence

```
  1  router.begin    head + Merkle trees 0,1        4 625 calldata felts   → MerkleState (228 felts)
  2  router.merkle   Merkle trees 2,3               4 583                  → MerkleState
  3  router.answers  sampled + queried values       3 685                  → FriState (576 felts)
  4  router.fri      FRI layer 0                    2 232                  → FriState
  5  router.fri      FRI layers 1–2                 2 924                  → FriState
  6  router.fri      FRI layers 3–5                 1 348                  → fact registered
  7  runs.submit_batch  leaves + members + replay     111                  → runs recorded
```

**One phase per transaction is not a choice.** The heaviest phase consumes 84 % of the 1.21e9
per-invoke L2-gas cap, so two phases can never share an invoke. The transactions are therefore
*dependent*: each echoes the checkpoint state the previous one returned, because the router keeps
only `poseidon(state)` in storage — the trick that made the transport 61× cheaper than staging the
proof (R7-A6).

**The consumer is 0.4 % of the bill.** `submit_batch` for 3 leaves / 2 games with replay is
16.3 M gas against 3.83e9 for the fact. Which games ride along is a policy question, not a cost
one (§10.1).

**Who submits (D20, `doomruns.md` §12 q1).** `Member.player` is a field, not the caller, so one
account can submit for everybody. `prepareSubmission` builds `submit_batch` for the whole batch by
default and `register_member` for one run (`--single`); both need the leaves of the *whole* batch
anyway, which is why per-player submission costs ~5× more. Nothing in the orchestrator assumes
which one is used.

**`leaves[] → Member` (q2) is checked before paying.** `membersFromPlacements` groups the
wrapper's fold order by `run_id` and **refuses** a run whose leaf positions are not contiguous or
not in segment order. The contract would reject it as a chain break — after the five verifier
transactions were already paid for. `checkBatch` does the same for the cheap batch-level rules
(`ABORT`, version, genesis, chaining, final status), and `preflight` asks the contract itself the
two questions that change what should be paid for at all:

* `DoomRuns.batch_fact(version_id, leaves)` + `router.is_valid(fact)` — **is the fact already
  registered?** If it is, all verifier transactions are skipped and the submission costs
  0.08 STRK instead of 117 (measured: `B2_doom`, §4.1).
* `run_id_of` + `is_run_registered` per member — **is this run already recorded?** (R10-A1). It
  will be skipped on chain with `already registered` (D18); the player should be told before
  paying, not after.

## 3. Resume

The router's checkpoint is `{tag, poseidon(state)}` per `(caller, proof_id)`, and every write
emits `Step {caller, proof_id, tag, state_hash}`. That gives a complete recovery path with no
local state at all:

1. **`checkpoint(caller, proof_id)`** — `FREE` means start at `begin`; `DONE` means the fact is
   registered and only the consumer transaction is left.
2. **the number of `Step` events places the sequence.** The tag alone cannot: `begin` and `merkle`
   both leave `MERKLE`, and every FRI chunk but the last leaves `FRI`. The tag is then used as a
   *consistency check* against the plan — which catches the one dangerous case, resuming a proof
   id with a differently-cut plan (a 5-tx plan over a sequence started with 6 would send 4 600
   felts of calldata for the router to refuse on the state echo).
3. **the echo** comes from a local store when there is one (`localStorage` in the browser, a JSON
   file in the CLI) and otherwise from the retdata of the last `Step` transaction's trace. Both
   paths are kept because neither is guaranteed: a public RPC may not serve traces, and a wiped
   profile has no file.

Only the remaining suffix is re-estimated, so a resume is also cheaper to prepare than a fresh
start (3.5 s against 13 s on the measured batch).

Verified on devnet by killing the process between `answers` and `fri1`, deleting the echo file,
and re-running: the run resumed at phase 3 with the echo recovered from the trace, skipped the
three paid phases, and registered the same fact.

```
resuming: the router's checkpoint for proof id 3 is at tag 2; 3 phase(s) already paid for, echo from trace
  begin          already on chain, skipped
  merkle         already on chain, skipped
  answers        already on chain, skipped
  fri1           0x34ada764…  l2_gas   565,579,520  fee 17.2363 STRK
```

**`proof_id` is the resume key** and is per caller, so it cannot be squatted. A *fresh* id
restarts a sequence from scratch; the same id continues one. Allocating them is an open question
for the wrapper (§10.2).

## 4. Estimation (R7-A1)

### 4.1 Why the sequence is simulated as growing prefixes

S5 established the rule — simulate the **ordered array**, `SKIP_VALIDATE`, empty signature — on a
design whose three transactions had calldata independent of each other (the checkpoint was in
storage). Here the checkpoint is **echoed as calldata**, so transaction *i+1* cannot be built
until transaction *i* has run.

`simulateSequence` therefore simulates prefixes `[0]`, `[0,1]`, … reading each phase's returned
state out of the simulation's own trace, and the **last** simulation is the complete ordered array
R7-A1 asks for; the earlier ones exist only to discover the echoes. It costs ~3× the sequence in
node CPU (13 s for 7 transactions on this laptop's devnet) and nothing on chain.

### 4.2 Estimate against receipt — `B2-1_doom`, 6-transaction plan, replay on

| tx | estimated L2 gas | receipt | gap | estimated L1 data gas | receipt |
|---|---:|---:|---:|---:|---:|
| `begin` | 459 145 440 | 459 195 680 | −0.011 % | 384 | 320 |
| `merkle` | 390 766 400 | 390 816 640 | −0.013 % | 256 | 256 |
| `answers` | 861 288 640 | 861 338 880 | −0.006 % | 320 | 320 |
| `fri1` | 565 529 280 | 565 579 520 | −0.009 % | 256 | 256 |
| `fri2` | 1 021 952 320 | 1 022 002 560 | −0.005 % | 256 | 256 |
| `fri3` | 527 635 920 | 527 686 160 | −0.010 % | 416 | 384 |
| `submit_batch` | 16 164 080 | 16 334 320 | −1.042 % | 2 400 | 1 664 |
| **total** | **3 842 482 080** | **3 842 953 760** | **−0.012 %** | 4 288 | 3 456 |

117.10 STRK ≈ $3.42 at the devnet's (S5 mainnet) prices; 11.53 STRK at the 3 gFri floor.
`results/devnet_B2-1_doom.json`.

**The gap is not noise, it is a constant.** Every verifier transaction is under-estimated by
*exactly* 50 240 L2 gas, from `begin` (4 625 calldata felts, 459 M gas) to `fri3` (1 348 felts,
528 M gas). A constant that ignores both size and compute is the `__validate__` the estimate
skips: `SKIP_VALIDATE` is what makes an unsigned simulation possible, and its price is one
signature check per transaction. Three consequences:

* the total gap scales with the **number of transactions**, not with their size — 7 × 50 240 =
  351 680 gas, 0.009 % of a submission;
* the ×1.15 margin is not covering estimator noise (there is none); it is covering protocol
  version drift (3.0 % measured between 0.14.3 and 0.14.4, S5 §4) and this constant;
* **this constant is where the account class lands** (§7.4). A class whose `__validate__` is a
  WebAuthn check instead of an ECDSA one moves this number, once per transaction — and only this
  number.

`submit_batch` is the exception at −1.04 %: it is the only transaction whose behaviour depends on
state written by the transactions before it (the fact, the run ids), and it was simulated against
a state where those writes were themselves simulated. Still 19 points inside C5.

**L1 data gas is never under-estimated**: identical on the transactions that write almost
nothing, +8 to +20 % on the verifier phases, **+44 %** on `submit_batch`, the only one with a
dense state diff — the same structural cause S5 identified (the simulation bills 3 felts per
modified key, the receipt 2, plus 2 for the nonce). That is the right direction, and why the
margin here is ×1.30 rather than ×1.15: under-provisioning `l1_data_gas` **reverts** and burns the
fee, while over-provisioning costs nothing.

### 4.3 Historical P4.0 bounds, superseded by P4.1 for the current default

P4.0's 5-transaction plan puts `fri1` at 90.3 % of the invoke cap. **The sequencer checks the
bound, not the consumption** (S5 §6), so ×1.15 asks for 1 257 075 488 — 3.9 % *over* the cap, and
the transaction is refused before execution. The 5-tx plan is only sendable with a margin below
×1.107, which is not a margin.

| plan | verifier tx | worst consumption | worst **bound** | total L2 gas | verdict |
|---|---:|---:|---:|---:|---|
| `--fri-split 2` (P4.0) | 5 | 90.3 % | **103.9 %** | 3.81e9 | refused |
| `--fri-split 1,3` (former default) | 6 | 84.5 % | 97.1 % | 3.83e9 | sendable, above the 90 % rule |
| `--fri-split 1,2,4` | 7 | 75.3 % | **86.5 %** | 3.84e9 | fully R7-A5-compliant, +0.3 % |

At P4.0, `planPhasesAuto` defaulted to six transactions. Since D28 it defaults to five; the CLI
still **re-plans and re-estimates automatically** when a bound comes out over the cap, only for
a fresh automatic sequence. A started sequence requires its saved or explicit original FRI cut.
`results/dryrun_B2-1_doom_5tx.json`
and `_7tx.json` hold the three estimates; the seven-transaction plan was also **sent** on a fresh
deployment (`results/devnet_B2-1_doom_7tx.json`): 3 854 361 440 L2 gas, 117.46 STRK, the same
fact, total gap **−0.014 %**, and the same 50 240-gas constant on all eight transactions — which
is the cross-check that §4.2's explanation does not depend on the plan.

This is the practical cost of the QM31 lever still being open (`onchain-verifier.md` §10.2): when
the FRI walk gets cheaper, the 5-tx plan becomes bound-able again and the extra transaction goes
away.

### 4.4 Bounds

| resource | bound | why |
|---|---|---|
| `l2_gas` | simulated **×1.15** | the estimator's own error is a known constant (§4.2); the margin covers protocol drift |
| `l1_data_gas` | simulated **×1.30** | the simulation already over-estimates; under-provisioning reverts, over-provisioning costs nothing |
| `l1_gas` | fixed 100 000 | zero consumption in blob mode; the bound only guards a DA-mode change |
| `max_price_per_unit` | block price **×2** | a ceiling, not a payment: it must still hold at inclusion, five transactions after the cost screen |
| `tip` | 0 | no tip market observed (S5 §6) |

Never a global ×1.5: on this sequence it puts `answers` and every FRI chunk over the cap.

## 5. Prices, fiat, and the 24-hour median (R7-A2)

Gas prices come from the **latest block** of the node being submitted to. The fiat quote comes
from a `PriceSource` — CoinGecko behind a 5-minute cache by default, a Pragma oracle reader being
the obvious second implementation — and always carries the time it was **read**, which the screen
prints. Since v0.14.3 the L2 base price follows the STRK price, so the dollar figure is the
steadier of the two (S5 §5) and a stale quote is misleading in a way a stale gas price is not.
When the source is unreachable the S5 snapshot is used and labelled as such, and the *attempt* is
cached so a dead endpoint is not re-hit on every render.

`GasPriceMedian` samples the latest block's L2 gas price on every interaction, persists the
samples (`localStorage` / a JSON file), keeps a 24-hour window and compares the price about to be
paid against its median. Above **2×** it warns and offers to wait. Samples closer than a minute
collapse, so a screen that polls cannot drown its own window and make a spike look normal.

**Limitation, stated rather than hidden.** This history is *local*. A fresh client, a new profile
or cleared storage has none, and the first session cannot tell a spike from a normal day. The
verdict is then `unknown` and the screen says "no price history yet on this device, so we cannot
tell whether this is a spike" — a warning that *cannot* fire must not look like one that *did not*
fire. Three ways to close it, none free:

1. ship a seed history with the build — stale the day after release;
2. read a public RPC's block history at startup — ~2 880 blocks for 24 h, minutes of requests;
3. **have the wrapper publish a rolling median** with the batch — one number, already-trusted
   party, no extra request. Recommended.

## 6. The cost screen (C5, C6)

The question is not "sign 7 transactions?" but "is this worth it now?", so the screen is built
around C6's three answers:

* **Submit now — 117.10 STRK** — plays the sequence.
* **Wait, the price is high** — nothing is lost; the proof and the batch stay on disk and the same
  `proof_id` resumes later. This is the button the R7-A2 warning points at.
* **Keep offline** — never submit. The game stays local and provable.

It shows the total in STRK and fiat, a per-transaction table (L2 gas, STRK, fiat), the timestamped
quote with its source, what the same work would cost at the 3 gFri floor (the reference that makes
"wait" meaningful), and the median verdict. Entry points are named for humans — `fri2` is "FRI
walk, part 2", `submit_batch` is "Record the games".

During submission each step shows `queued` → `sending` → an explorer link (Voyager by chain id; a
devnet has none, so the hash is shown bare) or `already on chain` for a resumed phase. A failure
is not an error page: it says which steps are already paid for, that the verifier keeps a
checkpoint, and offers **Resume**, which re-enters the same code path.

The screen renders into an element the caller owns and injects its own stylesheet, so it drops
into the game shell without touching `index.html`.

## 7. Wallets

### 7.1 The `Signer` interface

```ts
interface Signer {
  readonly address: string;            // and the address estimation must use
  readonly kind: string;               // 'controller' | 'devnet' | …
  readonly sponsored?: boolean;        // R7-A4
  classHash?(): Promise<string | undefined>;
  execute(calls: Call[], options: { bounds: ResourceBounds; tip?: bigint }): Promise<{ transactionHash: string }>;
}
```

Bounds are an **argument**, never the wallet's business. The whole point of R7-A1 is that they
come from a simulation of the ordered sequence; a wallet that re-estimates with its own ×1.5 puts
the heaviest phases over the cap.

### 7.2 The Controller session

`@cartridge/controller` is loaded **dynamically** and typed structurally, so `client/src/chain/`
stays importable from Node, the CLI and the tests. The session carries exactly six entrypoints:

| contract | entrypoints |
|---|---|
| `StwoCircuitRouter` | `begin`, `merkle`, `answers`, `fri` |
| `DoomRuns` | `submit_batch`, `register_member` |

and nothing else — no transfer, no approval, no other contract. A session matters more here than
almost anywhere: a submission is 6–8 dependent transactions that must go out back to back, and
stopping on transaction four to ask for a manual signature leaves the checkpoint half-way through
a fact.

### 7.3 Sponsoring (R7-A4)

`Signer.sponsored` is a flag on the signer and a paymaster policy on the Controller side. When it
is set the screen still renders the full cost, with "This submission is sponsored: you will not be
charged. The cost is shown because somebody pays it." A sponsored submission is not a free one,
and a player who is never shown the cost cannot tell the difference between sponsorship ending and
the network getting expensive. The paymaster wiring itself is a placeholder: the flag, the display
and the interface are in place; which season sponsors what is a policy decision that has not been
made.

### 7.4 The account class (S5 §4.1, a prerequisite of R7-A1)

S5 measured **+19.1 %** L2 gas on the same transaction from two account classes, and could not say
where it came from: in `stage_proof` a slot was both a calldata felt *and* a storage write, so the
extrapolation to a calldata-heavy transaction ranged from +0.7 M to +445 M gas — the upper bound
breaking the cap.

The P4.0 router settles the calldata half. `probe_noop(payload)` reads calldata and writes
**nothing**, so the slope of gas against payload length is the class's cost of carrying calldata
(`infra/submit/scripts/account_class_probe.ts`, `results/account_class.json`):

| account class | empty envelope | per calldata felt | worst transaction (4 627 felts) |
|---|---:|---:|---:|
| devnet OZ `0x05b4b537…e43564` (= the S5 baseline class) | 825 600 | **6 563.5** | 30 369 214 (2.5 % of the cap) |

Since the whole calldata cost of the heaviest transaction is 30 M gas, a class 19 % worse at
carrying calldata would add 5.8 M — **0.5 % of one phase**, nowhere near the cap. The S5 surcharge
of +89 k *per slot* is more than the entire calldata cost of a slot here, so it cannot have been a
calldata effect: it was a per-storage-write one, and our router writes 3–5 slots per transaction
instead of 138–158. Together with §4.2 — the estimation gap being one `__validate__` per
transaction — this says the account class lands on a **per-transaction constant**, not on a
per-felt slope.

**What is still missing, and how to get it.** No Cartridge Controller class artifact exists
locally: `~/git/controller` is the JS/keychain SDK (the account contract lives in
`cartridge-gg/account_sdk`), and it pins class hashes only — the current stable is v1.0.9
`0x743c83c41ce99ad470aa308823f417b2141e02e04571f5c0004e743556e7faf`. To close R7-A1's last
prerequisite without a public-network transaction:

1. read the class from a public node — `starknet_getClass` at that hash, a read-only call;
2. declare it on the local devnet and deploy a Controller account with a known signer;
3. re-run `scripts/account_class_probe.ts --account <oz> --account <controller>` for the calldata
   slope, and `submit-batch --dry-run` from each account for the `__validate__` constant, which is
   the number that actually differs;
4. record both in `results/account_class.json` and re-check the §4.3 table, since a large
   `__validate__` eats into the same cap headroom as the FRI split.

Until then the orchestrator does the one thing it can do about it unconditionally: it estimates
**from the account that will sign** (`Signer.address`), never from a convenient one, and records
the class hash in every receipt file.

## 8. The CLI (D20)

`infra/submit/submit-batch` is the same orchestrator with a devnet `Signer`, file-backed stores
and a text rendering of the cost screen — because D20 has the wrapper submitting whole batches,
and the wrapper is not a browser. It reads either a saved `GET /v1/batches/{id}` response or a
fixture directory (`batch.json` + `packed_output.json` + `root.proof.gz`), which is the shape the
Cairo side already ships.

**Devnet only, structurally**: `assertLocalRpc` refuses any host but `127.0.0.1`/`localhost`, and
no flag lifts it. The only private key this package ever sees is a devnet one.

`--setup-version` pins the season from the batch's own values (`add_version` + `set_genesis`),
which is the auditability `doomruns.md` §3 asked P4.3 for: the triple `(program_hash, genesis,
registry)` the client displays is the triple the setup checked. What it does **not** yet do is
recompute the genesis from a `doom_game` run (§10.4).

## 9. Tests

`infra/submit/test/` — 73 unit tests plus one devnet integration test that skips itself when no
devnet answers (so a clone stays green):

* **calldata** — against `tools/emit_calldata.py` field by field on both proved batches, and
  against the calldata lengths in `results/e2e_10felt_receipts.json`; packing round-trips,
  including the escaped `0xFFFFFFFF` that was a real 2⁻³² collision bug;
* **batch** — the `submit_batch` calldata against `doomruns_model.py`'s (the independent Python
  model the Cairo tests are pinned against), the contiguity refusals, the pre-flight rules;
* **bounds and median** — the ×1.15/×1.30 rules, the three plans of §4.3 against their measured
  gas, the spike threshold, the empty-history verdict, the sample-collapsing;
* **resume** — against a mocked RPC: placing by `Step` count, the tag consistency check, the store
  vs trace preference, the refusals;
* **selectors** — against starknet.js's `getSelectorFromName` on every entrypoint used;
* **devnet** — the real sequence on a real router, asserting the recorded fact and C5.

## 10. Open questions

1. **Which games ride along.** `submit_batch` costs the same whether it records one game or ten,
   and the fact costs 230× more than the consumer either way, so the batch should carry every
   member it can. But a member costs the *player* nothing and the *submitter* everything, which
   only works while the wrapper submits (D20). If players submit their own runs, the fair split of
   a shared fact is unsolved — and `register_member` re-sends the whole batch's leaves, so it is
   not a split, it is five times the cost.
2. **`proof_id` allocation.** It is per caller and write-once, and it is the resume key. A browser
   can use a counter in `localStorage`; a wrapper submitting for many batches needs something
   collision-free across restarts (batch id truncated to a felt is the obvious candidate, at the
   cost of making resumption depend on the wrapper's own id space).
3. **Attempts (DEAD runs).** `checkBatch` accepts them — they are recorded but invisible on the
   boards, and they cost exactly as much as a finished run. The client should probably not submit
   them by default; nothing in the orchestrator decides this today.
4. **Genesis provenance.** `--setup-version` pins the genesis the batch carries. Auditing it means
   recomputing it from a `doom_game` run, which is a script this lane did not write
   (`doomruns.md` §3).
5. **Replay on or off.** +24 % consumer gas on a 25-segment batch, and the client cannot know
   before submitting whether the run will enter a leaderboard. Today: a flag, default off in the
   CLI, on for anything ranked.
6. **The median's missing history** (§5) — the wrapper publishing a rolling median is the cheapest
   fix and needs a wrapper endpoint.
7. **Public-network estimation.** Everything here is devnet. S5 showed devnet is a faithful and
   slightly conservative oracle (0.16 % against Sepolia), but the `__validate__` constant of §4.2
   is account-class-specific and the Sepolia check should be redone with the class that will
   actually sign.

## 11. Reproduce

```bash
cd infra/submit && npm install                     # node 22.22.2, starknet.js 10.8.0
npm test                                           # 73 tests, no devnet needed

starknet-devnet --seed 42 --port 5081 --accounts 3 --state-archive-capacity full \
  --initial-balance 100000000000000000000000 \
  --gas-price 1054411845 --gas-price-fri 92599658875965 \
  --data-gas-price 426840 --data-gas-price-fri 37485578886 \
  --l2-gas-price 347016 --l2-gas-price-fri 30475398907
sncast --accounts-file .work/accounts.json account import --url http://127.0.0.1:5081/rpc \
  --name devnet42 --type oz --address <addr> --private-key <key>
scripts/devnet_setup.sh .work/accounts.json http://127.0.0.1:5081/rpc .work/deployment.json

npm run submit-batch -- --rpc http://127.0.0.1:5081/rpc --account <addr>:<key> \
  --batch ../../cairo/doom_contracts/crates/recursion_outputs/fixtures/B2-1_doom \
  --router <router> --runs <runs> --replay --setup-version --dry-run    # the cost screen
npm run submit-batch -- … --send --out results/devnet_B2-1_doom.json    # and the receipts

scripts/account_class_probe.ts --rpc http://127.0.0.1:5081/rpc --router <router> \
  --account <addr> --out results/account_class.json
```
