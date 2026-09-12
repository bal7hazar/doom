// SPDX-License-Identifier: Apache-2.0
/**
 * The browser-side pieces that are not DOM: the session policy list a Controller is asked to
 * approve, and the `localStorage` stores behind the resume and the price median.
 *
 * The policy list is worth a test because it is a *permission boundary*: a session that carries
 * one entrypoint too many is a session that can do something the player did not agree to, and a
 * session that carries one too few stalls the sequence half-way through a fact.
 */

import { afterEach, describe, expect, it } from "vitest";

import { submissionPolicies, ReadOnlySigner } from "../../../client/src/chain/signer.js";
import { sessionPolicies } from "../../../client/src/ui/controllerConnect.js";
import { LocalEchoStore, LocalSampleStore } from "../../../client/src/ui/browserStores.js";

const ROUTER = "0x4fd8";
const RUNS = "0x2e10";

describe("session policies", () => {
  it("covers exactly the entrypoints a submission calls, and nothing else", () => {
    const policies = submissionPolicies({ router: ROUTER, doomRuns: RUNS });
    expect(policies.filter((p) => p.target === ROUTER).map((p) => p.method)).toEqual([
      "begin",
      "merkle",
      "answers",
      "fri",
    ]);
    expect(policies.filter((p) => p.target === RUNS).map((p) => p.method)).toEqual([
      "submit_batch",
      "register_member",
    ]);
    expect(policies).toHaveLength(6);
    for (const p of policies) expect(p.description.length).toBeGreaterThan(10);
  });

  it("groups them per contract for the Controller SDK", () => {
    const { contracts } = sessionPolicies(ROUTER, RUNS);
    expect(Object.keys(contracts)).toEqual([ROUTER, RUNS]);
    expect(contracts[ROUTER]!.methods.map((m) => m.entrypoint)).toEqual([
      "begin",
      "merkle",
      "answers",
      "fri",
    ]);
  });
});

describe("the read-only signer", () => {
  it("refuses to send, which is what 'keep offline' and --dry-run rely on", async () => {
    const signer = new ReadOnlySigner("0x1");
    expect(signer.address).toBe("0x1");
    await expect(signer.execute()).rejects.toThrow(/nothing is sent/);
  });
});

/** A minimal `localStorage`, including the throwing kind some browsers hand out. */
function fakeStorage(broken = false): Storage {
  const map = new Map<string, string>();
  return {
    getItem: (k: string) => {
      if (broken) throw new Error("site data blocked");
      return map.get(k) ?? null;
    },
    setItem: (k: string, v: string) => {
      if (broken) throw new Error("quota");
      map.set(k, v);
    },
    removeItem: (k: string) => void map.delete(k),
    clear: () => map.clear(),
    key: () => null,
    length: 0,
  } as unknown as Storage;
}

afterEach(() => {
  delete (globalThis as { localStorage?: Storage }).localStorage;
});

describe("browser stores", () => {
  it("round-trips checkpoint echoes and forgets a finished proof", () => {
    (globalThis as { localStorage?: Storage }).localStorage = fakeStorage();
    const store = new LocalEchoStore("test.echoes");
    expect(store.get(1n, 0)).toBeNull();
    store.set(1n, 0, ["0x7"]);
    store.set(2n, 0, ["0x9"]);
    expect(store.get(1n, 0)).toEqual(["0x7"]);
    store.clear(1n);
    expect(store.get(1n, 0)).toBeNull();
    expect(store.get(2n, 0)).toEqual(["0x9"]);
  });

  it("degrades to 'no history' instead of throwing when storage is blocked", () => {
    (globalThis as { localStorage?: Storage }).localStorage = fakeStorage(true);
    const echoes = new LocalEchoStore("test.echoes");
    expect(echoes.get(1n, 0)).toBeNull();
    expect(() => echoes.set(1n, 0, ["0x7"])).not.toThrow();

    const samples = new LocalSampleStore("test.samples");
    expect(samples.load()).toEqual([]);
    expect(() => samples.save([{ t: 1, priceFri: "1" }])).not.toThrow();
  });

  it("works with no localStorage at all (a worker, a locked-down context)", () => {
    expect(new LocalSampleStore("test.samples").load()).toEqual([]);
    expect(new LocalEchoStore("test.echoes").get(1n, 0)).toBeNull();
  });
});
