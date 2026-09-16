// SPDX-FileCopyrightText: 2026 Bal7hazar
// SPDX-License-Identifier: Apache-2.0
/** Exact former Doom proof identities (0c8a3a8), oldest first, as persisted in `RunRecord.programIdentity`.
 * Frozen migration-rejection fixtures maintained by client/scripts/migrate-identity.mjs; never a current pin. */
export const legacyDoomIdentities = [
  {
    "adapter": "doom_run/state2/d14v1",
    "artifacts": {
      "revision": "0c8a3a8ed507640bd1d5c93d53820057609f3f93",
      "genesis": "12130f43a4493bb775e497521cb38bfdda7d83864a005ca180ac84b78227700e",
      "step": "82d5f2ddafc27562824068e71305091d61dd2ce26324c92231f1a61b6589593c",
      "segment": "5a3817dc5f8d60e2e3bd4b99ec146665a10eac8969fa16a8b709fbd3fb057b28",
      "wasm": "dd73ce152f44a9e00368e195c6de36d40b2948b0740794f056b2e557c94b67c5",
      "programHash": "0x35fb0446851a7fb0c55036bfc305b30cfa4a1e24800a2dd3efd128bd0c5268e",
      "snippet": "df2ed0c952715d37ee1cf0d8e63f388d70d92d4ef5800554559ef32159ebad5c",
      "glue": "6592e2163739afd332ff9262fa869c16b411906d953240acec0e1b2ae22701c7"
    },
    "simulation": "[1,2,1,\"0c8a3a8ed507640bd1d5c93d53820057609f3f93\",\"bcb9e852ee5d1f69f17b4a5a423ca29462d168290599f6ec4623d6959849ae2e\",\"12130f43a4493bb775e497521cb38bfdda7d83864a005ca180ac84b78227700e\",\"82d5f2ddafc27562824068e71305091d61dd2ce26324c92231f1a61b6589593c\",\"dd73ce152f44a9e00368e195c6de36d40b2948b0740794f056b2e557c94b67c5\"]"
  }
];
/** The most recently retired identity. */
export const legacyDoomIdentity = legacyDoomIdentities[legacyDoomIdentities.length - 1]!;
