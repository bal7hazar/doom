// SPDX-License-Identifier: Apache-2.0
// A stand-in for `stwo-run-and-prove`: reads the bootloader input the prover wrote, dumps the
// preimage the test asked for (FAKE_STWO_PREIMAGE, JSON) and a proof file; or sleeps
// (FAKE_STWO_MODE=hang) or fails (FAKE_STWO_MODE=fail).
import { readFileSync, writeFileSync } from "node:fs";

const argv = process.argv.slice(2);
const opt = (name) => argv[argv.indexOf(name) + 1];
const mode = process.env.FAKE_STWO_MODE ?? "ok";
if (mode === "hang") {
  setTimeout(() => {}, 60_000);
} else if (mode === "fail") {
  console.error("fake stwo: refusing");
  process.exit(3);
} else {
  const input = JSON.parse(readFileSync(opt("--program_input"), "utf8"));
  const args = JSON.parse(readFileSync(input.tasks[0].user_args_file, "utf8"));
  const preimage = JSON.parse(process.env.FAKE_STWO_PREIMAGE ?? "[]");
  writeFileSync(input.output_preimage_dump_path, JSON.stringify(preimage));
  const format = opt("--proof-format");
  if (format === "bincode") writeFileSync(opt("--proof_path"), Buffer.from(`bincode:${args.length}`));
  else writeFileSync(opt("--proof_path"), JSON.stringify(["0x1", "0x2", String(args.length)]));
  writeFileSync(opt("--program_output"), "[]");
  console.log(`fake stwo: proved ${args.length} args with ${input.tasks[0].program_hash_function}`);
}
