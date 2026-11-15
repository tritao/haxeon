#!/usr/bin/env bash
set -euo pipefail
repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
python3 - "$repo_dir" <<'PY'
import json, os, pathlib, selectors, signal, subprocess, sys, tempfile, time
repo = pathlib.Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix='haxeon-run-output-') as temporary:
    project = pathlib.Path(temporary); (project/'src').mkdir()
    (project/'haxeon.json').write_text(json.dumps({'version':1,'package':{'name':'run-output-test'},'entry':'Main','sourceRoots':['src'],'target':'host','outputDir':'build'}))
    (project/'src/Main.hx').write_text('class Main { static function main():Void { Sys.println("CHILD_READY"); Sys.stdout().flush(); while (!sys.FileSystem.exists(Sys.args()[0])) Sys.sleep(0.01); Sys.println("CHILD_DONE"); Sys.stdout().flush(); } }')
    release = project/'release'
    process = subprocess.Popen([str(repo/'scripts/haxeon'),'run','--project',str(project/'haxeon.json'),'--',str(release)],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,start_new_session=True)
    output = b''
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout,selectors.EVENT_READ)
            deadline = time.monotonic()+90
            while b'CHILD_READY\n' not in output and time.monotonic()<deadline:
                if process.poll() is not None: raise RuntimeError(output.decode(errors='replace'))
                for event,_ in selector.select(0.1):
                    output += os.read(event.fileobj.fileno(),65536)
            if b'CHILD_READY\n' not in output: raise RuntimeError('Running child output was buffered until exit: '+output.decode(errors='replace')[-3000:])
            assert process.poll() is None
            release.touch()
            tail,_ = process.communicate(timeout=10)
            assert process.returncode==0 and b'CHILD_DONE\n' in output+tail
    finally:
        if process.poll() is None:
            os.killpg(process.pid,signal.SIGKILL);process.wait(timeout=10)
print('PASS: run forwards flushed child output before the child exits')
PY
