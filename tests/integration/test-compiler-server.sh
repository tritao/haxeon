#!/usr/bin/env bash
set -euo pipefail
repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
python3 - "$repo_dir" <<'PY'
import json, os, pathlib, socket, struct, subprocess, sys, tempfile, time

repo = pathlib.Path(sys.argv[1])
env = os.environ.copy()
env.pop('HAXEON_COMPILER_SERVER', None)
env['LD_LIBRARY_PATH'] = str(repo / 'out') + ':' + str(repo / '.tools/hashlink') + ':' + env.get('LD_LIBRARY_PATH', '')

def stop(state):
    try:
        value = json.loads(state.read_text())
        with socket.create_connection(('127.0.0.1', value['port']), timeout=5) as client:
            body = json.dumps({'token': value['token'], 'shutdown': True}).encode()
            client.sendall(struct.pack('<i', len(body)) + body)
            client.recv(1024)
    except (OSError, ValueError):
        pass

with tempfile.TemporaryDirectory(prefix='haxeon-compiler-server-') as directory:
    root = pathlib.Path(directory)
    (root / 'src').mkdir()
    manifest = root / 'haxeon.json'
    manifest.write_text(json.dumps({'version': 1, 'package': {'name': 'fixture'}, 'entry': 'Main', 'sourceRoots': ['src'], 'outputDir': 'build'}))
    main = root / 'src/Main.hx'
    states = root / 'sessions'
    env['HAXEON_COMPILER_SESSION_DIR'] = str(states)
    def source(value):
        main.write_text('class Main { public static function main():Int { return ' + value + '; } }\n')
    def build(success=True, extra=(), environment=env):
        p = subprocess.run([str(repo / 'scripts/haxeon'), 'build', '--project', str(manifest), *extra], env=environment,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=120)
        assert (p.returncode == 0) == success, p.stdout
        return p.stdout
    def run(expected, output='host/main.hl'):
        p = subprocess.run([str(repo / '.tools/hashlink/hl'), str(root / 'build' / output)], env=env, timeout=20)
        assert p.returncode == expected, (output, p.returncode, expected)
    try:
        source('7')
        build()
        run(7)
        assert len(list(states.glob('*.json'))) == 1
        # A worker of another compiler version for this same project can never be reused.
        current = next(states.glob('*.json')).stem
        obsolete_state = states / ('0' * 64 + current[64:] + '.json')
        unrelated_state = states / ('1' * 64 + '-' + 'f' * 16 + '.json')
        obsolete = subprocess.Popen([str(repo / '.tools/hashlink/hl'), str(next(states.glob('*.hl'))), str(obsolete_state)], env=env,
                                    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        unrelated = subprocess.Popen([str(repo / '.tools/hashlink/hl'), str(next(states.glob('*.hl'))), str(unrelated_state)], env=env,
                                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(100):
            if obsolete_state.exists() and unrelated_state.exists():
                break
            time.sleep(0.01)
        assert obsolete_state.exists() and unrelated_state.exists(), 'extra workers did not start'
        time.sleep(1)
        source('9')
        assert 'reusing compiler session' in build()
        run(9)
        obsolete.wait(timeout=5)
        assert not obsolete_state.exists(), 'obsolete worker was not shut down'
        assert unrelated_state.exists() and unrelated.poll() is None, 'another project\'s worker was retired under the limit'
        # Beyond the global limit, the least recently used worker of any project is retired.
        source('10')
        assert 'reusing compiler session' in build(environment=dict(env, HAXEON_COMPILER_WORKERS='1'))
        run(10)
        unrelated.wait(timeout=5)
        assert not unrelated_state.exists(), 'least recently used worker was not retired'
        # A state file whose process is gone is dropped.
        dead_state = states / ('2' * 64 + '-' + 'e' * 16 + '.json')
        dead_state.write_text(json.dumps({'port': 1, 'token': '0' * 64, 'pid': 2 ** 22 + 1}))
        source('9')
        build()
        assert not dead_state.exists(), 'dead worker state was not removed'
        # Beyond the memory budget, other workers are retired even under the count limit.
        heavy_state = states / ('3' * 64 + '-' + 'd' * 16 + '.json')
        heavy = subprocess.Popen([str(repo / '.tools/hashlink/hl'), str(next(states.glob('*.hl'))), str(heavy_state)], env=env,
                                 stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(100):
            if heavy_state.exists():
                break
            time.sleep(0.01)
        time.sleep(1)
        source('12')
        build(environment=dict(env, HAXEON_COMPILER_MEMORY_MB='1'))
        run(12)
        heavy.wait(timeout=5)
        assert not heavy_state.exists(), 'worker beyond the memory budget was not retired'
        source('unknown_value')
        build(success=False)
        source('11')
        build()
        run(11)
        # A missing sidecar is a missing build output, even with unchanged source.
        (root / 'build/host/main.hl.functions').unlink()
        assert 'reusing compiler session' in build()
        assert (root / 'build/host/main.hl.functions').is_file()
        state = next(states.glob('*.json'))
        old_token = json.loads(state.read_text())['token']
        stop(state)
        source('13')
        build()
        run(13)
        assert json.loads(next(states.glob('*.json')).read_text())['token'] != old_token
        fallback = dict(env, HAXEON_COMPILER_SERVER='0')
        workers = set(states.glob('*.hl'))
        output = build(extra=('--output=build/fallback.hl',), environment=fallback)
        assert 'reusing compiler session' not in output and 'interpreting the compiler' not in output, output
        run(13, 'fallback.hl')
        assert len(set(states.glob('*.hl')) - workers) == 1, 'one-shot build did not use a compiled compiler'
        source('unknown_value')
        build(success=False, extra=('--output=build/fallback.hl',), environment=fallback)
        print('PASS: compiler worker reuse, retirement limits, error recovery, sidecars, restart, and compiled one-shot fallback')
    finally:
        for state in states.glob('*.json'):
            stop(state)
PY
