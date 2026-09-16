// SPDX-License-Identifier: Apache-2.0
/**
 * The on-chain leg of a submission (P4.3, C5/C6): from "the wrapper has folded a batch with a
 * root proof" to "the player has seen what it costs and decided".
 *
 * Nothing here plans, estimates or signs — `client/src/chain/` does all of that, and the CLI in
 * `infra/submit` runs the very same code (D20). What this module adds is the glue the game page
 * needs and the CLI does not:
 *
 * * **configuration** read from Vite variables or URL parameters, refused with a message that
 *   names what is missing rather than a failed RPC call (`readOnChainConfig`);
 * * **the batch** fetched with its root proof felts (`?include=proof`) and mapped onto the
 *   player's own run — the browser knows one address, its own, so the sequence records one
 *   member: `submit_batch` when the run is alone in its batch, `register_member` (the per-player
 *   fallback of D20) when the wrapper folded it with other players' games;
 * * **the proof id**, derived from the batch id so a reload resumes the same router checkpoint
 *   without storing anything (`proofIdFor`);
 * * **the three answers of C6** wired to the run record: "submit" plays the sequence with the
 *   connected signer and the browser's checkpoint echoes, "wait" leaves the batch pending under
 *   the same proof id, "keep offline" sets the flag the wrapper submitter refuses to upload past.
 */

import { checkBatch, membersFromPlacements, type Member, type WrapperBatch } from "../chain/batch.js";
import { parseTokenAmount } from "../chain/commit.js";
import type { PriceSource } from "../chain/prices.js";
import { RpcClient } from "../chain/rpc.js";
import type { StepProgress } from "../chain/sequence.js";
import type { Signer } from "../chain/signer.js";
import { prepareSubmission } from "../chain/submission.js";
import { CostScreen, type Choice } from "../ui/costScreen.js";
import type { RunStore } from "../store/runStore.js";
import type { RunRecord } from "./types.js";

export interface OnChainConfig {
  rpcUrl: string;
  /** `StwoCircuitRouter` with the optimized P4.1 classes (D28). */
  router: string;
  /** `DoomRuns` (P4.2). */
  doomRuns: string;
  /** Entry of `DoomRuns`'s version table. */
  versionId: number;
  /** Level recorded for the run; the wrapper does not return it with the batch. */
  levelId: number;
  /** Router proof id override; derived from the batch id when absent. */
  proofId?: bigint;
  /** Chain id, when known: skips the `starknet_chainId` round trip and seeds the Controller. */
  chainId?: string;
  /** Season sponsoring (R7-A4): the paymaster pays, the cost is still displayed. */
  sponsored: boolean;
  /** Publish the packed input logs (R10-A3), +24 % consumer gas. */
  replay: boolean;
  /**
   * D35 / P4.7: the bounty proposed on the commit screen, in the fee token's smallest unit
   * (`VITE_DEFAULT_BOUNTY` is written in whole tokens, e.g. `0.5`). Zero when unset.
   */
  defaultBounty: bigint;
  /** The fee token, when known up front; read from `DoomRuns.fee_token()` otherwise. */
  feeToken?: string;
}

/** Every setting, its Vite variable and the URL parameter that overrides it. */
export const ON_CHAIN_SETTINGS = {
  rpcUrl: { env: "VITE_RPC_URL", param: "rpc", required: true },
  router: { env: "VITE_ROUTER_ADDRESS", param: "router", required: true },
  doomRuns: { env: "VITE_DOOM_RUNS_ADDRESS", param: "runs", required: true },
  versionId: { env: "VITE_VERSION_ID", param: "version", required: true },
  levelId: { env: "VITE_LEVEL_ID", param: "level", required: false },
  proofId: { env: "VITE_PROOF_ID", param: "proofId", required: false },
  chainId: { env: "VITE_CHAIN_ID", param: "chain", required: false },
  sponsored: { env: "VITE_SPONSORED", param: "sponsored", required: false },
  replay: { env: "VITE_REPLAY", param: "replay", required: false },
  defaultBounty: { env: "VITE_DEFAULT_BOUNTY", param: "bounty", required: false },
  feeToken: { env: "VITE_FEE_TOKEN", param: "feeToken", required: false },
} as const;

