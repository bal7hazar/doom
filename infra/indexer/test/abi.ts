// SPDX-License-Identifier: Apache-2.0
/**
 * The compiled `DoomRuns` ABI as a test oracle, shared by the three TypeScript decoders of its
 * events and views (`infra/indexer`, `infra/prover-node`, `client/src/chain/commit.ts`).
 *
 * `scarb build -p doom_runs` (in `cairo/doom_contracts`) writes
 * `target/dev/doom_runs_DoomRuns.contract_class.json`; the file is ~850 kB and not committed,
 * so every test that uses this module skips itself when it is missing. What the helpers give
 * is the *layout* the contract really serialises: for an event, its `#[key]` fields then its
 * data fields in declaration order; for a struct or an entrypoint, the flattened felt count of
 * every member (`u256` is two felts, a `Span`/`Array` is a length then its items).
 */
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

// `import.meta.dirname` rather than a `file:` URL: the client's tests run under jsdom, where
// vitest serves `import.meta.url` over http.
export const CONTRACT_CLASS = join(
  import.meta.dirname,
  "../../../cairo/doom_contracts/target/dev/doom_runs_DoomRuns.contract_class.json",
);

export interface AbiMember {
  name: string;
  type: string;
  kind?: "key" | "data" | "nested" | "flat";
}

export interface AbiItem {
  type: string;
  name: string;
  kind?: string;
  members?: AbiMember[];
  variants?: AbiMember[];
  items?: AbiItem[];
  inputs?: { name: string; type: string }[];
  outputs?: { type: string }[];
  state_mutability?: string;
}

/** One flattened field: `felts` is its width, or -1 for a length-prefixed sequence. */
export interface Field {
  name: string;
  type: string;
  felts: number;
}

/** The ABI array, or `undefined` when the contract has not been built. */
export function loadDoomRunsAbi(): AbiItem[] | undefined {
  if (!existsSync(CONTRACT_CLASS)) return undefined;
  return JSON.parse(readFileSync(CONTRACT_CLASS, "utf8")).abi as AbiItem[];
}

/** `doom_runs::doom_runs::DoomRuns::RunCommitted` → `RunCommitted`. */
export const shortName = (path: string): string => path.split("::").pop()!;

/** Snake case as Cairo writes it → camel case as the decoders spell it. */
export const camel = (name: string): string => name.replace(/_([a-z0-9])/g, (_, c: string) => c.toUpperCase());

/** How many felts one value of `type` serialises to; -1 for a `Span`/`Array`. */
export function feltsOf(abi: AbiItem[], type: string): number {
  if (/^core::array::(Span|Array)::</.test(type)) return -1;
  if (type === "core::integer::u256") return 2;
  if (/^core::(felt252|integer::u(8|16|32|64|128)|bool|starknet::contract_address::ContractAddress|starknet::class_hash::ClassHash)$/.test(type)) return 1;
  const struct = abi.find((i) => i.type === "struct" && i.name === type);
  if (struct?.members) return struct.members.reduce((n, m) => n + feltsOf(abi, m.type), 0);
  throw new Error(`abi: unknown type ${type}`);
}

const field = (abi: AbiItem[], m: { name: string; type: string }): Field => ({ name: m.name, type: m.type, felts: feltsOf(abi, m.type) });

/** The event variant `name` of the `Event` enum: its keys and its data, in declaration order. */
export function eventLayout(abi: AbiItem[], name: string): { keys: Field[]; data: Field[] } {
  const enumItem = abi.find((i) => i.type === "event" && i.kind === "enum" && shortName(i.name) === "Event");
  const variant = enumItem?.variants?.find((v) => v.name === name);
  if (!variant) throw new Error(`abi: no Event variant ${name}`);
  if (variant.kind !== "nested") throw new Error(`abi: ${name} is ${variant.kind}, the decoders assume nested`);
  const ev = abi.find((i) => i.type === "event" && i.kind === "struct" && i.name === variant.type);
  if (!ev?.members) throw new Error(`abi: no event struct ${variant.type}`);
  return {
    keys: ev.members.filter((m) => m.kind === "key").map((m) => field(abi, m)),
    data: ev.members.filter((m) => m.kind === "data").map((m) => field(abi, m)),
  };
}

/** The members of struct `name` (short name), flattened widths included. */
export function structLayout(abi: AbiItem[], name: string): Field[] {
  const struct = abi.find((i) => i.type === "struct" && shortName(i.name) === name);
  if (!struct?.members) throw new Error(`abi: no struct ${name}`);
  return struct.members.map((m) => field(abi, m));
}

/** The inputs of entrypoint `name` (or of the constructor with `"constructor"`). */
export function entrypointInputs(abi: AbiItem[], name: string): Field[] {
  const fn =
    name === "constructor"
      ? abi.find((i) => i.type === "constructor")
      : abi.flatMap((i) => (i.type === "interface" ? (i.items ?? []) : [])).find((f) => f.type === "function" && f.name === name);
  if (!fn?.inputs) throw new Error(`abi: no entrypoint ${name}`);
  return fn.inputs.map((m) => field(abi, m));
}

/** The output types of entrypoint `name`. */
export function entrypointOutputs(abi: AbiItem[], name: string): string[] {
  const fn = abi.flatMap((i) => (i.type === "interface" ? (i.items ?? []) : [])).find((f) => f.type === "function" && f.name === name);
  if (!fn?.outputs) throw new Error(`abi: no entrypoint ${name}`);
  return fn.outputs.map((o) => o.type);
}

/**
 * A felt stream for `fields` where every position carries a distinct value (`base + i`), and
 * the values each field received, so a decoder's output can be checked position by position.
 * A sequence field gets `spanLen` items behind its length.
 */
export function synthesize(fields: Field[], base = 0x1000, spanLen = 2): { felts: string[]; values: Map<string, string[]> } {
  const felts: string[] = [];
  const values = new Map<string, string[]>();
  let next = base;
  const take = (): string => "0x" + (next++).toString(16);
  for (const f of fields) {
    const own: string[] = [];
    if (f.felts === -1) {
      felts.push("0x" + spanLen.toString(16));
      for (let i = 0; i < spanLen; i++) own.push(take());
    } else {
      for (let i = 0; i < f.felts; i++) own.push(take());
    }
    felts.push(...own);
    values.set(f.name, own);
  }
  return { felts, values };
}

/** `low + (high << 128)` of a two-felt value. */
export const u256Of = (v: string[]): bigint => BigInt(v[0]!) + (BigInt(v[1]!) << 128n);
