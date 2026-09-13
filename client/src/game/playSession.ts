import type { CairoClient } from "../sim/cairoClient.js";
import type { CairoScheduler } from "../sim/cairoScheduler.js";
import { GameInput } from "./gameInput.js";
import { InputJournal, type JournalExport } from "./inputJournal.js";
import { SavedGameStore, SAVE_BYTES, parseSavedGame, serializeSavedGame } from "./savedGame.js";

export function gameOutcome(status: number): string {
  return ["Paused", "You died", "Level complete", "Run stopped"][status] ?? "Run stopped";
}

/** User operations are serialized around the existing one-command Worker protocol. */
export class PlaySession {
  readonly input: GameInput;
  readonly element = document.createElement("section");
  private readonly title = document.createElement("h1");
  private readonly stats = document.createElement("p");
  private readonly message = document.createElement("p");
  private readonly saveStatus = document.createElement("p");
  private readonly startButton: HTMLButtonElement;
  private readonly buttons: HTMLButtonElement[] = [];
  private operation = false;
  private lastTerminal = false;
  private savedJournal?: InputJournal;
  private savedLength = -1;
  private savedRejected = false;
  private readonly storage = new SavedGameStore();

  constructor(readonly client: CairoClient, readonly scheduler: CairoScheduler, readonly canvas: HTMLCanvasElement,
    host: HTMLElement) {
    this.input = new GameInput(canvas, () => scheduler.isRunning && !client.terminal && !this.operation, () => this.pause());
    this.element.className = "play-session panel";
    this.element.setAttribute("aria-label", "Game controls");
    this.title.textContent = "Hellproof";
    this.message.setAttribute("role", "status");
    this.message.className = "play-message";
    const note = document.createElement("p");
    note.textContent = "Playable preview · some animations are unfinished. Runs are not certified.";
    note.className = "play-note";
    const actions = document.createElement("div");
    actions.className = "play-actions";
    const button = (name: string, click: () => void): HTMLButtonElement => {
      const node = document.createElement("button"); node.type = "button"; node.textContent = name;
      node.addEventListener("click", () => { node.blur(); click(); });
      this.buttons.push(node); actions.append(node); return node;
    };
    this.startButton = button("Start", () => this.start());
    button("Pause", () => this.pause());
    button("Restart", () => { void this.run(async () => {
      await client.restart(); this.message.textContent = "New game ready. Press Start when you're ready.";
    }, true); });
    button("Save", () => { void this.run(async () => {
      await client.checkpoint(); await this.storage.save(client.journal!.export());
      this.savedJournal = client.journal; this.savedLength = client.journal!.length; this.savedRejected = Boolean(client.journal!.rejected);
      this.message.textContent = "Saved on this device. You can reload and choose Load save.";
    }); });
    button("Load save", () => { void this.run(async () => {
      const saved = await this.storage.load();
      if (!saved) throw new Error("No local save yet. Use Save or import a file.");
      await this.restore(saved);
      this.savedJournal = client.journal; this.savedLength = client.journal!.length; this.savedRejected = Boolean(client.journal!.rejected);
      this.message.textContent = "Saved game restored in pause.";
    }); });
    button("Export", () => { void this.run(async () => {
      await client.checkpoint();
      const blob = new Blob([serializeSavedGame(client.journal!.export())], { type: "application/json" });
      const url = URL.createObjectURL(blob), link = document.createElement("a");
      link.href = url; link.download = `hellproof-tic-${client.journal!.ticEnd}.json`; link.click();
      setTimeout(() => URL.revokeObjectURL(url), 1000);
      this.message.textContent = "Save file prepared. Keep the downloaded file to restore this run.";
    }); });
    const file = document.createElement("input");
    file.type = "file"; file.accept = ".json,application/json"; file.hidden = true;
    file.setAttribute("aria-label", "Import saved game");
    file.addEventListener("change", () => {
      const selected = file.files?.[0]; file.value = "";
      if (!selected) return;
      void this.run(async () => {
        if (selected.size > SAVE_BYTES) throw new Error("Save exceeds the 8 MB limit.");
        await this.restore(parseSavedGame(await selected.text()));
        this.message.textContent = "File restored in pause. Use Save to keep it on this device.";
      });
    });
    button("Import", () => { this.pause(); file.click(); });
    const demo = document.createElement("a"); demo.href = "?sim=demo"; demo.textContent = "Renderer demo";
    this.saveStatus.className = "play-note";
    this.element.append(this.title, this.stats, actions, file, this.message, this.saveStatus, note, demo);
    host.append(this.element);
    canvas.addEventListener("click", () => { if (scheduler.isRunning) this.lockPointer(); });
    document.addEventListener("pointerlockchange", () => {
      if (document.pointerLockElement !== canvas) return;
      if (!scheduler.isRunning || this.operation || client.terminal) document.exitPointerLock();
      else this.message.textContent = "Esc or P pauses and releases the mouse.";
    });
    this.refresh();
  }

