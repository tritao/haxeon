#!/usr/bin/env bash
set -euo pipefail
repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
python3 - "$repo_dir" <<'PY'
import json, os, pathlib, socket, struct, subprocess, sys, tempfile

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
    states = root / 'build/.haxeon/compiler'
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
        source('9')
        assert 'reusing compiler session' in build()
        run(9)
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
        assert 'reusing compiler session' not in build(extra=('--output=build/fallback.hl',), environment=fallback)
        run(13, 'fallback.hl')
        print('PASS: compiler worker reuse, error recovery, sidecars, restart, and one-shot fallback')
    finally:
        for state in states.glob('*.json'):
            stop(state)
PY
