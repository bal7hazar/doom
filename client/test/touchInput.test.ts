// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0
// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";
import { GameInput } from "../src/game/gameInput.js";
import { TOUCH_TUNING, TouchInput, WEAPON_CYCLE } from "../src/game/touchInput.js";
import { decodeCmd, isCanonical } from "../src/prove/ticcmd.js";
import { isTouchDevice, mountTouchControls, watchOrientation } from "../src/ui/touchControls.js";

const R = TOUCH_TUNING.stickRadius;

/** A touch → ticcmd sample through the real `GameInput` path (quantized, encoded). */
function sampler(touch: TouchInput) {
  const canvas = document.createElement("canvas");
  document.body.append(canvas);
  const input = new GameInput(canvas, () => true, () => undefined, touch);
  return { input, cmd: () => decodeCmd(input.sample()) };
}

afterEach(() => { vi.restoreAllMocks(); document.body.innerHTML = ""; });

describe("touch → ticcmd translation", () => {
  it("maps the stick onto the keyboard's speeds, with a dead zone, and returns to zero on release", () => {
    const touch = new TouchInput();
    const { input, cmd } = sampler(touch);
    expect(cmd()).toEqual({ forward: 0, side: 0, turn: 0, buttons: 0 });
    touch.stickDown(1, 100, 300);
    touch.pointerMove(1, 100 + R * 0.1, 300); // inside the dead zone
    expect(cmd()).toEqual({ forward: 0, side: 0, turn: 0, buttons: 0 });
    touch.pointerMove(1, 100, 300 - R); // full deflection up
    expect(cmd()).toEqual({ forward: 25, side: 0, turn: 0, buttons: 0 });
    touch.pointerMove(1, 100 + R, 300); // full right
    expect(cmd()).toEqual({ forward: 0, side: 24, turn: 0, buttons: 0 });
    touch.pointerMove(1, 100 - 5 * R, 300 + 5 * R); // far beyond the radius: clamped, not extrapolated
    const diagonal = cmd();
    expect(isCanonical(diagonal)).toBe(true);
    expect(diagonal.forward).toBe(-17); // trunc(-25 / √2)
    expect(diagonal.side).toBe(-16);   // trunc(-24 / √2)
    touch.toggleRun();
    touch.pointerMove(1, 100, 300 - R);
    expect(cmd().forward).toBe(50);
    touch.pointerMove(1, 100 + R, 300);
    expect(cmd().side).toBe(40);
    touch.pointerUp(1);
    expect(cmd()).toEqual({ forward: 0, side: 0, turn: 0, buttons: 0 });
    expect(touch.run).toBe(true);
    input.dispose();
  });

  it("turns from the look drag once per sample, on the 256-BAM grid, bounded like the mouse", () => {
    const touch = new TouchInput();
    const { cmd } = sampler(touch);
    touch.lookDown(2, 600);
    touch.pointerMove(2, 610, 0);
    expect(cmd().turn).toBe(-1280); // 10 px × 128 BAM, already a multiple of 256
    expect(cmd().turn).toBe(0);     // consumed: a resting finger stops the turn
    touch.pointerMove(2, 607, 0);   // −3 px → 384 BAM → truncated to 256
    expect(cmd().turn).toBe(256);
    touch.pointerMove(2, 607 + 100_000, 0);
    const clamped = cmd();
    expect(clamped.turn).toBe(-32768);
    expect(isCanonical(clamped)).toBe(true);
    touch.pointerMove(2, 607 - 100_000, 0);
    expect(cmd().turn).toBe(32512);
    touch.pointerUp(2);
    touch.pointerMove(2, 0, 0); // an untracked pointer does nothing
    expect(cmd().turn).toBe(0);
  });

  it("keeps a moving stick, a turning finger and a held Fire independent (multi-touch)", () => {
    const touch = new TouchInput();
    const { cmd } = sampler(touch);
    touch.stickDown(1, 100, 300);
    touch.pointerMove(1, 100, 300 - R);
    touch.lookDown(2, 700);
    touch.pointerMove(2, 720, 0);
    touch.press("fire", true);
    touch.press("use", true);
    expect(cmd()).toEqual({ forward: 25, side: 0, turn: -2560, buttons: 3 });
    touch.pointerUp(2); // the look finger lifts; the stick and the buttons stay
    expect(cmd()).toEqual({ forward: 25, side: 0, turn: 0, buttons: 3 });
    touch.press("use", false);
    touch.press("fire", true); // a second finger on Fire
    touch.press("fire", false); // one of them lifts: still firing
    expect(cmd()).toEqual({ forward: 25, side: 0, turn: 0, buttons: 1 });
    touch.press("fire", false);
    touch.pointerUp(1);
    expect(cmd()).toEqual({ forward: 0, side: 0, turn: 0, buttons: 0 });
    touch.press("fire", false); // an unbalanced release never goes negative
    touch.press("fire", true);
    expect(cmd().buttons).toBe(1);
  });

  it("requests a weapon once, like a digit key, and cycles from the current one", () => {
    const touch = new TouchInput();
    const { cmd } = sampler(touch);
    touch.requestWeapon(TouchInput.nextWeapon(1));
    expect(cmd().buttons).toBe(4 | (2 << 3));
    expect(cmd().buttons).toBe(0);
    expect(TouchInput.nextWeapon(7)).toBe(WEAPON_CYCLE[0]);
    expect(TouchInput.nextWeapon(undefined)).toBe(WEAPON_CYCLE[0]);
    expect(TouchInput.nextWeapon(0)).toBe(7);
  });

  it("adds to the keyboard and clears with it on loss of focus", () => {
    const touch = new TouchInput();
    const { input, cmd } = sampler(touch);
    window.dispatchEvent(new KeyboardEvent("keydown", { code: "KeyW", cancelable: true }));
    touch.stickDown(1, 100, 300);
    touch.pointerMove(1, 100 + R, 300);
    expect(cmd()).toMatchObject({ forward: 25, side: 24 });
    touch.toggleRun(); // the run toggle is the keyboard's Shift too
    expect(cmd()).toMatchObject({ forward: 50, side: 40 });
    touch.toggleRun();
    window.dispatchEvent(new KeyboardEvent("keydown", { code: "Digit1", cancelable: true }));
    touch.requestWeapon(7); // keyboard's request wins, the touch one is dropped, never OR'ed
    expect(cmd().buttons).toBe(4);
    touch.press("fire", true);
    window.dispatchEvent(new Event("blur"));
    expect(cmd()).toEqual({ forward: 0, side: 0, turn: 0, buttons: 0 });
    expect(touch.firing).toBe(false);
    input.dispose();
  });
});

