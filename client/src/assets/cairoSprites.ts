// The data remains in its original GPL-2.0-only source. These URLs distribute
// that asset with its license; no Doom state machine is copied into the client.
import sourceUrl from "../../../cairo/doom/doom_things/generated/sprites.json?url";
import licenseUrl from "../../../LICENSES/GPL-2.0-only.txt?url";

export interface CairoSpriteNames {
  names: readonly string[];
  sourceUrl: string;
  licenseUrl: string;
}
export function parseCairoSpriteNames(value: unknown): readonly string[] {
  const names = (value as { sprites?: unknown } | null)?.sprites;
  if (!Array.isArray(names) || names.length !== 49 || new Set(names).size !== names.length ||
    !names.every(name => typeof name === "string" && /^[A-Z0-9]{4}$/.test(name))) {
    throw new Error("Unsupported Cairo sprite-name table");
  }
  return Object.freeze([...names]) as readonly string[];
}
export async function loadCairoSpriteNames(): Promise<CairoSpriteNames> {
  const response = await fetch(sourceUrl);
  if (!response.ok) throw new Error(`Cairo sprite table: HTTP ${response.status}`);
  return { names: parseCairoSpriteNames(await response.json()), sourceUrl, licenseUrl };
}
