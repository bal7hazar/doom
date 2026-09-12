import { selectSpriteLump } from "@hellproof/wad";
import {
  flatKey,
  spriteKey,
  texKey,
  textureSizeLookup,
  type AssetStore,
} from "../assets/assetStore.js";
import type { AtlasRect } from "../assets/atlas.js";
import { buildSubsectorPolygons, fanTriangulate } from "../map/bsp.js";
import { findDynamicSectors, SKY_FLAT, type LevelJson } from "../map/level.js";
import { mobjInfoFor } from "../map/mobjInfo.js";
import { buildWallQuads, quadCorners, type WallQuad } from "../map/walls.js";
import { MobjRenderFlag, pointToAngle, type InterpolatedView } from "../sim/snapshot.js";
import { cameraBasis, multiply, perspective, pitchRadians, viewMatrix } from "./camera.js";
import {
  bindInterleaved,
  compileProgram,
  createAtlasTexture,
  createR8Texture,
  createRgba32fTexture,
  createRgba8Texture,
  VertexScratch,
} from "./glutil.js";
import {
  FLAT_FRAG,
  FLAT_VERT,
  SKY_FRAG,
  SKY_VERT,
  SPRITE_FRAG,
  SPRITE_VERT,
  WALL_FRAG,
  WALL_VERT,
} from "./shaders.js";

const WALL_STRIDE = 11; // pos3 uv2 rect4 sector1 lightDelta1
const FLAT_STRIDE = 8; // pos2 sector1 kind1 rect4
const SPRITE_STRIDE = 11; // pos3 uv2 rect4 light1 flags1

export interface RenderOptions {
  /** Debug view: ignore textures, show only the light ramp. */
  flatShading: boolean;
  /** Palette index (0 = normal, 1–8 damage red, 9–12 bonus gold, 13 radiation). */
  paletteRow: number;
  /** Force a colormap row (32 = invulnerability inverse); −1 = normal shading. */
  forceColormap: number;
}

export interface RenderStats {
  wallQuads: number;
  dynamicWallQuads: number;
  flatTriangles: number;
  sprites: number;
  drawCalls: number;
  cpuMs: number;
}

/**
 * WebGL2 renderer for a Doom level (roadmap P2.2).
 *
 * ## Why raw WebGL2 and no library
 *
 * The whole renderer is four programs and five buffers. Doom's look depends on
 * doing texture addressing *in palette index space* and resolving colour
 * through `COLORMAP`/`PLAYPAL` at the last moment (see `shaders.ts`), which no
 * scene-graph library helps with and most actively get in the way of by
 * insisting on RGBA textures and linear filtering. A three.js/babylon
 * dependency would add ~600 kB to a page that also has to ship a cairo-vm wasm
 * module and a prover, in exchange for abstractions this pass does not use.
 *
 * ## What is static and what is rebuilt
 *
 * Geometry is uploaded once and left alone; the per-frame state that the
 * simulation changes reaches the GPU two ways:
 *
 *  - **floor/ceiling heights and light levels** live in a one-texel-per-sector
 *    RGBA32F texture sampled in the *vertex* shader, so a moving door or a
 *    strobing light changes nothing in any vertex buffer;
 *  - **wall quads of dynamic sectors** are the exception, because a wall's
 *    texture V coordinate depends on the heights through the pegging rules;
 *    those are rebuilt on the CPU each frame. On E1M1 that is ~180 quads out
 *    of ~2 400, the other 92 % staying in a static buffer.
 *
 * Sprites are rebuilt every frame by definition (they are billboards).
 */
export class Renderer {
  private readonly gl: WebGL2RenderingContext;
  private readonly level: LevelJson;
  private readonly store: AssetStore;

  private readonly wallProgram: WebGLProgram;
  private readonly flatProgram: WebGLProgram;
  private readonly spriteProgram: WebGLProgram;
  private readonly skyProgram: WebGLProgram;

  private readonly staticWallVao: WebGLVertexArrayObject;
  private readonly staticWallBuffer: WebGLBuffer;
  private staticWallVertices = 0;

