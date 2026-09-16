// SPDX-License-Identifier: Apache-2.0
/**
 * `Prover` — one segment in, one leaf proof out.
 *
 * The real implementation (`SubprocessProver`) runs `stwo-run-and-prove` the way
 * `cairo/doom/doom_run/bench/prove_segment.sh` step 6 does: the segment is a task of the leaf
 * simple bootloader (`program_hash_function: blake`, D31), proved with the leaf parameters,
 * under the shared proof lock (`mkdir $SCRATCH/.proof-lock`, owner pid recorded, released only
 * by its owner) and a process-group timeout — a timeout is a failure, never a proof.
 *
 * `FakeProver` is the test double: instant, deterministic, with programmable failures so the
 * resume path (proved segments are never re-proved) can be exercised.
 */
import { spawn } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, rmdirSync, unlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { normalizeFelt } from "../../../client/src/prove/felt.js";
import type { Felt } from "../../../client/src/prove/types.js";

export interface ProveRequest {
  index: number;
  /** `run_segment` arguments, as executed. */
  args: Felt[];
  /** The ten felts the execution produced; the proof's preimage must reproduce them. */
  expectedOutput: Felt[];
  /** Per-job scratch directory; the prover writes `segment-<index>/` under it. */
  workDir: string;
}

/** A leaf proof in the wrapper's wire format (`SegmentSubmission.proof`). */
export interface ProofArtifact {
  index: number;
  format: "bincode_b64" | "cairo_serde_felts";
  /** Base64 of the bincode `CairoProof`, for `bincode_b64`. */
  data?: string;
  /** The felt stream, for `cairo_serde_felts`. */
  felts?: string[];
  /** `[program_hash, out_0 … out_9]` as the bootloader dumped it. */
  outputPreimage: Felt[];
  programHash: Felt;
  proveMs: number;
  /** Where the raw proof landed on disk, when the prover kept it. */
  proofPath?: string;
}

export interface ProveOptions {
  timeoutMs?: number;
  signal?: AbortSignal;
}

export interface Prover {
  readonly id: string;
  prove(request: ProveRequest, options?: ProveOptions): Promise<ProofArtifact>;
}

export class ProofTimeoutError extends Error {
  constructor(readonly index: number, readonly timeoutMs: number) {
    super(`segment ${index}: the proof exceeded its ${timeoutMs} ms deadline; the process group was killed`);
    this.name = "ProofTimeoutError";
  }
}

// --- the shared proof lock -------------------------------------------------------------

export interface LockOptions {
  timeoutMs?: number;
  pollMs?: number;
  /** Reclaim a lock whose recorded owner pid is gone. Off by default, as in the shell script. */
  reclaimStale?: boolean;
}

/**
 * `mkdir` as a mutex, compatible with `prove_segment.sh`'s `$SCRATCH/.proof-lock`: the directory
 * is the lock, `owner.pid` names the holder, and only the holder removes it.
 */
export class ProofLock {
  private held = false;

  constructor(readonly dir: string) {}

  get ownerFile(): string {
    return join(this.dir, "owner.pid");
  }

  async acquire(options: LockOptions = {}): Promise<void> {
    const deadline = Date.now() + (options.timeoutMs ?? 600_000);
    const poll = options.pollMs ?? 10_000;
    for (;;) {
      try {
        mkdirSync(this.dir);
        writeFileSync(this.ownerFile, `${process.pid}\n`);
        this.held = true;
        return;
      } catch (e) {
        if ((e as NodeJS.ErrnoException).code !== "EEXIST") throw e;
      }
      if (options.reclaimStale && this.ownerGone()) {
        try {
          unlinkSync(this.ownerFile);
        } catch {
          /* already gone */
        }
        try {
          rmdirSync(this.dir);
        } catch {
          /* somebody else reclaimed it */
        }
        continue;
      }
      if (Date.now() >= deadline) {
        throw new Error(`proof lock ${this.dir} busy (owner pid ${this.ownerPid() ?? "unknown"}); owner left untouched`);
      }
      await new Promise((r) => setTimeout(r, Math.min(poll, Math.max(1, deadline - Date.now()))));
    }
  }

  ownerPid(): number | null {
    try {
      const pid = Number(readFileSync(this.ownerFile, "utf8").trim());
      return Number.isInteger(pid) && pid > 0 ? pid : null;
    } catch {
      return null;
    }
  }

  private ownerGone(): boolean {
    const pid = this.ownerPid();
    if (pid === null) return existsSync(this.dir) && !existsSync(this.ownerFile);
    try {
      process.kill(pid, 0);
      return false;
    } catch (e) {
      return (e as NodeJS.ErrnoException).code === "ESRCH";
    }
  }

