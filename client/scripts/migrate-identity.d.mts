// SPDX-FileCopyrightText: 2026 Bal7hazar
// SPDX-License-Identifier: Apache-2.0
/** Types of the dependency-free migration script, for its vitest coverage. */
export interface IdentityPins {
  revision: string; genesis: string; step: string; segment: string; wasm: string; programHash: string; snippet: string; glue: string;
}
export interface LegacyIdentity { adapter: string; artifacts: IdentityPins; simulation: string }
export const ADAPTER: string;
export const PIN_KEYS: readonly (keyof IdentityPins)[];
export const EXECUTABLES: Readonly<Record<"genesis" | "step" | "segment", string>>;
export const SIM_FILES: Readonly<Record<"wasm" | "glue" | "snippet", string>>;
export const FILES: Readonly<Record<"pins" | "legacy" | "readme" | "manifest" | "measure", string>>;
export const USAGE: string;
export class MigrationError extends Error { code: number }
export function parseArgs(argv: readonly string[]): Record<string, string | boolean | undefined>;
export function sha256(data: string | Uint8Array): string;
export function sha256File(path: string): string;
export function shortRev(revision: string): string;
export function normalizeProgramHash(value: string): string;
export function emptySegmentArgs(output: string): string[];
export function parsePins(source: string): IdentityPins;
export function renderPins(pins: IdentityPins, previousRevision: string): string;
export function parseLegacy(source: string): LegacyIdentity[];
export function renderLegacy(list: readonly LegacyIdentity[]): string;
export function identityOf(pins: IdentityPins, simulation: { snapshotSchema: number; revision: string; session: string }): LegacyIdentity;
export function renderReadmeBlock(pins: IdentityPins, legacy: readonly LegacyIdentity[]): string;
export function replaceReadmeBlock(source: string, block: string): string;
export function main(argv: readonly string[], io?: { stdout?(text: string): void }): number;
