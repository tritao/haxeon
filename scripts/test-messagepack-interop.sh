#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
haxe="$root_dir/.tools/haxe/haxe"
hl="$root_dir/.tools/hashlink/hl"
vectors="$root_dir/tests/fixtures/messagepack-vectors.tsv"
frames="$root_dir/tests/fixtures/messagepack-frame-vectors.tsv"
output="$root_dir/out/messagepack-interop.hl"
python_vectors="$root_dir/out/messagepack-python-vectors.tsv"
python_frames="$root_dir/out/messagepack-python-frame-vectors.tsv"

if [[ ! -x "$haxe" || ! -x "$hl" ]]; then
	echo "missing local toolchain; run ./scripts/bootstrap-tools.sh first" >&2
	exit 1
fi

mkdir -p "$root_dir/out"
"$haxe" --cwd "$root_dir" -cp src --run Main tests/programs/messagepack-interop.hx "$output" >/dev/null

if [[ "$(uname -s)" == "Darwin" ]]; then
	export DYLD_LIBRARY_PATH="$root_dir/out:$root_dir/.tools/hashlink${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
else
	export LD_LIBRARY_PATH="$root_dir/out:$root_dir/.tools/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

run_haxe_fixture() {
	local status
	if "$hl" "$output" "$@" >/dev/null; then
		status=0
	else
		status=$?
	fi
	if [[ $status -ne 42 ]]; then
		echo "MessagePack interop fixture failed with exit $status" >&2
		return 1
	fi
}

run_haxe_fixture "$vectors"

if ! python3 -c 'import msgpack' >/dev/null 2>&1; then
	echo "SKIP: Python msgpack is not installed; Haxe canonical vectors passed"
	exit 0
fi

python3 - "$vectors" "$frames" "$python_vectors" "$python_frames" <<'PY'
import pathlib
import sys

import msgpack

vectors_path, frames_path, output_vectors_path, output_frames_path = map(pathlib.Path, sys.argv[1:])


def read_vectors(path):
    result = {}
    for raw_line in path.read_text().splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        name, encoded = line.split("\t")
        result[name] = bytes.fromhex(encoded)
    return result


expected = {
    "nil": None,
    "false": False,
    "true": True,
    "positive-fixint": 42,
    "negative-fixint": -2,
    "uint8-128": 128,
    "uint16-256": 256,
    "uint32-65536": 65536,
    "int8-minus-33": -33,
    "int16-minus-129": -129,
    "int32-minus-32769": -32769,
    "uint32-max": 4294967295,
    "int64-max": 9223372036854775807,
    "int64-min": -9223372036854775808,
    "float64-1.5": 1.5,
    "string-hello": "hello",
    "string-euro": "€",
    "binary-deadbeef": b"\xde\xad\xbe\xef",
    "array-mixed": [1, -2, "x"],
    "map-ordered": {"a": 1, "b": True},
    "string-key-utf8": {"é": 1, "é": 2, "😀": 3},
    "nested": [{"a": 1}, [False, True]],
    "ext-fixext1": msgpack.ExtType(42, b"\x01"),
}

vectors = read_vectors(vectors_path)
for name, raw in vectors.items():
    decoded = msgpack.unpackb(
        raw,
        raw=False,
        strict_map_key=False,
        ext_hook=lambda code, data: msgpack.ExtType(code, data),
    )
    if decoded != expected[name]:
        raise AssertionError(f"{name}: Python decoded {decoded!r}, expected {expected[name]!r}")

def encode_value(name):
    return msgpack.packb(expected[name], use_bin_type=True)


output_vectors_path.write_text(
    "# name\thex\n"
    + "".join(
        f"{name}\t{encode_value(name).hex()}\n"
        for name in vectors
    )
)

frame_vectors = read_vectors(frames_path)
frame_payload_names = {"nil-frame": "nil", "map-ordered-frame": "map-ordered"}
for name, raw in frame_vectors.items():
    if raw[:4] != b"HMPK" or raw[4:6] != b"\x01\x00":
        raise AssertionError(f"{name}: invalid frame header")
    payload_length = int.from_bytes(raw[6:10], "big")
    payload = raw[10:]
    if payload_length != len(payload):
        raise AssertionError(f"{name}: frame payload length mismatch")
    decoded = msgpack.unpackb(payload, raw=False, strict_map_key=False)
    if decoded != expected[frame_payload_names[name]]:
        raise AssertionError(f"{name}: decoded payload differs")


def frame_for(value):
    payload = msgpack.packb(value, use_bin_type=True)
    return b"HMPK" + bytes([1, 0]) + len(payload).to_bytes(4, "big") + payload


output_frames_path.write_text(
    "# name\thex\n"
    + "".join(
        f"{name}\t{frame_for(expected[base]).hex()}\n"
        for name, base in frame_payload_names.items()
    )
)
print(f"PASS: Python msgpack decoded {len(vectors)} vectors and generated compatible encodings")
PY

run_haxe_fixture "$vectors" "$python_vectors" "$python_frames"
echo "PASS: Haxe and Python MessagePack interoperability, including frames"
