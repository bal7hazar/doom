/** Real client Worker campaign, with immutable Cairo references; never regenerates goldens.
 * node scripts/audit-sim-worker.mjs FIXTURES NATIVE_JSON OUTPUT [--unisolated]
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createServer } from 'vite';
import { chromium } from 'playwright';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const [fixturesPath, referencePath, output] = process.argv.slice(2);
if (!output) throw Error('expected FIXTURES NATIVE_JSON OUTPUT');
const isolated = !process.argv.includes('--unisolated');
const fixtures = JSON.parse(fs.readFileSync(fixturesPath));
const reference = JSON.parse(fs.readFileSync(referencePath));
const server = await createServer({ root, configFile: path.join(root, 'vite.config.ts'),
  plugins: [{ name: 'simulation-audit-page', configureServer(server) {
    server.middlewares.use('/__sim-audit__', (_req, res) => {
      res.setHeader('Content-Type', 'text/html');
      res.setHeader('Cross-Origin-Opener-Policy', isolated ? 'same-origin' : 'unsafe-none');
      res.setHeader('Cross-Origin-Embedder-Policy', isolated ? 'require-corp' : 'unsafe-none');
      res.end('<!doctype html><title>Client Cairo Worker audit</title>');
    });
  } }],
  server: { host: '127.0.0.1', port: 0, headers: isolated ? undefined : {
    'Cross-Origin-Opener-Policy': 'unsafe-none', 'Cross-Origin-Embedder-Policy': 'unsafe-none',
  } } });
await server.listen();
let browser;
const result = { isolated, manifest: JSON.parse(fs.readFileSync(path.join(root, 'public/sim/manifest.json'))) };
try {
  browser = await chromium.launch({ headless: true }); result.browser = browser.version();
  const page = await browser.newPage();
  page.on('console', message => console.log(message.text()));
  page.on('pageerror', error => console.error(error));
  await page.goto(`http://127.0.0.1:${server.httpServer.address().port}/__sim-audit__`);
  Object.assign(result, await page.evaluate(async ({ fixtures, reference, isolated }) => {
    if (crossOriginIsolated !== isolated) throw Error('isolation mode differs from requested test');
    const { CairoClient } = await import('/src/sim/cairoClient.ts');
    const { encodeFelts, sameBytes, decodeFelts } = await import('/src/sim/felts.ts');
    const { InputJournal } = await import('/src/game/inputJournal.ts');
    const equal = (a, b, name) => { if (!sameBytes(a, b)) throw Error(`${name}: bytes differ`); };
    const stats = xs => { const sorted = [...xs].sort((a, b) => a - b); return {
      mean: xs.reduce((a, b) => a + b, 0) / xs.length,
      p50: sorted[Math.ceil(xs.length * .5) - 1], p99: sorted[Math.ceil(xs.length * .99) - 1], max: sorted.at(-1),
    }; };
    const client = new CairoClient();
    const timeout = setTimeout(() => client.dispose(), 180_000);
    try {
      await client.init();
      if (client.latest.snapshot.tic !== 0 || client.journal.length !== 0 || client.ring.readPair() !== null) throw Error('genesis consumed a tic');
      const initial = await client.checkpoint();
      equal(initial, client.journal.boundary(0).state, 'genesis checkpoint');
      await client.resume();
      await client.advance(0x808080);
      if (client.journal.boundary(0, 1).words[0] !== 0x808080) throw Error('first input missing');
      const cases = [];
      for (const fixture of fixtures) {
        const ref = reference.cases.find(c => c.name === fixture.name);
        const setup = performance.now();
        await client.restart(encodeFelts(fixture.state));
        if (client.latest.snapshot.tic !== fixture.ticStart || client.ring.readPair() !== null) throw Error('restart advanced or retained old interpolation');
        await client.resume();
        const setupMs = performance.now() - setup, latency = [], workerMs = [], steps = [];
        for (let i = 0; i < ref.samples.length; i++) {
          const before = performance.now();
          const response = await client.advance(fixture.commands[i]);
          latency.push(performance.now() - before); workerMs.push(response.elapsedMs); steps.push(response.steps);
          equal(new Uint8Array(response.frame), encodeFelts(ref.samples[i].expectedSnapshot), `${fixture.name} snapshot ${i}`);
          if (response.status !== ref.samples[i].expectedStatus) throw Error('status differs');
          if (response.state) equal(new Uint8Array(response.state), encodeFelts(ref.samples[i].expectedCheckpoint), `${fixture.name} checkpoint ${i}`);
          if (fixture.name === 'idle' && i === 39) {
            // Save the journal BEFORE the explicit boundary to exercise suffix replay.
            localStorage.setItem('cairo-audit-journal', JSON.stringify(client.journal.export()));
            localStorage.setItem('cairo-audit-state', JSON.stringify(decodeFelts(await client.checkpoint()).map(String)));
          }
          if (i === 7) {
            await client.pause(); const tic = client.latest.snapshot.tic;
            await new Promise(r => setTimeout(r, 40));
            if (client.latest.snapshot.tic !== tic) throw Error('paused simulation advanced');
            let rejected = false; try { await client.advance(0); } catch { rejected = true; }
            if (!rejected) throw Error('paused input accepted');
            await client.resume();
          }
        }
        const state = await client.checkpoint();
        const raw = decodeFelts(client.lastRawFrame), fields = decodeFelts(state);
        const full = encodeFelts([client.latest.status, fields.length, ...fields, raw.length, ...raw]);
        equal(full, encodeFelts(ref.finalOutput), `${fixture.name} complete ABI`);
        const hash = Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', full)), n => n.toString(16).padStart(2, '0')).join('');
        if (hash !== fixture.expectedSha256) throw Error('frozen complete ABI hash differs');
        const exported = client.journal.export();
        const imported = InputJournal.import(JSON.parse(JSON.stringify(exported)));
        equal(imported.boundary(client.latest.snapshot.tic).state, state, 'journal reload checkpoint');
        if (JSON.stringify(imported.boundary(fixture.ticStart).words) !== JSON.stringify(fixture.commands.slice(0, ref.samples.length))) throw Error('journal words differ');
        if (client.terminal) {
          let rejected = false; try { await client.advance(0); } catch { rejected = true; }
          if (!rejected) throw Error('terminal input accepted');
        }
        const entry = { name: fixture.name, count: latency.length, setupMs, includingTransportAndMaintenanceMs: stats(latency),
          workerIncludingMaintenanceMs: stats(workerMs), steps: stats(steps), overBudget: latency.filter(x => x > 1000 / 35).length,
          memoryBytes: client.memoryBytes, exact: true, sha256: hash };
        cases.push(entry); console.log(JSON.stringify(entry));
      }
      // Malformed Cairo checkpoint must poison the operation, then recover on restart.
      let rejected = false; try { await client.restart(encodeFelts([1, 2, 3])); } catch { rejected = true; }
      if (!rejected) throw Error('malformed state accepted');
      await client.restart(initial);
      if (client.latest.snapshot.tic !== 0 || client.journal.length !== 0) throw Error('error recovery failed');
      const maxState = decodeFelts(initial); maxState[4] = 1n << 30n;
      await client.restart(encodeFelts(maxState));
      const maxFrame = client.lastRawFrame.slice();
      await client.resume(); const abort = await client.advance(0x808080);
      if (abort.status !== 3 || abort.consumed || client.journal.length !== 0 || client.latest.snapshot.tic !== 2 ** 30) throw Error('MAX_TIC ABORT consumed a tic');
      equal(client.lastRawFrame, maxFrame, 'MAX_TIC unchanged snapshot');
      equal(await client.checkpoint(), encodeFelts(maxState), 'MAX_TIC unchanged state');
      const abortedJournal = client.journal.export();
      await client.restore(abortedJournal);
      if (!client.terminal || client.status !== 3) throw Error('ABORT operation lost during restore');
      return { ok: true, cases, crossOriginIsolated, transport: 'arraybuffer', genesisExact: true, malformedRecovery: true,
        unchangedAbortExact: true,
        totalTics: cases.reduce((sum, c) => sum + c.count, 0) };
    } finally { clearTimeout(timeout); client.dispose(); }
  }, { fixtures, reference, isolated }));
  // A real document reload destroys the Worker and its WASM, then restores the
  // saved checkpoint + eight later inputs before accepting another command.
  await page.reload();
  result.reload = await page.evaluate(async ({ sample, next, word }) => {
    const { CairoClient } = await import('/src/sim/cairoClient.ts');
    const { encodeFelts, sameBytes } = await import('/src/sim/felts.ts');
    const saved = JSON.parse(localStorage.getItem('cairo-audit-journal'));
    const client = new CairoClient();
    const timer = setTimeout(() => client.dispose(), 30_000);
    try {
      await client.restore(saved);
      if (client.journal.length !== 40 || !client.paused) throw Error('reloaded journal order differs');
      const expectedState = JSON.parse(localStorage.getItem('cairo-audit-state'));
      if (!sameBytes(await client.checkpoint(), encodeFelts(expectedState))) throw Error('reloaded state differs');
      if (!sameBytes(client.lastRawFrame, encodeFelts(sample.expectedSnapshot))) throw Error('reloaded render differs');
      await client.resume(); const response = await client.advance(word);
      if (client.journal.length !== 41 || !sameBytes(new Uint8Array(response.frame), encodeFelts(next.expectedSnapshot))) throw Error('first input after reload differs');
      localStorage.removeItem('cairo-audit-journal'); localStorage.removeItem('cairo-audit-state');
      return { exact: true, restoredTics: 40, replayedSuffix: 8, nextTic: response.tic };
    } finally { clearTimeout(timer); client.dispose(); }
  }, { sample: reference.cases[0].samples[39], next: reference.cases[0].samples[40], word: fixtures[0].commands[40] });
  result.interruption = await page.evaluate(async ({ fixture, sample }) => {
    const { encodeFelts, sameBytes } = await import('/src/sim/felts.ts');
    const worker = new Worker('/test/fixtures/cairoInterrupt.worker.ts', { type: 'module' });
    const responses = new Map(), waiters = new Map();
    worker.onmessage = event => {
      const response = event.data; responses.set(response.id, response);
      waiters.get(response.id)?.(response); waiters.delete(response.id);
    };
    const wait = id => responses.has(id) ? Promise.resolve(responses.get(id)) : new Promise(resolve => waiters.set(id, resolve));
    const send = message => { worker.postMessage(message); return wait(message.id); };
    const timer = setTimeout(() => { worker.terminate(); for (const resolve of waiters.values()) resolve({ type: 'timeout' }); }, 30_000);
    try {
      const initial = await send({ type: 'init', id: 0, state: encodeFelts(fixture.state).buffer });
      if (initial.type !== 'ready') throw Error('interruption init failed');
      await send({ type: 'resume', id: 1 });
      const input = send({ type: 'advance', id: 2, seq: 0, word: fixture.commands[0] });
      const pause = await send({ type: 'pause', id: 3 });
      if (pause.type !== 'paused') throw Error('pause failed');
      const busy = await send({ type: 'advance', id: 4, seq: 1, word: 0 });
      if (busy.code !== 'busy') throw Error('second in-flight input was not rejected');
      await new Promise(resolve => setTimeout(resolve, 40));
      if (responses.has(2)) throw Error('interrupted input completed while paused');
      await send({ type: 'resume', id: 5 });
      const response = await input;
      if (response.type !== 'frame' || !sameBytes(new Uint8Array(response.frame), encodeFelts(sample.expectedSnapshot))) throw Error('resumed Cairo frame differs');
      const duplicate = await send({ type: 'advance', id: 6, seq: 0, word: 0 });
      if (duplicate.code !== 'order') throw Error('duplicate input not rejected');
      await send({ type: 'dispose', id: 7 });
      return { exact: true, firstQuantum: 101, busyRejected: true, duplicateRejected: true, pausedWithoutCompletion: true };
    } finally { clearTimeout(timer); worker.terminate(); }
  }, { fixture: fixtures[0], sample: reference.cases[0].samples[0] });
} catch (error) { result.ok = false; result.error = String(error.stack ?? error); process.exitCode = 1; }
finally {
  if (browser) await browser.close(); await server.close();
  fs.writeFileSync(output, JSON.stringify(result, null, 2) + '\n'); console.log(JSON.stringify(result));
}
