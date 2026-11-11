#!/usr/bin/env python3
"""Reads the allocation census a build wrote (HAXEON_COMPILER_ALLOC_CENSUS=<file>) and prints where it allocates.

usage: alloc-sites.py <census.json> [top]

Frames are the runtime's resolved names, innermost first. A "site" is the innermost frame that belongs to the compiler (a name starting
with a prefix in SITE_PREFIXES); the runtime and standard-library frames above it are the allocator and the container that did the work.
Each stack is a sample taken once per `every` allocated bytes, so a site's bytes are samples x every, and its share is its bytes over the total.
The per-type counts are exact.
"""
import collections, json, re, sys

SITE_PREFIXES = ("compiler.", "haxeon.", "app.")
PHASES = [  # outermost frame -> phase, first match wins when read from the outermost frame inward
    ("SemanticAssembly", "semantic"), ("ProgramTyper", "typing"), ("BodyTyper", "typing"), ("Typer.", "typing"),
    ("IrGenerator", "ir-generation"), ("IrInliner", "ir-passes"), ("IrProgramAssembler", "ir-assembly"),
    ("IrVerifier", "ir-verify"), ("HlLower", "lowering"), ("HlModuleAssembler", "hl-assembly"),
    ("BackendAssembly", "backend"), ("HlWriter", "encode"), ("FrontendCompilation", "frontend-other"),
]

def short(name):
    return re.sub(r"^compiler\.", "", name)

def phase_of(frames):
    for frame in reversed(frames):  # outermost first
        for key, phase in PHASES:
            if key in frame:
                return phase
    return "other"

def site_of(frames):
    for frame in frames:
        if frame.startswith(SITE_PREFIXES):
            return frame
    return frames[0] if frames else "?"

def main():
    data = json.load(open(sys.argv[1]))
    top = int(sys.argv[2]) if len(sys.argv) > 2 else 15
    every = data["every"]
    total_bytes = sum(t["bytes"] for t in data["types"])
    total_count = sum(t["count"] for t in data["types"])
    print(f"total: {total_count:,} allocations, {total_bytes / 2**30:.2f} GiB; stack sample every {every:,} bytes; {len(data['stacks'])} distinct stacks")
    sites = collections.defaultdict(lambda: [0, 0, collections.Counter()])  # samples, bytes, phases
    for stack in data["stacks"]:
        site = site_of(stack["frames"])
        entry = sites[site]
        entry[0] += stack["samples"]
        entry[1] += stack["bytes"]
        entry[2][phase_of(stack["frames"])] += stack["bytes"]
    sampled = sum(e[1] for e in sites.values()) or 1
    print("\n== top sites by sampled bytes (share of the sampled bytes) ==")
    for site, (samples, bytes_, phases) in sorted(sites.items(), key=lambda kv: -kv[1][1])[:top]:
        print(f"{100 * bytes_ / sampled:5.1f}%  {bytes_ / 2**20:9.1f} MiB  {samples:7d} samples  {phases.most_common(1)[0][0]:<14} {short(site)}")
    print("\n== top sites by samples (stack samples are taken by bytes; this is the same ranking by hits) ==")
    for site, (samples, bytes_, phases) in sorted(sites.items(), key=lambda kv: -kv[1][0])[:top]:
        print(f"{samples:7d}  {phases.most_common(1)[0][0]:<14} {short(site)}")
    print("\n== exact counts by type ==")
    for kind in sorted(data["types"], key=lambda t: -t["count"])[:top]:
        print(f"{100 * kind['count'] / total_count:5.1f}%  {kind['count']:>13,}  {kind['bytes'] / 2**20:9.1f} MiB  {kind['type']}")
    print("\n== exact bytes by type ==")
    for kind in sorted(data["types"], key=lambda t: -t["bytes"])[:top]:
        print(f"{100 * kind['bytes'] / total_bytes:5.1f}%  {kind['bytes'] / 2**20:9.1f} MiB  {kind['count']:>13,}  {kind['type']}")
    by_phase = collections.Counter()
    for stack in data["stacks"]:
        by_phase[phase_of(stack["frames"])] += stack["bytes"]
    print("\n== sampled bytes by phase ==")
    for phase, bytes_ in by_phase.most_common():
        print(f"{100 * bytes_ / sampled:5.1f}%  {phase}")

main()
