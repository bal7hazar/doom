// SPDX-License-Identifier: Apache-2.0
/**
 * `@hellproof/client` — on-chain submission (P4.3).
 *
 * Turns a wrapper batch into the 6–7 transactions that verify its root proof on Starknet and
 * record its games, estimates them before anything is signed, and resumes them where they
 * stopped. Design and measurements: `docs/design/submission.md`.
 *
 * The package has **no runtime dependency**: it builds calldata, talks JSON-RPC over `fetch`
 * and hands the signing to a `Signer` (the Cartridge Controller in the browser, a devnet key in
 * `infra/submit`). That is what lets the wrapper reuse it unchanged (D20).
 */

export * from "./proof.js";
export * from "./calldata.js";
export * from "./batch.js";
export * from "./rpc.js";
export * from "./selector.js";
export * from "./sequence.js";
export * from "./estimate.js";
export * from "./prices.js";
export * from "./median.js";
export * from "./signer.js";
export * from "./submission.js";
export * from "./poseidon.js";
export * from "./commit.js";
