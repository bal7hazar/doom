// SPDX-License-Identifier: Apache-2.0
/**
 * The real `Executor`: `scarb execute` on the `doom_run` executables, exactly as
 * `cairo/doom/doom_run/bench/prove_segment.sh` steps 2 and 4 run them.
 *
 * ```sh
 * scarb --manifest-path cairo/Scarb.toml --profile proving execute -p doom_run \
 *   --executable-name run_segment --no-build --output none --arguments-file args.json \
 *   --print-program-output --print-resource-usage
 * ```
 *
 * What Scarb 2.16.0 actually prints, and what this file decodes (measured on the real
 * executables, `test/realExecutor.test.ts`):
 *
 * ```text
 *    Executing doom_run
 * Program output:
 * 6362                     <- one felt per line, DECIMAL, signed: a value above p/2 is
 * 5210715704298394693         printed negative ("-1490066978…"), so every token is reduced
 * …                           into the field before it becomes a `0x…` felt
 * Resources:
 * 	steps: 1,338,951         <- thousands separators: the count is read with them stripped
 * 	builtins:
 * 		range_check_builtin: 46,626
 * ```
 *
 * The argument file is the JSON array of `0x…` strings `prove_segment.sh` writes. `--output
 * none` keeps the trace and memory off the disk; Scarb still creates an empty numbered
 * `target/execute/doom_run/execution<N>/` per call, which is removed afterwards.
 *
 * Steps-only: `scarb execute` reports the step count and builtin counters, not the AIR sizing
 * the browser's `resources()` computes. Until a native `resources()` oracle is wired in (see
 * README, "what remains to be plugged in"), this executor returns `resources: null` and the cut
 * is bound by the D26 step ceiling alone. The proving profile must have been built once
 * (`scarb --profile proving build -p doom_run`); `--no-build` never rebuilds.
 */
import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readdirSync, rmdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

import { decodeSegmentOutput } from "../../../client/src/prove/program.js";
import { toFelt } from "../../../client/src/prove/felt.js";
import type { Felt } from "../../../client/src/prove/types.js";
import { checkState, stepArgs } from "../../../client/src/prove/doomPreparation.js";
import { segmentArgs, type Executor, type GenesisResult, type SegmentExecution, type StepResult } from "./executor.js";

const PRIME = (1n << 251n) + 17n * (1n << 192n) + 1n;
/** The Scarb release the executables are built and run with (`doom_run/README.md`). */
export const SCARB_VERSION = "2.16.0";
/** The three `doom_run` executables, as `scarb build` names them under `target/<profile>/`. */
export const EXECUTABLES = ["genesis", "step_tic", "run_segment"] as const;
export type ExecutableName = (typeof EXECUTABLES)[number];

export interface ScarbExecutorOptions {
  /** `cairo/Scarb.toml` of this checkout. */
  manifest: string;
  /** Scratch directory for argument files and logs. */
  workDir: string;
  /** The `scarb` binary; default `$HELLPROOF_SCARB`, then `scarb` on the PATH. */
  scarb?: string;
  profile?: string;
  env?: NodeJS.ProcessEnv;
  timeoutMs?: number;
}

/** The `scarb` binary the node runs: `HELLPROOF_SCARB` when set, else `scarb` on the PATH. */
export function scarbBinary(explicit?: string): string {
  return explicit ?? process.env["HELLPROOF_SCARB"] ?? "scarb";
}

/** Environment for a Scarb subprocess: the pinned release for asdf users, then the caller's. */
export function scarbEnv(extra?: NodeJS.ProcessEnv): NodeJS.ProcessEnv {
  return { ASDF_SCARB_VERSION: SCARB_VERSION, ...process.env, ...extra };
}

/** `scarb --version` of a binary, or `null` when it cannot be run. */
export function probeScarb(bin = scarbBinary()): { bin: string; version: string } | null {
  try {
    const r = spawnSync(bin, ["--version"], { encoding: "utf8", env: scarbEnv(), timeout: 30_000 });
    const m = r.status === 0 ? /scarb\s+(\S+)/.exec(r.stdout) : null;
    return m ? { bin, version: m[1]! } : null;
  } catch {
    return null;
  }
}

/** Paths of the three built executables for a manifest and profile. */
export function executablePaths(manifest: string, profile = "proving"): Record<ExecutableName, string> {
  const target = join(dirname(manifest), "target", profile);
  return {
    genesis: join(target, "genesis.executable.json"),
    step_tic: join(target, "step_tic.executable.json"),
    run_segment: join(target, "run_segment.executable.json"),
  };
}

/** The executables missing under `target/<profile>/`; empty when the profile has been built. */
export function missingExecutables(manifest: string, profile = "proving"): string[] {
  return Object.values(executablePaths(manifest, profile)).filter((p) => !existsSync(p));
}

/**
 * Parses `scarb execute` output: the felts after `Program output:` (decimal or `0x`, possibly
 * negative, reduced into the field) and the step count (thousands separators stripped).
 */
