/**
 * GLSL ES 3.00 sources for the four passes: sky, flats, walls, sprites.
 *
 * ## Light model (P2.2, "éclairage par secteur")
 *
 * Colours are **not** approximated: every texel is a `PLAYPAL` index, and the
 * fragment shader performs vanilla's own two-step lookup
 *
 *     palette index -> COLORMAP[row][index] -> PLAYPAL[palette][index] -> RGB
 *
 * with `row` computed by the closed form derived from `R_InitLightTables` in
 * `wad/colormap.ts`:
 *
 *     lightnum = clamp(lightLevel >> 4, 0, 15)
 *     row      = clamp(floor((15 - lightnum)*4 - 1280/distance), 0, 31)
 *
 * so both the sector's light level *and* the distance fall-off ("diminishing
 * lighting") land on exactly the colormap row the software renderer would pick,
 * banding included. The one deliberate deviation from vanilla is that walls use
 * the same *z*-based table as floors instead of `scalelight[]`, which is
 * indexed by the wall's projected scale; the two agree to within one row
 * everywhere except at extreme grazing angles, and using one table keeps a
 * single uniform code path for walls, flats and sprites.
 *
 * `distance` is the view-space depth (perpendicular distance to the view
 * plane), which is what vanilla uses too - not the euclidean distance, which
 * would darken the screen edges.
 *
 * ## Atlas addressing
 *
 * Textures live in one RG8 atlas (R = palette index, G = coverage). Fragments
 * address it with `texelFetch` plus an explicit wrap inside the entry's own
 * rectangle, so entries can never bleed into each other and tiling is exact at
 * any distance.
 */

const COMMON = /* glsl */ `
precision highp float;
precision highp int;

uniform sampler2D uAtlas;     // RG8: R = PLAYPAL index, G = coverage mask
uniform sampler2D uColormap;  // R8, 256 x 34
uniform sampler2D uPalette;   // RGBA8, 256 x 14 (one row per PLAYPAL palette)
uniform int uPaletteRow;      // damage/bonus flash selection
uniform int uForceColormap;   // >= 0 forces a row (invulnerability powerup)
uniform int uFlatShading;     // 1 = ignore textures, show light only (debug view)

int lightRow(float lightLevel, float dist) {
  int lightnum = clamp(int(floor(lightLevel / 16.0)), 0, 15);
  float startmap = float(15 - lightnum) * 4.0;
  float level = floor(startmap - 1280.0 / max(dist, 1.0));
  return int(clamp(level, 0.0, 31.0));
}

// Wraps a texel coordinate into an atlas rectangle (xy = origin, zw = size).
ivec2 atlasTexel(vec2 uv, vec4 rect) {
  vec2 wrapped = mod(uv, rect.zw);
  return ivec2(rect.xy + floor(wrapped));
}

vec3 resolve(int paletteIndex, float lightLevel, float dist, bool fullbright) {
  int row = uForceColormap >= 0 ? uForceColormap : (fullbright ? 0 : lightRow(lightLevel, dist));
  int remapped = int(texelFetch(uColormap, ivec2(paletteIndex, row), 0).r * 255.0 + 0.5);
  return texelFetch(uPalette, ivec2(remapped, uPaletteRow), 0).rgb;
}
`;

/**
 * Per-sector state, sampled in the vertex shader so floor/ceiling geometry and
 * light levels stay static in GPU memory while doors and lifts move: one texel
 * per sector, `(floorZ, ceilingZ, lightLevel, unused)`.
 */
const SECTOR_LOOKUP = /* glsl */ `
uniform highp sampler2D uSectorData;
vec4 sectorState(float sectorIndex) {
  int i = int(sectorIndex + 0.5);
  int w = textureSize(uSectorData, 0).x;
  return texelFetch(uSectorData, ivec2(i % w, i / w), 0);
}
`;

export const WALL_VERT = /* glsl */ `#version 300 es
${SECTOR_LOOKUP}
uniform mat4 uViewProj;

in vec3 aPos;        // world position, map units
in vec2 aUV;         // texels along the wall / down from texture row 0
in vec4 aRect;       // atlas rectangle
in float aSector;    // sector supplying the light level
in float aLightDelta;// vanilla fake contrast: -16, 0 or +16

out vec2 vUV;
out vec4 vRect;
out float vLight;
out float vDist;

void main() {
  vec4 clip = uViewProj * vec4(aPos, 1.0);
  gl_Position = clip;
  vUV = aUV;
  vRect = aRect;
  vLight = clamp(sectorState(aSector).z + aLightDelta, 0.0, 255.0);
  vDist = clip.w;
}
`;

export const WALL_FRAG = /* glsl */ `#version 300 es
${COMMON}
in vec2 vUV;
in vec4 vRect;
in float vLight;
in float vDist;
out vec4 fragColor;

void main() {
  vec2 rg = texelFetch(uAtlas, atlasTexel(vUV, vRect), 0).rg;
  if (rg.g < 0.5) discard;              // masked middle textures (grates, bars)
  if (uFlatShading == 1) {
    float l = 1.0 - float(lightRow(vLight, vDist)) / 31.0;
    fragColor = vec4(vec3(l) * vec3(0.9, 0.85, 0.8), 1.0);
    return;
  }
  fragColor = vec4(resolve(int(rg.r * 255.0 + 0.5), vLight, vDist, false), 1.0);
}
`;

