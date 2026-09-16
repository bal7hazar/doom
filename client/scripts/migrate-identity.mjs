#!/usr/bin/env node
// SPDX-FileCopyrightText: 2026 Bal7hazar
// SPDX-License-Identifier: Apache-2.0
// Migrate the pinned Doom proof identity to the executables of a Cairo target
// directory, reproducibly and without guessing anything (Node >= 22, no
// dependency). It computes the SHA-256 of genesis/step_tic/run_segment, takes
// the Blake task hash from a real measurement (`--core` runs
// prover/wrapper/scripts/measure_task_hash.mjs; `--program-hash` accepts one
// measured elsewhere), rewrites client/src/prove/doomArtifacts.ts, freezes the
// retired identity in client/test/fixtures/legacyDoomIdentity.ts and refreshes
// the pin table of client/src/prove/README.md. `--check` only verifies.
//
//   node client/scripts/migrate-identity.mjs --check [--target cairo/target]
//   node client/scripts/migrate-identity.mjs --build --core prover/wasm/pkg/dist/core.js
//   node client/scripts/migrate-identity.mjs --program-hash 0x... [--target cairo/target]
import { createHash } from "node:crypto";
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, relative, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";

export const ADAPTER = "doom_run/state2/d14v1";
export const PIN_KEYS = ["revision", "genesis", "step", "segment", "wasm", "programHash", "snippet", "glue"];
export const EXECUTABLES = { genesis: "genesis.executable.json", step: "step_tic.executable.json", segment: "run_segment.executable.json" };
export const SIM_FILES = { wasm: "hellproof_sim_bg.wasm", glue: "hellproof_sim.js", snippet: "snippets/hellproof-sim-c1c84871eb3c9493/inline0.js" };
export const FILES = {
  pins: "client/src/prove/doomArtifacts.ts",
  legacy: "client/test/fixtures/legacyDoomIdentity.ts",
  readme: "client/src/prove/README.md",
  manifest: "client/public/sim/manifest.json",
  measure: "prover/wrapper/scripts/measure_task_hash.mjs",
};
const README_BEGIN = "<!-- identity:begin -->", README_END = "<!-- identity:end -->";
const STARK_PRIME = (1n << 251n) + 17n * (1n << 192n) + 1n;
const HEX64 = /^[0-9a-f]{64}$/;

export class MigrationError extends Error {
  constructor(message, code = 1) { super(message); this.code = code; }
}

export const USAGE = `usage: node client/scripts/migrate-identity.mjs [options]

  --target <dir>          Cairo target directory holding proving/*.executable.json
                          (default: <root>/cairo/target; a proving/ directory is accepted too)
  --build                 run \`scarb --profile proving build -p doom_run\` first (Scarb 2.16.0)
  --program-hash 0x...    Blake task hash of run_segment measured elsewhere with
                          prover/wrapper/scripts/measure_task_hash.mjs
  --core <core.js>        measure the task hash here with the built WASM runtime
                          (prover/wasm/pkg/dist/core.js; the measurement needs Node 24)
  --args <args.json>      run_segment arguments for --core (default: an empty segment over
                          the genesis state, produced by \`scarb execute\`)
  --node <binary>         Node binary running the measurement (default: this one)
  --revision <sha1>       engine revision to pin (default: git rev-parse HEAD)
  --legacy-session <sha256>
                          R5 session executable of the identity being retired (default:
                          client/public/sim/manifest.json when it matches the current pins)
  --sim <pkg>             prover/sim/pkg directory, to verify the wasm/glue/snippet pins
  --check                 verify the pins against the target; exit 1 on mismatch; write nothing
  --dry-run               print the summary and write nothing
  --root <dir>            repository root (default: derived from this script)
  -h, --help              this text

Without --program-hash or --core the migration stops before writing (exit 2):
the task hash is never guessed or copied from another build.`;

export function parseArgs(argv) {
  const options = { build: false, check: false, dryRun: false };
  const takes = { "--target": "target", "--program-hash": "programHash", "--core": "core", "--args": "args", "--node": "node",
    "--measure": "measure", "--revision": "revision", "--legacy-session": "legacySession", "--sim": "sim", "--root": "root" };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "-h" || arg === "--help") options.help = true;
    else if (arg === "--build") options.build = true;
    else if (arg === "--check") options.check = true;
    else if (arg === "--dry-run") options.dryRun = true;
    else if (arg in takes) {
      const value = argv[++i];
      if (value === undefined || value.startsWith("--")) throw new MigrationError(`${arg} needs a value\n${USAGE}`);
      options[takes[arg]] = value;
    } else throw new MigrationError(`unknown option ${arg}\n${USAGE}`);
  }
  return options;
}

