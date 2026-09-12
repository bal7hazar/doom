// Segment sizing scan: for a list of `steps_k` arguments, run execute + resources (no proving —
// a second or two each) and print the largest AIR component, i.e. what actually caps a segment.
//
//   node test/sizing.mjs [--n 100000,181371,272280] [--params ../harness/params/leaf.json]
//
// A segment is provable by the recursion leaf while `log_max_component_size <= 20`; above that the
// prover panics with "Preprocessed column Seq(21) is missing from static allocation" (the
// `canonical_small` preprocessed trace only has sequences up to 2^20).
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { ProverCore } from "../dist/core.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const argv = process.argv.slice(2);
const opt = (n, d) => {
  const i = argv.indexOf(`--${n}`);
  return i >= 0 ? argv[i + 1] : d;
};
const ns = String(opt("n", "1032,94867,181371,226000,272280,363189")).split(",").map(Number);
const paramsFile = opt("params", null);
const params = paramsFile ? fs.readFileSync(paramsFile, "utf8") : undefined;

const executable = fs.readFileSync(
  path.join(here, "../../harness/programs/steps_k/main.executable.json"),
  "utf8",
);

const core = new ProverCore(() => {});
await core.init({ threads: Number(opt("threads", 1)) });

console.log("n\ttotal steps\tmax component\trows\tlog\tfits\tid_to_big components\tmem GiB");
for (const n of ns) {
  const { input, stats } = core.execute(executable, [`0x${n.toString(16)}`]);
  const r = core.resources(input, params);
  console.log(
    [
      n,
      stats.n_steps,
      r.max_component,
      r.max_component_rows,
      r.log_max_component_size,
      r.fits_leaf_registry,
      r.n_memory_id_to_big_components,
      (core.memoryBytes / 2 ** 30).toFixed(2),
    ].join("\t"),
  );
}
core.terminate();
process.exit(0);
