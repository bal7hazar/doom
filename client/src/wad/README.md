<!--
SPDX-FileCopyrightText: 2026 Hellproof contributors
SPDX-License-Identifier: Apache-2.0
-->

# `client/src/wad` — why this is a duplicate of `tools/wad`

`tools/wad` (roadmap P0.2) already parses the WAD directory, `PLAYPAL`,
`COLORMAP`, `PNAMES` and `TEXTURE1/2`. The client does **not** import it, for
three reasons that are all properties of the tool, not of the client:

1. **It is Node-only.** `tools/wad/src/binary.ts` is typed against `Buffer`
   (`buffer.readInt16LE`, `Buffer.indexOf`, `Buffer.subarray` returning a
   `Buffer`), and `tools/wad/src/wad.ts` imports `node:fs`. Neither exists in a
   browser without a polyfill we do not want to ship.
2. **It is not importable.** `tools/wad/package.json` is `"private": true` with
   no `exports`, no `main`, and no build output committed; there is no module
   specifier the client could resolve.
3. **It is owned by another work stream** (P0.2 is still being edited). A
   compile-time dependency from the client onto its `src/` would couple the two
   lanes on every refactor.

So this directory is the *minimal* browser-side duplicate: directory parsing
plus the picture formats the renderer needs, all over `Uint8Array`/`DataView`,
with no Node imports.

## What would let us delete it

Three changes to `tools/wad`, in increasing order of effort — see the P2.1/P2.2
report for the same list:

- retype `BinaryReader` (and every parser signature) from `Buffer` to
  `Uint8Array`, reading through a `DataView`. `Buffer` *is* a `Uint8Array`, so
  every existing Node caller keeps working unchanged;
- move `readFileSync` out of `Wad.fromFile` into the CLI, leaving
  `Wad.fromBuffer` as the only entry point in the library;
- add `"exports": { ".": "./src/index.ts", "./assets/*": "./src/assets/*.ts" }`
  (or a built `dist/`) so the client can `import { Wad } from "@hellproof/tools-wad"`.

Until then, the two implementations are kept honest by
`test/wadDecode.test.ts`, which decodes real `freedoom1.wad` lumps and checks
them against fixtures, and by the fact that the *map* lumps are not duplicated
at all: the client consumes `tools/wad`'s JSON output, never the raw map lumps.

## What is deliberately **not** here

- map lump parsing (`THINGS`/`LINEDEFS`/…): the client reads
  `tools/wad`'s JSON instead, so there is exactly one map parser in the repo;
- the Cairo output, the report, the blockmap/reject decoders: server-side only.
