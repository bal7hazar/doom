import type { InputJournal } from "../game/inputJournal.js";
import { createDoomProgram, type DoomProgram, type DoomProgramOptions } from "./doomProgram.js";
import { parseHellproofFile } from "../store/hellproofFile.js";
import { unpackLog } from "./ticcmd.js";
import type { ProveSession } from "./session.js";

/** An archive retains its own journal object: restarting Cairo cannot change its provider. */
export interface GameProofRun { journal: InputJournal; runId?: string }
export interface GameProofBridgeOptions {
  createSession(program: DoomProgram, runId?: string, imported?: ArrayBuffer, signal?: AbortSignal): Promise<ProveSession>;
  createProgram?: (options: DoomProgramOptions) => Promise<DoomProgram>;
  notify(message: string): void;
  archived?(run: GameProofRun): void;
}
/** Coordinates lazy proof UI without owning the simulation or starting a proof. */
export class GameProofBridge {
  private imported?: ArrayBuffer;
  private live?: GameProofRun;
  private selected?: GameProofRun;
  private current?: ProveSession;
  private controller?: AbortController;
  private opening?: Promise<ProveSession | undefined>;
  private epoch = 0;
  private closed = false;
  private cleanup: Promise<void> = Promise.resolve();
  private syncing = false;
  constructor(private readonly options: GameProofBridgeOptions) {}
  get session(): ProveSession | undefined { return this.current; }
  get currentRun(): GameProofRun | undefined { return this.live; }
  observe(journal: InputJournal): void {
    if (this.closed || this.live?.journal === journal) return;
    const prior = this.live;
    if (prior) this.options.archived?.(prior);
    this.live = { journal };
    this.select(this.live);
  }
  select(run = this.live): void {
    this.retire();
    this.selected = run; this.imported = undefined;
  }
  async importFile(data: ArrayBuffer): Promise<ProveSession | undefined> {
    const { manifest } = parseHellproofFile(data);
    if (manifest.run.program !== "doom") throw new Error("This file uses a different program. Open its matching demo/version explicitly; the real game never uses the stub.");
    this.options.notify("Opening proof file locally; checking executable identity…");
    this.select(); this.imported = data;
    return this.open();
  }
  private retire(): void {
    ++this.epoch;
    this.controller?.abort(); this.controller = undefined; this.opening = undefined;
    const session = this.current; this.current = undefined;
    if (session) {
      session.element.remove(); session.cancelVerification();
      // Stop synchronous Worker activity before waiting for IndexedDB.
      void session.pipeline.stop(true).catch(error => this.options.notify(String(error)));
      this.cleanup = this.cleanup.then(async () => {
        try { await session.pipeline.syncGameJournal(); }
        catch (error) { this.options.notify(`Journal retained in game archive: ${String(error)}`); }
        finally { await session.dispose(); }
      }).catch(error => this.options.notify(String(error)));
    }
  }
  async open(): Promise<ProveSession | undefined> {
    if (this.closed) throw new Error("Proof bridge is closed");
    if (this.current) return this.current;
    if (this.opening) return this.opening;
    const run = this.selected ?? this.live;
    if (!run) throw new Error("The game journal is not ready");
    const imported = this.imported;
    const epoch = this.epoch, controller = new AbortController(); this.controller = controller;
    const stillCurrent = () => !this.closed && epoch === this.epoch;
    this.opening = (async () => {
      let program: DoomProgram | undefined;
      try {
        await this.cleanup;
        if (!stillCurrent()) return undefined;
        const manifest = imported ? parseHellproofFile(imported).manifest : undefined;
        const source: DoomProgramOptions = manifest ? { resume: { run: manifest.run,
          words: [...unpackLog(manifest.inputs.packed, manifest.inputs.ticCount - manifest.inputs.tail.length), ...manifest.inputs.tail] } }
          : { journal: () => run.journal.export() };
        program = await (this.options.createProgram ?? createDoomProgram)({ ...source, signal: controller.signal });
        if (!stillCurrent()) { program.dispose(); return undefined; }
        const session = await this.options.createSession(program, imported ? undefined : run.runId, imported, controller.signal);
        if (!stillCurrent()) { await session.dispose(); return undefined; }
        if (!imported) run.runId = session.pipeline.state.runId;
        this.current = session;
        this.options.notify(imported ? "Proof file resumed locally. No new proof has been generated." : "Real game journal attached. This run is not certified; export remains available if the resource check refuses it.");
        return session;
      } catch (error) {
        program?.dispose();
        if (stillCurrent()) this.options.notify(`Proof preparation unavailable: ${String(error)}. The game journal can still be exported.`);
        return undefined;
      } finally { if (stillCurrent()) this.opening = undefined; }
    })();
    return this.opening;
  }
  /** Called on a low-frequency UI timer, never on every animation frame. */
  async sync(): Promise<void> {
    if (this.syncing || !this.current) return;
    this.syncing = true;
    try { await this.current.pipeline.syncGameJournal(); }
    catch (error) { this.options.notify(`Journal sync failed: ${String(error)}. Export the game journal before recovery.`); }
    finally { this.syncing = false; }
  }
  async settle(): Promise<void> { await this.cleanup; }
  /** BFCache stops proof workers; the game lifecycle independently retains its VM. */
  suspend(): void { this.retire(); }
  async dispose(): Promise<void> { this.closed = true; this.retire(); await this.cleanup; }
}

