import { InputJournal, type JournalExport } from "./inputJournal.js";

export const SAVE_BYTES = 8 * 1024 * 1024;
/** Bound parsing and storage; one explicit save slot, never writes on each tic. */
export function parseSavedGame(text: string): JournalExport {
  if (new Blob([text]).size > SAVE_BYTES) throw new Error("Save exceeds the 8 MB limit.");
  const data = JSON.parse(text) as JournalExport;
  if (!data || !Array.isArray(data.initial) || !Array.isArray(data.checkpoint) || !Array.isArray(data.inputs)) throw new Error("This file is not a saved game.");
  return InputJournal.import(data).export();
}
export function serializeSavedGame(data: JournalExport): string {
  const text = JSON.stringify(data);
  if (new Blob([text]).size > SAVE_BYTES) throw new Error("Save exceeds the 8 MB limit. Your current game is still in memory.");
  return text;
}

export class SavedGameStore {
  private async database(): Promise<IDBDatabase> {
    return new Promise((resolve, reject) => {
      let settled = false;
      const request = indexedDB.open("hellproof-play", 1);
      request.onupgradeneeded = () => request.result.createObjectStore("save");
      request.onsuccess = () => { if (settled) request.result.close(); else { settled = true; resolve(request.result); } };
      request.onerror = () => { settled = true; reject(request.error ?? new Error("Local saves are unavailable.")); };
      request.onblocked = () => { settled = true; reject(new Error("Close other Hellproof tabs to open local saves.")); };
    });
  }
  private async transaction(value?: string): Promise<string | undefined> {
    const db = await this.database();
    try {
      return await new Promise((resolve, reject) => {
        const tx = db.transaction("save", value === undefined ? "readonly" : "readwrite");
        const store = tx.objectStore("save");
        const request = value === undefined ? store.get("current") : store.put(value, "current");
        tx.oncomplete = () => resolve(value === undefined ? request.result as string | undefined : value);
        tx.onabort = () => reject(tx.error ?? request.error ?? new Error("Local save failed. Export a file to keep this game."));
        tx.onerror = () => { /* onabort is authoritative: never announce a partial write. */ };
      });
    } finally { db.close(); }
  }
  async save(data: JournalExport): Promise<void> { await this.transaction(serializeSavedGame(data)); }
  async load(): Promise<JournalExport | undefined> {
    const value = await this.transaction();
    return value === undefined ? undefined : parseSavedGame(value);
  }
}
