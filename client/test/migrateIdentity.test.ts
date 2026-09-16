// SPDX-FileCopyrightText: 2026 Bal7hazar
// SPDX-License-Identifier: Apache-2.0
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { legacyDoomIdentities } from "./fixtures/legacyDoomIdentity.js";
import { D29_PROOF_ARTIFACTS as pins } from "../src/prove/doomArtifacts.js";
import * as migrate from "../scripts/migrate-identity.mjs";

const SCRIPT = join(__dirname, "../scripts/migrate-identity.mjs");
const REAL = join(__dirname, "..", "..");
const REVISION = "a".repeat(40), SESSION = "2f2be024e3f91e24385aa3d73dead26394b924fd36d16be98c83dca935e39300";
const TASK_HASH = "0x123abcdef0123abcdef0123abcdef0123abcdef0123abcdef0123abcdef012";
const sha256 = (data: string) => createHash("sha256").update(data).digest("hex");

interface Fake { root: string; target: string; files: Record<string, string>; sha: Record<string, string> }
let fake: Fake;
function stage(): Fake {
  const root = mkdtempSync(join(tmpdir(), "migrate-identity-test-"));
  for (const dir of ["client/src/prove", "client/test/fixtures", "client/public/sim", "cairo/target/proving"]) mkdirSync(join(root, dir), { recursive: true });
  const files = {
    pins: "client/src/prove/doomArtifacts.ts", legacy: "client/test/fixtures/legacyDoomIdentity.ts",
    readme: "client/src/prove/README.md", manifest: "client/public/sim/manifest.json",
  };
  writeFileSync(join(root, files.pins), readFileSync(join(REAL, files.pins)));
  writeFileSync(join(root, files.legacy), readFileSync(join(REAL, files.legacy)));
  writeFileSync(join(root, files.readme), `# prose before\n\n${migrate.renderReadmeBlock(pins, legacyDoomIdentities)}\n\nprose after mentioning ${pins.segment}\n`);
  writeFileSync(join(root, files.manifest), JSON.stringify({ version: 1, stateSchema: 2, snapshotSchema: 2, revision: pins.revision,
    hashes: { session: SESSION, genesis: pins.genesis, step: pins.step, wasm: pins.wasm } }));
  const target = join(root, "cairo/target"), sha: Record<string, string> = {};
  for (const [key, name] of Object.entries(migrate.EXECUTABLES)) {
    const body = JSON.stringify({ program: { bytecode: [key, "0x1"] } });
    writeFileSync(join(target, "proving", name), body); sha[key] = sha256(body);
  }
  return { root, target, files, sha };
}
function run(...args: string[]) {
  const result = spawnSync(process.execPath, [SCRIPT, "--root", fake.root, "--target", fake.target, ...args], { encoding: "utf8" });
  return { code: result.status, out: result.stdout, err: result.stderr };
}
const read = (key: string) => readFileSync(join(fake.root, fake.files[key]!), "utf8");
const snapshot = () => Object.fromEntries(Object.keys(fake.files).map(key => [key, existsSync(join(fake.root, fake.files[key]!)) ? read(key) : null]));

beforeEach(() => { fake = stage(); });
afterEach(() => { rmSync(fake.root, { recursive: true, force: true }); });