  /** Releases only a lock this process holds; a foreign lock is left untouched. */
  release(): void {
    if (!this.held) return;
    this.held = false;
    if (this.ownerPid() !== process.pid) return;
    try {
      unlinkSync(this.ownerFile);
      rmdirSync(this.dir);
    } catch {
      /* removed by someone else */
    }
  }
}

// --- subprocess with a process-group timeout -----------------------------------------

export interface SpawnResult {
  exitCode: number | null;
  timedOut: boolean;
  wallMs: number;
}

/**
 * Runs a command in its own process group, logging to `logPath`, and kills the whole group on
 * timeout (rayon threads included) — the Python supervisor of `prove_segment.sh`, in Node.
 */
export function spawnWithTimeout(
  command: string,
  args: string[],
  options: { timeoutMs: number; logPath: string; cwd?: string; env?: NodeJS.ProcessEnv; signal?: AbortSignal },
): Promise<SpawnResult> {
  return new Promise((resolve, reject) => {
    const started = performance.now();
    const chunks: Buffer[] = [];
    const child = spawn(command, args, {
      cwd: options.cwd,
      env: { ...process.env, ...options.env },
      detached: true,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let timedOut = false;
    const killGroup = (): void => {
      if (child.pid === undefined) return;
      try {
        process.kill(-child.pid, "SIGKILL");
      } catch {
        child.kill("SIGKILL");
      }
    };
    const timer = setTimeout(() => {
      timedOut = true;
      killGroup();
    }, options.timeoutMs);
    options.signal?.addEventListener("abort", killGroup, { once: true });
    child.stdout.on("data", (c: Buffer) => chunks.push(c));
    child.stderr.on("data", (c: Buffer) => chunks.push(c));
    child.on("error", (e) => {
      clearTimeout(timer);
      reject(e);
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      options.signal?.removeEventListener("abort", killGroup);
      const log = Buffer.concat(chunks).toString("utf8") + (timedOut ? "\nTIMEOUT: proof process group killed\n" : "");
      writeFileSync(options.logPath, log);
      resolve({ exitCode: code, timedOut, wallMs: performance.now() - started });
    });
  });
}

// --- the real prover -----------------------------------------------------------------

export interface SubprocessProverOptions {
  /** `stwo-run-and-prove` release binary (proving monorepo @ cd7bc5f). */
  bin: string;
  /** `leaf_simple_bootloader_compiled.json`. */
  bootloader: string;
  /** `prover/wasm/harness/params/leaf.json`. */
  params: string;
  /** `cairo/target/proving/run_segment.executable.json`. */
  executable: string;
  /** The shared lock directory, `$SCRATCH/.proof-lock`. */
  lockDir: string;
  hashFunction?: "blake" | "poseidon";
  /**
   * `bincode` is what the wrapper folds (`bincode_b64`): the extended `CairoProof`, which
   * `stwo-run-and-prove` writes with `--proof-format extended-binary` (bzip2-wrapped bincode,
   * accepted as is by the wrapper and `leaf-verify`; there is no `bincode` value in the binary's
   * `ProofFormat`, and `binary` drops the `aux` the leaf circuit needs). `cairo-serde` is the felt
   * stream.
   */
  proofFormat?: "bincode" | "cairo-serde";
  timeoutMs?: number;
  lockTimeoutMs?: number;
  lockPollMs?: number;
  /** `RAYON_NUM_THREADS` for the prover; the script defaults to 2. */
  threads?: number;
  env?: NodeJS.ProcessEnv;
  /** Arguments placed before the prover's own (a wrapper script, `/usr/bin/time -l`, …). */
  prefixArgs?: string[];
  extraArgs?: string[];
}

/** The `--proof-format` value of `stwo-run-and-prove` (`cairo_air::utils::ProofFormat`) for ours. */
export function proofFormatFlag(format: "bincode" | "cairo-serde"): "extended-binary" | "cairo-serde" {
  return format === "bincode" ? "extended-binary" : "cairo-serde";
}

export class SubprocessProver implements Prover {
  readonly id = "stwo-run-and-prove";
  readonly lock: ProofLock;

  constructor(private readonly options: SubprocessProverOptions) {
    this.lock = new ProofLock(options.lockDir);
  }

  async prove(request: ProveRequest, options: ProveOptions = {}): Promise<ProofArtifact> {
    const o = this.options;
    const dir = join(request.workDir, `segment-${request.index}`);
    mkdirSync(dir, { recursive: true });
    const argsFile = join(dir, "args.json");
    const inputFile = join(dir, "bl_input.json");
    const preimageFile = join(dir, "output_preimage.json");
    const format = o.proofFormat ?? "bincode";
    const proofFile = join(dir, format === "bincode" ? "proof.bin" : "proof.cairo_serde.json");
    const cliFormat = proofFormatFlag(format);
    const programOutput = join(dir, "program_output.json");
    writeFileSync(argsFile, JSON.stringify(request.args));
    writeFileSync(
      inputFile,
      JSON.stringify(
        {
          tasks: [
            {
              type: "Cairo1Executable",
              path: o.executable,
              program_hash_function: o.hashFunction ?? "blake",
              user_args_file: argsFile,
            },
          ],
          fact_topologies_path: null,
          single_page: true,
          output_preimage_dump_path: preimageFile,
        },
        null,
        2,
      ),
    );

    const timeoutMs = options.timeoutMs ?? o.timeoutMs ?? 600_000;
    await this.lock.acquire({ timeoutMs: o.lockTimeoutMs ?? 600_000, pollMs: o.lockPollMs ?? 10_000 });
    let result: SpawnResult;
    try {
      result = await spawnWithTimeout(
        o.bin,
        [
          ...(o.prefixArgs ?? []),
          "--program", o.bootloader,
          "--program_input", inputFile,
          "--prover_params_json", o.params,
          "--proof_path", proofFile,
          "--proof-format", cliFormat,
          "--program_output", programOutput,
          "--verify",
          ...(o.extraArgs ?? []),
        ],
        {
          timeoutMs,
          logPath: join(dir, "prove.log"),
          env: { RAYON_NUM_THREADS: String(o.threads ?? 2), ...o.env },
          ...(options.signal ? { signal: options.signal } : {}),
        },
      );
    } finally {
      this.lock.release();
    }
    writeFileSync(join(dir, "proof_metrics.json"), JSON.stringify({ ...result, timeout_ms: timeoutMs }, null, 2));
    if (result.timedOut) throw new ProofTimeoutError(request.index, timeoutMs);
    if (result.exitCode !== 0) {
      throw new Error(`segment ${request.index}: ${o.bin} exited ${result.exitCode} (see ${join(dir, "prove.log")})`);
    }
    if (!existsSync(preimageFile) || !existsSync(proofFile)) {
      throw new Error(`segment ${request.index}: the prover left no preimage or proof in ${dir}`);
    }
    const outputPreimage = (JSON.parse(readFileSync(preimageFile, "utf8")) as (string | number)[]).map((v) =>
      normalizeFelt(String(v)),
    );
    const artifact: ProofArtifact = {
      index: request.index,
      format: format === "bincode" ? "bincode_b64" : "cairo_serde_felts",
      outputPreimage,
      programHash: outputPreimage[0] ?? "0x0",
      proveMs: result.wallMs,
      proofPath: proofFile,
    };
    if (format === "bincode") artifact.data = readFileSync(proofFile).toString("base64");
    else artifact.felts = (JSON.parse(readFileSync(proofFile, "utf8")) as (string | number)[]).map((v) => normalizeFelt(String(v)));
    return artifact;
  }
}

// --- the test double -----------------------------------------------------------------

export interface FakeProverOptions {
  programHash?: Felt;
  /** Indices that fail once each (the next attempt succeeds). */
  failOnce?: number[];
  /** Indices that always fail. */
  failAlways?: number[];
  /** Milliseconds each proof takes. */
  delayMs?: number;
  /** Return a preimage that does not match the expected output (a lying prover). */
  corrupt?: number[];
}

export class FakeProver implements Prover {
  readonly id = "fake";
  readonly calls: number[] = [];
  private readonly failOnce: Set<number>;

  constructor(private readonly options: FakeProverOptions = {}) {
    this.failOnce = new Set(options.failOnce ?? []);
  }

  async prove(request: ProveRequest, options: ProveOptions = {}): Promise<ProofArtifact> {
    this.calls.push(request.index);
    if (this.options.delayMs) {
      await new Promise((r) => setTimeout(r, this.options.delayMs));
      options.signal?.throwIfAborted();
    }
    if (this.failOnce.delete(request.index)) throw new Error(`segment ${request.index}: fake prover failed once`);
    if (this.options.failAlways?.includes(request.index)) throw new Error(`segment ${request.index}: fake prover always fails`);
    const programHash = this.options.programHash ?? "0x5eed";
    const output = this.options.corrupt?.includes(request.index)
      ? request.expectedOutput.map((f, i) => (i === 2 ? "0xbad" : f))
      : request.expectedOutput;
    const payload = `fake-proof:${request.index}:${request.args.join(",")}`;
    return {
      index: request.index,
      format: "bincode_b64",
      data: Buffer.from(payload).toString("base64"),
      outputPreimage: [programHash, ...output],
      programHash,
      proveMs: this.options.delayMs ?? 0,
    };
  }
}
