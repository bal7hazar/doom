#!/usr/bin/env node
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { computeCellSubsectors } from "./accelerator.js";
import { ArrayEntry, assertBudget, BudgetExceededError, computeBytecodeBudget } from "./bytecodeBudget.js";
import { buildMapCairo } from "./cairoOutput.js";
import { ALL_PACKED_CONFIG, ALL_PLANAR_CONFIG, DEFAULT_EMIT_CONFIG, EmitConfig, resolveEmitConfig } from "./emitConfig.js";
import { buildMapJson } from "./jsonOutput.js";
import { extractAssetIndex, extractMap, MapData } from "./mapExtract.js";
import { buildReport } from "./report.js";
import { buildV2Report, SizeComparisonRow } from "./reportV2.js";
import { Wad } from "./wad.js";

const MODULE_DIR = dirname(fileURLToPath(import.meta.url));
const DEFAULT_CONFIG_PATH = join(MODULE_DIR, "..", "emit-config.json");
const DEFAULT_MAX_WORDS = 12_000;

interface Args {
  wad: string;
  map: string;
  out: string;
  config: string;
  maxWords: number;
}

function parseArgs(argv: string[]): Args {
  let wad: string | undefined;
  let map: string | undefined;
  let out: string | undefined;
  let config = DEFAULT_CONFIG_PATH;
  let maxWords = DEFAULT_MAX_WORDS;
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
      case "--config":
        config = resolve(next());
        break;
      case "--max-words": {
        const raw = next();
        const parsed = Number(raw);
        if (!Number.isFinite(parsed) || parsed <= 0) {
          throw new Error(`--max-words must be a positive number, got ${JSON.stringify(raw)}`);
        }
        maxWords = parsed;
        break;
      }
      default:
        throw new Error(`Unknown argument: ${arg}`);
    }
  }
  if (!wad || !map || !out) {
    throw new Error(
      "Usage: extract --wad <path/to/freedoom1.wad> --map <E1M1> --out <out/> [--config <emit-config.json>] [--max-words <n>]",
    );
  }
  return { wad, map, out, config, maxWords };
}

function loadEmitConfig(path: string): EmitConfig {
  if (!existsSync(path)) {
    console.error(`No emit-config.json at ${path}, using built-in defaults.`);
    return DEFAULT_EMIT_CONFIG;
  }
  const raw = JSON.parse(readFileSync(path, "utf8")) as Record<string, unknown>;
  return resolveEmitConfig(raw);
}

/** Total bytecode words for `map` re-emitted with every group forced to the same layout. */
function totalWordsFor(map: MapData, config: EmitConfig): number {
  const { arrays } = buildMapCairo(map, config);
  return computeBytecodeBudget(arrays as ArrayEntry[]).totalWords;
}

function main(): void {
  const { wad: wadPath, map: mapName, out: outDir, config: configPath, maxWords } = parseArgs(process.argv.slice(2));

  console.error(`Loading ${wadPath} ...`);
  const wad = Wad.fromFile(resolve(wadPath));
  console.error(`Extracting map ${mapName} ...`);
  const map = extractMap(wad, mapName);
  const assets = extractAssetIndex(wad, map);

  const config = loadEmitConfig(configPath);
  console.error(`Using emit-config from ${configPath}`);

  const resolvedOut = resolve(outDir);
  mkdirSync(resolvedOut, { recursive: true });

  const mapNameLower = mapName.toLowerCase();
  const jsonPath = join(resolvedOut, `${mapNameLower}.json`);
  const cairoPath = join(resolvedOut, `${mapNameLower}.cairo`);
  // The report is a committed deliverable (Output C), not a build artifact:
  // it lives alongside the tool, one directory above `out/`.
  const reportPath = join(resolvedOut, "..", `REPORT-${mapNameLower}.md`);

  const { spans: accelSpans, stats: accelStats } = computeCellSubsectors(map);
  const json = buildMapJson(map, assets, accelSpans);
  writeFileSync(jsonPath, JSON.stringify(json, null, 2) + "\n");
  console.error(`Wrote ${jsonPath}`);

  const cairoEmission = buildMapCairo(map, config);
  writeFileSync(cairoPath, cairoEmission.source);
  console.error(`Wrote ${cairoPath}`);

  const budget = computeBytecodeBudget(cairoEmission.arrays);
  console.error(`Cairo constants: ${budget.totalWords} bytecode words (budget: ${maxWords})`);

  const sizeComparison: SizeComparisonRow[] = [
    { label: "all planar", totalWords: totalWordsFor(map, ALL_PLANAR_CONFIG) },
    { label: "all packed", totalWords: totalWordsFor(map, ALL_PACKED_CONFIG) },
    { label: "recommended mix (emit-config.json)", totalWords: budget.totalWords },
  ];

  mkdirSync(dirname(reportPath), { recursive: true });
  const report =
    buildReport(map, assets) + "\n" + buildV2Report(map, accelStats, budget, sizeComparison, maxWords);
  writeFileSync(reportPath, report);
  console.error(`Wrote ${reportPath}`);

  try {
    assertBudget(budget, maxWords);
  } catch (err) {
    if (err instanceof BudgetExceededError) {
      console.error(`ERROR: ${err.message}`);
      process.exitCode = 1;
      return;
    }
    throw err;
  }

  console.error("Done.");
}

main();