  private readonly dynamicWallVao: WebGLVertexArrayObject;
  private readonly dynamicWallBuffer: WebGLBuffer;
  private dynamicWallCapacity = 0;

  private readonly flatVao: WebGLVertexArrayObject;
  private readonly flatBuffer: WebGLBuffer;
  private flatVertices = 0;

  private readonly spriteVao: WebGLVertexArrayObject;
  private readonly spriteBuffer: WebGLBuffer;
  private spriteCapacity = 0;

  private readonly skyVao: WebGLVertexArrayObject;

  private readonly atlasTexture: WebGLTexture;
  private readonly spriteAtlasTexture: WebGLTexture;
  private readonly colormapTexture: WebGLTexture;
  private readonly paletteTexture: WebGLTexture;
  private readonly sectorTexture: WebGLTexture;
  private readonly sectorTexWidth: number;
  private readonly sectorTexHeight: number;
  private readonly sectorData: Float32Array;

  private readonly dynamicSectors: ReadonlySet<number>;
  private readonly floorHeights: Float64Array;
  private readonly ceilingHeights: Float64Array;
  private readonly lightLevels: Float64Array;

  private readonly wallScratch = new VertexScratch(1 << 16);
  private readonly spriteScratch = new VertexScratch(1 << 14);
  private readonly skyRect: AtlasRect | undefined;

  private viewportWidth = 1;
  private viewportHeight = 1;

  readonly stats: RenderStats = {
    wallQuads: 0,
    dynamicWallQuads: 0,
    flatTriangles: 0,
    sprites: 0,
    drawCalls: 0,
    cpuMs: 0,
  };

  constructor(gl: WebGL2RenderingContext, level: LevelJson, store: AssetStore) {
    this.gl = gl;
    this.level = level;
    this.store = store;

    this.wallProgram = compileProgram(gl, "wall", WALL_VERT, WALL_FRAG);
    this.flatProgram = compileProgram(gl, "flat", FLAT_VERT, FLAT_FRAG);
    this.spriteProgram = compileProgram(gl, "sprite", SPRITE_VERT, SPRITE_FRAG);
    this.skyProgram = compileProgram(gl, "sky", SKY_VERT, SKY_FRAG);

    this.atlasTexture = createAtlasTexture(
      gl,
      store.surfaceAtlas.width,
      store.surfaceAtlas.height,
      store.surfaceAtlas.data,
    );
    this.spriteAtlasTexture = createAtlasTexture(
      gl,
      store.spriteAtlas.width,
      store.spriteAtlas.height,
      store.spriteAtlas.data,
    );
    this.colormapTexture = createR8Texture(gl, 256, store.colormap.mapCount, store.colormap.data);

    const paletteBlock = new Uint8Array(256 * 4 * store.playpal.paletteCount);
    store.playpal.rgba.forEach((p, i) => paletteBlock.set(p, i * 256 * 4));
    this.paletteTexture = createRgba8Texture(gl, 256, store.playpal.paletteCount, paletteBlock);

    const sectorCount = level.sectors.length;
    this.sectorTexWidth = Math.min(1024, Math.max(1, sectorCount));
    this.sectorTexHeight = Math.ceil(sectorCount / this.sectorTexWidth);
    this.sectorTexture = createRgba32fTexture(gl, this.sectorTexWidth, this.sectorTexHeight);
    this.sectorData = new Float32Array(this.sectorTexWidth * this.sectorTexHeight * 4);

    this.dynamicSectors = findDynamicSectors(level);
    this.floorHeights = new Float64Array(sectorCount);
    this.ceilingHeights = new Float64Array(sectorCount);
    this.lightLevels = new Float64Array(sectorCount);

    this.skyRect = store.surfaceAtlas.rects.get(texKey(store.skyTexture));

    this.staticWallBuffer = mustBuffer(gl);
    this.staticWallVao = mustVao(gl);
    this.dynamicWallBuffer = mustBuffer(gl);
    this.dynamicWallVao = mustVao(gl);
    this.flatBuffer = mustBuffer(gl);
    this.flatVao = mustVao(gl);
    this.spriteBuffer = mustBuffer(gl);
    this.spriteVao = mustVao(gl);
    this.skyVao = mustVao(gl);

    this.setupVao(this.staticWallVao, this.staticWallBuffer, this.wallProgram, [
      { name: "aPos", size: 3 },
      { name: "aUV", size: 2 },
      { name: "aRect", size: 4 },
      { name: "aSector", size: 1 },
      { name: "aLightDelta", size: 1 },
    ]);
    this.setupVao(this.dynamicWallVao, this.dynamicWallBuffer, this.wallProgram, [
      { name: "aPos", size: 3 },
      { name: "aUV", size: 2 },
      { name: "aRect", size: 4 },
      { name: "aSector", size: 1 },
      { name: "aLightDelta", size: 1 },
    ]);
    this.setupVao(this.flatVao, this.flatBuffer, this.flatProgram, [
      { name: "aPos", size: 2 },
      { name: "aSector", size: 1 },
      { name: "aKind", size: 1 },
      { name: "aRect", size: 4 },
    ]);
    this.setupVao(this.spriteVao, this.spriteBuffer, this.spriteProgram, [
      { name: "aPos", size: 3 },
      { name: "aUV", size: 2 },
      { name: "aRect", size: 4 },
      { name: "aLight", size: 1 },
      { name: "aFlags", size: 1 },
    ]);

    this.resetSectorStateFromLevel();
    this.buildStaticWalls();
    this.buildFlats();
  }