export const FLAT_VERT = /* glsl */ `#version 300 es
${SECTOR_LOOKUP}
uniform mat4 uViewProj;

in vec2 aPos;      // world x, y
in float aSector;
in float aKind;    // 0 = floor, 1 = ceiling
in vec4 aRect;

out vec2 vUV;
out vec4 vRect;
out float vLight;
out float vDist;

void main() {
  vec4 state = sectorState(aSector);
  float z = aKind < 0.5 ? state.x : state.y;
  vec4 clip = uViewProj * vec4(aPos, z, 1.0);
  gl_Position = clip;
  // Flats are world-aligned 64x64: vanilla indexes them with (x, -y).
  vUV = vec2(aPos.x, -aPos.y);
  vRect = aRect;
  vLight = state.z;
  vDist = clip.w;
}
`;

export const FLAT_FRAG = WALL_FRAG;

export const SPRITE_VERT = /* glsl */ `#version 300 es
uniform mat4 uViewProj;

in vec3 aPos;
in vec2 aUV;
in vec4 aRect;
in float aLight;
in float aFlags;   // bit 0 fullbright, bit 1 spectre fuzz

out vec2 vUV;
out vec4 vRect;
out float vLight;
out float vDist;
out float vFlags;

void main() {
  vec4 clip = uViewProj * vec4(aPos, 1.0);
  gl_Position = clip;
  vUV = aUV;
  vRect = aRect;
  vLight = aLight;
  vDist = clip.w;
  vFlags = aFlags;
}
`;

export const SPRITE_FRAG = /* glsl */ `#version 300 es
${COMMON}
in vec2 vUV;
in vec4 vRect;
in float vLight;
in float vDist;
in float vFlags;
out vec4 fragColor;

void main() {
  int flags = int(vFlags + 0.5);
  // Sprites are clamped, not wrapped: a billboard must never repeat.
  vec2 uv = clamp(vUV, vec2(0.0), vRect.zw - vec2(0.001));
  ivec2 texel = ivec2(vRect.xy + floor(uv));
  vec2 rg = texelFetch(uAtlas, texel, 0).rg;
  if (rg.g < 0.5) discard;
  if ((flags & 2) != 0) {
    // MF_SHADOW: vanilla draws the spectre through the fuzz table. A cheap
    // stand-in - the darkest colormap row plus a dither - keeps it readable
    // without a second code path.
    float dither = fract(sin(dot(gl_FragCoord.xy, vec2(12.9898, 78.233))) * 43758.5453);
    if (dither > 0.55) discard;
    fragColor = vec4(resolve(int(rg.r * 255.0 + 0.5), 0.0, 8192.0, false), 1.0);
    return;
  }
  if (uFlatShading == 1) {
    fragColor = vec4(vec3(0.8, 0.3, 0.3), 1.0);
    return;
  }
  fragColor = vec4(resolve(int(rg.r * 255.0 + 0.5), vLight, vDist, (flags & 1) != 0), 1.0);
}
`;

/**
 * Sky: a full-screen triangle whose fragments are coloured from the view
 * direction alone.
 *
 * Vanilla maps the sky with `angle = (viewangle + xtoviewangle[x]) >> ANGLETOSKYSHIFT`
 * (ANGLETOSKYSHIFT = 22), i.e. 1024 sky columns per full turn; a 256-wide sky
 * texture therefore repeats exactly **four times** per revolution, which is
 * reproduced here by `u = yaw_turns * 4 * width`. Vertically vanilla pins
 * `skytexturemid = 100 * FRACUNIT` on a 200-row view, so the sky's 128 rows
 * cover the upper 64 % of the screen; that ratio is reproduced against the
 * actual canvas height and offset by the camera pitch. The sky is never lit:
 * `R_DrawSkyColumn` always uses colormap row 0.
 */
export const SKY_VERT = /* glsl */ `#version 300 es
out vec2 vScreen;
void main() {
  // Full-screen triangle from gl_VertexID, no vertex buffer needed.
  vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);
  vScreen = p;
  gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
`;

export const SKY_FRAG = /* glsl */ `#version 300 es
${COMMON}
in vec2 vScreen;                  // 0..1 across the viewport, y up
uniform vec4 uSkyRect;            // atlas rectangle of the sky texture
uniform float uYawTurns;          // camera yaw, in turns (0..1)
uniform float uAspect;            // viewport width / height
uniform float uPitchRows;         // camera pitch, in 200-row screen units
out vec4 fragColor;

void main() {
  // Horizontal: reproduce ANGLETOSKYSHIFT's four repeats per revolution,
  // corrected for the actual horizontal field of view.
  float halfFov = atan(tan(radians(73.7397) * 0.5) * uAspect);
  float columnAngle = atan((vScreen.x * 2.0 - 1.0) * tan(halfFov));
  float turns = uYawTurns + columnAngle / 6.2831853;
  float u = fract(turns * 4.0) * uSkyRect.z;

  // Vertical: 200 screen rows map onto the sky texture 1:1 from its top.
  float row = (1.0 - vScreen.y) * 200.0 + uPitchRows;
  float v = clamp(row, 0.0, uSkyRect.w - 1.0);

  ivec2 texel = ivec2(uSkyRect.xy + vec2(floor(u), floor(v)));
  vec2 rg = texelFetch(uAtlas, texel, 0).rg;
  if (uFlatShading == 1) {
    fragColor = vec4(0.12, 0.14, 0.2, 1.0);
    return;
  }
  fragColor = vec4(resolve(int(rg.r * 255.0 + 0.5), 255.0, 1.0, true), 1.0);
}
`;
