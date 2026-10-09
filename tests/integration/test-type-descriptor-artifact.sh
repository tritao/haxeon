#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "$0")/../.." && pwd)
output_dir="$repo_dir/out/type-descriptor-artifact"
mkdir -p "$output_dir"

root_dir=$repo_dir
haxe_bin="$repo_dir/.tools/haxe/haxe"
source "$repo_dir/scripts/haxeon-compiler.sh"
haxeon_compile --target=hl --output="$output_dir/native-type-info-nonflat.hl" --entry=native-type-info-nonflat --root=tests/programs \
	 tests/programs/native-type-info-nonflat.hx

set +e
LD_LIBRARY_PATH="$repo_dir/out:$repo_dir/.tools/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
	"$repo_dir/.tools/hashlink/hl" "$output_dir/native-type-info-nonflat.hl"
status=$?
set -e
if [[ $status -ne 42 ]]; then
	echo "native type descriptor fixture returned $status, expected 42" >&2
	exit 1
fi

node - "$output_dir/native-type-info-nonflat.hl.descriptors" "$output_dir/native-type-info-nonflat.hl.descriptors.json" <<'NODE'
const assert = require('node:assert/strict');
const fs = require('node:fs');

const [binaryPath, jsonPath] = process.argv.slice(2);
const binary = fs.readFileSync(binaryPath);
const dump = JSON.parse(fs.readFileSync(jsonPath, 'utf8'));
assert.equal(binary.subarray(0, 3).toString('ascii'), 'HTD');
assert.equal(binary.readUInt8(3), 2);
assert.equal(binary.readUInt32LE(4), dump.descriptors.length);
assert.equal(dump.formatVersion, 2);
assert.deepEqual(dump.descriptors.map(item => item.name), ['InnerRecord', 'ManagedPayload', 'Range']);

const inner = dump.descriptors[0];
assert.equal(inner.flat, true);
assert.equal(inner.size, 8);
assert.equal(inner.alignment, 4);
assert.deepEqual(inner.fields.map(field => field.offset), [0, 4]);
assert.deepEqual(inner.fields[0].annotationValues[0], {
  name: 'Range',
  arguments: [
    { name: 'min', type: 'Float', value: -1.5 },
    { name: 'max', type: 'Float', value: 4.25 },
  ],
});
assert.deepEqual(inner.fields[1].annotationValues[0], {
  name: 'Replicate',
  arguments: [{ name: 'value', type: 'Int', value: 2 }],
});

const managed = dump.descriptors[1];
assert.equal(managed.flat, false);
assert.equal(managed.size, null);
assert.equal(managed.alignment, null);
assert.equal(managed.fields[1].fields.length, 2);
assert.equal(managed.fields[2].arguments[0].type, 'Int');
for (const descriptor of dump.descriptors)
  assert.match(descriptor.hash, /^[0-9a-f]{64}$/);

process.stdout.write('PASS: build emits versioned descriptor binary and recursive JSON dump\n');
NODE
