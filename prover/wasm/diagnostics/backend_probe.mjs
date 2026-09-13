// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Hellproof contributors
import {readFileSync} from 'node:fs';
import assert from 'node:assert/strict';
const [path, gibText='0']=process.argv.slice(2);
if(!path)throw new Error('usage: node backend_probe.mjs MODULE.wasm [RESERVED_GIB=0]');
const gib=BigInt(gibText);
assert(gib>=0n&&gib<=11n);
const {exports:e}=new WebAssembly.Instance(new WebAssembly.Module(readFileSync(path)),{});
const ptr=gib?e.reserve_address_space(gib*1024n**3n):0n;
console.log(JSON.stringify({node:process.versions.node,v8:process.versions.v8,module:path,reservedGiB:Number(gib),reservedPointer:String(ptr),memoryBytes:e.memory.buffer.byteLength}));
function check(test,arg,seed){
  const start=performance.now();const code=e[test](arg,seed);
  console.log(JSON.stringify({test,arg,seed,code,ms:performance.now()-start,detail:code?Array.from({length:8},(_,i)=>String(e.detail(i))):undefined}));
  assert.equal(code,0,`${test}(${arg},${seed})`);
}
for(const n of [0,1,2,3,4,5,15,16,17,63,64,65,511,512,513,1023,1024,1025,2048,65536])check('inverses',n,0);
for(const log of [5,8,14,15,16,17,18,20,21])check('roundtrip',log,19);
for(const log of [16,19,22])check('quotients',log,23);
