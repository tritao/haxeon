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
assert.equal(binary.readUInt8(3), 3);
assert.equal(binary.readUInt32LE(4), dump.descriptors.length);
assert.equal(dump.formatVersion, 3);
assert.deepEqual(dump.descriptors.map(item => item.name), ['DescriptorDefaultLeaf', 'DescriptorDefaultRoot', 'InnerRecord', 'ManagedPayload', 'Range']);
assert(dump.descriptors.every(item => item.version === 4));

const inner = dump.descriptors.find(item => item.name === 'InnerRecord');
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

const defaultRoot = dump.descriptors.find(item => item.name === 'DescriptorDefaultRoot');
assert.equal(defaultRoot.fields[0].defaultValue, null);
assert.deepEqual(defaultRoot.fields[0].fields.map(field => field.defaultValue), [
  { type: 'Int', value: 0 },
  { type: 'Float', value: 1.25 },
  { type: 'Null', value: null },
  null,
  { type: 'String', value: 'leaf' },
  { type: 'Bool', value: true },
]);

const managed = dump.descriptors.find(item => item.name === 'ManagedPayload');
assert.equal(managed.flat, false);
assert.equal(managed.size, null);
assert.equal(managed.alignment, null);
assert.equal(managed.fields[1].fields.length, 2);
assert.equal(managed.fields[2].arguments[0].type, 'Int');
for (const descriptor of dump.descriptors)
  assert.match(descriptor.hash, /^[0-9a-f]{64}$/);

process.stdout.write('PASS: build emits versioned descriptor binary and recursive JSON dump\n');
NODE

HAXEON_COMPILER_SESSION_DIR="$output_dir/schema-validation/compiler-session" \
HAXEON_SOURCE_CACHE="$output_dir/schema-validation/source-cache" \
HAXEON_DISABLE_ARTIFACT_CACHE=1 HAXEON_COMPILER_SERVER=0 HAXEON_CCACHE=0 \
	"$repo_dir/scripts/haxeon" build --project="$repo_dir/tests/fixtures/messagepack-schema-validation/haxeon.json"
schema_output="$output_dir/schema-validation/host/main.hl"
schema_status=0
HAXEON_SCHEMA_VALIDATION_ARTIFACT="$schema_output.descriptors.json" \
	LD_LIBRARY_PATH="$repo_dir/out:$repo_dir/.tools/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
	"$repo_dir/.tools/hashlink/hl" "$schema_output" || schema_status=$?
if [[ $schema_status -ne 42 ]]; then
	echo "MessagePackSchema validation fixture returned $schema_status, expected 42" >&2
	exit 1
fi
echo "PASS: runtime MessagePackSchema validates recursive descriptor defaults and rejects malformed artifacts"
