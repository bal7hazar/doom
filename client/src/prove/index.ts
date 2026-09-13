/** Public surface of the client's proving pipeline (roadmap P3.2). */
export * from "./types.js";
export { feltEquals, feltToNumber, feltValue, normalizeFelt, toFelt } from "./felt.js";
export {
  TICS_PER_FELT,
  TicLog,
  decodeCmd,
  encodeCmd,
  isCanonical,
  pack7,
  packLog,
  quantize,
  unpack7,
  unpackLog,
  type TicCmd,
} from "./ticcmd.js";
export {
  createStubProgram,
  decodeSegmentOutput,
  splitPreimage,
  type SegmentProgram,
  type SegmentRequest,
  type StubProgramOptions,
} from "./program.js";
export {
  DEFAULT_PLANNER_CONFIG,
  SegmentPlanner,
  nextPow2,
  rawMaxComponentRows,
  type PlannerConfig,
  type PlannerObservation,
  type PlannerVerdict,
} from "./planner.js";
export { statusName, verifyChain, type ChainOptions, type ChainResult } from "./chain.js";
export {
  ProverClient,
  ProverGoneError,
  ProverTimeoutError,
  type ProverClientOptions,
} from "./proverClient.js";
export { ProofPipeline, autoThreadCount, type PipelineOptions, type PipelineState } from "./pipeline.js";

export { createDoomProgram, DoomPreparationClient, type DoomProgram, type DoomProgramOptions } from "./doomProgram.js";
export { D29_PROOF_ARTIFACTS } from "./doomArtifacts.js";
