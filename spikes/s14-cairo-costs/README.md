# S14 — Cairo arithmetic costs (Scarb 2.16.0)

Isolated executables and opaque CLI inputs; no engine entry point, protocol or budget is changed by this spike. Run:

```sh
python3 spikes/s14-cairo-costs/measure.py --out /tmp/hellproof-cairo-arithmetic/micro
```

Each number below is **gross for one complete executable call**, including argument decoding, output, and wrapper overhead. These are not net primitive costs. Separate targets use the same input/output shape within each comparison. No loop or constant operand is used. RC and BW count builtin instances, not AIR rows; fewer steps alone does not establish proof admissibility. Sizes include wrapper/data.

| Profile | Variant | Steps (min–max) | RC | BW | Words |
|---|---|---:|---:|---:|---:|
| dev | `mod_operator` | 43–44 | 5 | 0 | 133 |
| dev | `mod_nonzero` | 43–44 | 5 | 0 | 133 |
| dev | `mask_byte` | 40 | 1 | 1 | 125 |
| dev | `pair_operator` | 54–56 | 9 | 0 | 152 |
| dev | `pair_nonzero` | 44–45 | 5 | 0 | 133 |
| dev | `sparse_mask` | 40 | 1 | 1 | 125 |
| dev | `sparse_arithmetic` | 139–143 | 36 | 0 | 328 |
| dev | `sin_cos_reference` | 142–146 | 14–16 | 0 | 2421 |
| dev | `sin_cos_shared` | 109–111 | 10–12 | 0 | 2408 |
| proving | `mod_operator` | 39–40 | 5 | 0 | 89 |
| proving | `mod_nonzero` | 39–40 | 5 | 0 | 89 |
| proving | `mask_byte` | 35 | 1 | 1 | 79 |
| proving | `pair_operator` | 51–53 | 9 | 0 | 108 |
| proving | `pair_nonzero` | 40–41 | 5 | 0 | 89 |
| proving | `sparse_mask` | 35 | 1 | 1 | 79 |
| proving | `sparse_arithmetic` | 133–137 | 36 | 0 | 241 |
| proving | `sin_cos_reference` | 134–137 | 14–16 | 0 | 2403 |
| proving | `sin_cos_shared` | 104–106 | 10–12 | 0 | 2308 |

The seven `u128` variants each cover 13 opaque values, including zero, bit boundaries, `2^32-1`, `2^64-1`, and `u128::MAX`. The two trig variants each cover 19 opaque `u32` angles across every quadrant, low bits and `u32::MAX`: **258 executions in both profiles combined**. The Python oracle uses integer arithmetic for bit extraction and an independent trigonometric calculation for the unchanged sampled table. The production unit suite additionally compares the first/last angle of **all 8,192 buckets** against unchanged historical lookups.

## Findings

* `% 256` and literal `NonZero` `DivRem` compile to equal size/cost here. A production trial on the remaining three constant divisions/modulos in `bam` was completely neutral (8,689-word bench and all differential counters unchanged) and was discarded. S7's historical panic-path rule is not a universal current compiler result.
* When both outputs are required, explicitly use one `DivRem`: separate `/` and `%` in this `u128` case execute two divisions; proving saves 11–12 gross steps and four RC instances with the shared pair. `ticcmd::decode_offsets` and transport unpacking already do this.
* An unsigned mask can be cheaper: `x & 255` beats `x % 256` in this harness; a sparse `0x1040` mask beats the shown unrolled arithmetic extraction. The latter is one concrete arithmetic alternative, not a claim that all possible arithmetic forms are optimal or that masks always beat loops. BW AIR cost still needs complete-program measurement.
* Do not replace signed floor/truncating division with unsigned masking blindly. `fixed` already uses biased positive encoding and `NonZero` divmod for exact signed shifts/products, and guards `FixedDiv` saturation. Those semantics remain untouched.
* Share work at an algorithmic level first: `bam::sin_cos` now folds one quarter-wave index and reuses complementary magnitudes. No extra builtin, data, precision, state field or API is introduced.

## Production candidate and tradeoff

Existing varying-input differential bench (net of operand baseline): `sin_cos` **109 → 76 steps**, **12 → 8 RC**, composite turn+pair **121 → 86**, **14 → 10 RC**; all other rows unchanged. Harness **8,689 → 8,681 words**. Full program sizes differ from that harness:

| Profile | Executable | Before | After | Delta |
|---|---|---:|---:|---:|
| proving | `step_tic.executable.json` | 108342 | 108404 | +62 |
| proving | `run_segment.executable.json` | 106855 | 106917 | +62 |
| proving | `genesis.executable.json` | 46434 | 46496 | +62 |
| dev | `step_tic.executable.json` | 125963 | 125711 | -252 |
| dev | `run_segment.executable.json` | 125836 | 125584 | -252 |
| dev | `genesis.executable.json` | 50746 | 50877 | +131 |

The proving program grows **62 words**, about **914.5 Blake hash steps/segment** at the existing 14.75 estimate. Rough break-even is about 28 calls at the differential gain; this is not an end-to-end benchmark. D29 is still over 100,000. Root must decide against actual segmented game workloads, resource profiles, and bytecode gate. No budget/pin updates or proof runs are part of this change.

The generic APIs and `sine`/`cosine` implementations remain unchanged. For any `u32` angle, the reduced index is below 8,192; after half-wave folding it is below 4,096; the quarter-wave `q` is at most 2,047. Thus both table reads and `2047-q` are valid. Sine sign is the half-wave sign and cosine sign is its XOR with the mirror flag. All encoded outputs stay in the prior Fixed range.
