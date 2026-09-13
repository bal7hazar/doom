import { D29_PROOF_ARTIFACTS as pins } from "./doomArtifacts.js";
import { DoomPreparation } from "./doomPreparation.js";
import { decodeFelts, encodeFelts } from "../sim/felts.js";
import { toFelt } from "./felt.js";
import type { SegmentRequest } from "./program.js";
interface Program { run(args: Uint8Array): Uint8Array; free(): void }
let preparation: DoomPreparation | undefined;
let programs: Program[] = [];
async function verified(base: URL, name: string, hash: string): Promise<Uint8Array> {
  const res = await fetch(new URL(name, base));
  if (!res.ok) throw new Error(`missing proof preparation asset ${name}: ${res.status}`);
  const bytes = new Uint8Array(await res.arrayBuffer());
  const actual = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes)), b => b.toString(16).padStart(2, "0")).join("");
  if (actual !== hash) throw new Error(`proof preparation SHA256 mismatch: ${name}`);
  return bytes;
}
let busy = false;
self.onmessage = async (event: MessageEvent<{ id: number; op: "init" | "prepare"; assets?: string; request?: SegmentRequest; journal?: number[] }>) => {
  const { id, op } = event.data;
  if (busy) { self.postMessage({ id, error: "preparation already running" }); return; }
  busy = true;
  try {
    if (op === "init") {
      if (preparation) throw new Error("preparation already initialized");
      const base = new URL(event.data.assets ?? "/prover/game-proof/", self.location.href);
      if (base.origin !== self.location.origin || !base.pathname.endsWith("/")) throw new Error("proof preparation assets must be a same-origin directory");
      const [genesis, step, segment, wasm, glue, snippet] = await Promise.all([
        verified(base, "genesis.json", pins.genesis), verified(base, "step.json", pins.step),
        verified(base, "segment.json", pins.segment), verified(base, "hellproof_sim_bg.wasm", pins.wasm),
        verified(base, "hellproof_sim.js", pins.glue), verified(base, "inline0.js", pins.snippet),
      ]);
      // Import the verified bytes, avoiding a second fetch of unchecked JavaScript.
      const snippetBlob = URL.createObjectURL(new Blob([snippet.slice().buffer], { type: "text/javascript" }));
      const glueText = new TextDecoder().decode(glue).replace(
        '"./snippets/hellproof-sim-c1c84871eb3c9493/inline0.js"', JSON.stringify(snippetBlob));
      const blob = URL.createObjectURL(new Blob([glueText], { type: "text/javascript" }));
      let mod;
      try { mod = await import(/* @vite-ignore */ blob); } finally { URL.revokeObjectURL(blob); URL.revokeObjectURL(snippetBlob); }
      await mod.default({ module_or_path: wasm });
      const text = new TextDecoder();
      programs = [genesis, step, segment].map(bytes => mod.SimProgram.load(text.decode(bytes)) as Program);
      preparation = new DoomPreparation({ run(name, args) {
        const program = programs[{ genesis: 0, step: 1, segment: 2 }[name]]!;
        return decodeFelts(program.run(encodeFelts(args))).map(toFelt);
      } });
      self.postMessage({ id, result: { initial: preparation.initial, genesis: preparation.genesis, executable: text.decode(segment) } });
    } else {
      if (!preparation || !event.data.request || !event.data.journal) throw new Error("preparation is not initialized");
      self.postMessage({ id, result: preparation.prepare(event.data.request, event.data.journal) });
    }
  } catch (error) { self.postMessage({ id, error: error instanceof Error ? error.message : String(error) }); }
  finally { busy = false; }
};
