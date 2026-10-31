#!/usr/bin/env python3
"""Summarize opt-in UI render probes and the GPU-enabled editor frame timeline."""

import argparse
from collections import defaultdict
import json
from pathlib import Path
import statistics

from ui_cost_report import frame_index, read_frames


def read_records(log):
    records = defaultdict(list)
    integers = {"id", "nodes", "primitives", "passes", "commands", "reused", "success"}
    for line in log.read_text().splitlines():
        if not line.startswith("render-cost "):
            continue
        _, stage, *fields = line.split()
        row = {}
        for field in fields:
            key, value = field.split("=", 1)
            if key in row:
                raise ValueError(f"{log}: duplicate {stage} field {key}")
            row[key] = int(value) if key in integers else float(value)
        if row.get("success", 1) != 1:
            raise ValueError(f"{log}: failed {stage} render: {row}")
        records[stage].append(row)
    if not records["haxe"] or not records["frontend"] or not records["executor"]:
        raise ValueError(f"{log}: missing render diagnostics (enable HAXEON_UI_RENDER_COST=1 and --render-ui)")
    return records


def frame_costs(log):
    frames, starts, measured = read_frames(log)
    host_path = log.parent / "render-timeline.jsonl"
    host = [json.loads(line) for line in host_path.read_text().splitlines() if line.strip()]
    if len(host) != len(frames):
        raise ValueError(f"{host_path}: render and frame timelines differ in length")
    records = read_records(log)
    grouped = defaultdict(lambda: defaultdict(list))
    frontend_ids = {}
    for stage in ("submit", "haxe", "frontend"):
        for row in records[stage]:
            index = frame_index(log, starts, row["started"])
            grouped[index][stage].append(row)
            if stage == "frontend":
                if row["id"] in frontend_ids:
                    raise ValueError(f"{log}: repeated frontend frame ID {row['id']}")
                frontend_ids[row["id"]] = index
    for stage in ("executor", "worker"):
        for row in records[stage]:
            index = frontend_ids.get(row["id"])
            if index is None:
                raise ValueError(f"{log}: {stage} has no frontend frame: {row['id']}")
            grouped[index][stage].append(row)
    result = []
    for index in sorted(measured):
        frame, rendered = frames[index], host[index]
        if (rendered["frameStartedAtSeconds"] != starts[index] or rendered["action"] != frame["action"] or
                rendered["cycle"] != frame.get("cycle")):
            raise ValueError(f"{host_path}: frame {index} does not match the submit timeline")
        if not rendered["rendered"]:
            continue
        phases = grouped[index]
        if len(phases["haxe"]) != 1 or len(phases["frontend"]) != 1 or not phases["executor"]:
            raise ValueError(f"{log}: incomplete rendered frame {index}")
        haxe, native = phases["haxe"][0], phases["frontend"][0]
        # A surface producer can execute a nested plan: its elapsed time already belongs to the outer execution.
        executor = max(phases["executor"], key=lambda row: row["total"])
        build = sum(row["build"] for row in phases["submit"])
        layout = sum(row["layout"] for row in phases["submit"])
        worker = sum(row["total"] for row in phases["worker"])
        row = {
            "frame": index, "action": frame["action"], "nodes": haxe["nodes"],
            "build": build, "layout": layout, "render": haxe["total"],
            "other": rendered["activeFrameSeconds"] - build - layout - haxe["total"],
            "active_frame": rendered["activeFrameSeconds"], "wall_frame": rendered["frameSeconds"],
            "surface_wait": rendered["surfaceWaitSeconds"], "worker": worker,
            "callbacks": haxe["callbacks"], "display_encode": haxe["encode"],
            "paint_other": haxe["total"] - haxe["native"] - haxe["callbacks"] - haxe["encode"],
            "paint_walk": haxe["walk"], "renderable": haxe["renderable"],
            "native": native["total"], "ffi_probe": haxe["native"] - native["total"],
            "primitives": native["primitives"], "passes": executor["passes"],
            "commands": executor["commands"], "reused": native["reused"],
        }
        for key in ("acquire", "custom_plans", "reuse_check", "layout_plan", "resources", "atlas_upload", "seal", "enqueue"):
            row[key] = native[key]
        for key in ("schedule", "begin", "dependencies", "draw", "submit"):
            row["exec_" + key] = executor[key]
        for key in ("bind", "backend", "atlas_upload", "execute", "cleanup", "completion"):
            row["worker_" + key] = sum(record[key] for record in phases["worker"])
        result.append(row)
    if not result:
        raise ValueError(f"{log}: no rendered frames after warmup")
    return result


def report(log, rows):
    def median(key):
        return statistics.median(row[key] for row in rows) * 1000

    print(f"\n{log.parent.name}: {len(rows)} rendered frames; "
          f"nodes {min(row['nodes'] for row in rows)}–{max(row['nodes'] for row in rows)}; "
          f"median primitives={statistics.median(row['primitives'] for row in rows):g}, "
          f"passes={statistics.median(row['passes'] for row in rows):g}, "
          f"commands={statistics.median(row['commands'] for row in rows):g}; "
          f"plan reuses={sum(row['reused'] for row in rows)}")
    for title, keys in (
        ("Frame breakdown", ("build", "layout", "render", "other", "active_frame", "surface_wait", "wall_frame", "worker")),
        ("Render phases", ("callbacks", "display_encode", "paint_other", "acquire", "custom_plans", "reuse_check",
                           "layout_plan", "resources", "atlas_upload", "seal", "enqueue", "ffi_probe")),
        ("Executor phases", ("exec_schedule", "exec_begin", "exec_dependencies", "exec_draw", "exec_submit")),
        ("Worker phases", ("worker_bind", "worker_backend", "worker_atlas_upload",
                           "worker_execute", "worker_cleanup", "worker_completion")),
    ):
        print(title + " (independent per-frame medians, ms)")
        print("| " + " | ".join(keys) + " |")
        print("|" + "---:|" * len(keys))
        print("| " + " | ".join(f"{median(key):.3f}" for key in keys) + " |")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("logs", nargs="+", type=Path)
    parser.add_argument("--json", type=Path, help="also save every measured frame's phases")
    args = parser.parse_args()
    captures = {}
    for log in args.logs:
        rows = frame_costs(log)
        captures[str(log)] = rows
        report(log, rows)
    if args.json:
        args.json.write_text(json.dumps(captures, indent=2) + "\n")


if __name__ == "__main__":
    main()