export function sha256(data) { return createHash("sha256").update(data).digest("hex"); }
export function sha256File(path) { return sha256(readFileSync(path)); }
export function shortRev(revision) { return revision.slice(0, 7); }

/** `0x…` lower-case without leading zeros: the client's normalizeFelt spelling, compared with `===`. */
export function normalizeProgramHash(value) {
  const text = String(value).trim().toLowerCase();
  if (!/^0x[0-9a-f]{1,64}$/.test(text)) throw new MigrationError(`task hash must be a 0x-prefixed hex felt, got ${JSON.stringify(value)}`);
  const felt = BigInt(text);
  if (felt === 0n || felt >= STARK_PRIME) throw new MigrationError(`task hash ${text} is not a nonzero field element`);
  return `0x${felt.toString(16)}`;
}

/** Arguments of an empty run_segment over the genesis state from `scarb execute --print-program-output`. */
export function emptySegmentArgs(output) {
  const lines = output.split(/\r?\n/);
  const start = lines.findIndex(line => /Program output:/.test(line));
  const felts = (start >= 0 ? lines.slice(start + 1) : lines).map(line => line.trim()).filter(line => /^-?(0x[0-9a-fA-F]+|\d+)$/.test(line))
    .map(text => ((BigInt(text) % STARK_PRIME) + STARK_PRIME) % STARK_PRIME);
  if (felts.length < 2) throw new MigrationError("genesis produced no program output");
  const length = Number(felts[0]);
  if (!Number.isSafeInteger(length) || length < 1 || felts.length < length + 2) throw new MigrationError("genesis output does not carry [state_len, state..., genesis_hash]");
  const state = felts.slice(1, 1 + length);
  return [BigInt(length), ...state, 0n, 0n, 0n].map(felt => `0x${felt.toString(16)}`);
}

export function parsePins(source) {
  const pins = {};
  for (const key of PIN_KEYS) {
    const match = new RegExp(`\\b${key}: "([^"]*)"`).exec(source);
    if (!match) throw new MigrationError(`${FILES.pins}: pin ${key} not found`);
    pins[key] = match[1];
  }
  return pins;
}

export function renderPins(pins, previous) {
  const lines = PIN_KEYS.map(key => `  ${key}: "${pins[key]}",`).join("\n");
  return `/** Cairo proving executables at ${shortRev(pins.revision)} (explicit migration from ${shortRev(previous)}) and unchanged R5 simulator; measured, never inferred. */
export const D29_PROOF_ARTIFACTS = Object.freeze({
${lines}
});
`;
}

export function parseLegacy(source) {
  const begin = source.indexOf("export const legacyDoomIdentities = ");
  if (begin < 0) throw new MigrationError(`${FILES.legacy}: legacyDoomIdentities list not found`);
  const open = source.indexOf("[", begin), close = source.indexOf("\n];", open);
  if (open < 0 || close < 0) throw new MigrationError(`${FILES.legacy}: legacyDoomIdentities is not a JSON array`);
  let list;
  try { list = JSON.parse(source.slice(open, close + 2)); }
  catch (error) { throw new MigrationError(`${FILES.legacy}: legacyDoomIdentities must stay strict JSON (${error.message})`); }
  for (const entry of list) {
    if (entry.adapter !== ADAPTER || typeof entry.simulation !== "string" || PIN_KEYS.some(key => typeof entry.artifacts?.[key] !== "string")) {
      throw new MigrationError(`${FILES.legacy}: malformed legacy identity ${JSON.stringify(entry).slice(0, 80)}`);
    }
  }
  return list;
}

export function renderLegacy(list) {
  const entries = list.map(entry => JSON.stringify(entry, null, 2).replace(/^/gm, "  ")).join(",\n");
  const revisions = list.map(entry => shortRev(entry.artifacts.revision)).join(", ");
  return `// SPDX-FileCopyrightText: 2026 Bal7hazar
// SPDX-License-Identifier: Apache-2.0
/** Exact former Doom proof identities (${revisions}), oldest first, as persisted in \`RunRecord.programIdentity\`.
 * Frozen migration-rejection fixtures maintained by client/scripts/migrate-identity.mjs; never a current pin. */
export const legacyDoomIdentities = [
${entries}
];
/** The most recently retired identity. */
export const legacyDoomIdentity = legacyDoomIdentities[legacyDoomIdentities.length - 1]!;
`;
}

