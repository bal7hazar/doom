/** Minimal WebGL2 helpers. No wrapper object model: the renderer owns raw GL handles. */

export function compileProgram(
  gl: WebGL2RenderingContext,
  name: string,
  vertexSource: string,
  fragmentSource: string,
): WebGLProgram {
  const vs = compileShader(gl, name, gl.VERTEX_SHADER, vertexSource);
  const fs = compileShader(gl, name, gl.FRAGMENT_SHADER, fragmentSource);
  const program = gl.createProgram();
  if (!program) throw new Error(`${name}: createProgram failed`);
  gl.attachShader(program, vs);
  gl.attachShader(program, fs);
  gl.linkProgram(program);
  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
    const log = gl.getProgramInfoLog(program);
    gl.deleteProgram(program);
    throw new Error(`${name}: link failed\n${log}`);
  }
  gl.deleteShader(vs);
  gl.deleteShader(fs);
  return program;
}

function compileShader(
  gl: WebGL2RenderingContext,
  name: string,
  type: number,
  source: string,
): WebGLShader {
  const shader = gl.createShader(type);
  if (!shader) throw new Error(`${name}: createShader failed`);
  gl.shaderSource(shader, source);
  gl.compileShader(shader);
  if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
    const log = gl.getShaderInfoLog(shader) ?? "";
    const kind = type === gl.VERTEX_SHADER ? "vertex" : "fragment";
    gl.deleteShader(shader);
    throw new Error(`${name} (${kind}): ${log}\n${numberLines(source)}`);
  }
  return shader;
}

function numberLines(source: string): string {
  return source
    .split("\n")
    .map((line, i) => `${String(i + 1).padStart(3)} | ${line}`)
    .join("\n");
}

export interface AttribSpec {
  name: string;
  size: number;
}

/**
 * Describes an interleaved float vertex layout and binds it on the currently
 * bound VAO/ARRAY_BUFFER. Attributes are located by name so the shaders stay
 * readable (no `layout(location=…)` bookkeeping duplicated in two places).
 */
export function bindInterleaved(
  gl: WebGL2RenderingContext,
  program: WebGLProgram,
  specs: AttribSpec[],
): number {
  const stride = specs.reduce((sum, s) => sum + s.size, 0) * 4;
  let offset = 0;
  for (const spec of specs) {
    const loc = gl.getAttribLocation(program, spec.name);
    if (loc >= 0) {
      gl.enableVertexAttribArray(loc);
      gl.vertexAttribPointer(loc, spec.size, gl.FLOAT, false, stride, offset);
    }
    offset += spec.size * 4;
  }
  return stride / 4;
}

/** Uploads an RG8 atlas as a NEAREST, non-mipmapped 2D texture. */
export function createAtlasTexture(
  gl: WebGL2RenderingContext,
  width: number,
  height: number,
  data: Uint8Array,
): WebGLTexture {
  const tex = gl.createTexture();
  if (!tex) throw new Error("createTexture failed");
  gl.bindTexture(gl.TEXTURE_2D, tex);
  gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RG8, width, height, 0, gl.RG, gl.UNSIGNED_BYTE, data);
  setNearestClamp(gl);
  return tex;
}

/** Uploads a single-channel byte texture (the COLORMAP). */
export function createR8Texture(
  gl: WebGL2RenderingContext,
  width: number,
  height: number,
  data: Uint8Array,
): WebGLTexture {
  const tex = gl.createTexture();
  if (!tex) throw new Error("createTexture failed");
  gl.bindTexture(gl.TEXTURE_2D, tex);
  gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.R8, width, height, 0, gl.RED, gl.UNSIGNED_BYTE, data);
  setNearestClamp(gl);
  return tex;
}

/** Uploads an RGBA8 texture (the PLAYPAL block: 256 columns × one row per palette). */
export function createRgba8Texture(
  gl: WebGL2RenderingContext,
  width: number,
  height: number,
  data: Uint8Array,
): WebGLTexture {
  const tex = gl.createTexture();
  if (!tex) throw new Error("createTexture failed");
  gl.bindTexture(gl.TEXTURE_2D, tex);
  gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, width, height, 0, gl.RGBA, gl.UNSIGNED_BYTE, data);
  setNearestClamp(gl);
  return tex;
}

/** A float texture the vertex shader samples for per-sector state. */
export function createRgba32fTexture(
  gl: WebGL2RenderingContext,
  width: number,
  height: number,
): WebGLTexture {
  const tex = gl.createTexture();
  if (!tex) throw new Error("createTexture failed");
  gl.bindTexture(gl.TEXTURE_2D, tex);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA32F, width, height, 0, gl.RGBA, gl.FLOAT, null);
  setNearestClamp(gl);
  return tex;
}

function setNearestClamp(gl: WebGL2RenderingContext): void {
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
}

/** A growable `Float32Array` backing a `DYNAMIC_DRAW` buffer. */
export class VertexScratch {
  data: Float32Array;
  length = 0;

  constructor(initialFloats = 4096) {
    this.data = new Float32Array(initialFloats);
  }

  reset(): void {
    this.length = 0;
  }

  ensure(extraFloats: number): void {
    if (this.length + extraFloats <= this.data.length) return;
    let size = this.data.length || 1;
    while (size < this.length + extraFloats) size *= 2;
    const bigger = new Float32Array(size);
    bigger.set(this.data.subarray(0, this.length));
    this.data = bigger;
  }

  push(...values: number[]): void {
    this.ensure(values.length);
    for (const v of values) this.data[this.length++] = v;
  }

  view(): Float32Array {
    return this.data.subarray(0, this.length);
  }
}