  private setupVao(
    vao: WebGLVertexArrayObject,
    buffer: WebGLBuffer,
    program: WebGLProgram,
    specs: { name: string; size: number }[],
  ): void {
    const gl = this.gl;
    gl.bindVertexArray(vao);
    gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
    bindInterleaved(gl, program, specs);
    gl.bindVertexArray(null);
  }

  private resetSectorStateFromLevel(): void {
    this.level.sectors.forEach((s, i) => {
      this.floorHeights[i] = s.floorHeight;
      this.ceilingHeights[i] = s.ceilingHeight;
      this.lightLevels[i] = s.lightLevel;
    });
  }

  /** Walls whose geometry can never move: uploaded once. */
  private buildStaticWalls(): void {
    const gl = this.gl;
    const lookup = textureSizeLookup(this.store);
    const quads = buildWallQuads(
      this.level,
      { floor: this.floorHeights, ceiling: this.ceilingHeights },
      lookup,
    ).filter((q) => !this.isDynamicQuad(q));
    this.wallScratch.reset();
    for (const q of quads) this.appendWallQuad(this.wallScratch, q);
    const data = this.wallScratch.view();
    gl.bindBuffer(gl.ARRAY_BUFFER, this.staticWallBuffer);
    gl.bufferData(gl.ARRAY_BUFFER, data, gl.STATIC_DRAW);
    this.staticWallVertices = data.length / WALL_STRIDE;
    this.stats.wallQuads = quads.length;
  }

  private isDynamicQuad(quad: WallQuad): boolean {
    if (this.dynamicSectors.has(quad.sector)) return true;
    const line = this.level.linedefs[quad.linedef];
    if (!line) return false;
    for (const sideIndex of [line.frontSidedef, line.backSidedef]) {
      const side = this.level.sidedefs[sideIndex];
      if (side && this.dynamicSectors.has(side.sector)) return true;
    }
    return false;
  }