/** Small page adapter; the real route has no path to createStubProgram. */
export function mountGameProofUI(host: HTMLElement): {
  bridge: GameProofBridge; toggle(): Promise<void>; dispose(): Promise<void>;
} {
  const element = document.createElement("section");
  element.style.zIndex = "3"; element.style.maxHeight = "80vh";
  element.className = "panel proof-queue-overlay"; element.hidden = true;
  element.setAttribute("aria-label", "Real game proof");
  const title = document.createElement("h2"); title.textContent = "Real game · local proof";
  const status = document.createElement("p"); status.setAttribute("role", "status");
  status.textContent = "This run is not certified. Proof requires a fresh resource check. Your journal remains exportable if it is refused.";
  const actions = document.createElement("div"), archives = document.createElement("div"), panelHost = document.createElement("div");
  actions.className = "proof-queue-actions"; archives.className = "proof-queue-actions";
  const download = (blob: Blob, filename: string) => {
    const url = URL.createObjectURL(blob), link = document.createElement("a");
    link.href = url; link.download = filename; link.click(); setTimeout(() => URL.revokeObjectURL(url), 1000);
  };
  const report = (error: unknown) => { status.textContent = String(error); };
  const button = (parent: HTMLElement, name: string, action: () => Promise<unknown> | void) => {
    const b = document.createElement("button"); b.type = "button"; b.textContent = name;
    b.addEventListener("click", () => { void Promise.resolve().then(action).catch(report); }); parent.append(b);
  };
  const exportJournal = async (run: GameProofRun) => {
    const { serializeSavedGame } = await import("../game/savedGame.js");
    download(new Blob([serializeSavedGame(run.journal.export())], { type: "application/json" }), `hellproof-game-tic-${run.journal.ticEnd}.json`);
  };
  const savedIds = new Set<string>();
  const bridge = new GameProofBridge({
    notify: report,
    archived(run) { button(archives, `Export previous game (${run.journal.length} tics)`, () => exportJournal(run)); },
    async createSession(program, runId, imported, signal) {
      const { ProveSession } = await import("./session.js");
      if (imported) {
        const { RunStore } = await import("../store/runStore.js");
        const { importRun } = await import("../store/hellproofFile.js");
        const store = await RunStore.open();
        try { runId = (await importRun(store, imported)).runId; } finally { store.close(); }
      }
      const session = await ProveSession.create({ host: panelHost, program, runId, signal, wrapperUrl: null,
        onImport: async file => { await bridge.importFile(await file.arrayBuffer()); } });
      try { await session.setKeepOffline(true); }
      catch (error) { await session.dispose(); throw error; }
      const proofButton = session.element.querySelector("[data-act=prove]");
      if (proofButton) proofButton.textContent = "Check resources / prove";
      const id = session.pipeline.state.runId;
      if (!savedIds.has(id)) {
        savedIds.add(id);
        button(archives, `Export stored run ${id.slice(0, 8)}`, async () => {
          await bridge.settle();
          if (bridge.session?.pipeline.state.runId === id) await bridge.sync();
          const { RunStore } = await import("../store/runStore.js");
          const { exportRunBlob } = await import("../store/hellproofFile.js");
          const store = await RunStore.open();
          try { download(await exportRunBlob(store, id), `${id}.hellproof`); } finally { store.close(); }
        });
      }
      return session;
    },
  });
  button(actions, "Current game", async () => { bridge.select(); await bridge.open(); });
  button(actions, "Export game journal", () => {
    const run = bridge.currentRun; if (!run) throw new Error("No game journal yet"); return exportJournal(run);
  });
  const file = document.createElement("input"); file.type = "file"; file.accept = ".hellproof"; file.hidden = true;
  file.setAttribute("aria-label", "Resume real proof file");
  file.addEventListener("change", () => {
    const selected = file.files?.[0]; file.value = "";
    if (selected) void selected.arrayBuffer().then(data => bridge.importFile(data)).catch(report);
  });
  button(actions, "Import / resume proof file", () => file.click());
  button(actions, "Close", () => { element.hidden = true; });
  element.append(title, status, actions, file, panelHost, archives); host.append(element);
  const timer = setInterval(() => { void bridge.sync(); }, 1000);
  const hide = (event: PageTransitionEvent) => {
    if (event.persisted) bridge.suspend(); else void dispose();
  };
  window.addEventListener("pagehide", hide);
  const dispose = async () => { clearInterval(timer); window.removeEventListener("pagehide", hide); await bridge.dispose(); element.remove(); };
  return { bridge, async toggle() {
    element.hidden = !element.hidden;
    if (!element.hidden) await bridge.open();
  }, dispose };
}
