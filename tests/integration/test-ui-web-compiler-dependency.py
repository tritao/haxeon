#!/usr/bin/env python3
"""A prepared UI Web build must regenerate its guest when its compiler changes."""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir', required=True, type=Path)
    args = parser.parse_args()
    build = args.build_dir.resolve()
    cache = {}
    for line in (build / 'CMakeCache.txt').read_text().splitlines():
        if not line.startswith(('#', '//')) and '=' in line and ':' in line.split('=', 1)[0]:
            key, value = line.split('=', 1)
            cache[key.split(':', 1)[0]] = value
    assert cache['NKUI_HAXEON_SELF_HOSTED'] in ('1', 'ON', 'TRUE'), 'Prepared build must use a compiled compiler'
    module = Path(cache['NKUI_HAXEON_COMPILER_MODULE']).resolve()
    guest = build / ('nativekit_ui_showcase_' + cache['NKUI_HAXEON_TARGET'].replace('-', '_') + '.wasm')
    assert module.is_file() and guest.is_file(), 'Build the UI guest before this check'

    def configure(selected):
        subprocess.run(['cmake', '-S', str(ROOT / 'packages/ui'), '-B', str(build),
                        '-DNKUI_HAXEON_SELF_HOSTED=ON', '-DNKUI_HAXEON_COMPILER_MODULE=' + str(selected)],
                       check=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

    def build_guest():
        subprocess.run(['cmake', '--build', str(build), '--target', 'nativekit_ui_haxeon_guest'],
                       check=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

    expected = hashlib.sha256(guest.read_bytes()).hexdigest()
    configure(module)
    build_guest()
    with tempfile.TemporaryDirectory(prefix='ui-compiler-dependency-') as temporary:
        alternate = Path(temporary) / 'compiler.hl'
        shutil.copyfile(module, alternate)
        try:
            before = guest.stat().st_mtime_ns
            configure(alternate)
            build_guest()
            assert guest.stat().st_mtime_ns > before, 'Changing the compiler path must regenerate its guest'
            assert hashlib.sha256(guest.read_bytes()).hexdigest() == expected, 'An identical compiler copy must emit the same guest'
            before = guest.stat().st_mtime_ns
            os.utime(alternate, ns=(before + 1_000_000, before + 1_000_000))
            build_guest()
            assert guest.stat().st_mtime_ns > before, 'Updating the selected compiler must regenerate its guest'
            assert hashlib.sha256(guest.read_bytes()).hexdigest() == expected
        finally:
            configure(module)
            build_guest()
    assert hashlib.sha256(guest.read_bytes()).hexdigest() == expected
    print('PASS: UI Web guest tracks the selected compiler path and file updates')


if __name__ == '__main__':
    main()
