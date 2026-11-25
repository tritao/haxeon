#!/usr/bin/env python3
"""Replays the compiler's own recent history as edits in one compile server session, with the reuse checks.

    tests/integration/test-edit-replay.py [EDITS]     the last EDITS commits that change src/compiler (default 4)

The byte-identical self-compile never builds warm, and the warm-edit tests build small programs with scripted edits. This takes
real edits: a copy of the compiler's sources (src, lib/haxeon-io, stdlib) as they were before the oldest of those commits, built
cold in a compile server, then each commit's sources in turn, rebuilt warm in the same session with `--check-reuse`, which
assembles every reused result again and fails the build on a difference. Each warm build must also write the module and the
function table a fresh one-shot compile of the same tree writes, byte for byte. A commit whose sources do not build must fail
both ways. The compile server and its protocol are scripts/perf-guard.py's; the builds use its arguments (release mode).
"""
import importlib.util
import os
import shutil
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("perf_guard", os.path.join(ROOT, "scripts", "perf-guard.py"))
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)

EDITED = "src/compiler"
OUTPUTS = ["", ".functions"]


def git(*arguments, **kwargs):
    return subprocess.run(["git", "-C", ROOT] + list(arguments), check=True, stdout=subprocess.PIPE, **kwargs).stdout


def commits(count):
    """The last `count` commits that change EDITED, oldest first, and the commit before the oldest; a shallow clone is deepened."""
    for attempt in range(2):
        found = git("log", "--first-parent", "--format=%H", f"-n{count}", "HEAD", "--", EDITED, text=True).split()
        if len(found) == count and subprocess.run(["git", "-C", ROOT, "rev-parse", "-q", "--verify", found[-1] + "^"],
                                                  stdout=subprocess.DEVNULL).returncode == 0:
            return list(reversed(found)), git("rev-parse", found[-1] + "^", text=True).strip()
        if attempt == 0 and git("rev-parse", "--is-shallow-repository", text=True).strip() == "true":
            # Not the submodules: the older commits name pins their shallow clones cannot fetch.
            git("fetch", "--quiet", "--no-recurse-submodules", "--deepen=500", "origin")
    raise SystemExit(f"edit-replay: the history has fewer than {count} commits that change {EDITED}")


def extract(revision, tree, paths):
    """Writes `paths` (all of the source roots when None) as they are at `revision` into `tree`."""
    archive = git("archive", revision, "--", *(guard.SOURCE_ROOTS if paths is None else paths))
    subprocess.run(["tar", "-x", "-C", tree], input=archive, check=True)


def advance(tree, previous, revision):
    """Moves `tree` from `previous`'s sources to `revision`'s, touching only the files that differ; returns how many."""
    changed = git("diff", "--name-only", "--no-renames", previous, revision, "--", *guard.SOURCE_ROOTS, text=True).split()
    kept = git("ls-tree", "-r", "--name-only", revision, "--", *changed, text=True).split() if changed else []
    for path in set(changed) - set(kept):
        os.remove(os.path.join(tree, path))
    if kept:
        extract(revision, tree, kept)
    guard.list_sources(tree, os.path.join(tree, "sources.txt"))
    return len(changed)


def main(arguments):
    count = int(arguments[0]) if arguments else 4
    hl = guard.hashlink()

    def tool(variable, main):
        return os.environ.get(variable) or guard.run([os.path.join(ROOT, "scripts", "haxeon"), "dev", "tool-path", main]).strip()

    server, compiler = tool("HAXEON_COMPILER_SERVER_HL", guard.SERVER_ENTRY), tool("HAXEON_COMPILER_HL", guard.ENTRY)
    out = os.path.join(os.environ.get("HAXEON_SUITE_OUT") or os.path.join(ROOT, "out"), "edit-replay")
    tree = os.path.join(out, "tree")
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(tree)
    edits, base = commits(count)
    extract(base, tree, None)
    guard.list_sources(tree, os.path.join(tree, "sources.txt"))

    session = guard.CompileServer([hl, server], tree, os.path.join(out, "server.log"), reports=False)
    failures, previous = [], base
    try:
        for step, revision in enumerate([base] + edits):
            label = git("log", "-1", "--format=%h %s", revision, text=True).strip()
            changed = advance(tree, previous, revision) if step else 0
            previous = revision
            started = time.monotonic()
            # The fresh build runs beside the warm one: they share nothing but the sources, which neither writes.
            with open(os.path.join(out, f"cold-{step}.log"), "w") as log:
                cold = subprocess.Popen(guard.compile_command(hl, compiler, "sources.txt", "cold.hl"), cwd=tree, stdout=log,
                                        stderr=subprocess.STDOUT)
            responses = session.request({"arguments": guard.compile_arguments("sources.txt", "warm.hl") + ["--check-reuse"]})
            cold_status = cold.wait()
            messages = [response["message"] for response in responses if "message" in response]
            with open(os.path.join(out, f"warm-{step}.log"), "w") as log:
                log.write("\n".join(messages) + "\n")
            warm_status = next((response["status"] for response in responses if "status" in response), None)
            what = "cold" if step == 0 else f"edit {step}/{len(edits)} ({changed} files)"
            print(f"edit-replay: {what}, {time.monotonic() - started:5.1f} s: {label}", flush=True)
            if warm_status != 0 and cold_status != 0:
                print("edit-replay:   these sources do not build, warm or fresh")
                continue
            if warm_status != 0 or cold_status != 0:
                failing = "warm" if warm_status != 0 else "cold"
                failures.append(f"{label}: only the {failing} build failed; log: {os.path.join(out, f'{failing}-{step}.log')}")
                sys.stderr.write("\n".join(messages[-20:]) + "\n")
                continue
            for suffix in OUTPUTS:
                with open(os.path.join(tree, "warm.hl" + suffix), "rb") as warm, open(os.path.join(tree, "cold.hl" + suffix),
                                                                                       "rb") as fresh:
                    if warm.read() != fresh.read():
                        failures.append(f"{label}: the warm build's warm.hl{suffix} differs from a fresh build's")
    finally:
        session.stop()
    for failure in failures:
        print("FAIL: " + failure, file=sys.stderr)
    if failures:
        return 1
    print(f"PASS: {len(edits)} edits from the compiler's history rebuilt warm with the reuse checks, each as a fresh build")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
