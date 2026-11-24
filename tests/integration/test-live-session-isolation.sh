#!/usr/bin/env bash
set -euo pipefail
repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
python3 - "$repo_dir" <<'PY'
import concurrent.futures
import json, os, pathlib, socket, struct, subprocess, sys, tempfile

repo = pathlib.Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix='haxeon-live-session-') as directory:
    root = pathlib.Path(directory)
    env = dict(os.environ, XDG_CACHE_HOME=str(root / 'cache'), LOCALAPPDATA=str(root / 'cache'),
               HAXEON_COMPILER_SERVER='1', HAXEON_COMPILER_WORKERS='1', HAXEON_COMPILER_IDLE_SECONDS='180')
    env.pop('HAXEON_COMPILER_SESSION_DIR', None)
    states = root / 'cache/haxeon/compiler'
    first, second = root / 'first', root / 'second'
    for project in (first, second):
        (project / 'src').mkdir(parents=True)
        (project / 'haxeon.json').write_text(json.dumps({
            'version': 1, 'package': {'name': 'fixture'}, 'entry': 'Main',
            'sourceRoots': ['src'], 'outputDir': 'build',
        }))
    def edit(project, value):
        (project / 'src/Main.hx').write_text(
            f'class Main {{ public static function main():Int {{ return {value}; }} }}\n')
    def build(project, name):
        output = project / 'build' / (name + '.hl')
        result = subprocess.run([str(repo / 'scripts/haxeon'), 'build', '--compiler-only', '--patchable',
                                 '--verbosity=normal', '--jobs=2', '--project', str(project / 'haxeon.json'),
                                 '--output=' + str(output)], env=env, capture_output=True, text=True, timeout=180)
        assert result.returncode == 0, result.stdout + result.stderr
        assert 'using one-shot compilation' not in result.stdout, result.stdout
        return json.loads(pathlib.Path(str(output) + '.live.patch.json').read_text())
    def assert_patch(before, after):
        assert after['moduleIdentity'] == before['moduleIdentity'], (before, after)
        assert after['baseRevision'] == before['revision'] and after['patchAvailable'], (before, after)
        assert not after['requiresReload'], after
    try:
        edit(first, 1)
        initial = build(first, 'app')
        edit(first, 2)
        patched = build(first, 'app')
        assert_patch(initial, patched)
        state, = states.glob('*.json')
        descriptor = json.loads(state.read_text())
        if sys.platform.startswith('linux'):
            # The loopback worker can be reachable from a checkout in a different PID namespace.
            unreadable_pid = state.with_suffix('.test')
            unreadable_pid.write_text(json.dumps(dict(descriptor, pid=2 ** 22 + 1)))
            unreadable_pid.replace(state)
        edit(second, 10)
        other = build(second, 'app')
        edit(first, 3)
        alternate = build(first, 'alternate')
        assert alternate['revision'] == 1 and alternate['moduleIdentity'] != initial['moduleIdentity'], alternate
        edit(first, 4)
        edit(second, 11)
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            first_edit = pool.submit(build, first, 'app')
            second_edit = pool.submit(build, second, 'app')
            assert_patch(patched, first_edit.result())
            assert_patch(other, second_edit.result())
        assert json.loads(state.read_text())['token'] == descriptor['token'], 'the live worker was displaced'
        print('PASS: live patches keep their module identity and base revision across checkouts and outputs')
    finally:
        for state in states.glob('*.json'):
            try:
                value = json.loads(state.read_text())
                with socket.create_connection(('127.0.0.1', value['port']), timeout=3) as client:
                    body = json.dumps({'token': value['token'], 'shutdown': True}).encode()
                    client.sendall(struct.pack('<i', len(body)) + body)
                    client.recv(1024)
            except (OSError, ValueError):
                pass
PY
