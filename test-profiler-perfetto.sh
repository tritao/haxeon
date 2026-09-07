#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 CAPTURE.hlpc" >&2
  exit 2
fi

profiler_tool="${HLPROF_LIVE:-vendor/hashlink/hlprof-live}"
output_file="$(mktemp /tmp/haxeon-perfetto-XXXXXX.json)"
trap 'rm -f "$output_file"' EXIT

"$profiler_tool" export --format perfetto --output "$output_file" "$1"
jq -e '
  (.traceEvents | length > 0) and
  any(.traceEvents[]; .ph == "C" and .name == "HashLink GC" and (.args.allocation_bytes_per_second != null)) and
  any(.traceEvents[]; .ph == "M" and .name == "thread_name") and
  any(.traceEvents[]; .cat == "hl.sample" and (.args.stack | contains("+0x")))
' "$output_file" >/dev/null
echo "PASS: Perfetto export contains counters, threads, and native frames"
