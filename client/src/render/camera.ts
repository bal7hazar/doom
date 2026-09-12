import { bamToRadians } from "../sim/snapshot.js";

/**
 * Column-major 4×4 matrices, GL order (`m[column*4 + row]`).
 *
 * World space is Doom's: x east, y north, z up, all in map units. View space is
 * OpenGL's: x right, y up, looking down -z.
 */
export type Mat4 = Float32Array;

/** Doom's vertical field of view: 90° horizontal at 320×200 shown as 4:3. */
export const REFERENCE_ASPECT = 4 / 3;
export const HORIZONTAL_FOV = Math.PI / 2;
/** 2·atan(tan(45°)/(4/3)) ≈ 73.74°. Kept fixed so widescreen adds horizontal view. */
export const VERTICAL_FOV = 2 * Math.atan(Math.tan(HORIZONTAL_FOV / 2) / REFERENCE_ASPECT);

export function perspective(aspect: number, near = 1, far = 16384): Mat4 {
  // "Vert-" widescreen: the vertical FOV is the 4:3 one, and a wider window
  // reveals more to the sides rather than cropping top and bottom - the
  // behaviour every modern Doom port settled on.
  const yScale = 1 / Math.tan(VERTICAL_FOV / 2);
  const xScale = yScale / Math.max(aspect, 1e-6);
  const m = new Float32Array(16);
  m[0] = xScale;
  m[5] = yScale;
  m[10] = (far + near) / (near - far);
  m[11] = -1;
  m[14] = (2 * far * near) / (near - far);
  return m;
}

/**
 * View matrix for a Doom camera: yaw about the world z axis, then pitch about
 * the camera's right axis.
 *
 * With yaw `a`: forward = (cos a, sin a, 0), right = (sin a, −cos a, 0),
 * up = (0, 0, 1). The view matrix rows are (right, up, −forward) applied to
 * `p − eye`.
 */
export function viewMatrix(x: number, y: number, z: number, yawBam: number, pitchBam: number): Mat4 {
  const a = bamToRadians(yawBam);
  const p = pitchRadians(pitchBam);
  const ca = Math.cos(a);
  const sa = Math.sin(a);
  const cp = Math.cos(p);
  const sp = Math.sin(p);

  // Basis before pitch.
  const fx = ca;
  const fy = sa;
  const rx = sa;
  const ry = -ca;

  // Pitch rotates forward/up in the plane spanned by (forward, worldUp).
  const f = [fx * cp, fy * cp, sp];
  const u = [-fx * sp, -fy * sp, cp];
  const r = [rx, ry, 0];

  const m = new Float32Array(16);
  m[0] = r[0]!;
  m[4] = r[1]!;
  m[8] = r[2]!;
  m[1] = u[0]!;
  m[5] = u[1]!;
  m[9] = u[2]!;
  m[2] = -f[0]!;
  m[6] = -f[1]!;
  m[10] = -f[2]!;
  m[3] = 0;
  m[7] = 0;
  m[11] = 0;
  m[12] = -(r[0]! * x + r[1]! * y + r[2]! * z);
  m[13] = -(u[0]! * x + u[1]! * y + u[2]! * z);
  m[14] = f[0]! * x + f[1]! * y + f[2]! * z;
  m[15] = 1;
  return m;
}

/**
 * Pitch is a BAM in the snapshot so the Cairo core can carry it losslessly if
 * freelook is ever added; vanilla always sends 0. Interpreted as a signed
 * quarter-turn range.
 */
export function pitchRadians(pitchBam: number): number {
  const signed = pitchBam | 0;
  return (signed / 4294967296) * Math.PI * 2;
}

export function multiply(a: Mat4, b: Mat4): Mat4 {
  const out = new Float32Array(16);
  for (let c = 0; c < 4; c++) {
    for (let r = 0; r < 4; r++) {
      let sum = 0;
      for (let k = 0; k < 4; k++) sum += a[k * 4 + r]! * b[c * 4 + k]!;
      out[c * 4 + r] = sum;
    }
  }
  return out;
}

/** The camera's right and forward vectors in world space; used to build billboards. */
export function cameraBasis(yawBam: number): { right: [number, number]; forward: [number, number] } {
  const a = bamToRadians(yawBam);
  return { right: [Math.sin(a), -Math.cos(a)], forward: [Math.cos(a), Math.sin(a)] };
}