/** The exact `programIdentity` the client persisted under these pins. */
export function identityOf(pins, simulation) {
  const artifacts = {};
  for (const key of PIN_KEYS) artifacts[key] = pins[key];
  const key = [1, 2, simulation.snapshotSchema, simulation.revision, simulation.session, pins.genesis, pins.step, pins.wasm];
  return { adapter: ADAPTER, artifacts, simulation: JSON.stringify(key) };
}

export function renderReadmeBlock(pins, legacy) {
  const former = legacy.length ? legacy.map(entry => `\`${shortRev(entry.artifacts.revision)}\``).join(", ") : "none";
  return `${README_BEGIN}
| Pin (\`doomArtifacts.ts\`) | Value |
|---|---|
| Engine revision | \`${pins.revision}\` |
| \`genesis\` SHA-256 | \`${pins.genesis}\` |
| \`step_tic\` SHA-256 | \`${pins.step}\` |
| \`run_segment\` SHA-256 | \`${pins.segment}\` |
| \`run_segment\` Blake task hash | \`${pins.programHash}\` |
| R5 simulator WASM SHA-256 | \`${pins.wasm}\` |
| Retired identities (refused, \`legacyDoomIdentity.ts\`) | ${former} |
${README_END}`;
}

export function replaceReadmeBlock(source, block) {
  const begin = source.indexOf(README_BEGIN), end = source.indexOf(README_END);
  if (begin < 0 || end < begin) throw new MigrationError(`${FILES.readme}: identity markers ${README_BEGIN} … ${README_END} not found`);
  return source.slice(0, begin) + block + source.slice(end + README_END.length);
}

function resolveTarget(root, target) {
  const base = resolve(root, target ?? "cairo/target");
  for (const dir of [join(base, "proving"), base]) {
    if (Object.values(EXECUTABLES).every(name => existsSync(join(dir, name)))) return dir;
  }
  throw new MigrationError(`no proving executables (${Object.values(EXECUTABLES).join(", ")}) under ${base}; build them with --build or pass --target`);
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, { encoding: "utf8", maxBuffer: 1 << 28, ...options });
  if (result.error) throw new MigrationError(`${command}: ${result.error.message}`);
  if (result.status !== 0) throw new MigrationError(`${command} ${args.join(" ")} failed (${result.status}):\n${result.stderr || result.stdout}`);
  return result.stdout;
}

function scarb(root, args) {
  return run("scarb", ["--manifest-path", join(root, "cairo/Scarb.toml"), "--profile", "proving", ...args],
    { env: { ...process.env, ASDF_SCARB_VERSION: "2.16.0", CARGO_BUILD_JOBS: process.env.CARGO_BUILD_JOBS ?? "2" }, stdio: ["ignore", "pipe", "pipe"] });
}

function measureTaskHash(root, options, segmentPath, segmentSha, log) {
  const script = resolve(root, options.measure ?? FILES.measure);
  const core = resolve(options.core);
  for (const [what, path] of [["measurement script", script], ["WASM core", core]]) {
    if (!existsSync(path)) throw new MigrationError(`${what} not found: ${path}`);
  }
  let args = options.args && resolve(options.args);
  if (!args) {
    log(`deriving empty-segment arguments from \`scarb execute\` genesis`);
    const output = scarb(root, ["execute", "-p", "doom_run", "--executable-name", "genesis", "--no-build", "--arguments", "0", "--print-program-output"]);
    args = join(mkdtempSync(join(tmpdir(), "migrate-identity-")), "args.json");
    writeFileSync(args, JSON.stringify(emptySegmentArgs(output)));
  }
  log(`measuring the task hash: ${options.node ?? process.execPath} ${relative(root, script)} ${relative(root, core)} ${relative(root, segmentPath)} ${args}`);
  const output = run(options.node ?? process.execPath, [script, core, segmentPath, args]);
  let measured;
  try { measured = JSON.parse(output.slice(output.indexOf("{"))); }
  catch { throw new MigrationError(`measurement did not return JSON:\n${output}`); }
  if (measured.executable_sha256 !== segmentSha) throw new MigrationError(`measurement executed ${measured.executable_sha256}, not the target's run_segment ${segmentSha}`);
  if (measured.hash_function && measured.hash_function !== "blake") throw new MigrationError(`measured ${measured.hash_function} hash; the client pins Blake`);
  return normalizeProgramHash(measured.program_hash);
}

