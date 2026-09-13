// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Hellproof contributors
// Real high-address/runtime test. Only a few pages are touched despite >4 GiB virtual memory.
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';

const leb = x => { const b=[]; let n=BigInt(x); do { let v=Number(n&127n); n>>=7n; if(n)v|=128; b.push(v); }while(n); return b; };
const vec = xs => [...leb(xs.length), ...xs.flat()];
const str = s => [...leb(s.length), ...Buffer.from(s)];
const section = (id, bytes) => [id,...leb(bytes.length),...bytes];
const type = (params,results) => [0x60,...vec(params),...vec(results)];
const body = code => { const b=[0,...code,0x0b]; return [...leb(b.length),...b]; };

function fixture() {
  const signatures=[type([0x7e],[0x7e]),type([0x7e,0x7e],[])];
  const funcs=[body([0x20,0,0x40,0]),body([0x20,0,0x20,1,0x37,3,0])];
  const fnTypes=[0,1];
  const exports=[ [...str('memory'),2,0], [...str('grow'),0,0], [...str('write'),0,1] ];
  for(const width of [1,2,4,8])for(const offset of [0n,7n,2n**32n]){
    const name=`load${width}_offset${offset}`;
    // Each splat yields its first 64-bit lane, preserving all repeated sublanes.
    const opcode=7+Math.log2(width);
    const code=[0x20,0,0xfd,opcode,0,...leb(offset),0xfd,0x1d,0];
    exports.push([...str(name),0,...leb(funcs.length)]);fnTypes.push(0);funcs.push(body(code));
  }
  return Buffer.from([0,97,115,109,1,0,0,0,
    ...section(1,vec(signatures)), ...section(3,vec(fnTypes)),
    ...section(5,[1,5,1,...leb(262144)]), ...section(7,vec(exports)),
    ...section(10,vec(funcs))]);
}
const expected = (value,width) => {
  const bits=BigInt(width*8);const part=BigInt.asUintN(width*8,value);let out=0n;
  for(let i=0n;i<64n;i+=bits)out|=part<<i;
  return BigInt.asIntN(64,out);
};
const run = (bytes, mustPass) => {
  const e=new WebAssembly.Instance(new WebAssembly.Module(bytes)).exports;
  e.grow(65538n);
  const lo=128n,hi=2n**32n+lo;
  const lowValue=0x1122334455667788n,highValue=0x2233445566778899n;
  e.write(lo,lowValue);e.write(hi,highValue);
  const failures=[];let checks=0;
  for(const width of [1,2,4,8])for(const offset of [0n,7n,2n**32n]){
    const fn=e[`load${width}_offset${offset}`];
    const args=offset===2n**32n?[[lo,highValue]]:[[lo-offset,lowValue],[hi-offset,highValue]];
    for(const [address,value]of args){
      const want=expected(value,width);
      for(let i=0;i<20000;i++){
        const got=fn(address);checks++;
        if(got!==want){failures.push({width,offset:String(offset),address:String(address),iteration:i,got:String(got),expected:String(want)});if(mustPass)assert.equal(got,want);break;}
      }
    }
    const end=BigInt(e.memory.buffer.byteLength);
    // Last valid access reads exactly width bytes, no over-read to v128 or 64-bit size.
    assert.doesNotThrow(()=>fn(end-BigInt(width)-offset));checks++;
    let trapped=false;
    try { fn(end-BigInt(width)+1n-offset); } catch(error) { if(!(error instanceof WebAssembly.RuntimeError))throw error; trapped=true; }
    if(mustPass)assert.equal(trapped,true,'out-of-bounds scalar-width access must trap');
    else if(!trapped)failures.push({width,offset:String(offset),missingTrap:true});
    checks++;
  }
  return {checks,failures,memoryBytes:e.memory.buffer.byteLength};
};
const tool=process.argv[2];
if(!tool)throw new Error('usage: node memory64-splats.mjs PATH_TO_LOWERING_TOOL');
const dir=mkdtempSync(join(tmpdir(),'hellproof-splats-'));
try{
  const input=join(dir,'input.wasm'),output=join(dir,'output.wasm'),again=join(dir,'again.wasm');
  writeFileSync(input,fixture());
  execFileSync(tool,[input,output]);execFileSync(tool,[output,again]);
  assert.deepEqual(readFileSync(output),readFileSync(again),'lowering must be idempotent');
  const original=run(readFileSync(input),false);
  const lowered=run(readFileSync(output),true);
  console.log(JSON.stringify({node:process.versions.node,v8:process.versions.v8,flags:process.execArgv,original,lowered}));
}finally{rmSync(dir,{recursive:true,force:true});}
