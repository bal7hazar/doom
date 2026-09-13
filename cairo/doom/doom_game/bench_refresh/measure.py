#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Measure opaque refresh cases and both full-program sizes. Pass an output directory."""
import json,os,re,subprocess,sys,pathlib
root=pathlib.Path(__file__).resolve().parents[4]
env=dict(os.environ,ASDF_SCARB_VERSION='2.16.0',RAYON_NUM_THREADS='1',CARGO_BUILD_JOBS='1')
out=pathlib.Path(sys.argv[1]);out.mkdir(parents=True,exist_ok=True);stage=out.name
results={}
for profile in ['dev','proving']:
 cmd=['scarb','--manifest-path',str(root/'cairo/doom/doom_game/bench_refresh/Scarb.toml'),'--profile',profile]
 subprocess.run(cmd+['build'],env=env,check=True,timeout=600,stdout=open(out/f'{profile}-build.log','w'),stderr=subprocess.STDOUT)
 prog=root/f'cairo/doom/doom_game/bench_refresh/target/{profile}/doom_game_refresh_bench.executable.json'
 obj=json.loads(prog.read_text()); results[profile]={'words':len(obj['program']['bytecode']),'cases':{}}
 (out/f'{profile}.executable.json').write_text(prog.read_text())
 for mode in range(4):
  pair=[]
  for n in [10,20]:
   p=subprocess.run(cmd+['execute','--no-build','--output','none','--print-resource-usage','--arguments',f'{n},98,{mode}'],env=env,capture_output=True,text=True,check=True,timeout=120)
   (out/f'{profile}-{mode}-{n}.log').write_text(p.stdout)
   stats={m.group(1).strip():int(m.group(2).replace(',','')) for m in re.finditer(r'^\s*([a-z_0-9 ]+):\s*([0-9,]+)\s*$',p.stdout,re.M)}
   pair.append(stats)
  results[profile]['cases'][str(mode)]={k:(pair[1].get(k,0)-pair[0].get(k,0))/10 for k in set(pair[0])|set(pair[1])}
  print(stage,profile,mode,results[profile]['cases'][str(mode)],flush=True)
 # actual full executable size
 p=subprocess.run(['scarb','--manifest-path',str(root/'cairo/Scarb.toml'),'--profile',profile,'build','-p','doom_run'],env=env,check=True,timeout=600,stdout=open(out/f'{profile}-game-build.log','w'),stderr=subprocess.STDOUT)
 results[profile]['game_words']={p.name:len(json.loads(p.read_text())['program']['bytecode']) for p in (root/f'cairo/target/{profile}').glob('*.executable.json')}
(out/'result.json').write_text(json.dumps(results,indent=2)+'\n')
