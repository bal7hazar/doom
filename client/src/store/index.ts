/** Public surface of the client's local persistence (roadmap P2.5). */
export {
  DEFAULT_DB_NAME,
  SCHEMA_VERSION,
  STORES,
  deleteDatabase,
  openDatabase,
} from "./db.js";
export {
  RunStore,
  type CreateRunInit,
  type InputRecord,
  type ProofRecord,
} from "./runStore.js";
export {
  HELLPROOF_FILE_VERSION,
  HELLPROOF_MAGIC,
  exportFileName,
  exportRun,
  exportRunBlob,
  importRun,
  parseHellproofFile,
  type HellproofManifest,
  type ImportOptions,
  type ImportResult,
  type ParsedHellproofFile,
  type ProofIndexEntry,
} from "./hellproofFile.js";
export {
  PROOF_BYTES_ESTIMATE,
  isQuotaExceeded,
  projectQuota,
  readStorageStatus,
  requestPersistence,
  type QuotaOptions,
  type QuotaWarning,
  type StorageStatus,
} from "./quota.js";
