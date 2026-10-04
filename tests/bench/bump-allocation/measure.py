import pathlib,subprocess,os,json,time,statistics,hashlib,sys
r=pathlib.Path.cwd(); w=r/'out/bump-allocation'; env=dict(os.environ,HL_GC_KEEP_EMPTY='1',HL_GC_EMPTY_BUDGET='67108864',LD_LIBRARY_PATH=f'{w}/baseline:{r}/out')
def wait_load():
 while os.getloadavg()[0]>4:
  print('Waiting for load <=4:',os.getloadavg(),flush=True);time.sleep(30)
commands={}
for size in [16,24,40]:
 for lang,cmd in [('haxeon',[str(w/'baseline/hl'),str(w/'bench.hl')]),('dart',[str(w/'dart-bench')]),('csharp',[str(r/'.tools/dotnet/dotnet'),str(w/'csharp/pub/app.dll')])]:commands[f'{lang}-{size}']=[*cmd,str(size),'5000000']
for name,n in [('binarytrees','18'),('merkletrees','16')]:commands[name]=[str(w/'baseline/hl'),str(r/f'out/optimization-next/{name}/app.hl'),n]
results={k:[] for k in commands}; refs={}
for size in [16,24,40]:
 refs[size]=float(subprocess.check_output([str(r/'.tools/haxe/haxe'),'-cp','tests/bench/bump-allocation','--run','AllocationBench',str(size),'1000'],text=True))
 for lang in ['haxeon','dart','csharp']:
  c=commands[f'{lang}-{size}'][:-1]+['1000'];assert float(subprocess.check_output(c,env=env,text=True))==refs[size]
for k,c in commands.items():subprocess.run(['taskset','-c','0',*c],env=env,stdout=subprocess.DEVNULL,check=True)
for run in range(9):
 for k in list(commands)[::1 if run%2==0 else -1]:
  while True:
   wait_load();before=os.getloadavg();t=time.perf_counter();p=subprocess.run(['/usr/bin/time','-f','%M','taskset','-c','0',*commands[k]],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=True);dt=time.perf_counter()-t;after=os.getloadavg()
   if max(before[0],after[0])>4:continue
   results[k].append(dict(seconds=dt,rssKiB=int(p.stderr.strip().splitlines()[-1]),loads=[before,after]));break
 print('RUN',run+1,flush=True);(w/'measure.json').write_text(json.dumps(results,indent=2))
for k,v in results.items():print(k,statistics.median(x['seconds'] for x in v),flush=True)
for k,c in commands.items():
 with (w/f'{k}-stat.log').open('wb') as f:subprocess.run(['perf','stat','-x,','-e','cpu_core/instructions/,cpu_core/cycles/,page-faults','--','taskset','-c','0',*c],env=env,stdout=subprocess.DEVNULL,stderr=f,check=True)
(w/'manifest.json').write_text(json.dumps({str(p.relative_to(r)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [w/'baseline/hl',w/'baseline/libhl.so.1.16.0',w/'baseline/haxeon_runtime.hdll',w/'bench.hl',w/'dart-bench',w/'csharp/pub/app.dll',r/'out/optimization-next/binarytrees/app.hl',r/'out/optimization-next/merkletrees/app.hl']},indent=2))
