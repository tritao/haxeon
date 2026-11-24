#!/usr/bin/env python3
"""Generate Haxe modules for the shaders discovered by a project build."""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time


def load_tool(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def publish(path, data):
    if path.is_file() and path.read_bytes() == data:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        stream.write(data)
    try:
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def report(path, line, column, message, style, project, warning=False):
    path = (project / Path(path)).resolve()
    if path.is_relative_to(project):
        display = path.relative_to(project)
    else:
        display = path
    code = "W4001" if warning else "E4001"
    severity = "warning" if warning else "error"
    label = code if style == "short" else f"{severity}[{code}]"
    print(f"{display.as_posix()}:{line}:{column}: {label}: {message}", file=sys.stderr)
    if style == "full" and path.is_file():
        lines = path.read_text(encoding="utf-8").splitlines()
        if 1 <= line <= len(lines):
            print(f" {line} | {lines[line - 1]}", file=sys.stderr)
            print(f" {' ' * len(str(line))} | {' ' * (column - 1)}^", file=sys.stderr)


def shader_run(command, check, style, project):
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            encoding="utf-8", errors="replace")
    seen = set()
    for row in result.stdout.splitlines():
        error = re.match(r"^(.+):(\d+):(\d+): (error|warning): (.*)$", row)
        if not error:
            if row:
                print(row, file=sys.stderr)
            continue
        path, line, column, severity, message = error.groups()
        if "non-opaque uniforms outside a block" in message:
            message = "Declare numeric uniforms inside a layout(std140, binding=N) uniform block"
        elif "'#version'" in message:
            message = "Remove #version; the shader tool sets the version for each target"
        key = (path, line, column, message)
        if key in seen:
            continue
        seen.add(key)
        report(path, max(1, int(line)), max(1, int(column)), message, style, project, severity == "warning")
    if check:
        result.check_returncode()
    return result


def discover(roots):
    modules = {}
    for root in roots:
        root = Path(root).resolve()
        for path in sorted(root.rglob("*.glsl")):
            source = path.read_text(encoding="utf-8")
            source = re.sub(r"/\*.*?\*/", "", source, flags=re.S)
            if not re.search(r"(?m)^\s*@program(?:\s|$)", source):
                continue
            relative = path.relative_to(root).with_suffix("")
            if not all(re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", part) for part in relative.parts):
                raise ValueError(f"{path}: shader paths must use Haxe identifiers")
            if not relative.name[0].isupper():
                raise ValueError(f"{path}: shader filenames must start with an uppercase letter")
            module = ".".join(("shaders", *relative.parts))
            if module in modules and modules[module] != path:
                raise ValueError(f"{path}: duplicate shader module {module} ({modules[module]})")
            modules[module] = path
    return modules


def signature(identity, dependencies):
    return [identity, [[str(path), digest(path)] for path in sorted(dependencies)]]


def previous_record(path):
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def compile_module(args, driver, generator, compiler, identity, name, path, variants):
    output = args.output.joinpath(*name.split(".")).with_suffix(".hx")
    record = args.output / ".shader-cache" / (name + ".json")
    old = previous_record(record)
    dependencies = [Path(item) for item in old.get("dependencies", [])]
    current = [*identity, str(path), variants]
    if path in dependencies and output.is_file() and all(item.is_file() for item in dependencies):
        if old.get("signature") == signature(current, dependencies) and old.get("output") == digest(output):
            return output, dependencies

    started = time.time_ns()
    before = {item: digest(item) for item in set(dependencies) | {path} if item.is_file()}
    with tempfile.TemporaryDirectory(prefix="project-shader-") as folder:
        work = Path(folder)
        slangs = [args.target]
        # Non-GL compiler output omits source vertex attribute names.
        if not args.target.startswith("glsl"):
            slangs.append("glsl410")
        reflection = work / "reflection.json"
        source = {"file": str(path)}
        if variants:
            source["variants"] = variants
        manifest = work / "shaders.json"
        manifest.write_text(json.dumps({"slangs": slangs, "embed_sources": True,
                                        "sources": [source], "reflection": reflection.name}), encoding="utf-8")
        driver.build(manifest, compiler, None, False,
                     run=lambda command, check: shader_run(command, check, args.diagnostics, args.project))
        data = json.loads(reflection.read_text(encoding="utf-8"))
        dependencies = {path}
        for program in data["programs"].values():
            for variant in program.values():
                dependencies.update((work / item).resolve() for item in variant["dependencies"])
                entry = variant["targets"][args.target]
                variant["targets"] = {args.target: entry}
        destination = name.split(".")
        hx = generator.generate(data, sorted(data["programs"]), destination[-1],
                                ".".join(destination[:-1]), None)
        fingerprint = signature(current, dependencies)
        after = {Path(file): sha for file, sha in fingerprint[1]}
        changed = any(before[item] != sha if item in before else
                      max(item.stat().st_mtime_ns, item.stat().st_ctime_ns) > started
                      for item, sha in after.items())
        if changed:
            raise ValueError("shader inputs changed during generation; run the build again")
        publish(output, hx)
        publish(record, json.dumps({"signature": fingerprint,
                                    "dependencies": sorted(map(str, dependencies)),
                                    "output": hashlib.sha256(hx).hexdigest()}).encode("utf-8"))
        return output, dependencies


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--driver", type=Path, required=True)
    parser.add_argument("--generator", type=Path, required=True)
    parser.add_argument("--project", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--diagnostics", choices=["short", "full"], required=True)
    parser.add_argument("--variants", type=json.loads, default={})
    parser.add_argument("roots", nargs="*")
    args = parser.parse_args()
    args.project = args.project.resolve()
    args.output = args.output.resolve()
    try:
        modules = discover(args.roots)
        missing = args.variants.keys() - modules.keys()
        if missing:
            raise ValueError("shaderVariants names an unknown module: " + ", ".join(sorted(missing)))
        output, inputs = [], set()
        if modules:
            try:
                driver = load_tool("shader_driver", args.driver)
            except ModuleNotFoundError as error:
                if error.name == "yaml":
                    raise ValueError("shader generation requires the PyYAML package for this Python interpreter") from error
                raise
            generator = load_tool("shader_generator", args.generator)
            compiler = driver.pinned_shdc(os.environ.get("SOKOL_SHDC"))
            identity = [args.target, digest(Path(compiler)), digest(Path(__file__)),
                        digest(args.driver), digest(args.generator)]
            for name, path in modules.items():
                try:
                    generated, dependencies = compile_module(args, driver, generator, compiler, identity,
                                                              name, path, args.variants.get(name))
                except (KeyError, ValueError, OSError) as error:
                    report(path, 1, 1, str(error), args.diagnostics, args.project)
                    return 1
                output.append(generated)
                inputs.update(dependencies)
        manifest = args.output / "shaders.sources"
        stale = set(manifest.read_text(encoding="utf-8").splitlines()) - set(map(str, output)) if manifest.is_file() else []
        for item in stale:
            path = Path(item)
            if path.is_relative_to(args.output / "shaders") and path.suffix == ".hx" and ".." not in path.parts:
                path.unlink(missing_ok=True)
        publish(manifest, "".join(f"{path}\n" for path in sorted(output)).encode("utf-8"))
        publish(args.output / "shaders.dependencies", "".join(f"{path}\n" for path in sorted(inputs)).encode("utf-8"))
    except subprocess.CalledProcessError:
        return 1
    except (ValueError, OSError) as error:
        print(f"shader generation failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.dont_write_bytecode = True
    sys.exit(main())