const pointer = (type: string, init: { pointerId: number; clientX?: number; clientY?: number }): Event =>
  Object.assign(new MouseEvent(type, { bubbles: true, cancelable: true, clientX: init.clientX ?? 0, clientY: init.clientY ?? 0 }),
    { pointerId: init.pointerId });

describe("touch overlay", () => {
  it("is only mounted for coarse pointers, or when forced by ?touch=", () => {
    expect(isTouchDevice("", window)).toBe(false); // jsdom: no matchMedia, no touch points
    expect(isTouchDevice("?touch=1", window)).toBe(true);
    expect(isTouchDevice("?sim=demo&touch=0", { ...window, matchMedia: () => ({ matches: true }) } as unknown as Window)).toBe(false);
    const coarse = { matchMedia: (q: string) => ({ matches: q === "(pointer: coarse)" }), navigator: { maxTouchPoints: 0 } } as unknown as Window;
    expect(isTouchDevice("", coarse)).toBe(true);
    const touchLaptop = { matchMedia: (q: string) => ({ matches: q === "(hover: hover)" }), navigator: { maxTouchPoints: 10 } } as unknown as Window;
    expect(isTouchDevice("", touchLaptop)).toBe(false);
    const phone = { matchMedia: (q: string) => ({ matches: q === "(hover: none)" }), navigator: { maxTouchPoints: 5 } } as unknown as Window;
    expect(isTouchDevice("", phone)).toBe(true);
  });

  it("feeds the model from pointer events, only while playing, and releases on cancel or hide", () => {
    const touch = new TouchInput();
    const actions = { pause: vi.fn(), toggleMap: vi.fn(), currentWeapon: vi.fn(() => 2) };
    const controls = mountTouchControls(document.body, touch, actions);
    const el = (name: string): HTMLElement => controls.element.querySelector(`[data-touch="${name}"]`)!;
    expect(controls.element.getAttribute("aria-label")).toBe("Touch controls");
    for (const name of ["stick", "look", "fire", "use", "run", "weapon", "pause", "map"]) expect(el(name)).toBeTruthy();

    // Paused: touches are ignored, Pause is hidden.
    el("stick").dispatchEvent(pointer("pointerdown", { pointerId: 1, clientX: 100, clientY: 300 }));
    el("stick").dispatchEvent(pointer("pointermove", { pointerId: 1, clientX: 100, clientY: 300 - R }));
    expect(touch.axes().active).toBe(false);
    expect(el("pause").hidden).toBe(true);

    controls.setPlaying(true);
    expect(el("pause").hidden).toBe(false);
    el("stick").dispatchEvent(pointer("pointerdown", { pointerId: 1, clientX: 100, clientY: 300 }));
    el("stick").dispatchEvent(pointer("pointermove", { pointerId: 1, clientX: 100, clientY: 300 - R }));
    expect(touch.axes()).toMatchObject({ x: 0, y: 1, originX: 100, originY: 300, active: true });
    expect(controls.element.querySelector<HTMLElement>(".touch-base")!.hidden).toBe(false);
    el("look").dispatchEvent(pointer("pointerdown", { pointerId: 2, clientX: 700, clientY: 200 }));
    el("look").dispatchEvent(pointer("pointermove", { pointerId: 2, clientX: 716, clientY: 220 }));
    el("fire").dispatchEvent(pointer("pointerdown", { pointerId: 3, clientX: 850, clientY: 350 }));
    expect(touch.firing).toBe(true);
    expect(el("fire").classList.contains("held")).toBe(true);
    expect(decodeCmd(new GameInput(document.createElement("canvas"), () => true, () => undefined, touch).sample()))
      .toEqual({ forward: 25, side: 0, turn: -2048, buttons: 1 });
    el("fire").dispatchEvent(pointer("pointerup", { pointerId: 3 }));
    el("fire").dispatchEvent(pointer("lostpointercapture", { pointerId: 3 }));
    expect(touch.firing).toBe(false);
    el("look").dispatchEvent(pointer("pointercancel", { pointerId: 2 }));
    el("look").dispatchEvent(pointer("pointermove", { pointerId: 2, clientX: 900, clientY: 220 }));
    expect(touch.consume(false).turn).toBe(0);
    expect(touch.axes().active).toBe(true); // the stick finger is untouched by the look cancel

    el("run").dispatchEvent(pointer("pointerdown", { pointerId: 4 }));
    expect(touch.run).toBe(true);
    expect(el("run").getAttribute("aria-pressed")).toBe("true");
    el("weapon").dispatchEvent(pointer("pointerdown", { pointerId: 5 }));
    expect(touch.consume(false).weapon).toBe(3); // next after the chaingun's predecessor, shotgun (2)
    el("map").dispatchEvent(pointer("pointerdown", { pointerId: 6 }));
    expect(actions.toggleMap).toHaveBeenCalledTimes(1);

    vi.spyOn(document, "hidden", "get").mockReturnValue(true);
    document.dispatchEvent(new Event("visibilitychange"));
    expect(touch.axes().active).toBe(false);
    expect(controls.element.querySelector<HTMLElement>(".touch-base")!.hidden).toBe(true);

    el("pause").dispatchEvent(pointer("pointerdown", { pointerId: 7 }));
    expect(actions.pause).toHaveBeenCalledTimes(1);
    controls.setPlaying(false);
    expect(controls.element.classList.contains("playing")).toBe(false);
    controls.dispose();
    expect(document.body.contains(controls.element)).toBe(false);
  });

  it("shows the orientation notice in portrait until dismissed", () => {
    const notice = document.createElement("div");
    notice.hidden = true;
    const button = document.createElement("button");
    notice.append(button);
    document.body.append(notice);
    let portrait = true;
    const listeners: (() => void)[] = [];
    const win = {
      matchMedia: () => ({ get matches() { return portrait; }, addEventListener: (_: string, fn: () => void) => listeners.push(fn), removeEventListener: () => undefined }),
      addEventListener: () => undefined, removeEventListener: () => undefined, innerWidth: 400, innerHeight: 900,
    } as unknown as Window;
    const stop = watchOrientation(notice, win);
    expect(notice.hidden).toBe(false);
    portrait = false; listeners.forEach(fn => fn());
    expect(notice.hidden).toBe(true);
    portrait = true; listeners.forEach(fn => fn());
    expect(notice.hidden).toBe(false);
    button.click();
    expect(notice.hidden).toBe(true);
    portrait = false; listeners.forEach(fn => fn()); portrait = true; listeners.forEach(fn => fn());
    expect(notice.hidden).toBe(true);
    stop();
  });
});