function readLegacySession(root, options, pins, log) {
  const manifestPath = join(root, FILES.manifest);
  if (options.legacySession) {
    if (!HEX64.test(options.legacySession)) throw new MigrationError("--legacy-session must be a 64-hex SHA-256");
    return { session: options.legacySession, snapshotSchema: 2, revision: pins.revision, source: "--legacy-session" };
  }
  if (existsSync(manifestPath)) {
    const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
    if (manifest.hashes?.genesis === pins.genesis && manifest.hashes?.step === pins.step && HEX64.test(manifest.hashes.session ?? "")) {
      return { session: manifest.hashes.session, snapshotSchema: manifest.snapshotSchema ?? 2, revision: manifest.revision ?? pins.revision, source: relative(root, manifestPath) };
    }
    log(`note: ${relative(root, manifestPath)} is staged from another engine than the current pins`);
  }
  throw new MigrationError(`the R5 session SHA-256 of the retired identity is unknown: stage the current game (scripts/prepare-sim.py) before migrating, or pass --legacy-session <sha256>`);
}

function gitRevision(root) {
  const result = spawnSync("git", ["-C", root, "rev-parse", "HEAD"], { encoding: "utf8" });
  if (result.status !== 0) throw new MigrationError(`cannot read the engine revision from git (${(result.stderr || "").trim()}); pass --revision`);
  const dirty = spawnSync("git", ["-C", root, "status", "--porcelain", "--", "cairo"], { encoding: "utf8" });
  return { revision: result.stdout.trim(), dirty: dirty.status === 0 && dirty.stdout.trim() !== "" };
}

function scanStale(root, previous, current) {
  const stale = new Map();
  for (const key of ["genesis", "step", "segment", "programHash"]) if (previous[key] !== current[key]) stale.set(previous[key], key);
  if (stale.size === 0) return [];
  const files = ["client/README.md", "client/src/prove/README.md", "client/src/prove/doomPrepare.worker.ts", "client/src/prove/doomProgram.ts",
    "client/scripts/prepare-game-proof.py", "client/scripts/prepare-sim.py", "client/e2e/gameProof.spec.ts", "client/test/doomProgram.test.ts"];
  const hits = [];
  for (const file of files) {
    const path = join(root, file);
    if (!existsSync(path)) continue;
    readFileSync(path, "utf8").split("\n").forEach((line, index) => {
      for (const [value, key] of stale) if (line.includes(value)) hits.push(`${file}:${index + 1}: former ${key} pin`);
    });
  }
  return hits;
}

