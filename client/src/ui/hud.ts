import { spriteKey, WEAPON_SPRITES, type AssetStore } from "../assets/assetStore.js";
import type { AtlasRect } from "../assets/atlas.js";
import type { PspriteSnapshot, RenderSnapshot } from "../sim/snapshot.js";

/**
 * HUD overlay, drawn on a 2D canvas above the WebGL view (roadmap P2.2,
 * "HUD (santé, munitions, armes, clés)").
 *
 * Canvas 2D rather than a fifth GL pass on purpose: the HUD is a handful of
 * glyphs and one sprite per frame, it is never fill-rate bound, and keeping it
 * out of the GL state machine means the renderer's four programs stay the whole
 * renderer. Live Cairo snapshots carry both psprite slots: frame, offsets and
 * flash visibility follow the authoritative weapon FSM at 35 tics/s. Legacy
 * v1/demo snapshots retain the static fallback.
 */
export type WeaponNumbering = "demo" | "cairo";
/** Compact Cairo WeaponId differs from vanilla only after chaingun. */
export function hudWeapon(weapon: number, numbering: WeaponNumbering = "demo"): number {
  if (numbering === "demo") return weapon;
  return [0, 1, 2, 3, 7][weapon] ?? -1;
}
export function hudWeaponAmmo(weapon: number, numbering: WeaponNumbering = "demo"): number {
  return WEAPON_AMMO[hudWeapon(weapon, numbering)] ?? -1;
}

export interface HudState {
  visible: boolean;
}

const AMMO_LABELS = ["BULL", "SHEL", "CELL", "RCKT"] as const;
const KEY_COLORS = ["#3b6ede", "#d8c020", "#c0392b", "#3b6ede", "#d8c020", "#c0392b"] as const;
const KEY_LABELS = ["blue card", "yellow card", "red card", "blue skull", "yellow skull", "red skull"];

/** Caches one decoded weapon sprite as an `ImageBitmap`-like canvas. */
export class Hud {
  private readonly store: AssetStore;
  private readonly weaponCache = new Map<number, HTMLCanvasElement>();

  constructor(store: AssetStore) {
    this.store = store;
  }

  draw(ctx: CanvasRenderingContext2D, snapshot: RenderSnapshot, width: number, height: number, numbering: WeaponNumbering = "demo"): void {
    const p = snapshot.player;
    if (p.psprites) {
      for (const slot of p.psprites) this.drawPsprite(ctx, slot, width, height);
    } else this.drawWeapon(ctx, hudWeapon(p.weapon, numbering), width, height);

    // Status bar strip along the bottom.
    const barHeight = 56;
    ctx.save();
    ctx.fillStyle = "rgba(10, 9, 8, 0.72)";
    ctx.fillRect(0, height - barHeight, width, barHeight);
    ctx.strokeStyle = "rgba(90, 80, 70, 0.8)";
    ctx.beginPath();
    ctx.moveTo(0, height - barHeight + 0.5);
    ctx.lineTo(width, height - barHeight + 0.5);
    ctx.stroke();

    const y = height - barHeight + 22;
    ctx.textBaseline = "middle";

    this.bigNumber(ctx, `${p.health}%`, 24, y, "HEALTH", p.health <= 30 ? "#eb4d4b" : "#d8d2c4");
    this.bigNumber(ctx, `${p.armor}%`, 150, y, p.armorType === 2 ? "ARMOR II" : "ARMOR", "#6ab04c");

    // Ammo for the current weapon, then the full tally.
    const weaponAmmo = hudWeaponAmmo(p.weapon, numbering);
    const current = weaponAmmo >= 0 ? `${p.ammo[weaponAmmo]}` : "-";
    this.bigNumber(ctx, current, 280, y, "AMMO", "#d8c020");

    ctx.font = "11px ui-monospace, Menlo, monospace";
    ctx.fillStyle = "#8d8578";
    for (let i = 0; i < 4; i++) {
      ctx.fillText(
        `${AMMO_LABELS[i]} ${String(p.ammo[i]).padStart(3)}/${p.maxAmmo[i]}`,
        400,
        height - barHeight + 12 + i * 11,
      );
    }

    // Keys.
    for (let i = 0; i < 6; i++) {
      const held = (p.keys & (1 << i)) !== 0;
      ctx.globalAlpha = held ? 1 : 0.18;
      ctx.fillStyle = KEY_COLORS[i]!;
      const kx = 530 + (i % 3) * 16;
      const ky = height - barHeight + 12 + Math.floor(i / 3) * 18;
      if (i < 3) ctx.fillRect(kx, ky, 10, 14);
      else {
        ctx.beginPath();
        ctx.arc(kx + 5, ky + 7, 6, 0, Math.PI * 2);
        ctx.fill();
      }
      ctx.globalAlpha = 1;
    }
    ctx.fillStyle = "#5c564d";
    ctx.font = "9px ui-monospace, Menlo, monospace";
    ctx.fillText(KEY_LABELS.filter((_, i) => (p.keys & (1 << i)) !== 0).join(", ") || "no keys", 530, height - 8);

    // Level tally.
    ctx.font = "11px ui-monospace, Menlo, monospace";
    ctx.fillStyle = "#8d8578";
    const s = snapshot.stats;
    const mins = Math.floor(s.levelTime / 35 / 60);
    const secs = Math.floor((s.levelTime / 35) % 60);
    ctx.textAlign = "right";
    ctx.fillText(`K ${s.kills}/${s.totalKills}   I ${s.items}/${s.totalItems}   S ${s.secrets}/${s.totalSecrets}`, width - 16, height - barHeight + 16);
    ctx.fillText(`tic ${s.levelTime}   ${mins}:${String(secs).padStart(2, "0")}`, width - 16, height - barHeight + 32);
    ctx.textAlign = "left";
    ctx.restore();
  }

