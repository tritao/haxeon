#!/usr/bin/env python3
"""Compile tracked example projects without writing into the checkout."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]


def projects():
    # Package examples are tracked projects; the Showcase has its own suite and no manifest.
    paths = subprocess.check_output(["git", "ls-files", "-z", "--", "packages/**/haxeon.json"], cwd=root)
    manifests = sorted(root / os.fsdecode(path) for path in paths.split(b"\0")
                       if path and "examples" in Path(os.fsdecode(path)).parts)
    if not manifests:
        raise RuntimeError("No example project manifests found")
    return manifests


def mirror(source, target, project_dirs):
    """Copy project manifests and Haxe sources; link everything else around their original paths."""
    target.mkdir(parents=True, exist_ok=True)
    is_project = source in project_dirs
    manifest = json.loads((source / "haxeon.json").read_text()) if is_project else None
    excluded = {"build", "out", manifest.get("outputDir", "build")} if manifest else set()
    for child in source.iterdir():
        if child.name in excluded:
            continue
        destination = target / child.name
        if child.is_dir() and any(project == child or child in project.parents for project in project_dirs):
            mirror(child, destination, project_dirs)
        elif is_project and child.is_file() and (child.name == "haxeon.json" or child.suffix == ".hx"):
            shutil.copyfile(child, destination)
        else:
            destination.symlink_to(child, target_is_directory=child.is_dir())


def main():
    manifests = projects()
    with tempfile.TemporaryDirectory(prefix="haxeon-example-builds-") as tmp:
        work = Path(tmp)
        tree = work / "tree"
        tree.mkdir()
        mirror(root / "packages", tree / "packages", {path.parent for path in manifests})
        (tree / "vendor").symlink_to(root / "vendor", target_is_directory=True)
        env = os.environ.copy()
        env["HAXEON_COMPILER_SOURCE"] = str(root / "src")
        env["XDG_CACHE_HOME"] = str(work / "cache")
        env["HAXEON_SOURCE_CACHE"] = str(work / "source-cache")
        env["HAXEON_ARTIFACT_CACHE"] = str(work / "artifact-cache")
        env["HAXEON_NATIVE_CACHE"] = "off"
        env["TMPDIR"] = str(work / "tmp")
        (work / "tmp").mkdir()
        for index, source in enumerate(manifests):
            project = tree / source.parent.relative_to(root)
            manifest = json.loads(source.read_text())
            declared = manifest.get("target", "host")
            targets = ["host"] if declared == "host" else ["host", declared]
            for target in targets:
                output = work / f"example-{index}-{target}.module"
                command = [str(root / "scripts/haxeon"), "build", "--compiler-only",
                           "--project", str(project / "haxeon.json"), "--target", target,
                           "--output", str(output)]
                result = subprocess.run(command, cwd=root, env=env, text=True,
                                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                if result.returncode:
                    print(result.stdout, end="", file=sys.stderr)
                    raise RuntimeError(f"{project.relative_to(tree)} target {target}: exit {result.returncode}")
                if not output.is_file() or not output.stat().st_size:
                    raise RuntimeError(f"{project.relative_to(tree)} target {target}: empty output")
                print(f"PASS: {project.relative_to(tree)} compiles for {target}", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"example builds: {error}", file=sys.stderr)
        sys.exit(1)