describe("migrate-identity.mjs", () => {
  it("computes the executables' SHA-256 and fails --check while the pins point at another engine", () => {
    const before = snapshot();
    const { code, out, err } = run("--check");
    expect(code).toBe(1);
    for (const key of ["genesis", "step", "segment"]) {
      expect(out).toContain(`${key.padEnd(11)} ≠ ${fake.sha[key]}`);
      expect(out).toContain(`FAIL ${key}: pinned ${pins[key as "genesis"]}, target ${fake.sha[key]}`);
    }
    expect(err).toContain("3 identity check(s) failed");
    expect(snapshot()).toEqual(before); // a check never writes
  });

  it("refuses to migrate without a measured task hash and writes nothing", () => {
    const before = snapshot();
    const { code, out, err } = run("--revision", REVISION);
    expect(code).toBe(2);
    expect(out).toMatch(/no Blake task hash.*--core.*--program-hash.*nothing written/);
    expect(err).toContain("missing task hash");
    expect(snapshot()).toEqual(before);
    for (const bad of ["55fb", "0x", "0xzz", "0x0"]) {
      expect(run("--revision", REVISION, "--program-hash", bad).code).toBe(1);
    }
    expect(snapshot()).toEqual(before);
  });

  it("rewrites the pins, freezes the retired identity, refreshes the README table and reports before/after", async () => {
    const before = snapshot();
    const { code, out } = run("--revision", REVISION, "--program-hash", TASK_HASH.toUpperCase().replace("0X", "0x00"));
    expect(code).toBe(0);
    expect(out).toContain(`migration ${pins.revision.slice(0, 7)} → aaaaaaa`);
    expect(out).toContain(`segment     ≠ ${pins.segment} → ${fake.sha.segment}`);
    expect(out).toContain(`programHash ≠ ${pins.programHash} → ${TASK_HASH}`);
    expect(out).toContain(`wasm        = ${pins.wasm}`);
    expect(out).toContain(`retired identity frozen with session ${SESSION} (client/public/sim/manifest.json)`);
    expect(out).toContain("review: client/src/prove/README.md:");
    expect(out).toContain("prepare-sim.py");
    const next = migrate.parsePins(read("pins"));
    expect(next).toEqual({ ...pins, revision: REVISION, genesis: fake.sha.genesis, step: fake.sha.step, segment: fake.sha.segment, programHash: TASK_HASH });
    expect(read("pins")).toMatch(new RegExp(`^/\\*\\* Cairo proving executables at aaaaaaa \\(explicit migration from ${pins.revision.slice(0, 7)}\\)`));
    expect(read("pins")).toContain("export const D29_PROOF_ARTIFACTS = Object.freeze({");
    // prepare-game-proof.py reads the pins with this exact regular expression.
    const python = [...read("pins").matchAll(/(genesis|step|segment|wasm|glue|snippet): "([0-9a-f]{64})"/g)].map(m => m[1]);
    expect(python).toEqual(["genesis", "step", "segment", "wasm", "snippet", "glue"]);
    const legacy = migrate.parseLegacy(read("legacy"));
    expect(legacy).toHaveLength(legacyDoomIdentities.length + 1);
    expect(legacy.slice(0, -1)).toEqual(legacyDoomIdentities);
    expect(legacy.at(-1)).toEqual({ adapter: "doom_run/state2/d14v1", artifacts: { ...pins },
      simulation: JSON.stringify([1, 2, 2, pins.revision, SESSION, pins.genesis, pins.step, pins.wasm]) });
    expect(JSON.stringify(legacy.at(-1)!.artifacts)).toBe(JSON.stringify(pins)); // key order is the persisted identity
    const module = await import(/* @vite-ignore */ pathToFileURL(join(fake.root, fake.files.legacy!)).href);
    expect(module.legacyDoomIdentity).toEqual(legacy.at(-1));
    expect(read("readme")).toContain(`| \`run_segment\` Blake task hash | \`${TASK_HASH}\` |`);
    const retired = [...legacyDoomIdentities.map(entry => entry.artifacts.revision), pins.revision].map(revision => `\`${revision.slice(0, 7)}\``).join(", ");
    expect(read("readme")).toContain(`| Retired identities (refused, \`legacyDoomIdentity.ts\`) | ${retired} |`);
    expect(read("readme")).toMatch(/^# prose before\n\n<!-- identity:begin -->/);
    expect(read("readme")).toMatch(/<!-- identity:end -->\n\nprose after/);
    expect(read("manifest")).toBe(before.manifest); // the Worker manifest is prepare-sim.py's
  });

  it("turns --check green after the migration and red again when an executable changes", () => {
    expect(run("--revision", REVISION, "--program-hash", TASK_HASH).code).toBe(0);
    const green = run("--check");
    expect(green.code).toBe(0);
    expect(green.out).toContain("OK: pins match");
    expect(run("--check", "--program-hash", TASK_HASH).code).toBe(0);
    expect(run("--check", "--program-hash", "0x1").out).toContain("FAIL programHash");
    writeFileSync(join(fake.target, "proving", "step_tic.executable.json"), "{}");
    const red = run("--check");
    expect(red.code).toBe(1);
    expect(red.out).toContain("FAIL step: pinned");
    expect(red.out).not.toContain("FAIL genesis");
  });

  it("is idempotent: a second run changes nothing and adds no duplicate legacy entry", () => {
    expect(run("--revision", REVISION, "--program-hash", TASK_HASH).code).toBe(0);
    const once = snapshot();
    const again = run("--revision", "b".repeat(40), "--program-hash", TASK_HASH);
    expect(again.code).toBe(0);
    expect(again.out).toContain("nothing to migrate");
    expect(snapshot()).toEqual(once);
    expect(migrate.parseLegacy(read("legacy"))).toHaveLength(legacyDoomIdentities.length + 1);
  });

  it("measures the task hash through the measurement script when --core is given", () => {
    const measure = join(fake.root, "measure.mjs"), core = join(fake.root, "core.js"), args = join(fake.root, "args.json");
    writeFileSync(core, "export class ProverCore {}\n"); writeFileSync(args, JSON.stringify(["0x1"]));
    writeFileSync(measure, `import { createHash } from "node:crypto"; import { readFileSync } from "node:fs";
const [core, executable, args] = process.argv.slice(2);
if (!core.endsWith("core.js") || !Array.isArray(JSON.parse(readFileSync(args, "utf8")))) throw new Error("bad arguments");
console.log("runtime noise"); console.log(JSON.stringify({ executable, executable_sha256: createHash("sha256").update(readFileSync(executable)).digest("hex"),
  hash_function: "blake", program_hash: process.env.FAKE_TASK_HASH ?? "${TASK_HASH}", n_steps: 1 }, null, 2));\n`);
    const measured = run("--revision", REVISION, "--core", core, "--args", args, "--measure", measure);
    expect(measured.code).toBe(0);
    expect(measured.out).toContain(`measuring the task hash: ${process.execPath} measure.mjs core.js`);
    expect(migrate.parsePins(read("pins")).programHash).toBe(TASK_HASH);
    // A measurement of another executable, or a non-Blake hash, is never pinned.
    writeFileSync(join(fake.target, "proving", "run_segment.executable.json"), '{"program":"other"}');
    writeFileSync(measure, `console.log(JSON.stringify({ executable_sha256: "${fake.sha.segment}", hash_function: "blake", program_hash: "0x2" }))\n`);
    const before = snapshot();
    const wrong = run("--revision", REVISION, "--core", core, "--args", args, "--measure", measure, "--legacy-session", SESSION);
    expect(wrong.code).toBe(1);
    expect(wrong.err).toContain("not the target's run_segment");
    expect(snapshot()).toEqual(before);
  });

  it("stops before writing when the retired session is unknown, and --dry-run writes nothing", () => {
    rmSync(join(fake.root, fake.files.manifest!));
    const before = snapshot();
    const missing = run("--revision", REVISION, "--program-hash", TASK_HASH);
    expect(missing.code).toBe(1);
    expect(missing.err).toContain("--legacy-session");
    expect(snapshot()).toEqual(before);
    const dry = run("--revision", REVISION, "--program-hash", TASK_HASH, "--legacy-session", SESSION, "--dry-run");
    expect(dry.code).toBe(0);
    expect(dry.out).toContain("dry run: nothing written");
    expect(dry.out).toContain(`retired identity frozen with session ${SESSION} (--legacy-session)`);
    expect(snapshot()).toEqual(before);
    expect(run("--revision", REVISION, "--program-hash", TASK_HASH, "--legacy-session", SESSION).code).toBe(0);
    expect(migrate.parseLegacy(read("legacy")).at(-1)!.simulation).toBe(JSON.stringify([1, 2, 2, pins.revision, SESSION, pins.genesis, pins.step, pins.wasm]));
  });

  it("re-pins the R5 simulator only with --sim --pin-sim, and the retired identity keeps the former VM", () => {
    const sim = join(fake.root, "sim"), files: Record<string, string> = {};
    mkdirSync(join(sim, "snippets/hellproof-sim-c1c84871eb3c9493"), { recursive: true });
    for (const [key, name] of Object.entries(migrate.SIM_FILES)) { writeFileSync(join(sim, name), `${key} bytes`); files[key] = sha256(`${key} bytes`); }
    const before = snapshot();
    const refused = run("--revision", REVISION, "--program-hash", TASK_HASH, "--sim", sim);
    expect(refused.code).toBe(1);
    expect(refused.err).toContain("--pin-sim");
    expect(snapshot()).toEqual(before);
    expect(run("--pin-sim", "--revision", REVISION, "--program-hash", TASK_HASH).err).toContain("--pin-sim needs --sim");
    expect(run("--check", "--sim", sim).out).toContain(`FAIL wasm: pinned ${pins.wasm}, target ${files.wasm}`);
    const { code, out } = run("--revision", REVISION, "--program-hash", TASK_HASH, "--sim", sim, "--pin-sim");
    expect(code).toBe(0);
    expect(out).toContain(`wasm        ≠ ${pins.wasm} → ${files.wasm}`);
    expect(out).toContain("R5 simulator re-pinned");
    const next = migrate.parsePins(read("pins"));
    expect(next).toEqual({ ...pins, revision: REVISION, genesis: fake.sha.genesis, step: fake.sha.step, segment: fake.sha.segment, programHash: TASK_HASH, ...files });
    expect(read("pins")).toContain("and re-pinned R5 simulator;");
    expect(read("readme")).toContain(`| R5 simulator WASM SHA-256 | \`${files.wasm}\` |`);
    const retired = migrate.parseLegacy(read("legacy")).at(-1)!;
    expect(retired.artifacts.wasm).toBe(pins.wasm);
    expect(retired.simulation).toBe(JSON.stringify([1, 2, 2, pins.revision, SESSION, pins.genesis, pins.step, pins.wasm]));
    expect(run("--check", "--sim", sim).code).toBe(0);
    // Re-pinning the VM alone (same executables) is a migration too, and needs no task hash.
    writeFileSync(join(sim, migrate.SIM_FILES.wasm), "newer vm");
    const vmOnly = run("--revision", "b".repeat(40), "--sim", sim, "--pin-sim", "--legacy-session", SESSION);
    expect(vmOnly.code).toBe(0);
    expect(migrate.parsePins(read("pins"))).toEqual({ ...next, revision: "b".repeat(40), wasm: sha256("newer vm") });
    expect(migrate.parseLegacy(read("legacy")).at(-1)!.artifacts.wasm).toBe(files.wasm);
  });

  it("derives empty-segment arguments from scarb's genesis output and normalizes task hashes", () => {
    const output = "Compiling...\nProgram output:\n3\n0x48502e5354415445\n-1\n7\n123456\n";
    expect(migrate.emptySegmentArgs(output)).toEqual(["0x3", "0x48502e5354415445", "0x800000000000011000000000000000000000000000000000000000000000000", "0x7", "0x0", "0x0", "0x0"]);
    expect(() => migrate.emptySegmentArgs("Program output:\n5\n1\n")).toThrow(/state_len/);
    expect(migrate.normalizeProgramHash("0x0055FB")).toBe("0x55fb");
    expect(() => migrate.normalizeProgramHash("0x800000000000011000000000000000000000000000000000000000000000001")).toThrow(/field element/);
  });

  it("keeps the repository's own pins, fixture and README consistent", () => {
    expect(migrate.parsePins(readFileSync(join(REAL, "client/src/prove/doomArtifacts.ts"), "utf8"))).toEqual({ ...pins });
    expect(migrate.parseLegacy(readFileSync(join(REAL, "client/test/fixtures/legacyDoomIdentity.ts"), "utf8"))).toEqual(legacyDoomIdentities);
    expect(readFileSync(join(REAL, "client/src/prove/README.md"), "utf8")).toContain(migrate.renderReadmeBlock(pins, legacyDoomIdentities));
  });
});
