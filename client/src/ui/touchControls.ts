// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0

import { TOUCH_TUNING, TouchInput } from "../game/touchInput.js";

/**
 * On-screen controls for touch screens: the DOM half of `game/touchInput.ts`.
 *
 * Left half of the view: a floating joystick (the base appears where the
 * finger lands). Right half: the look zone (drag to turn). Over the right half,
 * the held buttons (Fire, Use), the Run toggle and the Weapon cycle; at the top,
 * Pause and Map. Everything is Pointer Events with per-element capture, so a
 * stick finger, a look finger and a Fire finger are three independent pointers
 * and a finger sliding off a button still releases it. `touch-action: none` and
 * the non-passive `touchmove` handler keep the browser from scrolling, zooming
 * or pull-refreshing under the game.
 *
 * Nothing here decides gameplay: the model only stores what is held, and
 * `GameInput.sample()` quantizes it with the keyboard's own numbers.
 */

export interface TouchControlActions {
  /** Pause button; the central panel's Resume takes it from there. */
  pause(): void;
  toggleMap(): void;
  /** Weapon currently held, vanilla numbering (`hudWeapon`), so the Weapon button cycles from it. */
  currentWeapon(): number | undefined;
}

export interface TouchControls {
  readonly element: HTMLElement;
  /** Zones and held buttons only accept input while the game runs; Pause is only shown then. */
  setPlaying(playing: boolean): void;
  dispose(): void;
}

/**
 * Whether to show the controls. `?touch=1` / `?touch=0` force it (desktop
 * debugging, Playwright); otherwise a coarse primary pointer, or a touch screen
 * with no hover capability, means a phone or tablet. A touch-screen laptop with
 * a mouse keeps the keyboard layout.
 */
export function isTouchDevice(search = globalThis.location?.search ?? "", win: Window = globalThis as unknown as Window): boolean {
  const forced = new URLSearchParams(search).get("touch");
  if (forced === "1") return true;
  if (forced === "0") return false;
  const media = (query: string): boolean => {
    try { return win.matchMedia?.(query).matches ?? false; } catch { return false; }
  };
  const coarse = media("(pointer: coarse)");
  const noHover = media("(hover: none)");
  const touchPoints = (win.navigator?.maxTouchPoints ?? 0) > 0 || "ontouchstart" in win;
  return coarse || (touchPoints && noHover);
}

const pointerId = (event: Event): number => (event as PointerEvent).pointerId ?? 0;
const capture = (el: Element, event: Event): void => {
  try { el.setPointerCapture?.(pointerId(event)); } catch { /* not a pointer event, or already captured */ }
};

