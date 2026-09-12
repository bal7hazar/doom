#!/usr/bin/env node
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { buildMapCairo } from "./cairoOutput.js";
import { buildMapJson } from "./jsonOutput.js";
import { extractAssetIndex, extractMap } from "./mapExtract.js";
import { buildReport } from "./report.js";
import { Wad } from "./wad.js";

interface Args {
  wad: string;
  map: string;
  out: string;
}

function parseArgs(argv: string[]): Args {
  let wad: string | undefined;
  let map: string | undefined;
  let out: string | undefined;
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const next = () => {
      i++;
      const v = argv[i];
      if (v === undefined) throw new Error(`Missing value for ${arg}`);
      return v;
    };
    switch (arg) {
      case "--wad":
        wad = next();
        break;
      case "--map":
        map = next();
        break;
      case "--out":
        out = next();
        break;
      default:
        throw new Error(`Unknown argument: ${arg}`);
    }
  }
  if (!wad || !map || !out) {
    throw new Error(
      "Usage: extract --wad <path/to/freedoom1.wad> --map <E1M1> --out <out/>",
    );
  }
  return { wad, map, out };
}

function main(): void {
  const { wad: wadPath, map: mapName, out: outDir } = parseArgs(process.argv.slice(2));

  console.error(`Loading ${wadPath} ...`);
  const wad = Wad.fromFile(resolve(wadPath));
  console.error(`Extracting map ${mapName} ...`);
  const map = extractMap(wad, mapName);
  const assets = extractAssetIndex(wad, map);

  const resolvedOut = resolve(outDir);
  mkdirSync(resolvedOut, { recursive: true });

  const mapNameLower = mapName.toLowerCase();
  const jsonPath = join(resolvedOut, `${mapNameLower}.json`);
  const cairoPath = join(resolvedOut, `${mapNameLower}.cairo`);
  // The report is a committed deliverable (Output C), not a build artifact:
  // it lives alongside the tool, one directory above `out/`.
  const reportPath = join(resolvedOut, "..", `REPORT-${mapNameLower}.md`);

  const json = buildMapJson(map, assets);
  writeFileSync(jsonPath, JSON.stringify(json, null, 2) + "\n");
  console.error(`Wrote ${jsonPath}`);

  const cairo = buildMapCairo(map);
  writeFileSync(cairoPath, cairo);
  console.error(`Wrote ${cairoPath}`);

  mkdirSync(dirname(reportPath), { recursive: true });
  const report = buildReport(map, assets);
  writeFileSync(reportPath, report);
  console.error(`Wrote ${reportPath}`);

  console.error("Done.");
}

main();
