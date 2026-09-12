import { existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));

export const FIXTURE_PATH = join(HERE, "fixtures", "generated", "pictures.json");
export const LEVEL_PATH = resolve(HERE, "..", "public", "levels", "e1m1.json");

export interface PictureFixture {
  width: number;
  height: number;
  leftOffset: number;
  topOffset: number;
  pixels: string;
  mask: string;
}

export interface Fixture {
  wad: { path: string; lumps: number; identification: string };
  patch: { name: string; lumpIndex: number; raw: string; decoded: PictureFixture };
  flat: { name: string; raw: string; decoded: PictureFixture };
  texture: {
    name: string;
    width: number;
    height: number;
    patches: { originX: number; originY: number; name: string }[];
    decoded: PictureFixture;
  };
  sprites: {
    TROO: {
      frameCount: number;
      frameA: { rotate: boolean; lump: number[]; flip: boolean[] } | null;
      lumpNames: (string | null)[];
    };
    BON1: { frameA: { rotate: boolean; lump: number[]; flip: boolean[] } | null };
    rotationCases: { viewToThing: number; thingAngle: number; expected: number }[];
  };
  palette: { count: number; palette0: { r: number; g: number; b: number }[]; palette1: unknown[] };
  colormap: { mapCount: number; row0: number[]; row16: number[]; row31: number[] };
}

/**
 * Loads the WAD-derived fixture, or `null` when it has not been generated.
 *
 * Tests that need it call `describe.skipIf(!fixture)` so a checkout without
 * `freedoom1.wad` still has a green `npm test` - the WAD is never committed
 * (see `client/.gitignore`), and `npm run fixtures` regenerates this.
 */
export function loadFixture(): Fixture | null {
  if (!existsSync(FIXTURE_PATH)) return null;
  return JSON.parse(readFileSync(FIXTURE_PATH, "utf8")) as Fixture;
}

/** The E1M1 level JSON staged by `npm run assets`, or `null` when absent. */
export function loadLevel<T>(): T | null {
  if (!existsSync(LEVEL_PATH)) return null;
  return JSON.parse(readFileSync(LEVEL_PATH, "utf8")) as T;
}

export function fromBase64(s: string): Uint8Array {
  return new Uint8Array(Buffer.from(s, "base64"));
}

/** Index of the first differing byte, or −1. Reported instead of a 3 000-element diff. */
export function firstDifference(a: Uint8Array, b: Uint8Array): number {
  if (a.length !== b.length) return Math.min(a.length, b.length);
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return i;
  return -1;
}