export type OnChainConfigResult =
  | { ok: true; config: OnChainConfig }
  | { ok: false; missing: string[]; message: string };

const isAddress = (s: string): boolean => /^0x[0-9a-fA-F]{1,64}$/.test(s);
const truthy = (s: string | undefined): boolean => s !== undefined && ["1", "true", "yes"].includes(s.toLowerCase());

/**
 * Reads the configuration from Vite's `import.meta.env` and the page's query string (a parameter
 * wins over a variable, as the leaderboard page does with `rpc`/`runs`/`version`).
 *
 * A missing or malformed value is not an exception: the game page must boot without any of it,
 * and the player only learns about the gap when they press "Submit" — with the names to set.
 */
export function readOnChainConfig(
  env: Record<string, unknown> | undefined,
  search = "",
): OnChainConfigResult {
  const params = new URLSearchParams(search);
  const read = (key: keyof typeof ON_CHAIN_SETTINGS): string | undefined => {
    const setting = ON_CHAIN_SETTINGS[key];
    const fromParam = params.get(setting.param);
    if (fromParam !== null && fromParam !== "") return fromParam;
    const fromEnv = env?.[setting.env];
    return typeof fromEnv === "string" && fromEnv !== "" ? fromEnv : undefined;
  };
  const label = (key: keyof typeof ON_CHAIN_SETTINGS): string =>
    `${ON_CHAIN_SETTINGS[key].env} (or ?${ON_CHAIN_SETTINGS[key].param}=)`;

  const missing: string[] = [];
  const rpcUrl = read("rpcUrl");
  if (!rpcUrl) missing.push(label("rpcUrl"));
  const router = read("router");
  if (!router || !isAddress(router)) missing.push(label("router"));
  const doomRuns = read("doomRuns");
  if (!doomRuns || !isAddress(doomRuns)) missing.push(label("doomRuns"));
  const versionRaw = read("versionId");
  const versionId = versionRaw === undefined ? Number.NaN : Number(versionRaw);
  if (!Number.isInteger(versionId) || versionId < 0) missing.push(label("versionId"));
  const levelRaw = read("levelId");
  const levelId = levelRaw === undefined ? 1 : Number(levelRaw);
  if (!Number.isInteger(levelId) || levelId < 0) missing.push(label("levelId"));
  const proofRaw = read("proofId");
  let proofId: bigint | undefined;
  if (proofRaw !== undefined) {
    try {
      proofId = BigInt(proofRaw);
    } catch {
      missing.push(label("proofId"));
    }
  }
  const bountyRaw = read("defaultBounty");
  let defaultBounty = 0n;
  if (bountyRaw !== undefined) {
    try {
      defaultBounty = parseTokenAmount(bountyRaw);
    } catch {
      missing.push(label("defaultBounty"));
    }
  }
  const feeToken = read("feeToken");
  if (feeToken !== undefined && !isAddress(feeToken)) missing.push(label("feeToken"));

  if (missing.length) {
    return {
      ok: false,
      missing,
      message:
        `on-chain submission is not configured — set ${missing.join(", ")}` +
        `; the run stays on this device and can be submitted later (C6)`,
    };
  }
  const chainId = read("chainId");
  return {
    ok: true,
    config: {
      rpcUrl: rpcUrl!,
      router: router!,
      doomRuns: doomRuns!,
      versionId,
      levelId,
      ...(proofId === undefined ? {} : { proofId }),
      ...(chainId ? { chainId } : {}),
      sponsored: truthy(read("sponsored")),
      replay: truthy(read("replay")),
      defaultBounty,
      ...(feeToken ? { feeToken } : {}),
    },
  };
}

