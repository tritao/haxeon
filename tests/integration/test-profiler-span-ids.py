#!/usr/bin/env python3
"""Keep the Haxe marker API and native capture protocol in sync."""

from pathlib import Path
import re

root = Path(__file__).resolve().parents[2]
header = (root / "vendor/hashlink/src/profile_events.h").read_text()
haxe = (root / "stdlib/haxeon/ProfileSpan.hx").read_text()
for name in ("SPAN_BEGIN", "SPAN_END"):
    native = re.search(rf"#define PROFILE_EVENT_{name}\s+(0x[0-9A-Fa-f]+)U", header)
    marker = re.search(rf"static inline var {name}\s*=\s*(0x[0-9A-Fa-f]+)", haxe)
    assert native and marker and int(native.group(1), 16) == int(marker.group(1), 16), name
print("profiler span IDs match")
