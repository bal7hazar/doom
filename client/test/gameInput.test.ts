// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";
import { GameInput } from "../src/game/gameInput.js";
import { decodeCmd, isCanonical } from "../src/prove/ticcmd.js";

const captures: GameInput[] = [];
afterEach(() => { for (const input of captures.splice(0)) input.dispose(); vi.restoreAllMocks(); document.body.innerHTML = ""; });
function setup() {
  const canvas = document.createElement("canvas"); document.body.append(canvas);
  let active = true;
  const lost = vi.fn(() => { active = false; });
  const input = new GameInput(canvas, () => active, lost); captures.push(input);
  return { input, canvas, lost, active: (value: boolean) => { active = value; } };
}
const key = (code: string, type = "keydown", repeat = false) => window.dispatchEvent(new KeyboardEvent(type, { code, repeat, cancelable: true }));

describe("real game input D12", () => {
  it("does not retain input before Start, and quantizes movement, turn and running", () => {
    const { input, active } = setup(); active(false); key("KeyW"); active(true);
    expect(decodeCmd(input.sample()).forward).toBe(0);
    key("KeyW"); key("KeyD"); key("ArrowLeft");
    expect(decodeCmd(input.sample())).toEqual({ forward: 25, side: 24, turn: 512, buttons: 0 });
    key("ShiftLeft"); key("ArrowRight");
    const cmd = decodeCmd(input.sample()); expect(isCanonical(cmd)).toBe(true);
    expect(cmd).toEqual({ forward: 50, side: 40, turn: 0, buttons: 0 });
    key("KeyW", "keyup"); expect(decodeCmd(input.sample()).forward).toBe(0);
  });
  it("uses the actual Cairo button mapping and ignores repeated weapon events", () => {
    const { input } = setup();
    key("ControlLeft"); key("KeyE"); key("Digit7");
    expect(decodeCmd(input.sample()).buttons).toBe(1 | 2 | 4 | (7 << 3));
    key("Digit7", "keydown", true);
    expect(decodeCmd(input.sample()).buttons).toBe(3);
    input.clear(); key("Digit1"); expect(decodeCmd(input.sample()).buttons).toBe(4);
    key("Digit2"); expect(decodeCmd(input.sample()).buttons).toBe(12);
  });
  it("bounds mouse deltas, requires pointer lock and clears held inputs on loss of focus", () => {
    const { input, canvas, active, lost } = setup();
    Object.defineProperty(document, "pointerLockElement", { configurable: true, get: () => null });
    const lock = vi.spyOn(document, "pointerLockElement", "get").mockReturnValue(canvas);
    document.dispatchEvent(new Event("pointerlockchange"));
    window.dispatchEvent(Object.assign(new MouseEvent("mousemove"), { movementX: 100000 }));
    window.dispatchEvent(new MouseEvent("mousedown", { button: 0 }));
    expect(decodeCmd(input.sample())).toMatchObject({ turn: -32768, buttons: 1 });
    expect(decodeCmd(input.sample()).turn).toBe(0);
    key("KeyW"); lock.mockReturnValue(null); document.dispatchEvent(new Event("pointerlockchange"));
    expect(lost).toHaveBeenCalledTimes(1); active(true);
    expect(decodeCmd(input.sample())).toEqual({ forward: 0, side: 0, turn: 0, buttons: 0 });
    key("KeyW"); window.dispatchEvent(new Event("blur")); active(true);
    expect(decodeCmd(input.sample()).forward).toBe(0);
  });
  it("clears on hide and page cache, and does not intercept form controls", () => {
    const { input, active } = setup();
    const field = document.createElement("input"); document.body.append(field);
    field.dispatchEvent(new KeyboardEvent("keydown", { bubbles: true, code: "KeyW" }));
    expect(decodeCmd(input.sample()).forward).toBe(0);
    key("KeyW"); window.dispatchEvent(new Event("pagehide"));
    expect(decodeCmd(input.sample()).forward).toBe(0);
    key("KeyW"); vi.spyOn(document, "hidden", "get").mockReturnValue(true);
    document.dispatchEvent(new Event("visibilitychange")); active(true);
    expect(decodeCmd(input.sample()).forward).toBe(0);
  });
});
