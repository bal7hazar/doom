# S<n> — <short title>

> Copy this file to `docs/spikes/S<n>.md` and fill it in. One spike, one
> file. See PLAN.md §3 (Phase 0) for the list of spikes, their questions,
> and their GO criteria; ROADMAP.md §1 for lane/duration/dependencies.

## Question

<!--
The single unknown this spike resolves (reference the U* id from
CONTEXT.md §10 if there is one, e.g. "U1: cost per tic"). One or two
sentences: what do we not know, and why does it block later work?
-->

## Setup / versions

<!--
Exact, reproducible environment: OS + CPU + RAM; pinned commit/version of
every tool and repository involved (scarb, starknet-foundry, the `proving`
monorepo commit hash, cairo compiler version, browser + version for
in-browser spikes, ...). If it isn't pinned here, the result cannot be
reproduced later -- treat this section as the spike's lockfile.
-->

| Component | Version / commit |
|---|---|
| OS / CPU / RAM | |
| scarb | |
| starknet-foundry | |
| `proving` monorepo | |
| (other) | |

## Method

<!--
What was actually run, in enough detail that a different person could
redo it from this section alone: commands, inputs, what was measured and
how (tool + flag, e.g. `scarb execute --print-resource-usage`,
`/usr/bin/time -l`, `performance.measureUserAgentSpecificMemory`). Link to
the throwaway code under `spikes/s<n>/` if any.
-->

## Results

<!--
Raw, dated measurements. Prefer a table per PLAN.md's own metric for this
spike (steps/tic, RSS(2^20), tics/s, wrap time, cost delta %, ...). Include
enough repeats/variance to trust the numbers, not just a single run.
-->

| Metric | Target (PLAN.md) | Measured | Notes |
|---|---|---|---|
| | | | |

## Verdict

<!--
Exactly one of: GO / GO-with-fallback / NO-GO, plus the one-sentence
reason. If GO-with-fallback or NO-GO, name the fallback from PLAN.md's
"Repli si NO-GO" column and what triggers switching to it.
-->

**Verdict:** GO / GO-with-fallback / NO-GO

**Reason:**

**Fallback (if not GO):**

## Follow-ups

<!--
Concrete, owned next actions this spike's result creates -- new R<n>-A<m>
actions to add/adjust in RISKS.md, decisions to record at G0, upstream
issues to file, follow-up spikes.
-->

- [ ]

## Reproduce

<!--
The exact command(s) to redo this spike from a clean checkout, matching
the "Setup / versions" section above verbatim (copy-pasteable, no
placeholders left unfilled).
-->

```sh

```
