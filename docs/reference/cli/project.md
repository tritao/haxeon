# Project

## create

`haxeon create DIRECTORY` makes a project from a template in the installation's `templates/`: `--template app` (the default) is a window with a counter and an
`[app]` section ([MANIFEST.md](../MANIFEST.md)) that uses the UI package from the `haxeon` registry (`ui = "^0.3"`, with
`compatibility.haxeon`). Use `--template console` (or `-t console`) for a console program without an `[app]` section.
`--platforms` lists an app's
platforms (by default every platform the template has a runner for: android, linux, macos, web and windows) and `--org` the prefix of its identifier (`com.example`). `haxeon create .` adds the
template's files a project lacks and never overwrites one. Use `create . -t console` for a console program in the current directory.

```sh
haxeon create my_app
haxeon create my_tool --template console
haxeon create .
haxeon create mobile_app --platforms android
```

## migrate

`haxeon migrate` rewrites a project's `haxeon.json` as `haxeon.toml`. It checks that the TOML reads back to the same settings, then
removes the JSON file. `haxeon migrate --dry-run` prints the TOML instead and changes nothing; `--project PATH` names
another project.

```sh
haxeon migrate --dry-run
haxeon migrate
```

## clean

`haxeon clean` removes what builds wrote for the project: its `outputDir` (and `outputDir-instrument`, the instrumented
build's) and its tests project's. What projects share stays: the compiler workers, the native CMake cache, the artifact
cache and the package source cache. An `outputDir` that would hold the project itself is refused, never removed.

## doctor

The `doctor` command checks Haxeon's own installation (the compiler, the HashLink runtime), the C and C++ toolchain
that an app, a package with C or C++ code and a build ahead of time need, and the Android SDK tools. It
prints one `ok:` or `missing:` line for each. The toolchain is looked up as the builds find it: on Linux and macOS the
C and C++ compilers (`CC` and `CXX`, else `cc` and `c++`, `gcc` and `g++` or `clang` and `clang++`), on macOS the Xcode
command line tools first, on Windows MSVC through `vswhere` (Visual Studio or its Build Tools with the C++ tools); then
CMake 3.24 or later, Ninja or Make (not on Windows), and on Linux `pkg-config` with the development files of GTK 3,
OpenGL and Fontconfig, which the UI package's window needs. When a tool is missing it prints the command that installs
the toolchain on this system (`apt-get` on Debian and Ubuntu, `dnf` on Fedora, `xcode-select --install` and Homebrew on
macOS, `winget` on Windows). It exits with 1 only when Haxeon's own installation is incomplete: a program builds without
the toolchain.

## platforms

`haxeon platforms` lists the targets with the backend each builds. See [Targets and backends](build-run.md#targets-and-backends).

## devices

`haxeon devices` reports connected Android devices.
