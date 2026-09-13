import { describe, expect, it } from "vitest";
import {
  TICS_PER_FELT,
  TicLog,
  decodeCmd,
  encodeCmd,
  isCanonical,
  pack7,
  packLog,
  quantize,
  unpack7,
  unpackLog,
  type TicCmd,
} from "../src/prove/ticcmd.js";

const cmd = (over: Partial<TicCmd> = {}): TicCmd => ({
  forward: 0,
  side: 0,
  turn: 0,
  buttons: 0,
  ...over,
});

describe("the ticcmd word", () => {
  it("round-trips every canonical command over each field's range", () => {
    for (let forward = -128; forward <= 127; forward++) {
      expect(decodeCmd(encodeCmd(cmd({ forward })))).toEqual(cmd({ forward }));
    }
    for (let step = -128; step <= 127; step++) {
      const c = cmd({ turn: step * 256 });
      expect(decodeCmd(encodeCmd(c))).toEqual(c);
    }
    for (let buttons = 0; buttons <= 255; buttons++) {
      expect(decodeCmd(encodeCmd(cmd({ buttons })))).toEqual(cmd({ buttons }));
    }
  });

  it("packs into 32 bits, in the crate's field order", () => {
    const word = encodeCmd(cmd({ forward: 1, side: -1, turn: 256, buttons: 0x0f }));
    expect(word >>> 0).toBe(((0x0f << 24) | (129 << 16) | (127 << 8) | 129) >>> 0);
    expect(word).toBeLessThan(2 ** 32);
  });

  it("refuses a non-canonical command rather than truncating (D12)", () => {
    expect(() => encodeCmd(cmd({ turn: 320 }))).toThrow(/canonical/);
    expect(() => encodeCmd(cmd({ forward: 200 }))).toThrow(/canonical/);
  });

  it("quantize is total, idempotent, and snaps the turn like G_WriteDemoTiccmd", () => {
    for (const raw of [cmd({ turn: 320 }), cmd({ turn: 640 }), cmd({ turn: -1280 }), cmd({ forward: 9999 })]) {
      const once = quantize(raw);
      expect(isCanonical(once)).toBe(true);
      expect(quantize(once)).toEqual(once);
    }
    expect(quantize(cmd({ turn: 320 })).turn).toBe(256);
    expect(quantize(cmd({ turn: 640 })).turn).toBe(512);
    expect(quantize(cmd({ turn: 1280 })).turn).toBe(1280);
  });
});

describe("the transport felt (7 tics per felt)", () => {
  const words = [1, 2, 3, 0xffffffff, 5, 6, 7];

  it("round-trips a full group", () => {
    expect(unpack7(pack7(words))).toEqual(words);
  });

  it("lays the lanes out little-endian in 32-bit slices", () => {
    expect(pack7([1, 1])).toBe(`0x${(1n + (1n << 32n)).toString(16)}`);
  });

  it("leaves the last group short and needs the tic count to read it back", () => {
    const log = [1, 2, 3, 4, 5, 6, 7, 8, 9];
    const felts = packLog(log);
    expect(felts).toHaveLength(2);
    expect(unpackLog(felts, log.length)).toEqual(log);
  });

  it("round-trips every log length from 0 to 15", () => {
    for (let n = 0; n <= 15; n++) {
      const log = Array.from({ length: n }, (_, i) => (i * 2654435761) >>> 0);
      expect(unpackLog(packLog(log), n)).toEqual(log);
    }
  });

  it("refuses more than seven words in one felt", () => {
    expect(() => pack7([1, 2, 3, 4, 5, 6, 7, 8])).toThrow(/at most 7/);
  });
});

describe("TicLog", () => {
  it("freezes a felt exactly every seven tics, and matches packLog", () => {
    const log = new TicLog();
    const words = Array.from({ length: 17 }, (_, i) => (i + 1) >>> 0);
    for (const word of words) log.push(word);
    expect(log.length).toBe(17);
    expect(log.completeFelts).toHaveLength(2);
    expect(log.tailWords).toHaveLength(17 % TICS_PER_FELT);
    expect(log.toFelts()).toEqual(packLog(words));
    expect(log.toWords()).toEqual(words);
  });

  it("restores from what was persisted", () => {
    const log = new TicLog();
    for (let i = 0; i < 10; i++) log.push(i + 1);
    const restored = TicLog.fromPersisted(log.completeFelts, log.tailWords);
    expect(restored.length).toBe(10);
    expect(restored.toWords()).toEqual(log.toWords());
    restored.push(11);
    expect(restored.toWords()).toEqual([...log.toWords(), 11]);
  });

  it("slices a segment's own span out of the journal", () => {
    const log = new TicLog();
    for (let i = 0; i < 30; i++) log.push(i);
    expect(log.slice(7, 14)).toEqual([7, 8, 9, 10, 11, 12, 13]);
    expect(log.slice(28, 100)).toEqual([28, 29]);
  });
});
