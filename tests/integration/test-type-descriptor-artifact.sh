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
assert.equal(binary.readUInt8(3), 4);
assert.equal(binary.readUInt32LE(4), dump.descriptors.length);
assert.equal(dump.formatVersion, 4);
assert.deepEqual(dump.descriptors.map(item => item.name), ['DescriptorDefaultLeaf', 'DescriptorDefaultRoot', 'InnerRecord', 'ManagedPayload', 'Range']);
assert(dump.descriptors.every(item => item.version === 5));

const inner = dump.descriptors.find(item => item.name === 'InnerRecord');
assert.equal(inner.sourceKind, 'struct');
assert.deepEqual(inner.interfaces, []);
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
assert.equal(managed.sourceKind, 'struct');
assert.deepEqual(managed.interfaces, []);
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
HAXEON_SCHEMA_LEGACY_ARTIFACT="$repo_dir/tests/fixtures/native-type-descriptor-v4-legacy.json" \
	LD_LIBRARY_PATH="$repo_dir/out:$repo_dir/.tools/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
	"$repo_dir/.tools/hashlink/hl" "$schema_output" || schema_status=$?
if [[ $schema_status -ne 42 ]]; then
	echo "MessagePackSchema validation fixture returned $schema_status, expected 42" >&2
	exit 1
fi
echo "PASS: runtime MessagePackSchema validates source facts, recursive defaults, legacy unknowns, and malformed artifacts"

python3 - "$repo_dir" "$output_dir" <<'PY'
import json, os, pathlib, socket, struct, subprocess, sys, tempfile

repo = pathlib.Path(sys.argv[1])
outputs = pathlib.Path(sys.argv[2])
env = os.environ.copy()
env.pop('HAXEON_COMPILER_SERVER', None)
env['LD_LIBRARY_PATH'] = str(repo / 'out') + ':' + str(repo / '.tools/hashlink') + ':' + env.get('LD_LIBRARY_PATH', '')

def stop(state):
    try:
        value = json.loads(state.read_text())
        with socket.create_connection(('127.0.0.1', value['port']), timeout=5) as client:
            body = json.dumps({'token': value['token'], 'shutdown': True}).encode()
            client.sendall(struct.pack('<i', len(body)) + body)
            client.recv(1024)
    except (OSError, ValueError):
        pass

with tempfile.TemporaryDirectory(prefix='descriptor-invalidation-', dir=outputs) as directory:
    root = pathlib.Path(directory)
    src = root / 'src'
    (src / 'schema').mkdir(parents=True)
    (src / 'model').mkdir()
    manifest = root / 'haxeon.json'
    manifest.write_text(json.dumps({
        'version': 1, 'package': {'name': 'descriptor-invalidation'}, 'entry': 'Main',
        'sourceRoots': ['src'], 'target': 'host', 'outputDir': 'build'
    }))
    resource = src / 'schema/Resource.hx'
    base = src / 'schema/BaseResource.hx'
    item = src / 'model/Item.hx'
    main = src / 'Main.hx'
    resource.write_text('package schema; interface Resource {}\n')
    base.write_text('package schema; interface BaseResource {}\n')
    item.write_text('package model; import schema.BaseResource; struct Item : BaseResource { public var value:Int; }\n')
    main.write_text('import model.Item; function main():Int return typeInfo<Item>().interfaces.length;\n')
    session_dir = root / 'sessions'
    env['HAXEON_COMPILER_SESSION_DIR'] = str(session_dir)
    env['HAXEON_SOURCE_CACHE'] = str(root / 'source-cache')
    env['HAXEON_DISABLE_ARTIFACT_CACHE'] = '1'
    env['HAXEON_CCACHE'] = '0'
    artifact = root / 'build/host/main.hl.descriptors.json'

    def build(reuse):
        result = subprocess.run([str(repo / 'scripts/haxeon'), 'build', '--project', str(manifest)], env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=120)
        assert result.returncode == 0, result.stdout
        assert ('reusing compiler session' in result.stdout) == reuse, result.stdout
        value = next(item for item in json.loads(artifact.read_text())['descriptors'] if item['name'] == 'model.Item')
        return value

    try:
        first = build(False)
        assert first['interfaces'] == ['interface:schema.BaseResource<>']
        base.write_text('package schema; import schema.Resource; interface BaseResource extends Resource {}\n')
        inherited = build(True)
        assert inherited['interfaces'] == ['interface:schema.BaseResource<>', 'interface:schema.Resource<>']
        assert inherited['hash'] != first['hash'], 'adding an ancestor interface must change the emitted descriptor hash'
        base.write_text('package schema; interface BaseResource {}\n')
        ancestor_removed = build(True)
        assert ancestor_removed['interfaces'] == first['interfaces']
        assert ancestor_removed['hash'] != inherited['hash'], 'removing an ancestor interface must change the emitted descriptor hash'
        item.write_text('package model; import schema.BaseResource; import schema.Resource; struct Item : BaseResource, Resource { public var value:Int; }\n')
        direct = build(True)
        assert direct['interfaces'] == inherited['interfaces']
        assert direct['hash'] != ancestor_removed['hash'], 'adding a direct interface must change the emitted descriptor hash'
        item.write_text('package model; import schema.BaseResource; import schema.Resource; struct Item : BaseResource { public var value:Int; }\n')
        direct_removed = build(True)
        assert direct_removed['interfaces'] == ancestor_removed['interfaces']
        assert direct_removed['hash'] == ancestor_removed['hash'], 'removing the direct interface must restore the original descriptor hash'
    finally:
        for state in session_dir.glob('*.json'):
            stop(state)

print('PASS: persistent compiler session invalidates descriptors for direct and inherited interface add/remove')
PY
