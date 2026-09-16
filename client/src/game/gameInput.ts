import { encodeCmd, quantize } from "../prove/ticcmd.js";
import type { TouchInput } from "./touchInput.js";

const KEYS = new Set(["KeyW", "KeyA", "KeyS", "KeyD", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight",
  "ShiftLeft", "ShiftRight", "ControlLeft", "ControlRight", "Space", "KeyE", "Digit1", "Digit2", "Digit3", "Digit4", "Digit7"]);

/**
 * Only input capture/quantization; movement, weapons and use are decided by Cairo.
 * An optional `TouchInput` (phones) contributes to the same fields and is
 * quantized with them, so the journal never depends on the input device.
 */
export class GameInput {
  private keys = new Set<string>();
  private mouseX = 0;
  private fire = false;
  private weapon: number | undefined;
  private locked = false;
  private readonly listeners = new AbortController();

  constructor(private readonly canvas: HTMLCanvasElement, private readonly active: () => boolean,
    private readonly loseFocus: () => void, readonly touch?: TouchInput) {
    const options = { signal: this.listeners.signal };
    window.addEventListener("keydown", event => {
      if (!this.active() || (event.target instanceof Element && event.target.closest("input,textarea,select,button,a"))) return;
      if (event.code === "Escape" || event.code === "KeyP") { if (!event.repeat) this.loseFocus(); return; }
      if (!KEYS.has(event.code)) return;
      event.preventDefault();
      if (event.repeat) return;
      this.keys.add(event.code);
      if (/^Digit[12347]$/.test(event.code)) this.weapon = event.code === "Digit7" ? 7 : Number(event.code.slice(5)) - 1;
    }, options);
    window.addEventListener("keyup", event => { this.keys.delete(event.code); }, options);
    window.addEventListener("mousemove", event => {
      if (this.active() && document.pointerLockElement === this.canvas) {
        this.mouseX = Math.max(-2048, Math.min(2048, this.mouseX + event.movementX));
      }
    }, options);
    window.addEventListener("mousedown", event => {
      if (event.button === 0 && this.active() && document.pointerLockElement === this.canvas) this.fire = true;
    }, options);
    window.addEventListener("mouseup", event => { if (event.button === 0) this.fire = false; }, options);
    window.addEventListener("blur", () => { this.clear(); this.loseFocus(); }, options);
    window.addEventListener("pagehide", () => this.clear(), options);
    document.addEventListener("visibilitychange", () => {
      if (document.hidden) { this.clear(); this.loseFocus(); }
    }, options);
    document.addEventListener("pointerlockchange", () => {
      const locked = document.pointerLockElement === this.canvas;
      if (this.locked && !locked) { this.clear(); this.loseFocus(); }
      this.locked = locked;
    }, options);
  }
  clear(): void { this.keys.clear(); this.mouseX = 0; this.fire = false; this.weapon = undefined; this.touch?.clear(); }
  sample(): number {
    if (!this.active()) { this.clear(); return encodeCmd({ forward: 0, side: 0, turn: 0, buttons: 0 }); }
    const down = (...keys: string[]): number => Number(keys.some(key => this.keys.has(key)));
    const fast = down("ShiftLeft", "ShiftRight") === 1 || (this.touch?.run ?? false);
    const touch = this.touch?.consume(fast);
    const forward = (down("KeyW", "ArrowUp") - down("KeyS", "ArrowDown")) * (fast ? 50 : 25) + (touch?.forward ?? 0);
    const side = (down("KeyD") - down("KeyA")) * (fast ? 40 : 24) + (touch?.side ?? 0);
    const turn = (down("ArrowLeft") - down("ArrowRight")) * (fast ? 1280 : 640) - this.mouseX * 32 + (touch?.turn ?? 0);
    // d_event.h bits, as consumed by doom_player::state/think (not compact WeaponId).
    let buttons = Number(this.fire || touch?.fire || Boolean(down("ControlLeft", "ControlRight")))
      | (Number(down("KeyE", "Space") === 1 || touch?.use) << 1);
    const weapon = this.weapon ?? touch?.weapon;
    if (weapon !== undefined) buttons |= 4 | (weapon << 3);
    this.mouseX = 0; this.weapon = undefined;
    return encodeCmd(quantize({ forward, side, turn, buttons }));
  }
  dispose(): void { this.clear(); this.listeners.abort(); }
}
