import { LinedefFlag, NO_SIDEDEF, type LevelJson } from "../map/level.js";
import { mobjInfoFor } from "../map/mobjInfo.js";
import { bamToRadians, type InterpolatedView } from "../sim/snapshot.js";

/**
 * Debug top-down map view (roadmap P2.2, "vue 2D de debug").
 *
 * Drawn on the same 2D overlay as the HUD, in Doom's automap colour code:
 * one-sided walls white, floor-height changes brown, ceiling-height changes
 * yellow, specials (doors, lifts, exits) tinted, the player a green arrow. On
 * top of that it shows what the *renderer* needs to be debugged: the dynamic
 * sectors it rebuilds each frame, the scripted tour the stub sim walks, and
 * every mobj with its facing.
 */
export interface AutomapOptions {
  /** Map units visible across the height of the view. */
  zoom: number;
  /** Rotate the map so the player always faces up, as vanilla's automap can. */
  rotate: boolean;
  showThings: boolean;
  showPath: boolean;
}

export const DEFAULT_AUTOMAP: AutomapOptions = {
  zoom: 2400,
  rotate: false,
  showThings: true,
  showPath: true,
};

export function drawAutomap(
  ctx: CanvasRenderingContext2D,
  level: LevelJson,
  view: InterpolatedView,
  width: number,
  height: number,
  options: AutomapOptions,
  path: { x: number; y: number }[] = [],
  dynamicSectors?: ReadonlySet<number>,
): void {
  const scale = height / options.zoom;
  const angle = options.rotate ? -bamToRadians(view.angle) + Math.PI / 2 : 0;
  const ca = Math.cos(angle);
  const sa = Math.sin(angle);

  const project = (x: number, y: number): [number, number] => {
    const dx = (x - view.x) * scale;
    const dy = (y - view.y) * scale;
    const rx = dx * ca - dy * sa;
    const ry = dx * sa + dy * ca;
    // Screen y grows downwards; map y grows north.
    return [width / 2 + rx, height / 2 - ry];
  };

  ctx.save();
  ctx.fillStyle = "rgba(6, 6, 8, 0.94)";
  ctx.fillRect(0, 0, width, height);
  ctx.lineWidth = 1;

  // Sector fills for the sectors the renderer treats as dynamic.
  if (dynamicSectors) {
    ctx.strokeStyle = "rgba(80, 200, 255, 0.55)";
    ctx.lineWidth = 2.5;
    ctx.beginPath();
    for (const line of level.linedefs) {
      const front = line.frontSidedef === NO_SIDEDEF ? undefined : level.sidedefs[line.frontSidedef];
      const back = line.backSidedef === NO_SIDEDEF ? undefined : level.sidedefs[line.backSidedef];
      const touches =
        (front && dynamicSectors.has(front.sector)) || (back && dynamicSectors.has(back.sector));
      if (!touches) continue;
      const v1 = level.vertexes[line.startVertex]!;
      const v2 = level.vertexes[line.endVertex]!;
      const [x1, y1] = project(v1.x, v1.y);
      const [x2, y2] = project(v2.x, v2.y);
      ctx.moveTo(x1, y1);
      ctx.lineTo(x2, y2);
    }
    ctx.stroke();
    ctx.lineWidth = 1;
  }

  // Linedefs, grouped by colour so each colour is a single path.
  const groups: Record<string, [number, number, number, number][]> = {
    "#d8d2c4": [],
    "#8a5a2b": [],
    "#c8b93a": [],
    "#3b8ede": [],
    "#3a3a3a": [],
  };
  for (const line of level.linedefs) {
    const v1 = level.vertexes[line.startVertex];
    const v2 = level.vertexes[line.endVertex];
    if (!v1 || !v2) continue;
    const front = line.frontSidedef === NO_SIDEDEF ? undefined : level.sidedefs[line.frontSidedef];
    const back = line.backSidedef === NO_SIDEDEF ? undefined : level.sidedefs[line.backSidedef];
    let color: string;
    if (line.specialType !== 0) color = "#3b8ede";
    else if (!back) color = "#d8d2c4";
    else {
      const fs = level.sectors[front?.sector ?? 0];
      const bs = level.sectors[back.sector];
      if (!fs || !bs) color = "#3a3a3a";
      else if (fs.floorHeight !== bs.floorHeight) color = "#8a5a2b";
      else if (fs.ceilingHeight !== bs.ceilingHeight) color = "#c8b93a";
      else color = "#3a3a3a";
    }
    const [x1, y1] = project(v1.x, v1.y);
    const [x2, y2] = project(v2.x, v2.y);
    groups[color]!.push([x1, y1, x2, y2]);
  }
  for (const [color, segments] of Object.entries(groups)) {
    if (segments.length === 0) continue;
    ctx.strokeStyle = color;
    ctx.beginPath();
    for (const [x1, y1, x2, y2] of segments) {
      ctx.moveTo(x1, y1);
      ctx.lineTo(x2, y2);
    }
    ctx.stroke();
  }

  // The scripted tour.
  if (options.showPath && path.length > 1) {
    ctx.strokeStyle = "rgba(255, 150, 40, 0.8)";
    ctx.setLineDash([4, 4]);
    ctx.beginPath();
    path.forEach((p, i) => {
      const [x, y] = project(p.x, p.y);
      if (i === 0) ctx.moveTo(x, y);
      else ctx.lineTo(x, y);
    });
    ctx.stroke();
    ctx.setLineDash([]);
  }

  // Things.
  if (options.showThings) {
    for (const mo of view.mobjs) {
      const info = mobjInfoFor(mo.type);
      if (!info) continue;
      const [x, y] = project(mo.x, mo.y);
      if (x < -10 || y < -10 || x > width + 10 || y > height + 10) continue;
      const isMonster = info.height >= 56 && info.frames.length >= 2 && info.radius >= 16;
      ctx.fillStyle = isMonster ? "rgba(235, 77, 75, 0.85)" : "rgba(106, 176, 76, 0.7)";
      ctx.beginPath();
      ctx.arc(x, y, Math.max(1.5, info.radius * scale), 0, Math.PI * 2);
      ctx.fill();
    }
  }

  // Player arrow.
  const [px, py] = project(view.x, view.y);
  const facing = bamToRadians(view.angle) + angle;
  ctx.strokeStyle = "#6ab04c";
  ctx.lineWidth = 2;
  ctx.beginPath();
  const arm = 14;
  ctx.moveTo(px + Math.cos(facing) * arm, py - Math.sin(facing) * arm);
  ctx.lineTo(px + Math.cos(facing + 2.6) * arm * 0.8, py - Math.sin(facing + 2.6) * arm * 0.8);
  ctx.lineTo(px + Math.cos(facing - 2.6) * arm * 0.8, py - Math.sin(facing - 2.6) * arm * 0.8);
  ctx.closePath();
  ctx.stroke();

  // Legend.
  ctx.font = "11px ui-monospace, Menlo, monospace";
  ctx.fillStyle = "#8d8578";
  const legend = [
    `${level.map}  ${level.counts.linedefs} linedefs  ${level.counts.sectors} sectors`,
    `x ${view.x.toFixed(0)}  y ${view.y.toFixed(0)}  z ${view.viewZ.toFixed(0)}  sector ${view.sector}`,
    `zoom ${options.zoom} units   [+/-] zoom   [R] rotate`,
  ];
  legend.forEach((line, i) => ctx.fillText(line, 14, 20 + i * 14));
  ctx.restore();
}

/** Kept for the legend: which linedef flags the automap would normally hide. */
export const AUTOMAP_HIDDEN_FLAGS = LinedefFlag.NOT_ON_MAP;