/** Proof ids are felts; keep them under the field's 251 bits. */
const PROOF_ID_BITS = 250n;

/**
 * The router keys its checkpoint on `(caller, proof_id)`, so the id must be the same on every
 * attempt for the same batch and different for the next one. Deriving it from the wrapper's
 * batch id gives both without a second piece of state to lose: a hex id is read as a number,
 * anything else is hashed into the same range. Never zero — `--proof-id` conventions start at 1.
 */
export function proofIdFor(batchId: string): bigint {
  const hex = /^(?:0x)?([0-9a-fA-F]+)$/.exec(batchId)?.[1];
  let id: bigint;
  if (hex) {
    id = BigInt("0x" + hex.slice(0, Number(PROOF_ID_BITS / 4n)));
  } else {
    id = 0n;
    for (const ch of batchId) id = (id * 131n + BigInt(ch.codePointAt(0)!)) % (1n << PROOF_ID_BITS);
  }
  return id === 0n ? 1n : id;
}

export interface OnChainDeps {
  config: OnChainConfig;
  store: RunStore;
  /** Where the screen is mounted. */
  host: HTMLElement;
  log: (message: string) => void;
  /** `GET /v1/batches/{id}?include=proof`, parsed. */
  fetchBatch: (batchId: string) => Promise<WrapperBatch>;
  /** The Controller in the browser; a devnet key in tests. Connected only once a batch is ready. */
  connectSigner: (config: OnChainConfig) => Promise<Signer>;
  /** C6: the player asked for the run to stay on this device. */
  onKeepOffline: () => Promise<void>;
  rpc?: RpcClient;
  priceSource?: PriceSource;
  /** `document` to build the screen in; the host's by default. */
  document?: Document;
}

export interface OnChainOutcome {
  /** The C6 answer, or `none` when the screen could not be shown or was closed. */
  choice: Choice | "none";
  /** The fact the router registered, when the sequence reached the end of the FRI walk. */
  fact?: string;
  steps?: StepProgress[];
  error?: string;
}

/** The last on-chain state of a run, as `RunSubmissionState.chainStatus`. */
export type ChainStatus = "waiting" | "submitting" | "done" | "failed";

export class OnChainSubmitter {
  private readonly deps: OnChainDeps;

  constructor(deps: OnChainDeps) {
    this.deps = deps;
  }

