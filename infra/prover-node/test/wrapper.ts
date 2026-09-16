// SPDX-License-Identifier: Apache-2.0
/**
 * Test doubles for the two network sides: an in-memory wrapper (`fetch`) implementing the
 * resumable upload routes and `GET /v1/batches/{id}`, and a mocked Starknet node for the D28
 * sequence. The wrapper's batch is either the proved `B2-1_doom` fixture (`batch: "fixture"`)
 * or built from the segments the node uploaded (`batch: "uploads"`), always with the fixture's
 * real root proof so `prepareSubmission` parses genuine FRI sections.
 */
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { hash } from "starknet";
import { vi } from "vitest";

import type { ResourceBounds, RpcClient } from "../../../client/src/chain/rpc.js";
import { WrapperClient } from "../../../prover/wrapper/client-ts/src/index.js";
import { rootProofFelts } from "../../submit/src/fixture.js";
import { FIXTURE_DIR } from "./fixtures.js";

export interface FakeWrapperOptions {
  held?: number[];
  pollsUntilDone?: number;
  swapLeaves?: boolean;
  batch?: "fixture" | "uploads";
}

type Node = { Composite?: { circuit_hash: number[]; subtasks: Node[] }; Plain?: { output_preimage: string[] } };

export function fakeWrapper(runId: string, options: FakeWrapperOptions = {}) {
  const held = new Map<number, { output_preimage: string[] }>((options.held ?? []).map((i) => [i, { output_preimage: [] }]));
  let status = "collecting";
  let polls = 0;
  const calls: string[] = [];
  const fixtureOutput = JSON.parse(readFileSync(join(FIXTURE_DIR, "packed_output.json"), "utf8")) as Node;
  const proof = rootProofFelts(FIXTURE_DIR).map((f) => "0x" + f.toString(16));
  const mvHash = fixtureOutput.Composite!.circuit_hash;
  const leafHash = fixtureOutput.Composite!.subtasks[0]!.Composite!.circuit_hash;

  const batch = (): { leaves: unknown[]; packed_output: Node } => {
    if ((options.batch ?? "fixture") === "fixture") {
      return {
        leaves: [
          { position: 0, run_id: runId, segment_index: options.swapLeaves ? 1 : 0, leaf_key: "k0" },
          { position: 1, run_id: runId, segment_index: options.swapLeaves ? 0 : 1, leaf_key: "k1" },
          { position: 2, run_id: "someone-else", segment_index: 0, leaf_key: "k2" },
        ],
        packed_output: fixtureOutput,
      };
    }
    const indices = [...held.keys()].sort((a, b) => a - b);
    return {
      leaves: indices.map((i, position) => ({ position, run_id: runId, segment_index: i, leaf_key: `k${i}` })),
      packed_output: {
        Composite: {
          circuit_hash: mvHash,
          subtasks: indices.map((i) => ({
            Composite: { circuit_hash: leafHash, subtasks: [{ Plain: { output_preimage: held.get(i)!.output_preimage } }] },
          })),
        },
      },
    };
  };

  const json = (body: unknown, code = 200) =>
    new Response(JSON.stringify(body), { status: code, headers: { "content-type": "application/json" } });
  const fetch = async (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const url = new URL(String(input));
    const method = init?.method ?? "GET";
    calls.push(`${method} ${url.pathname}${url.search}`);
    const m = url.pathname.match(/^\/v1\/runs\/([^/]+)(?:\/(segments)(?:\/(\d+))?|\/(complete))?$/);
    if (m) {
      if (m[1] !== runId) return json({ error: "not found" }, 404);
      if (m[2] === "segments" && m[3] !== undefined && method === "PUT") {
        const body = JSON.parse(String(init?.body)) as { output_preimage: string[] };
        held.set(Number(m[3]), body);
        return json({ run_id: runId, index: Number(m[3]), verified: true, verify_ms: 20, sha256: "ab", size_bytes: String(init?.body).length });
      }
      if (m[2] === "segments") return json({ run_id: runId, status, held: [...held.keys()], segments: [] });
      if (m[4] === "complete") {
        status = "queued";
        return json({ run_id: runId, status, segments: held.size });
      }
      polls++;
      if (status !== "collecting" && polls >= (options.pollsUntilDone ?? 2)) status = "done";
      return json({
        run_id: runId, status, program: "doom_run", solo: false, batch_id: status === "done" ? "B2-1_doom" : undefined,
        created_at_ms: 0, updated_at_ms: 0, progress: {}, segments: [], timings: {},
      });
    }
    if (url.pathname === "/v1/batches/B2-1_doom") {
      const withProof = url.searchParams.get("include")?.includes("proof");
      return json({ batch_id: "B2-1_doom", status: "done", runs: [runId], created_at_ms: 0, ...batch(), ...(withProof ? { root_proof_felts: proof } : {}) });
    }
    return json({ error: `unexpected ${method} ${url.pathname}` }, 500);
  };
  return { client: new WrapperClient({ baseUrl: "http://wrapper.test", fetch: fetch as typeof globalThis.fetch }), calls, held };
}