  /** Floors and ceilings: static in x/y, with z and light read from the sector texture. */
  private buildFlats(): void {
    const gl = this.gl;
    const polygons = buildSubsectorPolygons(this.level);
    const scratch = new VertexScratch(1 << 16);
    let triangles = 0;

    for (const poly of polygons) {
      const sector = this.level.sectors[poly.sector];
      if (!sector) continue;
      const indices = fanTriangulate(poly.points);
      if (indices.length === 0) continue;

      for (const [kind, flatName] of [
        [0, sector.floorTexture],
        [1, sector.ceilingTexture],
      ] as const) {
        if (flatName === SKY_FLAT) continue; // the sky pass already covers it
        const rect = this.store.surfaceAtlas.rects.get(flatKey(flatName));
        if (!rect) continue;
        for (let i = 0; i < indices.length; i += 3) {
          // Wind floors counter-clockwise and ceilings clockwise so that, if
          // culling is ever enabled, both face the player.
          const order = kind === 0 ? [0, 1, 2] : [2, 1, 0];
          for (const k of order) {
            const p = poly.points[indices[i + k]!]!;
            scratch.push(p.x, p.y, poly.sector, kind, rect.x, rect.y, rect.width, rect.height);
          }
          triangles++;
        }
      }
    }

    const data = scratch.view();
    gl.bindBuffer(gl.ARRAY_BUFFER, this.flatBuffer);
    gl.bufferData(gl.ARRAY_BUFFER, data, gl.STATIC_DRAW);
    this.flatVertices = data.length / FLAT_STRIDE;
    this.stats.flatTriangles = triangles;
  }

  private appendWallQuad(scratch: VertexScratch, quad: WallQuad): void {
    const rect = this.store.surfaceAtlas.rects.get(texKey(quad.texture));
    if (!rect) return;
    const corners = quadCorners(quad);
    const order = [0, 1, 2, 0, 2, 3];
    for (const i of order) {
      const c = corners[i]!;
      scratch.push(
        c.x,
        c.y,
        c.z,
        c.u,
        c.v,
        rect.x,
        rect.y,
        rect.width,
        rect.height,
        quad.sector,
        quad.lightDelta,
      );
    }
  }

  resize(width: number, height: number): void {
    this.viewportWidth = Math.max(1, width);
    this.viewportHeight = Math.max(1, height);
  }

  render(view: InterpolatedView, options: RenderOptions): void {
    const t0 = performance.now();
    const gl = this.gl;
    this.stats.drawCalls = 0;

    // 1. Fold the snapshot's dynamic sectors into the height/light arrays.
    this.resetSectorStateFromLevel();
    for (const [index, state] of view.sectors) {
      if (index < 0 || index >= this.floorHeights.length) continue;
      this.floorHeights[index] = state.floor;
      this.ceilingHeights[index] = state.ceiling;
      this.lightLevels[index] = state.light;
    }
    this.uploadSectorState();

    // 2. Rebuild the wall quads whose pegging depends on moving heights.
    const dynamicQuads = buildWallQuads(
      this.level,
      { floor: this.floorHeights, ceiling: this.ceilingHeights },
      textureSizeLookup(this.store),
      this.dynamicSectors,
    );
    this.wallScratch.reset();
    for (const q of dynamicQuads) this.appendWallQuad(this.wallScratch, q);
    const dynamicData = this.wallScratch.view();
    this.stats.dynamicWallQuads = dynamicQuads.length;
    gl.bindBuffer(gl.ARRAY_BUFFER, this.dynamicWallBuffer);
    if (dynamicData.length > this.dynamicWallCapacity) {
      this.dynamicWallCapacity = Math.max(dynamicData.length * 2, 4096);
      gl.bufferData(gl.ARRAY_BUFFER, this.dynamicWallCapacity * 4, gl.DYNAMIC_DRAW);
    }
    gl.bufferSubData(gl.ARRAY_BUFFER, 0, dynamicData);

    // 3. Billboards.
    const spriteVertices = this.buildSprites(view);

    // 4. Draw.
    const aspect = this.viewportWidth / this.viewportHeight;
    const proj = perspective(aspect);
    const vm = viewMatrix(view.x, view.y, view.viewZ, view.angle, view.pitch);
    const viewProj = multiply(proj, vm);

    gl.viewport(0, 0, this.viewportWidth, this.viewportHeight);
    gl.clearColor(0, 0, 0, 1);
    gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
    gl.disable(gl.CULL_FACE);
    gl.disable(gl.BLEND);

    this.drawSky(view, options, aspect);

    gl.enable(gl.DEPTH_TEST);
    gl.depthFunc(gl.LEQUAL);
    gl.depthMask(true);

    this.bindCommonTextures(this.flatProgram, this.atlasTexture, options);
    gl.uniformMatrix4fv(gl.getUniformLocation(this.flatProgram, "uViewProj"), false, viewProj);
    gl.bindVertexArray(this.flatVao);
    gl.drawArrays(gl.TRIANGLES, 0, this.flatVertices);
    this.stats.drawCalls++;

    this.bindCommonTextures(this.wallProgram, this.atlasTexture, options);
    gl.uniformMatrix4fv(gl.getUniformLocation(this.wallProgram, "uViewProj"), false, viewProj);
    gl.bindVertexArray(this.staticWallVao);
    gl.drawArrays(gl.TRIANGLES, 0, this.staticWallVertices);
    this.stats.drawCalls++;
    gl.bindVertexArray(this.dynamicWallVao);
    gl.drawArrays(gl.TRIANGLES, 0, dynamicData.length / WALL_STRIDE);
    this.stats.drawCalls++;

    if (spriteVertices > 0) {
      this.bindCommonTextures(this.spriteProgram, this.spriteAtlasTexture, options);
      gl.uniformMatrix4fv(gl.getUniformLocation(this.spriteProgram, "uViewProj"), false, viewProj);
      gl.bindVertexArray(this.spriteVao);
      gl.drawArrays(gl.TRIANGLES, 0, spriteVertices);
      this.stats.drawCalls++;
    }

    gl.bindVertexArray(null);
    this.stats.cpuMs = performance.now() - t0;
  }

