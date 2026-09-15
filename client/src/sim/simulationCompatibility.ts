import type { SimIdentity } from "./cairoProtocol.js";

/** Only the audited render-only session migration; simulation/proof executables are identical. */
export function compatibleSimulation(saved: SimIdentity, loaded: SimIdentity): boolean {
  if (saved.version !== loaded.version || saved.stateSchema !== loaded.stateSchema ||
      (["genesis", "step", "wasm"] as const).some(key => saved.hashes[key] !== loaded.hashes[key])) return false;
  if (saved.hashes.session === loaded.hashes.session) return saved.snapshotSchema === loaded.snapshotSchema;
  return saved.snapshotSchema === 1 && loaded.snapshotSchema === 2 &&
    saved.hashes.session === "dcb7193cbb8d77cdb08c66517e1c5e68453b15687808e40ea2abb5acbc4a0cac" &&
    loaded.hashes.session === "2f2be024e3f91e24385aa3d73dead26394b924fd36d16be98c83dca935e39300";
}
