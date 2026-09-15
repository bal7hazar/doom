// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0

/**
 * Touch-screen input model (PLAN C1 revised, D35: playable on a phone).
 *
 * Pure state, no DOM: `ui/touchControls.ts` feeds it pointer coordinates and
 * button presses, `GameInput.sample()` consumes it once per tic. It produces
 * the *same* ticcmd fields as the keyboard/mouse path, in the same units, and
 * the result still goes through `quantize()` in `GameInput`: a phone journal
 * is a keyboard journal in nature (D12), only the source of the numbers differs.
 *
 *  - the left **stick** is a floating joystick: full deflection is the keyboard
 *    speed (25 / 50 forward, 24 / 40 strafe, run toggled), anything in between
 *    is scaled like vanilla's analog joystick and truncated by `quantize`;
 *  - the right **look** zone turns like the locked mouse: a horizontal drag is
 *    accumulated in pixels, bounded, converted to BAM once per sample and then
 *    zeroed, so a stationary finger stops the turn;
 *  - **fire** / **use** are held buttons, **run** is a toggle, a weapon request
 *    is a one-shot exactly like a digit key (`BT_CHANGE | code << 3`).
 *
 * Every pointer is tracked by id, so a stick finger and a look finger, or a
 * stick finger and the fire button, coexist; releasing one leaves the others.
 */

export const TOUCH_TUNING = {
  /** Fraction of the stick radius that is ignored (finger resting on the base). */
  deadzone: 0.18,
  /** CSS pixels of deflection for full speed; the base is drawn at this radius. */
  stickRadius: 56,
  /** BAM per pixel of look drag: 4× the mouse's 32 BAM/px, ≈700 px for a full turn. */
  turnPerPx: 128,
  /** Bound of the unconsumed drag, like the mouse's ±2048 px; `quantize` clamps the rest. */
  maxDragPx: 2048,
} as const;

/** Vanilla weapon codes the Weapon button cycles through: pistol, shotgun, chaingun, fist, chainsaw. */
export const WEAPON_CYCLE = [1, 2, 3, 0, 7] as const;

export interface TouchContribution {
  forward: number;
  side: number;
  /** Raw BAM turn, not yet quantized. */
  turn: number;
  fire: boolean;
  use: boolean;
  /** Vanilla weapon code requested this sample, if any. */
  weapon: number | undefined;
}

export interface StickAxes {
  /** −1..1, right positive. */
  x: number;
  /** −1..1, forward (screen up) positive. */
  y: number;
  /** Where the floating base was put down, in the caller's coordinates. */
  originX: number;
  originY: number;
  active: boolean;
}

export class TouchInput {
  private stick?: { id: number; x0: number; y0: number; dx: number; dy: number };
  private look?: { id: number; lastX: number };
  private dragPx = 0;
  private fire = 0;
  private use = 0;
  private weapon: number | undefined;
  /** Run toggle (Shift's equivalent); survives `clear()` because it is a mode, not a press. */
  run = false;

  constructor(private readonly tuning = TOUCH_TUNING) {}

  /** A finger landed on the stick zone: the base floats to where it touched. */
  stickDown(id: number, x: number, y: number): void {
    this.stick = { id, x0: x, y0: y, dx: 0, dy: 0 };
  }
  /** A finger landed on the look zone. */
  lookDown(id: number, x: number): void {
    this.look = { id, lastX: x };
  }
  /** Any tracked pointer moved; unknown ids are ignored. */
  pointerMove(id: number, x: number, y: number): void {
    if (this.stick?.id === id) {
      this.stick.dx = x - this.stick.x0;
      this.stick.dy = y - this.stick.y0;
    }
    if (this.look?.id === id) {
      const limit = this.tuning.maxDragPx;
      this.dragPx = Math.max(-limit, Math.min(limit, this.dragPx + (x - this.look.lastX)));
      this.look.lastX = x;
    }
  }
  /** Any tracked pointer lifted or was cancelled: its axis returns to zero. */
  pointerUp(id: number): void {
    if (this.stick?.id === id) this.stick = undefined;
    if (this.look?.id === id) this.look = undefined;
  }
  /** Held buttons count presses, so two fingers on Fire do not cancel each other. */
  press(button: "fire" | "use", down: boolean): void {
    const next = Math.max(0, (button === "fire" ? this.fire : this.use) + (down ? 1 : -1));
    if (button === "fire") this.fire = next;
    else this.use = next;
  }
  toggleRun(): boolean {
    this.run = !this.run;
    return this.run;
  }
  /** One-shot weapon request; consumed by the next sample, like a digit key. */
  requestWeapon(code: number): void {
    this.weapon = code;
  }
  /** The weapon the Weapon button should ask for after `current` (vanilla numbering). */
  static nextWeapon(current: number | undefined): number {
    const at = WEAPON_CYCLE.indexOf(current as (typeof WEAPON_CYCLE)[number]);
    return WEAPON_CYCLE[(at + 1) % WEAPON_CYCLE.length]!;
  }

  get firing(): boolean { return this.fire > 0; }
  get using(): boolean { return this.use > 0; }

  /** Current stick deflection after the dead zone, for drawing the knob. */
  axes(): StickAxes {
    const s = this.stick;
    if (!s) return { x: 0, y: 0, originX: 0, originY: 0, active: false };
    const { deadzone, stickRadius } = this.tuning;
    const distance = Math.hypot(s.dx, s.dy);
    const magnitude = distance / stickRadius;
    if (magnitude < deadzone || distance === 0) return { x: 0, y: 0, originX: s.x0, originY: s.y0, active: true };
    const scaled = Math.min(1, (magnitude - deadzone) / (1 - deadzone));
    return { x: (s.dx / distance) * scaled, y: (-s.dy / distance) * scaled, originX: s.x0, originY: s.y0, active: true };
  }

  /**
   * The sample for one tic. `fast` is the speed tier the caller settled on
   * (keyboard Shift or the run toggle). The look drag and the weapon request
   * are consumed; held state is not.
   */
  consume(fast: boolean): TouchContribution {
    const axes = this.axes();
    // Keyboard maxima at full deflection; `quantize` truncates towards zero.
    const forward = axes.y * (fast ? 50 : 25);
    const side = axes.x * (fast ? 40 : 24);
    const turn = -this.dragPx * this.tuning.turnPerPx || 0; // never −0
    const weapon = this.weapon;
    this.dragPx = 0;
    this.weapon = undefined;
    return { forward, side, turn, fire: this.fire > 0, use: this.use > 0, weapon };
  }

  /** Everything held returns to zero: pointer loss, blur, pause, rotation. */
  clear(): void {
    this.stick = undefined;
    this.look = undefined;
    this.dragPx = 0;
    this.fire = 0;
    this.use = 0;
    this.weapon = undefined;
  }
}