  private drawSky(view: InterpolatedView, options: RenderOptions, aspect: number): void {
    if (!this.skyRect) return;
    const gl = this.gl;
    gl.disable(gl.DEPTH_TEST);
    gl.depthMask(false);
    this.bindCommonTextures(this.skyProgram, this.atlasTexture, options);
    gl.uniform4f(
      gl.getUniformLocation(this.skyProgram, "uSkyRect"),
      this.skyRect.x,
      this.skyRect.y,
      this.skyRect.width,
      this.skyRect.height,
    );
    gl.uniform1f(gl.getUniformLocation(this.skyProgram, "uYawTurns"), (view.angle >>> 0) / 4294967296);
    gl.uniform1f(gl.getUniformLocation(this.skyProgram, "uAspect"), aspect);
    // Pitch expressed in the 200-row reference screen the sky mapping uses.
    const pitchRows = (pitchRadians(view.pitch) / (Math.PI / 2)) * 100;
    gl.uniform1f(gl.getUniformLocation(this.skyProgram, "uPitchRows"), pitchRows);
    gl.bindVertexArray(this.skyVao);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
    this.stats.drawCalls++;
  }

  private bindCommonTextures(
    program: WebGLProgram,
    atlas: WebGLTexture,
    options: RenderOptions,
  ): void {
    const gl = this.gl;
    gl.useProgram(program);
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, atlas);
    gl.uniform1i(gl.getUniformLocation(program, "uAtlas"), 0);
    gl.activeTexture(gl.TEXTURE1);
    gl.bindTexture(gl.TEXTURE_2D, this.colormapTexture);
    gl.uniform1i(gl.getUniformLocation(program, "uColormap"), 1);
    gl.activeTexture(gl.TEXTURE2);
    gl.bindTexture(gl.TEXTURE_2D, this.paletteTexture);
    gl.uniform1i(gl.getUniformLocation(program, "uPalette"), 2);
    gl.activeTexture(gl.TEXTURE3);
    gl.bindTexture(gl.TEXTURE_2D, this.sectorTexture);
    gl.uniform1i(gl.getUniformLocation(program, "uSectorData"), 3);
    gl.uniform1i(gl.getUniformLocation(program, "uPaletteRow"), options.paletteRow);
    gl.uniform1i(gl.getUniformLocation(program, "uForceColormap"), options.forceColormap);
    gl.uniform1i(gl.getUniformLocation(program, "uFlatShading"), options.flatShading ? 1 : 0);
  }

  private uploadSectorState(): void {
    const gl = this.gl;
    for (let i = 0; i < this.level.sectors.length; i++) {
      const o = i * 4;
      this.sectorData[o] = this.floorHeights[i]!;
      this.sectorData[o + 1] = this.ceilingHeights[i]!;
      this.sectorData[o + 2] = this.lightLevels[i]!;
      this.sectorData[o + 3] = 0;
    }
    gl.activeTexture(gl.TEXTURE3);
    gl.bindTexture(gl.TEXTURE_2D, this.sectorTexture);
    gl.texSubImage2D(
      gl.TEXTURE_2D,
      0,
      0,
      0,
      this.sectorTexWidth,
      this.sectorTexHeight,
      gl.RGBA,
      gl.FLOAT,
      this.sectorData,
    );
  }

  /**
   * Builds one camera-facing quad per mobj.
   *
   * Doom sprites rotate about the vertical axis only - they are never tilted
   * towards the eye - so the quad is spanned by the camera's *horizontal* right
   * vector and world up. The anchor follows `R_ProjectSprite`: the sprite's
   * left edge sits `leftOffset` to the left of the thing's position along the
   * screen-x axis, and its top edge `topOffset` above the thing's z.
   */
  private buildSprites(view: InterpolatedView): number {
    const gl = this.gl;
    const scratch = this.spriteScratch;
    scratch.reset();
    const { right } = cameraBasis(view.angle);
    let count = 0;

    for (const mo of view.mobjs) {
      const info = mobjInfoFor(mo.type);
      if (!info) continue;
      const def = this.store.spriteDefs.get(info.sprite);
      if (!def) continue;
      const frame = def.frames[mo.frame] ?? def.frames.find(Boolean);
      if (!frame) continue;
      const viewToThing = pointToAngle(mo.x - view.x, mo.y - view.y);
      const pick = selectSpriteLump(frame, viewToThing, mo.angle);
      if (!pick) continue;
      const rect = this.store.spriteAtlas.rects.get(spriteKey(pick.lump));
      if (!rect) continue;

      const leftDist = -rect.leftOffset;
      const rightDist = leftDist + rect.width;
      const topZ = mo.z + rect.topOffset;
      const bottomZ = topZ - rect.height;

      const lx = mo.x + right[0] * leftDist;
      const ly = mo.y + right[1] * leftDist;
      const rxw = mo.x + right[0] * rightDist;
      const ryw = mo.y + right[1] * rightDist;

      const light = this.lightLevels[mo.sector] ?? 255;
      let flags = 0;
      if (info.fullbright || (mo.flags & MobjRenderFlag.FULLBRIGHT) !== 0) flags |= 1;
      if ((mo.flags & MobjRenderFlag.SHADOW) !== 0) flags |= 2;

      const u0 = pick.flip ? rect.width : 0;
      const u1 = pick.flip ? 0 : rect.width;
      const corners: [number, number, number, number, number][] = [
        [lx, ly, bottomZ, u0, rect.height],
        [rxw, ryw, bottomZ, u1, rect.height],
        [rxw, ryw, topZ, u1, 0],
        [lx, ly, bottomZ, u0, rect.height],
        [rxw, ryw, topZ, u1, 0],
        [lx, ly, topZ, u0, 0],
      ];
      for (const [x, y, z, u, v] of corners) {
        scratch.push(x, y, z, u, v, rect.x, rect.y, rect.width, rect.height, light, flags);
      }
      count++;
    }

    this.stats.sprites = count;
    const data = scratch.view();
    gl.bindBuffer(gl.ARRAY_BUFFER, this.spriteBuffer);
    if (data.length > this.spriteCapacity) {
      this.spriteCapacity = Math.max(data.length * 2, 4096);
      gl.bufferData(gl.ARRAY_BUFFER, this.spriteCapacity * 4, gl.DYNAMIC_DRAW);
    }
    gl.bufferSubData(gl.ARRAY_BUFFER, 0, data);
    return data.length / SPRITE_STRIDE;
  }
}

function mustBuffer(gl: WebGL2RenderingContext): WebGLBuffer {
  const b = gl.createBuffer();
  if (!b) throw new Error("createBuffer failed");
  return b;
}

function mustVao(gl: WebGL2RenderingContext): WebGLVertexArrayObject {
  const v = gl.createVertexArray();
  if (!v) throw new Error("createVertexArray failed");
  return v;
}
