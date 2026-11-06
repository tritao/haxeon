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
        output = root / 'main.hl'
        env = {**os.environ, 'HAXEON_COMPILER_SERVER': '0', 'XDG_CACHE_HOME': str(root / 'cache')}
        def build(mode):
            subprocess.run([str(ROOT / 'scripts/haxeon'), 'build', '--compiler-only'] +
                           ([] if mode is None else ['--build-mode', mode]) + ['--project', str(root / 'haxeon.json'), '--output', str(output)],
                           cwd=ROOT, env=env, check=True, capture_output=True, text=True)
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
