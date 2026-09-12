// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0

// Minimal static server for the browser benchmark. It serves `prover/sim/`
// (so that `bench/` can reach `../pkg/`) with the COOP/COEP headers the client
// will need anyway for `SharedArrayBuffer` (PLAN.md phase 2, task 7).

import { createServer } from 'node:http';
import { createReadStream } from 'node:fs';
import { stat } from 'node:fs/promises';
import { extname, join, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = fileURLToPath(new URL('..', import.meta.url));

const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.wasm': 'application/wasm',
  '.ts': 'text/plain; charset=utf-8',
};

export function startServer(port = 0) {
  const server = createServer(async (request, response) => {
    const url = new URL(request.url, 'http://localhost');
    const path = join(ROOT, normalize(decodeURIComponent(url.pathname)).replace(/^(\.\.[/\\])+/, ''));
    try {
      const info = await stat(path);
      if (info.isDirectory()) throw new Error('directory');
      response.writeHead(200, {
        'content-type': TYPES[extname(path)] ?? 'application/octet-stream',
        'content-length': info.size,
        // Cross-origin isolation, required for SharedArrayBuffer (R5-A2).
        'cross-origin-opener-policy': 'same-origin',
        'cross-origin-embedder-policy': 'require-corp',
        'cache-control': 'no-store',
      });
      createReadStream(path).pipe(response);
    } catch {
      response.writeHead(404).end('not found');
    }
  });
  return new Promise((resolve) => {
    server.listen(port, '127.0.0.1', () => resolve({ server, port: server.address().port }));
  });
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const { port } = await startServer(Number(process.env.PORT ?? 8787));
  console.log(`serving ${ROOT} on http://127.0.0.1:${port}/bench/index.html`);
}
