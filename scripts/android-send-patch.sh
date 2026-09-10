#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "$script_dir/.." && pwd)"
source "$root_dir/scripts/android-env.sh"

patch_path="${1:-$root_dir/android/app/src/main/assets/app.hlp}"
state_path="${2:-$root_dir/android/app/src/main/assets/app.hcs}"
pending_state_path="$state_path.pending"
local_port="${HAXEON_ANDROID_PATCH_PORT:-39817}"
if [[ ! -f "$patch_path" ]]; then
    echo "missing patch: $patch_path" >&2
    exit 1
fi

adb forward "tcp:$local_port" "tcp:$local_port" >/dev/null
PATCH_PATH="$patch_path" PATCH_PORT="$local_port" python3 - <<'PY'
import os
import socket
import struct
import sys

patch_path = os.environ["PATCH_PATH"]
port = int(os.environ["PATCH_PORT"])
payload = open(patch_path, "rb").read()
if not payload or len(payload) > 32 * 1024 * 1024:
    raise SystemExit("patch must be between 1 byte and 32 MiB")

with socket.create_connection(("127.0.0.1", port), timeout=10) as connection:
    connection.sendall(struct.pack(">I", len(payload)) + payload)
    response = b""
    while len(response) < 8:
        chunk = connection.recv(8 - len(response))
        if not chunk:
            raise SystemExit("Android host closed the patch connection")
        response += chunk

status, revision = struct.unpack(">ii", response)
print(f"Android patch status={status}, revision={revision}")
if status != 0:
    sys.exit(1)
PY

if [[ -f "$pending_state_path" ]]; then
    mv -f "$pending_state_path" "$state_path"
fi
