#!/usr/bin/env python3
"""Cross-language benchmark runner: Haxeon vs stock Haxe/HashLink, .NET, Dart.

Sources live in <problem>/<variant>.{hx,cs,dart}; expected outputs in
<problem>/<input>_out. Problems and variants are adapted from
hanabi1224/Programming-Language-Benchmarks (see NOTICE.md).

  ./benchmarks/cross-lang/run.py                      # all problems, all available langs
  ./benchmarks/cross-lang/run.py --langs haxeon,csharp --problems nbody --runs 10
  ./benchmarks/cross-lang/run.py --test-only          # build + verify outputs only

Languages whose toolchain is missing are skipped, not failed.
Times are whole-process wall clock (startup included) plus peak RSS.
"""
import argparse, json, os, shutil, statistics, subprocess, sys, tempfile, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
TOOLS = ROOT / ".tools"
HL = TOOLS / "hashlink" / "hl"
HAXE = TOOLS / "haxe" / "haxe"
DOTNET = TOOLS / "dotnet" / "dotnet"
DART = TOOLS / "dart-sdk" / "bin" / "dart"


def find(local, name):
    return str(local) if local.exists() else shutil.which(name)


def tool_env():
    return dict(os.environ, DOTNET_CLI_TELEMETRY_OPTOUT="1", DOTNET_NOLOGO="1",
                DOTNET_ROOT=str(TOOLS / "dotnet"), NUGET_PACKAGES=str(TOOLS / "nuget"),
                HOME=os.environ.get("HOME", ""))

# variant file per language, unit-test inputs (with expected-output file) and bench inputs.
PROBLEMS = {
    "binarytrees": dict(haxe="1.hx", csharp="1.cs", dart="1.dart",
                        tests=[("10", "10_out")], bench=["18", "20"]),
    "nbody": dict(haxe="1.hx", csharp="2.cs", dart="3.dart",
                  tests=[("1000", "1000_out")], bench=["5000000", "20000000"]),
    "spectral-norm": dict(haxe="1.hx", csharp="3.cs", dart="1.dart",
                          tests=[("100", "100_out")], bench=["2000", "4000"]),
    "fasta": dict(haxe="1.hx", csharp="5.cs", dart="1.dart",
                  tests=[("1000", "1000_out")], bench=["2500000", "10000000"]),
    "merkletrees": dict(haxe="1.hx", csharp="1.cs", dart="1.dart",
                        tests=[("10", "10_out")], bench=["16", "18"]),
    "lru": dict(haxe="1.hx", csharp="2.cs", dart="1.dart",
                tests=[("10 1000", "10_1000_out")], bench=["100 1000000", "1000 3000000"]),
}
LANGS = ["haxeon", "haxe-hl", "csharp", "dart"]


class Skip(Exception):
    pass


def sh(cmd, cwd, env=None):
    r = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True)
    if r.returncode:
        raise RuntimeError((r.stdout + r.stderr).strip()[-600:])


def build(lang, problem, spec, work):
    src = HERE / problem / spec[{"haxeon": "haxe", "haxe-hl": "haxe"}.get(lang, lang)]
    work.mkdir(parents=True, exist_ok=True)
    if lang == "haxe-hl":
        if not HAXE.exists() or not HL.exists():
            raise Skip("run scripts/bootstrap-tools.sh")
        shutil.copy(src, work / "App.hx")
        env = dict(os.environ, HAXE_STD_PATH=str(TOOLS / "haxe" / "std"))
        sh([str(HAXE), "-m", "App", "--hl", "app.hl"], work, env)
        return [str(HL), str(work / "app.hl")], hl_env()
    if lang == "haxeon":
        if not HL.exists():
            raise Skip("run scripts/bootstrap-tools.sh")
        (work / "src").mkdir(exist_ok=True)
        shutil.copy(src, work / "src" / "App.hx")
        (work / "haxeon.json").write_text(json.dumps(dict(
            version=1, package=dict(name="bench"), entry="App", sources=["src/App.hx"],
            sourceRoots=["src"], target="host", defines=[], outputDir="build")))
        sh([str(ROOT / "scripts" / "haxeon"), "build"], work)
        return [str(HL), str(work / "build" / "host" / "main.hl")], hl_env(ROOT / "out")
    if lang == "csharp":
        dotnet = find(DOTNET, "dotnet")
        if not dotnet:
            raise Skip("dotnet not installed (.tools/dotnet)")
        (work / "app.csproj").write_text(
            '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType>'
            "<TargetFramework>net9.0</TargetFramework><Nullable>disable</Nullable>"
            "<ImplicitUsings>enable</ImplicitUsings><AllowUnsafeBlocks>true</AllowUnsafeBlocks>"
            "<InvariantGlobalization>true</InvariantGlobalization>"
            "<TieredPGO>true</TieredPGO></PropertyGroup></Project>")
        shutil.copy(src, work / "Program.cs")
        sh([dotnet, "publish", "-c", "Release", "-o", "pub", "-v", "q", "--nologo"], work, tool_env())
        return [dotnet, str(work / "pub" / "app.dll")], tool_env()
    if lang == "dart":
        dart = find(DART, "dart")
        if not dart:
            raise Skip("dart not installed (.tools/dart-sdk)")
        shutil.copy(src, work / "app.dart")
        sh([dart, "compile", "exe", "app.dart", "-o", "app"], work, tool_env())
        return [str(work / "app")], None
    raise ValueError(lang)


