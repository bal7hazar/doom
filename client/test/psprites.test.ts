import { describe, expect, it } from "vitest";
import { decodeCairoSnapshot } from "../src/sim/cairoSnapshot.js";
import { decodeFelts, encodeFelts } from "../src/sim/felts.js";
import { SnapshotRing } from "../src/sim/snapshot.js";
import { compatibleSimulation } from "../src/sim/simulationCompatibility.js";
import type { SimIdentity } from "../src/sim/cairoProtocol.js";

function frame() {
  const f = Array<bigint>(36).fill(0n); f[0] = 2n;
  for (let i = 5; i <= 8; i++) f[i] = 1n << 32n;
  return encodeFelts([...f, 12n, 2n, 32769n, (1n << 32n) - 65536n, (1n << 32n) + 2097152n,
    0n, 0n, 0n, 1n << 32n, 1n << 32n]);
}
describe("Cairo psprite transport", () => {
  it("preserves active/fullbright, hidden slots and signed offsets across the render ring", () => {
    const snapshot = decodeCairoSnapshot(frame()).snapshot;
    const ring = new SnapshotRing(); ring.publish(snapshot);
    expect(ring.readLatest()).toEqual(snapshot);
    expect(snapshot.player.psprites?.[0]).toEqual({ state: 12, sprite: 2, frame: 32769, x: -65536, y: 2097152 });
    expect(snapshot.player.psprites?.[1].state).toBe(0);
    delete snapshot.player.psprites; ring.publish(snapshot);
    expect(ring.readLatest()?.player.psprites).toBeUndefined();
  });
  it("rejects incomplete and unsupported trailers and accepts legacy v1", () => {
    const f = decodeFelts(frame());
    expect(() => decodeCairoSnapshot(encodeFelts(f.slice(0, -1)))).toThrow();
    f[0] = 3n; expect(() => decodeCairoSnapshot(encodeFelts(f))).toThrow();
    f[0] = 1n; expect(decodeCairoSnapshot(encodeFelts(f.slice(0, 36))).snapshot.player.psprites).toBeUndefined();
  });
  it("permits only the audited render-session migration with identical game executables", () => {
    const old: SimIdentity = { version: 1, stateSchema: 2, snapshotSchema: 1, revision: "old", hashes: {
      session: "dcb7193cbb8d77cdb08c66517e1c5e68453b15687808e40ea2abb5acbc4a0cac", genesis: "g", step: "s", wasm: "w" } };
    const next: SimIdentity = { ...old, snapshotSchema: 2, hashes: { ...old.hashes, session: "2f2be024e3f91e24385aa3d73dead26394b924fd36d16be98c83dca935e39300" } };
    expect(compatibleSimulation(old, next)).toBe(true);
    expect(compatibleSimulation(next, old)).toBe(false);
    expect(compatibleSimulation({ ...old, hashes: { ...old.hashes, session: "unknown" } }, next)).toBe(false);
    expect(compatibleSimulation(old, { ...next, hashes: { ...next.hashes, step: "different" } })).toBe(false);
  });
});