export function main(argv, io = {}) {
  const out = io.stdout ?? (text => process.stdout.write(text + "\n"));
  const options = parseArgs(argv);
  if (options.help) { out(USAGE); return 0; }
  const root = resolve(options.root ?? join(dirname(fileURLToPath(import.meta.url)), "../.."));
  const log = text => out(text);
  const paths = Object.fromEntries(Object.entries(FILES).map(([key, file]) => [key, join(root, file)]));
  const pinsSource = readFileSync(paths.pins, "utf8"), previous = parsePins(pinsSource);
  const legacySource = readFileSync(paths.legacy, "utf8"), legacy = parseLegacy(legacySource);
  const readmeSource = readFileSync(paths.readme, "utf8");

  if (options.build) {
    if (options.check) throw new MigrationError("--build and --check are exclusive: a check never builds");
    log("building doom_run (scarb --profile proving build -p doom_run)");
    scarb(root, ["build", "-p", "doom_run"]);
  }
  const target = resolveTarget(root, options.target);
  const measured = {};
  for (const [key, name] of Object.entries(EXECUTABLES)) measured[key] = sha256File(join(target, name));
  if (options.sim) {
    for (const [key, name] of Object.entries(SIM_FILES)) {
      const path = join(resolve(options.sim), name);
      if (!existsSync(path)) throw new MigrationError(`--sim: ${path} not found`);
      measured[key] = sha256File(path);
    }
  }
  if (options.programHash) measured.programHash = normalizeProgramHash(options.programHash);
  else if (options.core) measured.programHash = measureTaskHash(root, options, join(target, EXECUTABLES.segment), measured.segment, log);

  const compared = Object.keys(measured).map(key => [key, previous[key], measured[key]]);
  log(`target: ${relative(root, target) || target}`);
  for (const [key, before, after] of compared) log(`  ${key.padEnd(11)} ${before === after ? "=" : "≠"} ${after}`);

  if (options.check) {
    const failures = compared.filter(([, before, after]) => before !== after).map(([key, before, after]) => `${key}: pinned ${before}, target ${after}`);
    for (const entry of legacy) {
      if (entry.artifacts.segment === previous.segment) failures.push(`legacy fixture ${shortRev(entry.artifacts.revision)} lists the current run_segment ${previous.segment}`);
    }
    const block = renderReadmeBlock(previous, legacy);
    if (!readmeSource.includes(block)) failures.push(`${FILES.readme}: pin table differs from doomArtifacts.ts (rerun the migration)`);
    if (existsSync(paths.manifest)) {
      const manifest = JSON.parse(readFileSync(paths.manifest, "utf8"));
      if (manifest.hashes?.genesis !== previous.genesis || manifest.hashes?.step !== previous.step) log(`note: ${FILES.manifest} is staged from another engine; rerun scripts/prepare-sim.py`);
    }
    if (failures.length) { for (const failure of failures) log(`FAIL ${failure}`); throw new MigrationError(`${failures.length} identity check(s) failed`); }
    log(`OK: pins match ${relative(root, target) || target}${options.sim ? ` and ${options.sim}` : ""}`);
    return 0;
  }

  const unchanged = ["genesis", "step", "segment"].every(key => previous[key] === measured[key]) && (!measured.programHash || previous.programHash === measured.programHash);
  if (unchanged) {
    if (options.sim && ["wasm", "glue", "snippet"].some(key => previous[key] !== measured[key])) throw new MigrationError("the R5 simulator pins differ from --sim; that migration is a separate decision (prepare-sim.py pins the VM)");
    log("nothing to migrate: the pins already describe these executables");
    return 0;
  }
  if (options.sim && ["wasm", "glue", "snippet"].some(key => previous[key] !== measured[key])) throw new MigrationError("the R5 simulator pins differ from --sim; that migration is a separate decision (prepare-sim.py pins the VM)");
  if (!measured.programHash) {
    log(`\nno Blake task hash for run_segment ${measured.segment}: pass --core <core.js> (measured here) or --program-hash 0x… (measured with ${FILES.measure}); nothing written`);
    throw new MigrationError("missing task hash", 2);
  }
  let revision = options.revision;
  if (revision) { if (!/^[0-9a-f]{40}$/.test(revision)) throw new MigrationError("--revision must be a full 40-hex commit"); }
  else {
    const git = gitRevision(root);
    revision = git.revision;
    if (git.dirty) log("warning: cairo/ has uncommitted changes; the pinned revision may not rebuild these executables");
  }
  const next = { ...previous, revision, genesis: measured.genesis, step: measured.step, segment: measured.segment, programHash: measured.programHash };
  const retiring = readLegacySession(root, options, previous, log);
  const retired = identityOf(previous, retiring);
  const alreadyFrozen = legacy.some(entry => JSON.stringify(entry) === JSON.stringify(retired));
  const nextLegacy = alreadyFrozen ? legacy : [...legacy, retired];

  log(`\nmigration ${shortRev(previous.revision)} → ${shortRev(revision)}`);
  for (const key of PIN_KEYS) log(`  ${key.padEnd(11)} ${previous[key] === next[key] ? "=" : "≠"} ${previous[key]}${previous[key] === next[key] ? "" : ` → ${next[key]}`}`);
  log(`  retired identity frozen with session ${retiring.session} (${retiring.source})${alreadyFrozen ? " (already listed)" : ""}`);
  const stale = scanStale(root, previous, next);
  if (options.dryRun) { log("dry run: nothing written"); return 0; }

  writeFileSync(paths.pins, renderPins(next, previous.revision));
  writeFileSync(paths.legacy, renderLegacy(nextLegacy));
  writeFileSync(paths.readme, replaceReadmeBlock(readmeSource, renderReadmeBlock(next, nextLegacy)));
  log(`\nwritten: ${FILES.pins}, ${FILES.legacy}, ${FILES.readme}`);
  for (const hit of stale) log(`  review: ${hit}`);
  log(`next: python3 client/scripts/prepare-sim.py <prover/sim/pkg>  (rebuilds the Worker manifest for the new executables)`);
  log(`      python3 client/scripts/prepare-game-proof.py --target ${relative(root, dirname(target)) || "cairo/target"} --sim <prover/sim/pkg>`);
  log(`      cd client && npx vitest run && node scripts/migrate-identity.mjs --check`);
  return 0;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try { process.exitCode = main(process.argv.slice(2)); }
  catch (error) {
    if (error instanceof MigrationError) { console.error(`migrate-identity: ${error.message}`); process.exitCode = error.code; }
    else throw error;
  }
}
