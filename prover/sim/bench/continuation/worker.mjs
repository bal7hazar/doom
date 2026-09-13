// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0
import init, {SimContinuation} from '/sim/hellproof_sim.js';
const encode = values => {
  const bytes = new Uint8Array(values.length * 32);
  for (let i=0; i<values.length; i++) {
    let n=BigInt(values[i]);
    for (let k=0; n>0n; k++, n>>=8n) bytes[i*32+k]=Number(n&255n);
  }
  return bytes;
};
const equal=(a,b,label)=>{
  if(a.length!==b.length) throw Error(label+': different lengths');
  for(let i=0;i<a.length;i++) if(a[i]!==b[i]) throw Error(label+': byte '+i+' differs');
};
const stats=xs=>{
  const sorted=[...xs].sort((a,b)=>a-b),at=p=>sorted[Math.ceil(p*xs.length)-1];
  return {mean:xs.reduce((a,b)=>a+b,0)/xs.length,p50:at(.5),p99:at(.99),max:sorted.at(-1)};
};
self.onmessage=async()=>{
  try {
    const wasm=await init();
    const [program,fixtures,native]=await Promise.all([
      fetch('/session.json').then(r=>r.text()),fetch('/fixtures.json').then(r=>r.json()),
      fetch('/native.json').then(r=>r.json())]);
    const results={hardwareConcurrency:navigator.hardwareConcurrency,crossOriginIsolated,cases:[]};
    let sim;
    for(const f of fixtures) {
      const reference=native.cases.find(x=>x.name===f.name);
      const initial=encode(f.state);
      const setup=performance.now();
      if(sim) sim.restart(initial); else sim=SimContinuation.load(program,initial);
      const setupMs=performance.now()-setup;
      const tickMs=[],inclusiveMs=[],steps=[],maintenance=[];
      let lastSnapshot,lastStatus,state;
      for(let i=0;i<reference.samples.length;i++) {
        const sample=reference.samples[i],expected=encode(sample.expectedSnapshot);
        const before=sim.total_steps(),t=performance.now();
        let progress=sim.advance(f.commands[i],i%7===0?101:1000000);
        while(progress===1) progress=sim.resume(1000000);
        if(progress!==0) throw Error('session ended unexpectedly');
        lastSnapshot=sim.snapshot();lastStatus=sim.status();
        const elapsed=performance.now()-t;
        tickMs.push(elapsed);steps.push(sim.total_steps()-before);
        equal(lastSnapshot,expected,`${f.name} snapshot tic ${i}`);
        if(lastStatus!==sample.expectedStatus) throw Error('status differs');
        // Checkpoint/restart only every32tics. Account for this latency;
        // no later command is submitted before the current snapshot exists.
        let extra=0;
        if((i+1)%32===0 || lastStatus!==0) {
          const start=performance.now();
          let p=sim.request_checkpoint(1000000);while(p===1)p=sim.resume(1000000);
          if(p!==0)throw Error('checkpoint did not pause');
          state=sim.checkpoint();
          const checkpointMs=performance.now()-start;
          equal(state,encode(sample.expectedCheckpoint),`${f.name} checkpoint ${i}`);
          const restartStart=performance.now();sim.restart(state);
          const restartMs=performance.now()-restartStart;
          extra=checkpointMs+restartMs;
          maintenance.push({tic:i,checkpointMs,restartMs,memoryBytes:wasm.memory.buffer.byteLength});
        }
        inclusiveMs.push(elapsed+extra);
      }
      // Export final full state to compare the complete old Worker ABI too.
      let p=sim.request_checkpoint(1000000);while(p===1)p=sim.resume(1000000);
      state=sim.checkpoint();
      const full=new Uint8Array((3+state.length/32+lastSnapshot.length/32)*32);
      full.set(encode([lastStatus,state.length/32]));full.set(state,64);
      full.set(encode([lastSnapshot.length/32]),64+state.length);full.set(lastSnapshot,96+state.length);
      const hash=[...new Uint8Array(await crypto.subtle.digest('SHA-256',full))].map(v=>v.toString(16).padStart(2,'0')).join('');
      if(hash!==f.expectedSha256)throw Error(f.name+': complete ABI differs');
      const entry={name:f.name,tics:tickMs.length,setupMs,tickMs:stats(tickMs),includingMaintenanceMs:stats(inclusiveMs),
        steps:stats(steps),overBudget:inclusiveMs.filter(v=>v>1000/35).length,maintenance,
        memoryBytes:wasm.memory.buffer.byteLength,outputSha256:hash,exact:true};
      results.cases.push(entry);self.postMessage({progress:entry});
    }
    sim.free();self.postMessage({ok:true,results});
  }catch(e){self.postMessage({ok:false,error:String(e.stack??e)});}
};