  /**
   * Shows the cost screen for a folded batch and resolves once the player's choice has run its
   * course: "wait" and "keep offline" resolve at once, "submit" once the sequence has finished or
   * stopped. A stopped sequence leaves the screen up with its "Resume" button — that path keeps
   * updating the run record but no longer holds this promise.
   */
  async open(run: RunRecord, batchId: string): Promise<OnChainOutcome> {
    const { config, store, log } = this.deps;
    if (run.keepOffline) {
      log("run kept offline (C6): clear the flag before submitting");
      return { choice: "none" };
    }
    const wrapperRunId = run.submission.runId;
    if (!wrapperRunId) {
      log("this run has no wrapper id: upload it before submitting on chain");
      return { choice: "none" };
    }

    const batch = await this.deps.fetchBatch(batchId);
    if (!batch.rootProofFelts?.length) {
      throw new Error(`batch ${batchId} came back without root proof felts (fetch with ?include=proof)`);
    }
    const runIds = new Set(batch.placements.map((p) => p.runId));
    if (!runIds.has(wrapperRunId)) {
      throw new Error(`batch ${batchId} does not contain run ${wrapperRunId}`);
    }

    // The address is the one thing `prepareSubmission` needs that only the wallet knows.
    const signer = await this.deps.connectSigner(config);
    const proofId = config.proofId ?? proofIdFor(batchId);
    const players = { [wrapperRunId]: signer.address };
    const [member] = membersFromPlacements(batch.placements, {
      players,
      levelIds: {},
      defaultLevelId: config.levelId,
    }) as [Member];
    const prepared = prepareSubmission({
      batch,
      router: config.router,
      doomRuns: config.doomRuns,
      versionId: config.versionId,
      proofId,
      players,
      defaultLevelId: config.levelId,
      replay: config.replay,
      // Alone in the batch: `submit_batch` records the game. Folded with other players' games:
      // `register_member` records ours and leaves theirs to them (D20).
      ...(runIds.size > 1 ? { singleMember: member } : {}),
    });
    const problems = checkBatch(batch, prepared.members, BigInt(run.genesis));
    if (problems.length) {
      throw new Error(`the batch would be rejected on chain, nothing is paid for: ${problems.join("; ")}`);
    }
    log(
      `batch ${batchId}: ${batch.leaves.length} leaves, ${prepared.phases.length} verifier ` +
        `transaction(s) then ${prepared.sequence.consumer.call.entrypoint} — proof id ${proofId}` +
        `, signer ${signer.kind} ${signer.address.slice(0, 10)}…`,
    );
    await store.updateSubmission(run.id, { proofId: "0x" + proofId.toString(16), chainStatus: "waiting" });

    const rpc = this.deps.rpc ?? new RpcClient(config.rpcUrl);
    const doc = this.deps.document ?? this.deps.host.ownerDocument;
    const overlay = doc.createElement("section");
    overlay.className = "panel onchain-overlay";
    overlay.setAttribute("aria-label", "On-chain submission");
    const screenEl = doc.createElement("div");
    const close = doc.createElement("button");
    close.type = "button";
    close.dataset["act"] = "close";
    close.textContent = "Close";
    overlay.append(screenEl, close);
    this.deps.host.append(overlay);

    return new Promise<OnChainOutcome>((resolve) => {
      let settled = false;
      const finish = (outcome: OnChainOutcome, remove: boolean): void => {
        if (remove) overlay.remove();
        if (settled) return;
        settled = true;
        resolve(outcome);
      };
      let chosen: Choice | null = null;
      const screen = new CostScreen(screenEl, {
        rpc,
        sequence: prepared.sequence,
        signer,
        ...(this.deps.priceSource ? { priceSource: this.deps.priceSource } : {}),
        ...(config.chainId ? { chainId: config.chainId } : {}),
        onChoice: (choice) => {
          chosen = choice;
          if (choice === "wait") {
            log(`batch ${batchId} kept waiting: nothing sent, press Submit again later (proof id ${proofId})`);
            void store.updateSubmission(run.id, { chainStatus: "waiting" });
            finish({ choice }, true);
          } else if (choice === "offline") {
            void this.deps.onKeepOffline().then(() => finish({ choice }, true));
          } else {
            log(`submitting on chain from ${signer.address.slice(0, 10)}…`);
            void store.updateSubmission(run.id, { chainStatus: "submitting" });
          }
        },
        onDone: (result) => {
          log(result.fact ? `fact registered: ${result.fact}` : "recorded on chain");
          void store.updateSubmission(run.id, {
            chainStatus: "done",
            ...(result.fact ? { fact: result.fact } : {}),
          });
          finish({ choice: "submit", steps: result.steps, ...(result.fact ? { fact: result.fact } : {}) }, false);
        },
        onFailed: (error) => {
          log(`on-chain submission stopped: ${error} — the checkpoint is kept, Resume continues from there`);
          void store.updateSubmission(run.id, { chainStatus: "failed", error });
          finish({ choice: chosen ?? "none", error }, false);
        },
      });
      close.addEventListener("click", () => {
        // Closing before choosing is "wait"; closing later leaves the sequence where it is.
        if (chosen === null) log(`batch ${batchId} kept waiting: nothing sent`);
        finish({ choice: chosen ?? "wait" }, true);
      });
      void screen.open();
    });
  }
}
