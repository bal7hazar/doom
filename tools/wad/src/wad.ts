import { readFileSync } from "node:fs";
import { BinaryReader } from "./binary.js";

/**
 * WAD header (12 bytes):
 *   identification : 4 bytes ASCII, "IWAD" or "PWAD"
 *   numlumps       : int32 LE, number of entries in the lump directory
 *   infotableofs   : int32 LE, byte offset of the lump directory
 */
export interface WadHeader {
  identification: "IWAD" | "PWAD";
  numLumps: number;
  infoTableOfs: number;
}

/**
 * One 16-byte lump directory entry:
 *   filepos : int32 LE, byte offset of the lump's data in the file
 *   size    : int32 LE, byte length of the lump's data (0 for marker lumps)
 *   name    : 8 bytes ASCII, NUL-padded, uppercase lump name
 */
export interface LumpEntry {
  /** Index of this lump in the directory (also its identity for "Nth lump named X" lookups). */
  index: number;
  name: string;
  filePos: number;
  size: number;
}

const HEADER_SIZE = 12;
const DIRECTORY_ENTRY_SIZE = 16;

export class Wad {
  readonly buffer: Buffer;
  readonly header: WadHeader;
  readonly lumps: LumpEntry[];

  private constructor(buffer: Buffer, header: WadHeader, lumps: LumpEntry[]) {
    this.buffer = buffer;
    this.header = header;
    this.lumps = lumps;
  }

  static fromFile(path: string): Wad {
    return Wad.fromBuffer(readFileSync(path));
  }

  static fromBuffer(buffer: Buffer): Wad {
    if (buffer.length < HEADER_SIZE) {
      throw new Error(`Not a WAD file: too short (${buffer.length} bytes)`);
    }
    const r = new BinaryReader(buffer);
    const identification = r.name(4);
    if (identification !== "IWAD" && identification !== "PWAD") {
      throw new Error(`Not a WAD file: bad identification "${identification}"`);
    }
    const numLumps = r.int32();
    const infoTableOfs = r.int32();
    if (numLumps < 0) {
      throw new Error(`Invalid WAD: negative numlumps ${numLumps}`);
    }
    const directoryEnd = infoTableOfs + numLumps * DIRECTORY_ENTRY_SIZE;
    if (infoTableOfs < 0 || directoryEnd > buffer.length) {
      throw new Error(
        `Invalid WAD: directory [${infoTableOfs}, ${directoryEnd}) exceeds file length ${buffer.length}`,
      );
    }

    const lumps: LumpEntry[] = [];
    const dirReader = new BinaryReader(buffer, infoTableOfs);
    for (let i = 0; i < numLumps; i++) {
      const filePos = dirReader.int32();
      const size = dirReader.int32();
      const name = dirReader.name(8);
      if (size < 0) {
        throw new Error(`Invalid lump directory entry ${i} ("${name}"): negative size ${size}`);
      }
      // Marker lumps (size 0) may legitimately point past EOF-ish offsets in some
      // tools; only validate bounds for lumps that actually carry data.
      if (size > 0 && (filePos < 0 || filePos + size > buffer.length)) {
        throw new Error(
          `Invalid lump directory entry ${i} ("${name}"): data [${filePos}, ${filePos + size}) ` +
            `exceeds file length ${buffer.length}`,
        );
      }
      lumps.push({ index: i, name, filePos, size });
    }

    return new Wad(buffer, { identification, numLumps, infoTableOfs }, lumps);
  }

  /** Raw bytes of a lump, by directory index. */
  lumpData(entry: LumpEntry): Buffer {
    return this.buffer.subarray(entry.filePos, entry.filePos + entry.size);
  }

  /** First lump with this name (vanilla WADs may repeat names; last-wins for PWAD overrides is a
   * convention we do not need here since only a single IWAD is read). */
  findLump(name: string): LumpEntry | undefined {
    return this.lumps.find((l) => l.name === name);
  }

  /** All lumps with this exact name, in directory order. */
  findAllLumps(name: string): LumpEntry[] {
    return this.lumps.filter((l) => l.name === name);
  }

  lumpDataByName(name: string): Buffer {
    const entry = this.findLump(name);
    if (!entry) throw new Error(`Lump not found: ${name}`);
    return this.lumpData(entry);
  }

  /**
   * Returns the `count` lumps immediately following `afterName` in directory
   * order (e.g. the ten lumps following a map marker like "E1M1"). Vanilla
   * map lumps always follow the marker directly, in a fixed order.
   */
  lumpsAfter(afterName: string, count: number): LumpEntry[] {
    const idx = this.lumps.findIndex((l) => l.name === afterName);
    if (idx === -1) throw new Error(`Marker lump not found: ${afterName}`);
    const slice = this.lumps.slice(idx + 1, idx + 1 + count);
    if (slice.length < count) {
      throw new Error(
        `Expected ${count} lumps after "${afterName}", but only ${slice.length} remain in the directory`,
      );
    }
    return slice;
  }

  /**
   * Collects the lumps strictly between a `startMarker`/`endMarker` pair of
   * zero-size marker lumps (used for flats F_START/F_END and sprites
   * S_START/S_END). Nested sub-range markers (e.g. F1_START/F1_END used by
   * Freedoom to delimit animation sequences) are skipped: they carry no data
   * of their own (size 0) and are not real flats/sprites.
   */
  lumpsBetweenMarkers(startMarker: string, endMarker: string): LumpEntry[] {
    const startIdx = this.lumps.findIndex((l) => l.name === startMarker);
    const endIdx = this.lumps.findIndex((l) => l.name === endMarker);
    if (startIdx === -1) throw new Error(`Start marker not found: ${startMarker}`);
    if (endIdx === -1) throw new Error(`End marker not found: ${endMarker}`);
    if (endIdx < startIdx) {
      throw new Error(`End marker ${endMarker} appears before start marker ${startMarker}`);
    }
    return this.lumps
      .slice(startIdx + 1, endIdx)
      .filter((l) => l.size > 0 || !isMarkerName(l.name));
  }
}

/** Heuristic: WAD "sub-range" marker lumps are zero-size and end in _START/_END. */
function isMarkerName(name: string): boolean {
  return name.endsWith("_START") || name.endsWith("_END");
}