export function mountTouchControls(host: HTMLElement, input: TouchInput, actions: TouchControlActions): TouchControls {
  const listeners = new AbortController();
  const options = { signal: listeners.signal };
  let playing = false;

  const element = document.createElement("div");
  element.className = "touch-controls";
  element.setAttribute("aria-label", "Touch controls");
  const zone = (name: "stick" | "look"): HTMLDivElement => {
    const node = document.createElement("div");
    node.className = `touch-zone touch-${name}`;
    node.dataset.touch = name;
    return node;
  };
  const stickZone = zone("stick");
  const lookZone = zone("look");
  const base = document.createElement("div");
  base.className = "touch-base";
  base.style.setProperty("--touch-radius", `${TOUCH_TUNING.stickRadius}px`);
  const knob = document.createElement("div");
  knob.className = "touch-knob";
  base.append(knob);
  stickZone.append(base);

  const button = (name: string, label: string, parent: HTMLElement): HTMLButtonElement => {
    const node = document.createElement("button");
    node.type = "button";
    node.dataset.touch = name;
    node.className = `touch-button touch-${name}`;
    node.textContent = label;
    node.setAttribute("aria-label", name);
    parent.append(node);
    return node;
  };
  const top = document.createElement("div");
  top.className = "touch-top";
  const bottom = document.createElement("div");
  bottom.className = "touch-buttons";
  const map = button("map", "MAP", top);
  const pause = button("pause", "PAUSE", top);
  pause.hidden = true;
  const weapon = button("weapon", "WPN", bottom);
  const run = button("run", "RUN", bottom);
  run.setAttribute("aria-pressed", "false");
  const use = button("use", "USE", bottom);
  const fire = button("fire", "FIRE", bottom);
  element.append(stickZone, lookZone, top, bottom);
  host.append(element);

  const draw = (): void => {
    const axes = input.axes();
    base.hidden = !axes.active;
    if (axes.active) {
      const rect = stickZone.getBoundingClientRect();
      base.style.left = `${axes.originX - rect.left}px`;
      base.style.top = `${axes.originY - rect.top}px`;
      const r = TOUCH_TUNING.stickRadius;
      knob.style.transform = `translate(${(axes.x * r).toFixed(1)}px, ${(-axes.y * r).toFixed(1)}px)`;
    }
    fire.classList.toggle("held", input.firing);
    use.classList.toggle("held", input.using);
    run.setAttribute("aria-pressed", String(input.run));
    run.classList.toggle("held", input.run);
  };

  // Zones: one pointer each, captured so the finger may wander off the zone.
  const bindZone = (node: HTMLElement, down: (id: number, x: number, y: number) => void): void => {
    node.addEventListener("pointerdown", event => {
      event.preventDefault();
      if (!playing) return;
      capture(node, event);
      down(pointerId(event), event.clientX, event.clientY);
      draw();
    }, options);
    node.addEventListener("pointermove", event => {
      input.pointerMove(pointerId(event), event.clientX, event.clientY);
      draw();
    }, options);
    for (const type of ["pointerup", "pointercancel", "lostpointercapture"] as const) {
      node.addEventListener(type, event => { input.pointerUp(pointerId(event)); draw(); }, options);
    }
  };
  bindZone(stickZone, (id, x, y) => input.stickDown(id, x, y));
  bindZone(lookZone, (id, x) => input.lookDown(id, x));

  // Held buttons: press on down, release on up/cancel/capture loss, once per pointer.
  const bindHeld = (node: HTMLButtonElement, name: "fire" | "use"): void => {
    const pressed = new Set<number>();
    node.addEventListener("pointerdown", event => {
      event.preventDefault();
      if (!playing) return;
      const id = pointerId(event);
      if (pressed.has(id)) return;
      pressed.add(id);
      capture(node, event);
      input.press(name, true);
      draw();
    }, options);
    for (const type of ["pointerup", "pointercancel", "lostpointercapture"] as const) {
      node.addEventListener(type, event => {
        const id = pointerId(event);
        if (!pressed.delete(id)) return;
        input.press(name, false);
        draw();
      }, options);
    }
  };
  bindHeld(fire, "fire");
  bindHeld(use, "use");

  // Taps.
  const tap = (node: HTMLButtonElement, action: () => void): void => {
    node.addEventListener("pointerdown", event => { event.preventDefault(); action(); draw(); }, options);
  };
  tap(run, () => { if (playing) input.toggleRun(); });
  tap(weapon, () => { if (playing) input.requestWeapon(TouchInput.nextWeapon(actions.currentWeapon())); });
  tap(pause, () => actions.pause());
  tap(map, () => actions.toggleMap());

  // The browser must not scroll, zoom, select or open a menu under the game.
  element.addEventListener("touchmove", event => event.preventDefault(), { ...options, passive: false });
  element.addEventListener("touchstart", event => { if (event.touches.length > 1) event.preventDefault(); }, { ...options, passive: false });
  element.addEventListener("contextmenu", event => event.preventDefault(), options);
  document.addEventListener("gesturestart", event => event.preventDefault(), options);

  // Losing the pointers (rotation, tab switch, incoming call) releases everything.
  const release = (): void => { input.clear(); draw(); };
  window.addEventListener("blur", release, options);
  window.addEventListener("pagehide", release, options);
  window.addEventListener("resize", release, options);
  window.addEventListener("orientationchange", release, options);
  document.addEventListener("visibilitychange", () => { if (document.hidden) release(); }, options);

  draw();
  return {
    element,
    setPlaying(next: boolean): void {
      if (playing === next) return;
      playing = next;
      element.classList.toggle("playing", next);
      pause.hidden = !next;
      if (!next) release();
    },
    dispose(): void {
      listeners.abort();
      element.remove();
    },
  };
}

/**
 * Shows `notice` while a touch device is held in portrait, until its dismiss
 * button is tapped; the game itself keeps running underneath either way.
 * Returns the unsubscribe function.
 */
export function watchOrientation(notice: HTMLElement, win: Window = window): () => void {
  let dismissed = false;
  const query = (() => { try { return win.matchMedia?.("(orientation: portrait)") ?? null; } catch { return null; } })();
  const portrait = (): boolean => query ? query.matches : win.innerHeight > win.innerWidth;
  const apply = (): void => { notice.hidden = dismissed || !portrait(); };
  const dismiss = (): void => { dismissed = true; apply(); };
  notice.querySelector("button")?.addEventListener("click", dismiss);
  query?.addEventListener?.("change", apply);
  win.addEventListener("resize", apply);
  apply();
  return () => {
    query?.removeEventListener?.("change", apply);
    win.removeEventListener("resize", apply);
    notice.querySelector("button")?.removeEventListener("click", dismiss);
  };
}