  private lockPointer(): void {
    if (document.pointerLockElement === this.canvas) return;
    try {
      const lock = this.canvas.requestPointerLock();
      void lock?.then(() => {
        if (document.pointerLockElement === this.canvas && (!this.scheduler.isRunning || this.operation || this.client.terminal)) document.exitPointerLock();
      }).catch(() => { this.message.textContent = "Mouse capture unavailable. Use arrow keys to turn, or click the view to retry."; });
    } catch { this.message.textContent = "Mouse capture unavailable. Use arrow keys to turn."; }
  }
  start(): void {
    if (this.operation || this.client.terminal) return;
    this.input.clear(); this.message.textContent = "Esc or P pauses. Click the view to capture the mouse.";
    this.lockPointer(); this.scheduler.start(); this.refresh();
  }
  pause(): void {
    this.input.clear();
    if (!this.operation) this.scheduler.stop();
    if (document.pointerLockElement === this.canvas) document.exitPointerLock();
    this.refresh();
  }
  error(error: unknown): void {
    this.input.clear();
    if (document.pointerLockElement === this.canvas) document.exitPointerLock();
    this.message.textContent = `Game paused: ${error instanceof Error ? error.message : String(error)}`;
    this.refresh();
  }
  private async quiesce(recovery = false): Promise<void> {
    this.scheduler.stop(); this.input.clear();
    if (document.pointerLockElement === this.canvas) document.exitPointerLock();
    // A paused quantum already owns a sampled word. Finish only that word before
    // snapshot/export/reset; the stopped scheduler cannot submit another one.
    if (this.client.busy) {
      await this.client.resume();
      const deadline = performance.now() + 30_000;
      while (this.client.busy) {
        if (performance.now() > deadline) { await this.client.pause(); throw new Error("The current move did not finish. Your existing journal has been kept."); }
        await new Promise(resolve => setTimeout(resolve, 5));
      }
    }
    try { await this.client.pause(); }
    catch (error) { if (!recovery) throw error; }
  }
  private async run(action: () => Promise<void>, recovery = false): Promise<void> {
    if (this.operation) return;
    this.operation = true; this.message.textContent = "Please wait…"; this.refresh();
    try { await this.quiesce(recovery); await action(); }
    catch (error) { this.message.textContent = `Could not complete: ${error instanceof Error ? error.message : String(error)}`; }
    finally { this.operation = false; this.refresh(); }
  }
  private async restore(data: JournalExport): Promise<void> {
    // Reject different executables before touching the current live VM/journal.
    const imported = InputJournal.import(data);
    if (imported.boundary(imported.ticEnd).prefix.length > 256) {
      throw new Error("This save needs too much replay. Export it again with a recent checkpoint.");
    }
    const current = this.client.journal!;
    if ((["session", "genesis", "step", "wasm"] as const).some(key => data.identity.hashes[key] !== current.identity.hashes[key])) {
      throw new Error("This save belongs to a different game version. Your current run is unchanged.");
    }
    await this.client.checkpoint();
    const backup = current.export();
    try { await this.client.restore(data); }
    catch (error) {
      try { await this.client.restore(backup); }
      catch { throw new Error("Import and recovery failed. Reload your last saved game; the imported file was not saved."); }
      throw new Error(`Import rejected; current run recovered. ${error instanceof Error ? error.message : String(error)}`);
    }
  }
  refresh(): void {
    const journal = this.client.journal, frame = this.client.latest?.snapshot;
    const running = this.scheduler.isRunning && !this.client.terminal;
    if (this.client.terminal && !this.lastTerminal) {
      this.input.clear();
      if (document.pointerLockElement === this.canvas) document.exitPointerLock();
    }
    this.lastTerminal = this.client.terminal;
    const title = this.client.terminal ? gameOutcome(this.client.status) : running ? "Playing" : journal?.length ? "Paused" : "Ready to play";
    if (this.title.textContent !== title) this.title.textContent = title;
    const stats = frame ? `Time ${(frame.stats.levelTime / 35).toFixed(1)}s · Kills ${frame.stats.kills}/${frame.stats.totalKills} · Items ${frame.stats.items}/${frame.stats.totalItems} · Secrets ${frame.stats.secrets}/${frame.stats.totalSecrets}` : "";
    if (this.stats.textContent !== stats) this.stats.textContent = stats;
    this.element.classList.toggle("playing", running);
    for (const button of this.buttons) button.disabled = this.operation;
    this.startButton.disabled = this.operation || this.client.terminal || running;
    this.startButton.textContent = journal?.length ? "Resume" : "Start";
    const saved = journal === this.savedJournal && journal?.length === this.savedLength && Boolean(journal?.rejected) === this.savedRejected;
    const saveStatus = saved ? "Current position saved on this device." : "Save before leaving. Save replaces one local slot; Export keeps a separate file.";
    if (this.saveStatus.textContent !== saveStatus) this.saveStatus.textContent = saveStatus;
  }
}
