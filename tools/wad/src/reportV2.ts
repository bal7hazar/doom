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

  push("## Cell -> subsector accelerator (R2-A9, docs/DECISIONS.md D22)");
  push();
  push(
    "For each blockmap cell, `CELL_NODE` (the deepest BSP node whose region contains the whole " +
      "cell) and, optionally, the list of subsectors whose region can overlap that cell " +
      "(RISKS.md R2-A9), both replacing a full BSP descent from the root (docs/spikes/S1.md §7 " +
      "`bsp`: ~1 014 steps, 35% of an optimized tic) with a shorter one, or a span lookup.",
  );
  push();
  push(
    "**Method**: both are built from the map's BSP **regions**, exactly as " +
      "`cairo/doom/doom_map/scripts/gen_level.py` builds `doom_map`'s own compiled accelerator - " +
      "descend from the root, recursing into both children whenever the four corners of the query " +
      "box straddle a node's partition (a partition is linear, so its sign over an axis-aligned " +
      "box is decided entirely by the corners). `CELL_NODE` stops the descent the moment the box " +
      "no longer straddles; the candidate list keeps going to every reachable leaf. Both are exact " +
      "(a subsector's region either meets the cell or it doesn't), hence conservative, and need no " +
      "SEGS at all.",
  );
  push();
  push(
    "**This replaces an earlier seg-bbox method that was not conservative**: it derived a " +
      "subsector's extent from the bounding box of its SEGS' vertices, on the assumption that a " +
      "vanilla node builder always closes a subsector's polygon with SEGS. That premise is false - " +
      "a vanilla builder emits no minisegs at all - so a subsector's actual BSP region routinely " +
      "reached far outside the box of its own segs (e.g. E1M1 subsector 630's segs span " +
      "y in [-36, 4] while its region reaches y = -214), and the seg-bbox candidate list omitted " +
      "the true subsector for 81 of 200 lattice-sampled points on E1M1. See `accelerator.ts`'s " +
      "module header for the full history, and `test/accelerator.test.ts` for the fixed " +
      "conservativeness test: a dense lattice over every cell, checked against an independent BSP " +
      "descent, with no \"is this real geometry\" skip logic (a region-based accelerator has no " +
      "void - the BSP tiles the whole plane).",
  );
  push();
  push("| Metric | Value |");
  push("|---|---:|");
  push(`| Blockmap cells | ${accelStats.cells} |`);
  push(`| Mean BSP descent depth from the root | ${accelStats.meanDepthFromRoot.toFixed(2)} |`);
  push(`| Mean BSP descent depth from \`CELL_NODE\` | ${accelStats.meanDepthFromCellNode.toFixed(2)} |`);
  push(`| Candidate-list total (cell, subsector) entries | ${accelStats.totalEntries} |`);
  push(`| Average subsectors per cell (candidate list) | ${accelStats.averageLength.toFixed(2)} |`);
  push(`| Max subsectors in one cell (candidate list) | ${accelStats.maxLength} |`);
  push(`| Cells resolved by a single subsector (candidate list) | ${accelStats.singleSubsectorCells} (${((100 * accelStats.singleSubsectorCells) / Math.max(1, accelStats.cells)).toFixed(1)}%) |`);
  push();
  push(
    "The candidate-list arrays are informational here (`test/accelerator.test.ts` exercises them " +
      "either way); the Cairo emitter leaves them out by default " +
      "(`emitConfig.ts#emitAccelCandidates`, D22) since `CELL_NODE` alone answers the same query " +
      "exactly.",
  );
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
