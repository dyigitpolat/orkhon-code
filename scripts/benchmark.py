#!/usr/bin/env python3
import subprocess,os,time,json,statistics,sys,tempfile
from pathlib import Path
root=Path(__file__).resolve().parent.parent
binary=Path(sys.argv[1]) if len(sys.argv)>1 else Path((root/'work/staged-app-path.txt').read_text().strip())/'Contents/MacOS/Orkhon Code'
rows=[]
for i in range(12):
 marker=root/f'work/launch-{i}.txt'
 marker.unlink(missing_ok=True)
 env=os.environ.copy();env['LUMEN_BENCHMARK_FILE']=str(marker);env['ORKHON_TEST_DATA']=tempfile.mkdtemp(prefix='orkhon-benchmark-data-');env['ORKHON_SKIP_SETUP']='1'
 start=time.perf_counter_ns()
 p=subprocess.Popen([str(binary)],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 deadline=time.monotonic()+15
 while not marker.exists() and p.poll() is None and time.monotonic()<deadline:time.sleep(.001)
 elapsed=(time.perf_counter_ns()-start)/1e6
 if marker.exists():rows.append({'run':i+1,'processToWindowReadyMs':elapsed,'mainToWindowReadyMs':float(marker.read_text().strip())})
 else:rows.append({'run':i+1,'error':'No readiness marker'})
 try:p.wait(timeout=5)
 except subprocess.TimeoutExpired:
  raise RuntimeError("Benchmark app did not exit gracefully; leaving it intact for inspection.")
 time.sleep(.15)
valid=[r for r in rows if 'processToWindowReadyMs' in r]
result={'method':'Fresh processes with warm filesystem caches. Readiness is window creation and synchronous AppKit drawing; compositor presentation and Finder launch dispatch are not measured. First run retained separately. No OS cache purge.', 'runs':rows,'medianProcessToWindowReadyMs':statistics.median(r['processToWindowReadyMs'] for r in valid),'medianMainToWindowReadyMs':statistics.median(r['mainToWindowReadyMs'] for r in valid),'p95ProcessToWindowReadyMs':sorted(r['processToWindowReadyMs'] for r in valid)[min(len(valid)-1,int(len(valid)*.95))]}
(root/'work/launch-benchmark.json').write_text(json.dumps(result,indent=2));print(json.dumps(result,indent=2))
