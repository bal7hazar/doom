import "fake-indexeddb/auto";
import { describe, expect, it } from "vitest";
import { InputJournal } from "../src/game/inputJournal.js";
import { encodeFelts } from "../src/sim/felts.js";
import { SavedGameStore, SAVE_BYTES, parseSavedGame, serializeSavedGame } from "../src/game/savedGame.js";

function journal() {
  return new InputJournal({ version: 1, stateSchema: 2, snapshotSchema: 1, revision: "test",
    hashes: { wasm: "a".repeat(64), session: "b".repeat(64), genesis: "c".repeat(64), step: "d".repeat(64) } },
  encodeFelts([0x48502e5354415445n, 2, 3, 0x45314d31, 0, 0]));
}

describe("explicit local save slot", () => {
  it("stores the complete acknowledged journal transactionally and survives a new store instance", async () => {
    const one = journal(); one.record(0, 0x808099, 1);
    await new SavedGameStore().save(one.export());
    expect(await new SavedGameStore().load()).toEqual(one.export());
    const two = journal();
    await new SavedGameStore().save(two.export());
    expect(await new SavedGameStore().load()).toEqual(two.export());
  });
  it("rejects oversized, malformed and noncanonical imports", () => {
    expect(() => parseSavedGame(" ".repeat(SAVE_BYTES + 1))).toThrow("8 MB");
    expect(() => parseSavedGame("null")).toThrow();
    const data = journal().export(); data.inputs = ["0x0"];
    expect(() => parseSavedGame(JSON.stringify(data))).toThrow("noncanonical");
    expect(parseSavedGame(serializeSavedGame(journal().export()))).toEqual(journal().export());
  });
});
