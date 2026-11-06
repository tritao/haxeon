#!/usr/bin/env python3
"""Read emitted debug lines with HashLink's independent bytecode decoder."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main():
    preset = os.environ.get('HAXEON_CMAKE_PRESET', 'release')
    tool = Path(os.environ.get('HLDUMP', ROOT / 'out/cmake' / preset / 'hashlink/bin/hldump'))
    with tempfile.TemporaryDirectory(prefix='haxeon-debug-lines-') as directory:
        artifact = Path(directory) / 'lines.hl'
        fixture = subprocess.run([str(ROOT / '.tools/haxe/haxe'), '-cp', 'src', '-cp', 'tests/tooling',
                                  '--run', 'DebugLineEncodingFixture', str(artifact)], cwd=ROOT, check=True,
                                 env={**os.environ, 'HAXEON_IR_CENSUS': '1'}, capture_output=True, text=True)
        census = next(json.loads(line[len('SIZE_CENSUS '):]) for line in fixture.stderr.splitlines()
                      if line.startswith('SIZE_CENSUS '))
        assert census['functionDebug'] < 40, census['functionDebug']
        output = subprocess.check_output([str(tool), '--debug', str(artifact)], text=True)
        files = {int(i): name for i, name in re.findall(r'^file (\d+) (.+)$', output, re.M)}
        actual = [(files[int(file)], int(line)) for file, line in
                  re.findall(r'^\s+\d+ O\w+\s+@(\d+):(\d+)', output, re.M)]
        expected = [('second.hx' if i == 24 else 'first.hx',
                     1 if i <= 20 else 32 if i == 21 else 64 if i == 22 else 2 if i <= 24 else 3)
                    for i in range(57)]
        assert actual == expected, (actual, expected)
    print('PASS: HashLink decodes repeated, delta, absolute and cross-file debug lines')


if __name__ == '__main__':
    main()