export function parseScarbOutput(text: string): { output: Felt[]; nSteps: number } {
  const lines = text.split(/\r?\n/);
  const output: Felt[] = [];
  let collecting = false;
  let nSteps = 0;
  for (const line of lines) {
    const steps = /^\s*steps:\s*([\d,_]+)/.exec(line);
    if (steps) nSteps = Number(steps[1]!.replace(/[,_]/g, ""));
    if (/Program output:/.test(line)) {
      collecting = true;
      continue;
    }
    if (!collecting) continue;
    const token = line.trim().split(/\s+/)[0];
    if (!token) {
      if (output.length) collecting = false;
      continue;
    }
    if (!/^-?(0x[0-9a-fA-F]+|\d+)$/.test(token)) {
      collecting = false;
      continue;
    }
    // Scarb prints signed representations; normalise into the field, as the script does.
    output.push(toFelt(((BigInt(token) % PRIME) + PRIME) % PRIME));
  }
  return { output, nSteps };
}

export class ScarbExecutor implements Executor {
  readonly id = "scarb";
  private calls = 0;

  constructor(private readonly options: ScarbExecutorOptions) {
    mkdirSync(options.workDir, { recursive: true });
  }

  /** The command line for one executable, with the argument file already written. */
  private argv(executable: ExecutableName, file: string): string[] {
    return [
      "--manifest-path",
      this.options.manifest,
      "--profile",
      this.options.profile ?? "proving",
      "execute",
      "-p",
      "doom_run",
      "--executable-name",
      executable,
      "--no-build",
      "--output",
      "none",
      "--arguments-file",
      file,
      "--print-program-output",
      "--print-resource-usage",
    ];
  }

  private async run(executable: ExecutableName, args: Felt[]): Promise<{ output: Felt[]; nSteps: number; ms: number }> {
    const file = join(this.options.workDir, `${executable}_${this.calls++}.args.json`);
    writeFileSync(file, JSON.stringify(args));
    const t0 = performance.now();
    const text = await new Promise<string>((resolve, reject) => {
      const child = spawn(scarbBinary(this.options.scarb), this.argv(executable, file), {
        env: scarbEnv(this.options.env),
        stdio: ["ignore", "pipe", "pipe"],
      });
      const chunks: Buffer[] = [];
      child.stdout.on("data", (c: Buffer) => chunks.push(c));
      child.stderr.on("data", (c: Buffer) => chunks.push(c));
      const timer = setTimeout(() => child.kill("SIGKILL"), this.options.timeoutMs ?? 1_800_000);
      child.on("error", reject);
      child.on("close", (code) => {
        clearTimeout(timer);
        const out = Buffer.concat(chunks).toString("utf8");
        if (code !== 0) reject(new Error(`scarb execute ${executable} exited ${code}: ${out.slice(-600)}`));
        else resolve(out);
      });
    });
    this.sweepExecutionDirs();
    const parsed = parseScarbOutput(text);
    if (parsed.output.length === 0 || parsed.nSteps === 0) {
      throw new Error(`scarb execute ${executable}: no program output or resources in:\n${text.slice(-600)}`);
    }
    return { ...parsed, ms: performance.now() - t0 };
  }

  /** Removes the empty `execution<N>/` directories `--output none` still leaves behind. */
  private sweepExecutionDirs(): void {
    const dir = join(dirname(this.options.manifest), "target", "execute", "doom_run");
    try {
      for (const entry of readdirSync(dir)) {
        if (!/^execution\d+$/.test(entry)) continue;
        try {
          rmdirSync(join(dir, entry)); // fails, harmlessly, when a trace was written there
        } catch {
          /* not empty: someone else's `scarb execute` output, left alone */
        }
      }
    } catch {
      /* no execute directory yet */
    }
  }

  async genesis(levelId: number): Promise<GenesisResult> {
    const { output } = await this.run("genesis", [toFelt(levelId)]);
    const count = Number(BigInt(output[0] ?? "-1"));
    if (count < 47 || output.length !== count + 2) {
      throw new Error(`invalid genesis envelope for level ${levelId}: ${output.length} felts, state length ${count}`);
    }
    const state = output.slice(1, -1);
    if (checkState(state) !== 0) throw new Error("genesis state is not at tic zero");
    return { state, hash: output[output.length - 1]! };
  }

  async step(state: readonly Felt[], words: readonly number[]): Promise<StepResult> {
    const { output } = await this.run("step_tic", stepArgs(state, words));
    const count = Number(BigInt(output[1] ?? "-1"));
    // `[status, state_len, state…, snapshot_len, snapshot…]`; a malformed state yields `(3, [], [])`.
    if (count < 47 || output.length < count + 3 || Number(BigInt(output[count + 2]!)) !== output.length - count - 3) {
      throw new Error(`invalid step_tic envelope: ${output.length} felts, status ${output[0]}, state length ${count}`);
    }
    return { status: Number(BigInt(output[0]!)), state: output.slice(2, count + 2) };
  }

  async segment(state: readonly Felt[], words: readonly number[], ticStart: number, maxTics: number): Promise<SegmentExecution> {
    const args = segmentArgs(state, words, ticStart, maxTics);
    const { output, nSteps, ms } = await this.run("run_segment", args);
    if (output.length !== 10) throw new Error(`run_segment returned ${output.length} felts, not the ten of D14`);
    return { args, outputFelts: output, output: decodeSegmentOutput(output), nSteps, resources: null, ms };
  }
}
