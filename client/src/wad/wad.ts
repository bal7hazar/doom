import { BinaryReader } from "./binary.js";

export interface LumpEntry {
  index: number;
  name: string;
  filePos: number;
  size: number;
}

const HEADER_SIZE = 12;
const DIRECTORY_ENTRY_SIZE = 16;

/**
 * Browser-side WAD directory. Mirrors `tools/wad/src/wad.ts` minus the
 * filesystem entry point (the client always has the bytes already, from
 * `fetch`), plus a name index because the client does thousands of lookups
 * while building atlases and a linear `Array.find` over ~2 800 lumps adds up.
 *
 * Name lookups follow the id/pwad convention of **last wins**: a later lump
 * with the same name overrides an earlier one. A single IWAD never relies on
 * it, but it makes adding a PWAD later a non-change.
 */
export class Wad {
  readonly bytes: Uint8Array;
  readonly identification: "IWAD" | "PWAD";
  readonly lumps: LumpEntry[];
  private readonly byName = new Map<string, number>();

  private constructor(bytes: Uint8Array, identification: "IWAD" | "PWAD", lumps: LumpEntry[]) {
    this.bytes = bytes;
    this.identification = identification;
    this.lumps = lumps;
    for (const l of lumps) this.byName.set(l.name, l.index);
  }

  static fromBytes(bytes: Uint8Array): Wad {
    if (bytes.length < HEADER_SIZE) {
      throw new Error(`Not a WAD file: too short (${bytes.length} bytes)`);
    }
    const r = new BinaryReader(bytes);
    const identification = r.name(4);
    if (identification !== "IWAD" && identification !== "PWAD") {
      throw new Error(`Not a WAD file: bad identification "${identification}"`);
    }
    const numLumps = r.int32();
    const infoTableOfs = r.int32();
    if (numLumps < 0) throw new Error(`Invalid WAD: negative numlumps ${numLumps}`);
    const directoryEnd = infoTableOfs + numLumps * DIRECTORY_ENTRY_SIZE;
    if (infoTableOfs < 0 || directoryEnd > bytes.length) {
      throw new Error(
        `Invalid WAD: directory [${infoTableOfs}, ${directoryEnd}) exceeds file length ${bytes.length}`,
      );
    }

    const lumps: LumpEntry[] = new Array(numLumps);
    const dir = new BinaryReader(bytes, infoTableOfs);
    for (let i = 0; i < numLumps; i++) {
      const filePos = dir.int32();
      const size = dir.int32();
      const name = dir.name(8);
      if (size < 0) throw new Error(`Invalid lump ${i} ("${name}"): negative size ${size}`);
      if (size > 0 && (filePos < 0 || filePos + size > bytes.length)) {
        throw new Error(
          `Invalid lump ${i} ("${name}"): data [${filePos}, ${filePos + size}) exceeds length ${bytes.length}`,
        );
      }
      lumps[i] = { index: i, name, filePos, size };
    }
    return new Wad(bytes, identification, lumps);
  }

  lumpData(entry: LumpEntry): Uint8Array {
    return this.bytes.subarray(entry.filePos, entry.filePos + entry.size);
  }

  find(name: string): LumpEntry | undefined {
    const i = this.byName.get(name);
    return i === undefined ? undefined : this.lumps[i];
  }

  has(name: string): boolean {
    return this.byName.has(name);
  }

  dataByName(name: string): Uint8Array {
    const entry = this.find(name);
    if (!entry) throw new Error(`Lump not found: ${name}`);
    return this.lumpData(entry);
  }

  dataByIndex(index: number): Uint8Array {
    const entry = this.lumps[index];
    if (!entry) throw new Error(`Lump index out of range: ${index}`);
    return this.lumpData(entry);
  }

  /**
   * Lumps strictly between a marker pair (`F_START`/`F_END`,
   * `S_START`/`S_END`), skipping the nested zero-size sub-range markers
   * Freedoom uses to delimit animation groups (`F1_START`, `S1_START`, …).
   */
  between(startMarker: string, endMarker: string): LumpEntry[] {
    const start = this.byName.get(startMarker);
    const end = this.byName.get(endMarker);
    if (start === undefined) throw new Error(`Start marker not found: ${startMarker}`);
    if (end === undefined) throw new Error(`End marker not found: ${endMarker}`);
    if (end < start) throw new Error(`${endMarker} appears before ${startMarker}`);
    return this.lumps
      .slice(start + 1, end)
      .filter((l) => l.size > 0 || !(l.name.endsWith("_START") || l.name.endsWith("_END")));
  }
}