export const bound: ResourceBounds = {
  l1_gas: { max_amount: "0x186a0", max_price_per_unit: "0x1" },
  l1_data_gas: { max_amount: "0x200", max_price_per_unit: "0x1" },
  l2_gas: { max_amount: "0x20000000", max_price_per_unit: "0x1" },
};

export interface MockRpcOptions {
  tag: number;
  registered?: boolean;
  steps?: number;
  /** The `Commitment` view: status (1 PENDING, 2 PROVED, 3 RECLAIMED) and who proved it. */
  commitment?: { status: number; prover?: string; tics?: number; player?: string; genesis?: string };
  /** Emit `CommitmentProved` for this id in every receipt (as the consumer's would carry it). */
  settles?: { commitmentId: string; prover: string };
}

/** A mocked node: a router checkpoint, the DoomRuns views, receipts carrying a fact. */
export function mockRpc(options: MockRpcOptions): RpcClient {
  const bounty = 5_000_000_000_000_000_000n;
  const view = options.commitment ?? { status: 1 };
  return {
    call: vi.fn(async (c: { entrypoint: string; calldata: string[] }) => {
      switch (c.entrypoint) {
        case "checkpoint": return ["0x" + options.tag.toString(16), "0xdead"];
        case "run_id_of": return ["0x7777"];
        case "is_run_registered": return [options.registered ? "0x1" : "0x0"];
        case "get_commitment": return [
          view.player ?? "0x1a7e5", "0x1", "0x1", view.genesis ?? "0x3efa44a65e6e86c14a36b6f10ade97754d79a7864944ce52cf3159784d58b7", "0x0",
          "0x" + (view.tics ?? 297).toString(16), "0x" + bounty.toString(16), "0x0", "0x1", "0x3e8",
          "0x" + view.status.toString(16), view.status === 2 ? "0x7777" : "0x0", view.prover ?? "0x0",
        ];
        default: throw new Error(`unexpected view ${c.entrypoint}`);
      }
    }),
    request: vi.fn(async () => ({
      events: Array.from({ length: options.steps ?? 0 }, (_, i) => ({ transaction_hash: "0x" + (i + 1).toString(16), data: ["0x2", "0xdead"] })),
    })),
    trace: vi.fn(async () => ({ execute_invocation: { calls: [{ result: ["0x1", "0xab"] }] } })),
    waitForReceipt: vi.fn(async () => ({
      execution_status: "SUCCEEDED",
      execution_resources: { l2_gas: 1000, l1_data_gas: 10 },
      actual_fee: { amount: "0x64" },
      events: [
        { keys: [hash.getSelectorFromName("FactRegistered"), "0xfac7"], data: ["0x1", "0x2"] },
        ...(options.settles
          ? [{ keys: [hash.getSelectorFromName("CommitmentProved"), options.settles.commitmentId, "0x7777", options.settles.prover], data: ["0x1a7e5", "0x" + bounty.toString(16), "0x0"] }]
          : []),
      ],
    })),
  } as unknown as RpcClient;
}

/** Fixed bounds for every remaining step of the sequence — no simulation. */
export const fixedEstimate = async (_a: unknown, prepared: { phases: unknown[] }, resume: { nextPhase: number }) => ({
  prepared: prepared as never,
  bounds: new Array<ResourceBounds>(prepared.phases.length + 1 - resume.nextPhase).fill(bound),
});
