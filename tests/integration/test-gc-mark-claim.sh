#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
if [[ $(uname -sm) != 'Linux x86_64' ]]; then
 echo 'SKIP: serial mark optimization is supported only on Linux x86-64'
 exit 0
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-gc-claim.XXXXXX")
trap 'rm -rf "$work"' EXIT
# Expose the existing private helper in a copied collector, without adding a
# production API or reimplementing the claim operation in the test.
python3 - "$root" "$work" "${HL_GC_TEST_BUILD_DIR:-$root/out/cmake/release}" <<'PYCODE'
from pathlib import Path
import shlex,subprocess,sys
root,work,build=map(Path,sys.argv[1:])
source=(root/'vendor/hashlink/src/gc.c').read_bytes()
needle=b'static void gc_dispatch_mark('
assert source.count(needle)==1
source=source.replace(needle,b'HL_API bool hl_gc_mark_claim_test(unsigned char *addr,unsigned char mask) { return atomic_bit_set(addr,mask); }\n\n'+needle)
(work/'gc.c').write_bytes(source)
commands=subprocess.check_output(['ninja','-C',str(build),'-t','commands','libhl'],text=True).splitlines()
args=shlex.split(next(x for x in commands if ' -c ' in x and x.endswith('/src/gc.c')))
for opt in ['-MD','-MT','-MF']:
 if opt in args:
  i=args.index(opt);del args[i:i+(1 if opt=='-MD' else 2)]
args[args.index('-c')+1]=str(work/'gc.c');args[args.index('-o')+1]=str(work/'gc.o')
subprocess.run(args,cwd=build,check=True)
args=shlex.split(next(x for x in commands if ' -shared ' in x).split(' && ')[1])
args[args.index('-o')+1]=str(work/'libhl.so.1.16.0')
args=[str(work/'gc.o') if x.endswith('/src/gc.c.o') else x for x in args]
subprocess.run(args,cwd=build,check=True)
for name in ['libhl.so.1','libhl.so']:
 (work/name).symlink_to('libhl.so.1.16.0')
PYCODE
"${CC:-cc}" -shared -fPIC -I"$root/vendor/hashlink/src" "$root/tests/native/gc_mark_claim_probe.c" -L"$work" -lhl -lpthread -o "$work/gcclaim.hdll"
"$root/.tools/haxe/haxe" -cp "$root/tests/native" -hl "$work/probe.hl" -main GcMarkClaimProbe
for threads in 1 4; do
 for mode in 0 1; do
  HL_GC_THREADS=$threads HL_GC_MARK_SERIAL=$mode LD_LIBRARY_PATH="$work:$root/out:$root/.tools/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "${HL_JIT_TEST_VM:-$root/.tools/hashlink/hl}" "$work/probe.hl"
 done
done
