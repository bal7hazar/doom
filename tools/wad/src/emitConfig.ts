/**
 * WAD tool v2 (roadmap G0.md D4 / RISKS.md R2-A9, R2-A12): configurable
 * layout of the Cairo-emitted `const` arrays.
 *
 * docs/spikes/S1.md §5.3 and §5.9 establish that the right layout for a WAD
 * field depends on how often the Cairo core reads it per tic, not on
 * principle:
 *
 *   - "planar" (struct-of-arrays: one `const` array per field) costs 11
 *     steps per read regardless of array size (§5.1) and is the cheapest
 *     representation for fields read tens of times per tic - but it spends
 *     one felt of *bytecode* per field per record, and bytecode is a
 *     per-segment bootloader cost of ~14.7 steps/word (§5.9, S0.md).
 *   - "packed" (one felt252 per record, fields bit-packed) costs more per
 *     read (a handful of divisions/shifts) but a fraction of the bytecode
 *     words, which wins decisively for large tables read only a few times
 *     per tic (REJECT, THINGS, cold linedef/sidedef metadata).
 *
 * The exact rule (S1 §5.9): pack a field if
 *   `14.7 * (felts saved by packing) / K > (extra steps per access) * (accesses per tic)`
 * At K ~= 100 tics/segment this favors planar for hot data and packed for
 * cold, bulky tables - which is what `DEFAULT_EMIT_CONFIG` below encodes.
 *
 * `tools/wad/emit-config.json` (loaded by `loadEmitConfig`) lets a caller
 * override the layout per group without touching code; any group omitted
 * from the file falls back to the default here.
 */

export type Layout = "planar" | "packed";

/**
 * Every independently toggleable group of Cairo constants emitted by
 * `cairoOutput.ts`. Names mirror the WAD lump the data derives from, not the
 * literal PascalCase Cairo const names (see cairoOutput.ts for those).
 */
export const EMIT_GROUPS = [
  // --- hot: read tens of times per tic (S1 §5.3, §7) -----------------------
  "vertices",
  "nodePredicates",
  "nodeChildren",
  "linedefPredicates",
  "linedefBBox",
  "linedefFlags",
  "linedefSides",
  "sectorHeights",
  "blockmap",
  "accelerator",
  // --- cold: read a handful of times per tic, or only on trigger (S1 §5.9) -
  "reject",
  "things",
  "linedefSpecial",
  "sidedefSector",
  "subsectorSector",
  "sectorMeta",
] as const;

export type EmitGroup = (typeof EMIT_GROUPS)[number];

export type EmitConfig = Record<EmitGroup, Layout>;

/**
 * S1's default recommendation (docs/spikes/S1.md §7 "Règles transverses" and
 * the "programme maigre" table in §5.9), as spelled out in the WAD v2 task:
 *
 *   hot / planar:  vertices, node partition predicates, linedef half-plane
 *                  predicates and flags, sector heights, blockmap
 *   cold / packed: REJECT, things, linedef tags/specials, sidedef -> sector
 *
 * Groups the task text does not name explicitly are assigned the layout
 * S1's own detailed sizing table uses for the closest matching data:
 *
 *   - `nodeChildren` (planar): read at the same point in the hot path as
 *     `nodePredicates` (every BSP descent); S1 §5.9's lean-program estimate
 *     keeps `N_C0`/`N_C1` alongside `N_AB`/`N_BB`/`N_CB`.
 *   - `linedefBBox`, `linedefSides` (packed): S1 §5.9's lean-program
 *     estimate bundles the linedef bbox with its front/back sector lookup
 *     into "bbox + drapeaux + secteurs packés (3 felts/ligne)" - read only
 *     for the 2-5 lines/tic that survive the two rejects, not the tens of
 *     half-plane reads per tic that justify keeping the predicate itself
 *     planar.
 *   - `accelerator` (packed): the R2-A9 candidate-subsector list is read
 *     once per moving mobj per tic (a handful of times), the same
 *     frequency class as `sidedefSector`/`subsectorSector`; by S1's rule
 *     (§5.9: pack when `14.7 * felts_saved / K > extra_steps * accesses`),
 *     bit-packing 8 indices/felt saves ~2 000 felts on E1M1 for a few
 *     extra steps per lookup, which wins at any realistic K.
 *   - `subsectorSector`, `sectorMeta` (packed): read a handful of times per
 *     tic at most, like `sidedefSector`.
 */
export const DEFAULT_EMIT_CONFIG: EmitConfig = {
  vertices: "planar",
  nodePredicates: "planar",
  nodeChildren: "planar",
  linedefPredicates: "planar",
  linedefBBox: "packed",
  linedefFlags: "planar",
  linedefSides: "packed",
  sectorHeights: "planar",
  blockmap: "planar",
  accelerator: "packed",

  reject: "packed",
  things: "packed",
  linedefSpecial: "packed",
  sidedefSector: "packed",
  subsectorSector: "packed",
  sectorMeta: "packed",
};

export const ALL_PLANAR_CONFIG: EmitConfig = Object.fromEntries(
  EMIT_GROUPS.map((g) => [g, "planar" as Layout]),
) as EmitConfig;

export const ALL_PACKED_CONFIG: EmitConfig = Object.fromEntries(
  EMIT_GROUPS.map((g) => [g, "packed" as Layout]),
) as EmitConfig;

function isLayout(v: unknown): v is Layout {
  return v === "planar" || v === "packed";
}

/**
 * Merges a partial `{group: "planar"|"packed"}` object (as parsed from
 * `emit-config.json`) onto `DEFAULT_EMIT_CONFIG`. Unknown group names or
 * invalid layout values throw, so a typo in the config file fails loudly
 * instead of silently keeping the default. Keys starting with `$` or `_`
 * (e.g. a `"$schema"` or `"_comment"` documentation key) are ignored.
 */
export function resolveEmitConfig(overrides: Record<string, unknown> | undefined): EmitConfig {
  const config: EmitConfig = { ...DEFAULT_EMIT_CONFIG };
  if (!overrides) return config;
  for (const [key, value] of Object.entries(overrides)) {
    if (key.startsWith("$") || key.startsWith("_")) continue;
    if (!(EMIT_GROUPS as readonly string[]).includes(key)) {
      throw new Error(
        `emit-config: unknown group "${key}". Valid groups: ${EMIT_GROUPS.join(", ")}`,
      );
    }
    if (!isLayout(value)) {
      throw new Error(`emit-config: group "${key}" has invalid layout ${JSON.stringify(value)} (want "planar" or "packed")`);
    }
    config[key as EmitGroup] = value;
  }
  return config;
}
