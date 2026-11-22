#!/usr/bin/env bash
set -euo pipefail
repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
python3 - "$repo_dir" <<'PY'
import hashlib, json, os, pathlib, socket, struct, subprocess, sys, tempfile, time

repo = pathlib.Path(sys.argv[1])
env = os.environ.copy()
env.pop('HAXEON_COMPILER_SERVER', None)
env['LD_LIBRARY_PATH'] = str(repo / 'out') + ':' + str(pathlib.Path(subprocess.check_output([str(repo / 'scripts/hashlink-path.sh')], text=True).strip())) + ':' + env.get('LD_LIBRARY_PATH', '')

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
        p = subprocess.run([str(repo / 'scripts/haxeon'), 'build', '--verbosity=normal', '--project', str(manifest), *extra], env=environment,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=120)
        assert (p.returncode == 0) == success, p.stdout
        if success:
            binary = root / 'build/host/main.hl'
            if binary.exists():
                assert binary.with_name(binary.name + '.build-id').read_text() == hashlib.sha256(binary.read_bytes()).hexdigest()
        return p.stdout
    hashlink = pathlib.Path(subprocess.check_output([str(repo / 'scripts/hashlink-path.sh')], text=True).strip())
    def worker(state):
        # The worker program: the compiler built ahead of time when it is current (build.AotCompiler), which needs no bytecode
        # in the session directory, else the VM with the worker bytecode built there.
        programs = list(states.glob('*.hl'))
        command = [str(programs[0])] if programs else [str(hashlink / 'haxeon-compiler'), 'serve']
        return subprocess.Popen(([str(hashlink / 'hl')] if programs else []) + command + [str(state)], env=env,
                                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    def run(expected, output='host/main.hl'):
        p = subprocess.run([str(hashlink / 'hl'), str(root / 'build' / output)], env=env, timeout=20)
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
        aot = not list(states.glob('*.hl'))
        obsolete = worker(obsolete_state)
        unrelated = worker(unrelated_state)
        # A worker publishes its state once the VM has loaded the compiler, which takes seconds, not milliseconds.
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if obsolete_state.exists() and unrelated_state.exists():
                break
            time.sleep(0.05)
        assert obsolete_state.exists() and unrelated_state.exists(), 'extra workers did not start'
        time.sleep(1)
        source('9')
        assert 'reusing compiler session' in build()
        run(9)
        # Editing a module with inline conditional compilation must compare its active
        # declarations rather than feeding directives to the ordinary lexer.
        main.write_text('class Main { public static function main():Int { return #if hl 10 #else 11 #end; } }\n')
        assert 'reusing compiler session' in build()
        run(10)
        main.write_text('class Main { public static function main():Int { return #if hl 12 #else 11 #end; } }\n')
        assert 'reusing compiler session' in build()
        run(12)
        obsolete.wait(timeout=5)
        assert not obsolete_state.exists(), 'obsolete worker was not shut down'
        assert unrelated_state.exists() and unrelated.poll() is None, 'another project\'s worker was retired under the limit'
        # Beyond the global limit, the least recently used worker of any project is retired.
        source('10')
        assert 'reusing compiler session' in build(environment=dict(env, HAXEON_COMPILER_WORKERS='1'))
        run(10)
        unrelated.wait(timeout=5)
        assert not unrelated_state.exists(), 'least recently used worker was not retired'
        # Whether a worker's process is alive and how much memory it holds are read from /proc, so only Linux retires a dead
        # worker's state file or a worker beyond the memory budget (CompilerClient.workerMemory).
        linux = sys.platform.startswith('linux')
        # A state file whose process is gone is dropped.
        dead_state = states / ('2' * 64 + '-' + 'e' * 16 + '.json')
        dead_state.write_text(json.dumps({'port': 1, 'token': '0' * 64, 'pid': 2 ** 22 + 1}))
        source('9')
        build()
        assert not linux or not dead_state.exists(), 'dead worker state was not removed'
        if not linux:
            dead_state.unlink()
        # Beyond the memory budget, other workers are retired even under the count limit.
        heavy_state = states / ('3' * 64 + '-' + 'd' * 16 + '.json')
        heavy = worker(heavy_state)
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if heavy_state.exists():
                break
            time.sleep(0.05)
        assert heavy_state.exists(), 'the heavy worker did not start'
        time.sleep(1)
        source('12')
        build(environment=dict(env, HAXEON_COMPILER_MEMORY_MB='1'))
        run(12)
        if linux:
            heavy.wait(timeout=5)
            assert not heavy_state.exists(), 'worker beyond the memory budget was not retired'
        else:
            stop(heavy_state)
            heavy.wait(timeout=5)
        source('unknown_value')
        build(success=False)
        source('11')
        build()
        run(11)
        # A missing sidecar is a missing build output, even with unchanged source.
        for suffix in ('.functions', '.descriptors', '.descriptors.json'):
            sidecar = root / ('build/host/main.hl' + suffix)
            expected = sidecar.read_bytes()
            sidecar.unlink()
            assert 'reusing compiler session' in build()
            assert sidecar.read_bytes() == expected, 'rebuild changed an unchanged sidecar: ' + suffix
        state = next(states.glob('*.json'))
        # Closing a requester cancels its transaction and leaves the worker reusable.
        descriptor = json.loads(state.read_text())
        cancelled_output = root / 'build/cancelled.hl'
        cancelled_output.write_bytes(b'previous successful publication')
        cancelled_sidecars = [pathlib.Path(str(cancelled_output) + suffix)
                              for suffix in ('.descriptors', '.descriptors.json')]
        for sidecar in cancelled_sidecars:
            sidecar.write_bytes(b'previous successful descriptor publication')
        with socket.create_connection(('127.0.0.1', descriptor['port']), timeout=5) as client:
            arguments = ['--target=hl', '--entry=Main', '--root=' + str(root / 'src'),
                         '--output=' + str(cancelled_output), str(main)]
            body = json.dumps({'token': descriptor['token'], 'arguments': arguments}).encode()
            client.sendall(struct.pack('<i', len(body)) + body)
            # The first progress message precedes request preparation and compilation.
            assert client.recv(4096), 'worker did not begin cancellation fixture'
        source('14')
        build()
        run(14)
        assert cancelled_output.read_bytes() == b'previous successful publication', 'cancellation damaged previous bytecode'
        for sidecar in cancelled_sidecars:
            assert sidecar.read_bytes() == b'previous successful descriptor publication', 'cancellation damaged previous descriptors'
        assert not list((root / 'build').glob('cancelled.hl.request-*')), 'cancelled staging artifacts leaked'
        assert json.loads(state.read_text())['token'] == descriptor['token'], 'cancellation killed the shared worker'
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
        # A compiled compiler: the one built ahead of time, or bytecode built for the one-shot run.
        assert len(set(states.glob('*.hl')) - workers) == (0 if aot else 1), 'one-shot build did not use a compiled compiler'
        source('unknown_value')
        build(success=False, extra=('--output=build/fallback.hl',), environment=fallback)
        print('PASS: compiler worker reuse, retirement limits, error recovery, sidecars, disconnect cancellation, restart, and compiled one-shot fallback')
    finally:
        for state in states.glob('*.json'):
            stop(state)
PY
