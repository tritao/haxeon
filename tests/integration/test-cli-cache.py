#!/usr/bin/env python3
"""Exercise the Unix launcher's cache against checkout and toolchain changes."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

LAUNCHER = Path(__file__).resolve().parents[2] / 'scripts/haxeon'
with tempfile.TemporaryDirectory(prefix='haxeon-cli-cache-') as directory:
    root = Path(directory)
    for name in ['scripts', 'src', '.tools/haxe/std', '.tools/hashlink', 'out']:
        (root / name).mkdir(parents=True)
    shutil.copy2(LAUNCHER, root / 'scripts/haxeon')
    (root / 'scripts/hashlink-path.sh').write_text(
        '#!/bin/sh\ncd "$(dirname "$0")/.." && printf "%s/.tools/hashlink\\n" "$PWD"\n')
    # The fake compiler counts actual invocations; the fake runtime accepts any artifact.
    compiler = root / '.tools/haxe/haxe'
    compiler.write_text('''#!/bin/sh
printf 'compile\\n' >> "$HAXEON_HOME/out/invocations"
while [ "$#" -gt 0 ]; do
    if [ "$1" = -hl ]; then shift; printf 'bytecode\\n' > "$1"; fi
    shift
done
''')
    (root / '.tools/hashlink/hl').write_text('#!/bin/sh\nexit 0\n')
    for name in ['scripts/haxeon', 'scripts/hashlink-path.sh', '.tools/haxe/haxe', '.tools/hashlink/hl']:
        (root / name).chmod(0o755)
    source = root / 'src/Main.hx'
    source.write_text('class Main {}\n')
    std = root / '.tools/haxe/std/Std.hx'
    std.write_text('class Std {}\n')

    def check(expected):
        subprocess.run([str(root / 'scripts/haxeon'), '--help'], check=True)
        actual = len((root / 'out/invocations').read_text().splitlines())
        assert actual == expected, (actual, expected)

    check(1)
    check(1)
    os.utime(source, None)
    check(1)
    # Changed content with preserved mtime must still invalidate.
    prior = source.stat()
    source.write_text('class Main { /* changed */ }\n')
    os.utime(source, ns=(prior.st_atime_ns, prior.st_mtime_ns))
    check(2)
    added = root / 'src/Added.hx'
    added.write_text('class Added {}\n')
    check(3)
    added.unlink()
    check(4)
    std.write_text('class Std { /* changed */ }\n')
    check(5)
    compiler.write_text(compiler.read_text() + '# new host compiler\n')
    check(6)
    launcher = root / 'scripts/haxeon'
    launcher.write_text(launcher.read_text() + '# new launcher\n')
    check(7)
    (root / 'out/haxeon-cli.hl').unlink()
    check(8)
    (root / 'out/haxeon-cli.hl.inputs').unlink()
    check(9)
print('PASS: CLI cache tracks content, additions, removals and the host toolchain')