  private bigNumber(
    ctx: CanvasRenderingContext2D,
    value: string,
    x: number,
    y: number,
    label: string,
    color: string,
  ): void {
    ctx.font = "bold 26px ui-monospace, Menlo, monospace";
    ctx.fillStyle = color;
    ctx.fillText(value, x, y);
    ctx.font = "9px ui-monospace, Menlo, monospace";
    ctx.fillStyle = "#5c564d";
    ctx.fillText(label, x, y + 20);
  }

  private readonly pspriteCache = new Map<number, HTMLCanvasElement>();

  private drawPsprite(ctx: CanvasRenderingContext2D, slot: PspriteSnapshot, width: number, height: number): void {
    if (slot.state === 0) return;
    const name = this.store.cairoSprites?.names[slot.sprite];
    if (!name) throw new Error(`Unknown Cairo psprite ${slot.sprite}`);
    const frame = this.store.spriteDefs.get(name)?.frames[slot.frame & 0x7fff];
    const lump = frame?.lump[0];
    if (lump === undefined || lump < 0) throw new Error(`Missing Cairo psprite ${name} frame ${slot.frame}`);
    const rect = this.store.spriteAtlas.rects.get(spriteKey(lump));
    if (!rect) throw new Error(`Missing Cairo psprite atlas lump ${lump}`);
    let canvas = this.pspriteCache.get(lump);
    if (!canvas) {
      canvas = atlasRectToCanvas(this.store, rect, this.store.spriteAtlas, 0);
      this.pspriteCache.set(lump, canvas);
    }
    const scale = height / 200;
    // R_DrawPSprite uses a 320x200 view: sx is relative to its 160px
    // centre, while sy and signed WAD patch offsets give the top edge.
    const x = width / 2 + (slot.x / 65536 - 160 - rect.leftOffset) * scale;
    const y = (slot.y / 65536 - rect.topOffset) * scale;
    ctx.save();
    ctx.imageSmoothingEnabled = false;
    if (frame?.flip[0]) {
      ctx.translate(x + rect.width * scale, y); ctx.scale(-1, 1);
      ctx.drawImage(canvas, 0, 0, rect.width * scale, rect.height * scale);
    } else ctx.drawImage(canvas, x, y, rect.width * scale, rect.height * scale);
    ctx.restore();
  }

  private drawWeapon(
    ctx: CanvasRenderingContext2D,
    weapon: number,
    width: number,
    height: number,
  ): void {
    const canvas = this.weaponCanvas(weapon);
    if (!canvas) return;
    // Vanilla draws the weapon in a 320x200 frame anchored at the bottom
    // centre; scale that frame to the canvas height so it stays proportional.
    const scale = height / 200;
    const w = canvas.width * scale;
    const h = canvas.height * scale;
    ctx.imageSmoothingEnabled = false;
    ctx.drawImage(canvas, (width - w) / 2, height - h - 32 * scale, w, h);
  }

  private weaponCanvas(weapon: number): HTMLCanvasElement | null {
    const cached = this.weaponCache.get(weapon);
    if (cached) return cached;
    const name = WEAPON_SPRITES[weapon];
    if (!name) return null;
    const def = this.store.spriteDefs.get(name);
    const frame = def?.frames.find(Boolean);
    const lump = frame?.lump[0];
    if (lump === undefined || lump < 0) return null;
    const rect = this.store.spriteAtlas.rects.get(spriteKey(lump));
    if (!rect) return null;
    const canvas = atlasRectToCanvas(this.store, rect, this.store.spriteAtlas, 0);
    this.weaponCache.set(weapon, canvas);
    return canvas;
  }
}

/** `weapontype_t` → `ammotype_t`; −1 for the fist and chainsaw. */
const WEAPON_AMMO: Record<number, number> = {
  0: -1,
  1: 0,
  2: 1,
  3: 0,
  4: 3,
  5: 2,
  6: 2,
  7: -1,
  8: 1,
};

/**
 * Copies one atlas rectangle into an RGBA canvas through the palette, for the
 * 2D overlays (HUD weapon sprite, automap icons). Transparent texels get alpha
 * 0 rather than a colour key.
 */
export function atlasRectToCanvas(
  store: AssetStore,
  rect: AtlasRect,
  atlas: { width: number; data: Uint8Array },
  paletteIndex: number,
): HTMLCanvasElement {
  const canvas = document.createElement("canvas");
  canvas.width = rect.width;
  canvas.height = rect.height;
  const ctx = canvas.getContext("2d");
  if (!ctx) return canvas;
  const image = ctx.createImageData(rect.width, rect.height);
  const palette = store.playpal.rgba[paletteIndex] ?? store.playpal.rgba[0]!;
  for (let y = 0; y < rect.height; y++) {
    for (let x = 0; x < rect.width; x++) {
      const src = ((rect.y + y) * atlas.width + (rect.x + x)) * 2;
      const dst = (y * rect.width + x) * 4;
      const index = atlas.data[src]!;
      const covered = atlas.data[src + 1]! > 0;
      image.data[dst] = palette[index * 4]!;
      image.data[dst + 1] = palette[index * 4 + 1]!;
      image.data[dst + 2] = palette[index * 4 + 2]!;
      image.data[dst + 3] = covered ? 255 : 0;
    }
  }
  ctx.putImageData(image, 0, 0);
  return canvas;
}
