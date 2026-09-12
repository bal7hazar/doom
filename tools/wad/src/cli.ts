#!/usr/bin/env node
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { computeCellAccelerator } from "./accelerator.js";
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

/** R2-A12 bytecode-budget-exceeded exit code, distinct from a generic CLI/parse error (1). */
export const EXIT_BUDGET_EXCEEDED = 3;

export interface Args {
  wad: string;
  map: string;
  out: string;
  config: string;
  maxWords: number;
  /** Where to write REPORT-<map>.md; omitted entirely when not given (see --report below). */
  report: string | undefined;
  noBudgetGate: boolean;
}

export function parseArgs(argv: string[]): Args {
  let wad: string | undefined;
  let map: string | undefined;
  let out: string | undefined;
  let config = DEFAULT_CONFIG_PATH;
  let maxWords = DEFAULT_MAX_WORDS;
  let report: string | undefined;
  let noBudgetGate = false;
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
      case "--report":
        report = resolve(next());
        break;
      case "--no-budget-gate":
        noBudgetGate = true;
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
      "Usage: extract --wad <path/to/freedoom1.wad> --map <E1M1> --out <out/> " +
        "[--config <emit-config.json>] [--max-words <n>] [--report <path>] [--no-budget-gate]",
    );
  }
  return { wad, map, out, config, maxWords, report, noBudgetGate };
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

export function main(): void {
  const {
    wad: wadPath,
    map: mapName,
    out: outDir,
    config: configPath,
    maxWords,
    report: reportPath,
    noBudgetGate,
  } = parseArgs(process.argv.slice(2));

  console.error(`Loading ${wadPath} ...`);
  // Reading the file is the CLI's job, not the library's: `Wad.fromBytes`
  // (the library entry point) takes bytes it never had to fetch itself, so
  // it works unchanged given bytes from `fetch()` in the browser.
  const wad = Wad.fromBytes(readFileSync(resolve(wadPath)));
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

  const { spans: accelSpans, stats: accelStats } = computeCellAccelerator(map);
  const json = buildMapJson(map, assets, accelSpans);
  writeFileSync(jsonPath, JSON.stringify(json, null, 2) + "\n");
  console.error(`Wrote ${jsonPath}`);

  const cairoEmission = buildMapCairo(map, config);
  writeFileSync(cairoPath, cairoEmission.source);
  console.error(`Wrote ${cairoPath}`);

  const budget = computeBytecodeBudget(cairoEmission.arrays);
  console.error(`Cairo constants: ${budget.totalWords} bytecode words (budget: ${maxWords})`);

  // Output C (REPORT-<map>.md) is a committed deliverable, not a build
  // artifact - `--out` must never be able to overwrite it, so the report is
  // only ever written to an explicit `--report <path>`, entirely decoupled
  // from `--out` (previously it was derived as `<out>/../REPORT-<map>.md`,
  // which silently overwrote tools/wad/REPORT-<map>.md whenever `--out` was
  // `tools/wad/out`).
  if (reportPath) {
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
  } else {
    console.error("No --report <path> given; skipping REPORT.md generation.");
  }

  // R2-A12 bytecode budget gate: JSON/Cairo/report are already written above,
  // so a budget failure still leaves every artifact on disk to inspect.
  // --no-budget-gate keeps the exit code 0 (still logging the overrun) for
  // callers (e.g. client/scripts/prepare-assets.sh) that only care about the
  // JSON output and treat the Cairo budget as informational.
  if (noBudgetGate) {
    if (budget.totalWords > maxWords) {
      console.error(
        `NOTE: bytecode budget exceeded (${budget.totalWords} > ${maxWords} words) but --no-budget-gate ` +
          "was passed; not failing.",
      );
    }
    console.error("Done.");
    return;
  }

  try {
    assertBudget(budget, maxWords);
  } catch (err) {
    if (err instanceof BudgetExceededError) {
      console.error(`ERROR: ${err.message}`);
      process.exitCode = EXIT_BUDGET_EXCEEDED;
      return;
    }
    throw err;
  }

  console.error("Done.");
}

// Only run when executed directly (`tsx src/cli.ts` / `npm run extract`),
// not when `parseArgs`/`main` are imported for testing.
const isMain = process.argv[1] === fileURLToPath(import.meta.url);
if (isMain) {
  main();
}
