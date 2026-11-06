#!/usr/bin/env python3
"""Project builds select release or development metadata without losing runtime names."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main():
    preset = os.environ.get('HAXEON_CMAKE_PRESET', 'release')
    hldump = Path(os.environ.get('HLDUMP', ROOT / 'out/cmake' / preset / 'hashlink/bin/hldump'))
    with tempfile.TemporaryDirectory(prefix='haxeon-build-mode-') as directory:
        root = Path(directory)
        (root / 'src').mkdir()
        (root / 'src/Main.hx').write_text('class Main { static function main():Int return 42; }\n')
        (root / 'haxeon.json').write_text(json.dumps({'version': 1, 'package': {'name': 'build-mode-test'},
                                                     'entry': 'Main', 'sourceRoots': ['src'], 'target': 'host'}))
        (root / 'native').mkdir()
        (root / 'native/CMakeLists.txt').write_text('cmake_minimum_required(VERSION 3.20)\nproject(profile_probe C)\nadd_library(profile_probe SHARED probe.c)\n')
        (root / 'native/probe.c').write_text('int profile_probe(void) { return 42; }\n')
        manifest = json.loads((root / 'haxeon.json').read_text())
        manifest['native'] = {'cmake': {'source': 'native', 'target': 'profile_probe', 'library': 'profile_probe'}}
        (root / 'haxeon.json').write_text(json.dumps(manifest))
        output = root / 'main.hl'
        env = {**os.environ, 'HAXEON_COMPILER_SERVER': '0', 'XDG_CACHE_HOME': str(root / 'cache'), 'HAXEON_NATIVE_CACHE': str(root / 'native-cache')}
        def build(mode):
            subprocess.run([str(ROOT / 'scripts/haxeon'), 'build'] +
                           ([] if mode is None else ['--build-mode', mode]) + ['--project', str(root / 'haxeon.json'), '--output', str(output)],
                           cwd=ROOT, env=env, check=True, capture_output=True, text=True)
            caches = list((root / 'native-cache').rglob('CMakeCache.txt'))
            assert caches, 'Native CMake probe did not configure'
            assert all('CMAKE_BUILD_TYPE:STRING=Release' in cache.read_text() for cache in caches), mode
            dump = subprocess.check_output([str(hldump), '--debug', str(output)], text=True)
            run = subprocess.run([str(ROOT / 'scripts/hl'), str(output)], cwd=ROOT, env=env, capture_output=True)
            assert run.returncode == 42, (mode, run.returncode, run.stderr)
            return output.read_bytes(), dump
        release, release_dump = build('release')
        development, development_dump = build(None)
        explicit_development, _ = build('development')
        assert development == explicit_development
        release_again, _ = build('release')
        assert release == release_again
        assert 'section kind=1 ' in release_dump and 'section kind=2 ' not in release_dump and 'section kind=3 ' not in release_dump
        assert all(f'section kind={kind} ' in development_dump for kind in (1, 2, 3))
        assert len(release) < len(development)
    print('PASS: project build modes select development metadata and retain executable names')


if __name__ == '__main__':
    main()
