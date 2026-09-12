/**
 * WAD tool v2 report sections (task items 2 and 3): the R2-A9 accelerator
 * statistics and the R2-A12 bytecode budget. Appended to the v1 report
 * (`report.ts#buildReport`) by `cli.ts`, kept in a separate module so the
 * v1 report generator (and its existing tests) does not need to know about
 * the new emission machinery.
 */
import { AcceleratorStats } from "./accelerator.js";
import { bootloaderHashSteps, BytecodeBudget } from "./bytecodeBudget.js";
import { MapData } from "./mapExtract.js";

export interface SizeComparisonRow {
  label: string;
  totalWords: number;
}

export function buildV2Report(
  map: MapData,
  accelStats: AcceleratorStats,
  budget: BytecodeBudget,
  sizeComparison: SizeComparisonRow[],
  maxWords: number,
): string {
  const lines: string[] = [];
  const push = (s = "") => lines.push(s);

  push("## Cell -> subsector accelerator (R2-A9)");
  push();
  push(
    "For each blockmap cell, the list of subsectors whose geometry can overlap that cell " +
      "(RISKS.md R2-A9), replacing a full BSP descent (docs/spikes/S1.md §7 `bsp`: ~1 014 steps, " +
      "35% of an optimized tic) with a span lookup.",
  );
  push();
  push(
    "**Method**: a subsector's bounding box is the union of the vertex coordinates of its SEGS " +
      "(the vanilla node builder always closes a subsector's polygon with SEGS, wall segs and " +
      "internal partition segs alike). A subsector is listed for a cell whenever the two boxes " +
      "intersect.",
  );
  push();
  push(
    "**Why it is conservative**: for any polygon, every interior point's x and y coordinates lie " +
      "between the min and max of the polygon's own vertex coordinates (a point inside a polygon " +
      "is a convex combination of its vertices), so the polygon is always a subset of its own " +
      "vertex bounding box. If a point lies in both subsector S and blockmap cell C, then the " +
      "point lies in `bbox(S)` (by the fact above) and in `bbox(C)` (by construction), so the two " +
      "boxes intersect and S is listed for C. The accelerator can list extra subsectors whose bbox " +
      "reaches a cell without their polygon actually doing so, but it can never omit the true one. " +
      "`test/accelerator.test.ts` checks this by sampling points in every cell and comparing " +
      "against a ground-truth BSP descent (`accelerator.ts#locateSubsector`).",
  );
  push();
  push("| Metric | Value |");
  push("|---|---:|");
  push(`| Blockmap cells | ${accelStats.cells} |`);
  push(`| Total (cell, subsector) entries | ${accelStats.totalEntries} |`);
  push(`| Average subsectors per cell | ${accelStats.averageLength.toFixed(2)} |`);
  push(`| Max subsectors in one cell | ${accelStats.maxLength} |`);
  push(`| Cells resolved by a single subsector | ${accelStats.singleSubsectorCells} (${((100 * accelStats.singleSubsectorCells) / Math.max(1, accelStats.cells)).toFixed(1)}%) |`);
  push(`| Cells with no candidate subsector (outside all subsector bboxes) | ${accelStats.emptyCells} |`);
  push();

  push("## Bytecode budget (R2-A12)");
  push();
  push(
    "docs/spikes/S1.md §5.9 measured that a `const [felt252; N]` array costs exactly one word of " +
      "compiled bytecode per element, and that the bootloader rehashes the whole compiled program " +
      "on every proof segment for `2 340 + 14.7 * words` steps (docs/spikes/S0.md §5.2). This table " +
      "applies that 1-word-per-element rule to every array this tool emits (approximated uniformly " +
      "across `felt252`/`u32`, see `bytecodeBudget.ts`), for the `emit-config.json` layout actually " +
      `used to produce out/${map.name.toLowerCase()}.cairo.`,
  );
  push();
  push("| Array | Group | Layout | Felts | Words |");
  push("|---|---|---|---:|---:|");
  const sorted = [...budget.arrays].filter((a) => a.group !== "scalar").sort((a, b) => b.words - a.words);
  for (const a of sorted) {
    push(`| ${a.name} | ${a.group} | ${a.layout} | ${a.count} | ${a.words} |`);
  }
  const scalarWords = budget.arrays.filter((a) => a.group === "scalar").reduce((s, a) => s + a.words, 0);
  push(`| *(${budget.arrays.filter((a) => a.group === "scalar").length} scalar consts)* | scalar | - | - | ${scalarWords} |`);
  push();
  push(`**Total: ${budget.totalWords} words** (budget: ${maxWords}, ${budget.totalWords <= maxWords ? "OK" : "EXCEEDED"}).`);
  push();
  push(
    `At \`2 340 + 14.7 * words\`, this is ~${Math.round(bootloaderHashSteps(budget.totalWords)).toLocaleString("en-US")} steps of bootloader ` +
      "program-hashing cost per proof segment for the level-data constants alone (docs/G0.md D4 " +
      "budgets 16 000 words for the whole `doom_run` program; this tool's default `--max-words` is " +
      "a 12 000-word slice of that for level data).",
  );
  push();

  push("### Size vs. layout choice");
  push();
  push(
    "The same map, re-emitted with every group forced to `planar`, forced to `packed`, and with " +
      "the recommended per-group mix actually used above (`emit-config.json`):",
  );
  push();
  push("| Layout | Total words | Bootloader hash / segment |");
  push("|---|---:|---:|");
  for (const row of sizeComparison) {
    push(`| ${row.label} | ${row.totalWords} | ${Math.round(bootloaderHashSteps(row.totalWords)).toLocaleString("en-US")} |`);
  }
  push();

  return lines.join("\n") + "\n";
}
