import { selectSpriteLump } from "@hellproof/wad";
import { spriteKey, type AssetStore } from "../assets/assetStore.js";
import type { AtlasRect } from "../assets/atlas.js";
import type { CairoFrame } from "../sim/cairoSnapshot.js";
import type { InterpolatedMobj } from "../sim/snapshot.js";

export interface ActorAppearance { state: number; sprite: number; frame: number; flags: number }
export interface CairoAppearance {
  tic: number;
  viewMobjId: number;
  actors: ReadonlyMap<number, ActorAppearance>;
}
export function cairoAppearance(frame: CairoFrame, viewMobjId: number): CairoAppearance {
  const raw = new Map(frame.actors.map(actor => [actor.id, actor]));
  const actors = new Map<number, ActorAppearance>();
  for (const actor of frame.snapshot.mobjs) {
    const value = raw.get(actor.id);
    if (!value || actors.has(actor.id)) throw new Error(`Inconsistent Cairo appearance for actor ${actor.id}`);
    actors.set(actor.id, { state: value.state, sprite: value.sprite, frame: actor.frame, flags: value.flags });
  }
  if (raw.size !== actors.size) throw new Error("Cairo appearance count differs from the frame");
  return { tic: frame.snapshot.tic, viewMobjId, actors };
}
export function assertAppearanceTic(appearance: CairoAppearance, tic: number): void {
  if (appearance.tic !== tic) throw new Error(`Cairo appearance tic ${appearance.tic} differs from render tic ${tic}`);
}
export interface CairoSpritePick { rect: AtlasRect; flip: boolean; fullbright: boolean; shadow: boolean; prefix: string }
/** No spawn-family/frame fallback: a missing resource is a rendering error. */
export function selectCairoSprite(store: Pick<AssetStore, "cairoSprites" | "spriteDefs" | "spriteAtlas">,
  appearance: CairoAppearance, actor: InterpolatedMobj, viewToThingBam: number): CairoSpritePick {
  const data = appearance.actors.get(actor.id);
  if (!data || data.frame !== actor.frame) throw new Error(`Missing or stale Cairo actor ${actor.id}`);
  const prefix = store.cairoSprites?.names[data.sprite];
  if (!prefix) throw new Error(`Unknown Cairo sprite ${data.sprite} (actor ${actor.id})`);
  const frame = store.spriteDefs.get(prefix)?.frames[data.frame];
  if (!frame) throw new Error(`Missing Cairo sprite frame ${prefix}:${data.frame} (actor ${actor.id})`);
  const selected = selectSpriteLump(frame, viewToThingBam, actor.angle);
  if (!selected) throw new Error(`Missing Cairo sprite rotation ${prefix}:${data.frame} (actor ${actor.id})`);
  const rect = store.spriteAtlas.rects.get(spriteKey(selected.lump));
  if (!rect) throw new Error(`Missing Cairo sprite atlas lump ${selected.lump} (actor ${actor.id})`);
  return { rect, flip: selected.flip, prefix, fullbright: (data.flags & 1) !== 0, shadow: (data.flags & 2) !== 0 };
}