def hl_env(*extra):
    paths = [str(TOOLS / "hashlink"), *map(str, extra), os.environ.get("LD_LIBRARY_PATH", "")]
    return dict(os.environ, LD_LIBRARY_PATH=":".join(paths))


def run_once(cmd, args, env):
    t0 = time.perf_counter()
    # /usr/bin/time reports the child's own peak RSS; wait4's ru_maxrss would inherit ours.
    r = subprocess.run(["/usr/bin/time", "-f", "\n%M KB", *cmd, *args.split()], env=env,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    dt = time.perf_counter() - t0
    err = r.stderr.decode(errors="replace").rstrip()
    body, _, rss = err.rpartition("\n")
    if r.returncode:
        raise RuntimeError(f"exit status {r.returncode}: {err[-300:]}")
    return r.stdout.decode(errors="replace"), dt, int(rss.split()[0]) / 1024


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--langs", default=",".join(LANGS))
    ap.add_argument("--problems", default=",".join(PROBLEMS))
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--size", type=int, default=0, help="index into each problem's bench sizes")
    ap.add_argument("--test-only", action="store_true")
    ap.add_argument("--json", default=str(ROOT / "out" / "cross-lang.json"))
    a = ap.parse_args()

    results, tmp = [], Path(tempfile.mkdtemp(prefix="xlang-"))
    print(f"{'problem':14}{'lang':9}{'status':9}{'median s':>10}{'p95 s':>9}{'rss MiB':>9}")
    for problem in a.problems.split(","):
        spec = PROBLEMS[problem]
        for lang in a.langs.split(","):
            row = dict(problem=problem, lang=lang, source=spec[{"haxeon": "haxe", "haxe-hl": "haxe"}.get(lang, lang)])
            try:
                cmd, env = build(lang, problem, spec, tmp / f"{problem}-{lang}")
            except Skip as e:
                row.update(status="skip", detail=str(e))
            except RuntimeError as e:
                row.update(status="build-fail", detail=str(e))
            else:
                try:
                    for args, exp in spec["tests"]:
                        got, _, _ = run_once(cmd, args, env)
                        want = (HERE / problem / exp).read_text()
                        if got.strip() != want.strip():
                            raise RuntimeError(f"output mismatch for input '{args}'")
                    row["status"] = "ok"
                    if not a.test_only:
                        args = spec["bench"][a.size]
                        run_once(cmd, args, env)  # warmup, discarded
                        samples = [run_once(cmd, args, env) for _ in range(a.runs)]
                        ts = sorted(s[1] for s in samples)
                        row.update(input=args, times=ts, median=statistics.median(ts),
                                   p95=ts[min(len(ts) - 1, int(0.95 * len(ts)))],
                                   rss_mib=max(s[2] for s in samples))
                except RuntimeError as e:
                    row.update(status="fail", detail=str(e))
            results.append(row)
            print(f"{problem:14}{lang:9}{row['status']:9}"
                  + (f"{row['median']:10.3f}{row['p95']:9.3f}{row['rss_mib']:9.0f}" if "median" in row else
                     f"  {row.get('detail', '')[:60].splitlines()[0] if row.get('detail') else ''}"))
    Path(a.json).parent.mkdir(parents=True, exist_ok=True)
    Path(a.json).write_text(json.dumps(dict(runs=a.runs, results=results), indent=2))
    shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
