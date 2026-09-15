// SPDX-License-Identifier: Apache-2.0
/**
 * The real `Executor`: `scarb execute` on the `doom_run` executables, exactly as
 * `cairo/doom/doom_run/bench/prove_segment.sh` steps 2 and 4 run them.
 *
 * ```sh
 * scarb --manifest-path cairo/Scarb.toml --profile proving execute -p doom_run \
 *   --executable-name run_segment --no-build --arguments-file args.json \
 *   --print-program-output --print-resource-usage
 * ```
 *
 * Steps-only: `scarb execute` reports the step count and builtin counters, not the AIR sizing
 * the browser's `resources()` computes. Until a native `resources()` oracle is wired in (see
 * README, "what remains to be plugged in"), this executor returns `resources: null` and the cut
 * is bound by the D26 step ceiling alone. The proving profile must have been built once
 * (`scarb --profile proving build -p doom_run`); `--no-build` never rebuilds.
 */
import { spawn } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { decodeSegmentOutput } from "../../../client/src/prove/program.js";
import { toFelt } from "../../../client/src/prove/felt.js";
import type { Felt } from "../../../client/src/prove/types.js";
import { stepArgs } from "../../../client/src/prove/doomPreparation.js";
import { segmentArgs, type Executor, type GenesisResult, type SegmentExecution, type StepResult } from "./executor.js";

const PRIME = (1n << 251n) + 17n * (1n << 192n) + 1n;

export interface ScarbExecutorOptions {
  /** `cairo/Scarb.toml` of this checkout. */
  manifest: string;
  /** Scratch directory for argument files and logs. */
  workDir: string;
  scarb?: string;
  profile?: string;
  env?: NodeJS.ProcessEnv;
  timeoutMs?: number;
}

/** Parses `scarb execute` output: the felts after `Program output:` and the step count. */
export function parseScarbOutput(text: string): { output: Felt[]; nSteps: number } {
  const lines = text.split(/\r?\n/);
  const output: Felt[] = [];
  let collecting = false;
  let nSteps = 0;
  for (const line of lines) {
    const steps = /^\s*steps:\s*(\d+)/.exec(line);
    if (steps) nSteps = Number(steps[1]);
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

  private async run(executable: "genesis" | "step_tic" | "run_segment", args: Felt[]): Promise<{ output: Felt[]; nSteps: number; ms: number }> {
    const file = join(this.options.workDir, `${executable}_${this.calls++}.args.json`);
    writeFileSync(file, JSON.stringify(args));
    const argv = [
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
      "--arguments-file",
      file,
      "--print-program-output",
      "--print-resource-usage",
    ];
    const t0 = performance.now();
    const text = await new Promise<string>((resolve, reject) => {
      const child = spawn(this.options.scarb ?? "scarb", argv, {
        env: { ASDF_SCARB_VERSION: "2.16.0", ...process.env, ...this.options.env },
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
    return { ...parseScarbOutput(text), ms: performance.now() - t0 };
  }

  async genesis(levelId: number): Promise<GenesisResult> {
    const { output } = await this.run("genesis", [toFelt(levelId)]);
    const count = Number(BigInt(output[0] ?? "-1"));
    if (count < 47 || output.length !== count + 2) throw new Error("invalid genesis envelope");
    return { state: output.slice(1, -1), hash: output[output.length - 1]! };
  }

  async step(state: readonly Felt[], words: readonly number[]): Promise<StepResult> {
    const { output } = await this.run("step_tic", stepArgs(state, words));
    const count = Number(BigInt(output[1] ?? "-1"));
    if (count < 47 || output.length < count + 3) throw new Error("invalid step_tic envelope");
    return { status: Number(BigInt(output[0]!)), state: output.slice(2, count + 2) };
  }

  async segment(state: readonly Felt[], words: readonly number[], ticStart: number, maxTics: number): Promise<SegmentExecution> {
    const args = segmentArgs(state, words, ticStart, maxTics);
    const { output, nSteps, ms } = await this.run("run_segment", args);
    const outputFelts = output.slice(0, 10);
    return { args, outputFelts, output: decodeSegmentOutput(outputFelts), nSteps, resources: null, ms };
  }
}
