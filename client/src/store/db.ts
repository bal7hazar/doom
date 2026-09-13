/**
 * A ~120-line promise wrapper over IndexedDB. No dependency: the client ships a
 * WAD, a WebGL renderer and a 45 MB prover already, and what P2.5 needs from a
 * database is five object stores and `getAll`.
 */

/** The stores the client keeps. Bumping `SCHEMA_VERSION` must migrate all of them. */
export const STORES = {
  /** One record per game (`RunRecord`). */
  runs: "runs",
  /** One record per segment, keyed `[runId, index]` (`SegmentRecord`). */
  segments: "segments",
  /** The packed ticcmd journal of a run, keyed `runId`. */
  inputs: "inputs",
  /** The bincode proof bytes, keyed `[runId, index]` — ~4 MB each, kept apart. */
  proofs: "proofs",
  /** Small key/value settings (the "keep offline" default, the wrapper URL, …). */
  meta: "meta",
} as const;

export const SCHEMA_VERSION = 1;
export const DEFAULT_DB_NAME = "hellproof";

export type IdbFactory = IDBFactory;

function request<T>(req: IDBRequest<T>): Promise<T> {
  return new Promise((resolve, reject) => {
    req.onsuccess = (): void => resolve(req.result);
    req.onerror = (): void => reject(req.error ?? new Error("IndexedDB request failed"));
  });
}

function transactionDone(tx: IDBTransaction): Promise<void> {
  return new Promise((resolve, reject) => {
    tx.oncomplete = (): void => resolve();
    tx.onerror = (): void => reject(tx.error ?? new Error("IndexedDB transaction failed"));
    tx.onabort = (): void => reject(tx.error ?? new DOMException("aborted", "AbortError"));
  });
}

/** Opens (and migrates) the database. */
export async function openDatabase(
  name = DEFAULT_DB_NAME,
  factory: IdbFactory = globalThis.indexedDB,
): Promise<IDBDatabase> {
  if (!factory) throw new Error("IndexedDB is not available in this context");
  const req = factory.open(name, SCHEMA_VERSION);
  req.onupgradeneeded = (): void => {
    const db = req.result;
    if (!db.objectStoreNames.contains(STORES.runs)) {
      db.createObjectStore(STORES.runs, { keyPath: "id" });
    }
    if (!db.objectStoreNames.contains(STORES.segments)) {
      const store = db.createObjectStore(STORES.segments, { keyPath: ["runId", "index"] });
      store.createIndex("byRun", "runId", { unique: false });
    }
    if (!db.objectStoreNames.contains(STORES.inputs)) {
      db.createObjectStore(STORES.inputs, { keyPath: "runId" });
    }
    if (!db.objectStoreNames.contains(STORES.proofs)) {
      const store = db.createObjectStore(STORES.proofs, { keyPath: ["runId", "index"] });
      store.createIndex("byRun", "runId", { unique: false });
    }
    if (!db.objectStoreNames.contains(STORES.meta)) {
      db.createObjectStore(STORES.meta, { keyPath: "key" });
    }
  };
  const db = await request(req);
  // A second tab upgrading the schema must not leave this one on a stale handle.
  db.onversionchange = (): void => db.close();
  return db;
}

/** Runs `fn` inside one transaction and resolves when the transaction commits. */
export async function withTransaction<T>(
  db: IDBDatabase,
  storeNames: string | string[],
  mode: IDBTransactionMode,
  fn: (tx: IDBTransaction) => Promise<T> | T,
): Promise<T> {
  const tx = db.transaction(storeNames, mode);
  const done = transactionDone(tx);
  let result: T;
  try {
    result = await fn(tx);
  } catch (error) {
    try {
      tx.abort();
    } catch {
      /* already finished */
    }
    throw error;
  }
  await done;
  return result;
}

export function put<T>(tx: IDBTransaction, store: string, value: T): Promise<IDBValidKey> {
  return request(tx.objectStore(store).put(value as unknown as Record<string, unknown>));
}

export function get<T>(tx: IDBTransaction, store: string, key: IDBValidKey): Promise<T | undefined> {
  return request(tx.objectStore(store).get(key) as IDBRequest<T | undefined>);
}

export function getAll<T>(
  tx: IDBTransaction,
  store: string,
  query?: IDBKeyRange | IDBValidKey,
): Promise<T[]> {
  return request(tx.objectStore(store).getAll(query) as IDBRequest<T[]>);
}

export function getAllFromIndex<T>(
  tx: IDBTransaction,
  store: string,
  index: string,
  query: IDBKeyRange | IDBValidKey,
): Promise<T[]> {
  return request(tx.objectStore(store).index(index).getAll(query) as IDBRequest<T[]>);
}

export function remove(tx: IDBTransaction, store: string, key: IDBValidKey | IDBKeyRange): Promise<void> {
  return request(tx.objectStore(store).delete(key)).then(() => undefined);
}

/**
 * Every key in `[runId, *]`: the compound-key range one run occupies.
 *
 * `[runId]` sorts before `[runId, n]` (a shorter array is the smaller key) and
 * `[runId, []]` after it (an array sorts after every number), so the bound is
 * exact without naming an index.
 */
export function runKeyRange(runId: string): IDBKeyRange {
  return IDBKeyRange.bound([runId], [runId, []]);
}

/** Deletes the whole database — the "explicit reset" C6 asks for, across runs. */
export function deleteDatabase(
  name = DEFAULT_DB_NAME,
  factory: IdbFactory = globalThis.indexedDB,
): Promise<void> {
  return new Promise((resolve, reject) => {
    const req = factory.deleteDatabase(name);
    req.onsuccess = (): void => resolve();
    req.onerror = (): void => reject(req.error ?? new Error("deleteDatabase failed"));
    req.onblocked = (): void => resolve();
  });
}
