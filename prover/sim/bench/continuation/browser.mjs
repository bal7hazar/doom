// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
const here=path.dirname(fileURLToPath(import.meta.url));
const {chromium}=await import(process.env.PLAYWRIGHT_MODULE??'playwright');
const fixtures=process.argv[2],native=process.argv[3],out=process.argv[4];
if(!out)throw Error('browser.mjs FIXTURES NATIVE_RESULTS OUTPUT');
const pkg=path.resolve(here,'../../pkg');
const files=new Map([['/worker.mjs',path.join(here,'worker.mjs')],['/session.json',path.join(here,'cairo/target/proving/session.executable.json')],['/fixtures.json',fixtures],['/native.json',native]]);
for(const n of ['hellproof_sim.js','hellproof_sim_bg.wasm'])files.set('/sim/'+n,path.join(pkg,n));
for(const n of fs.readdirSync(path.join(pkg,'snippets'),{recursive:true}))if(n.endsWith('.js'))files.set('/sim/snippets/'+n,path.join(pkg,'snippets',n));
const server=http.createServer((req,res)=>{
  res.setHeader('Cross-Origin-Opener-Policy','same-origin');res.setHeader('Cross-Origin-Embedder-Policy','require-corp');
  const url=new URL(req.url,'http://localhost').pathname;
  if(url==='/'){res.setHeader('Content-Type','text/html');res.end('<!doctype html><title>Cairo continuation audit</title>');return;}
  const f=files.get(url);if(!f){res.statusCode=404;res.end();return;}
  res.setHeader('Content-Type',f.endsWith('.wasm')?'application/wasm':/\.m?js$/.test(f)?'text/javascript':'application/json');fs.createReadStream(f).pipe(res);
});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
let browser;const result={};
try {
  result.wasmSha256=createHash('sha256').update(fs.readFileSync(path.join(pkg,'hellproof_sim_bg.wasm'))).digest('hex');
  result.executableSha256=createHash('sha256').update(fs.readFileSync(files.get('/session.json'))).digest('hex');
  browser=await chromium.launch({headless:true});result.browser=browser.version();
  const page=await browser.newPage();page.on('console',m=>console.log(m.text()));
  await page.goto(`http://127.0.0.1:${server.address().port}`);
  const data=await page.evaluate(()=>new Promise((resolve,reject)=>{
    const worker=new Worker('/worker.mjs',{type:'module'});
    const timer=setTimeout(()=>{worker.terminate();reject(Error('continuation deadline180s'));},180000);
    worker.onerror=e=>{clearTimeout(timer);worker.terminate();reject(Error(e.message));};
    worker.onmessage=e=>{if(e.data.progress){console.log(JSON.stringify(e.data));return;}clearTimeout(timer);worker.terminate();resolve(e.data);};worker.postMessage({});
  }));
  Object.assign(result,data);if(!result.ok)throw Error(result.error);
}catch(e){result.ok=false;result.error=String(e.stack??e);process.exitCode=1;}
finally{if(browser)await browser.close();await new Promise(r=>server.close(r));fs.writeFileSync(out,JSON.stringify(result,null,2));console.log(JSON.stringify(result));}
