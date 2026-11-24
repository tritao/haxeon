# Get started

This page installs what you need to build apps with Haxeon: a C and C++ toolchain with CMake, then Haxeon itself from a
release archive. No checkout of Haxeon's sources is needed. Then [Your first app](01-first-app.md) makes an app with it.

## Install a C and C++ toolchain and CMake

An app uses Haxeon's UI package, which is partly written in C and C++. Haxeon builds that code on your machine, once,
with your C and C++ compiler and CMake 3.24 or later, and keeps the result in a cache every project shares. A
command-line program needs none of this, but the toolchain is quick to install, so install it first.

On Debian, Ubuntu and their derivatives, which also installs the development files of GTK, OpenGL and Fontconfig that an
app's window needs:

```sh
sudo apt-get install build-essential cmake ninja-build pkg-config libgtk-3-dev libgl1-mesa-dev libfontconfig1-dev
```

On Fedora and RHEL:

```sh
sudo dnf install gcc gcc-c++ make cmake ninja-build pkgconf-pkg-config gtk3-devel mesa-libGL-devel fontconfig-devel
```

Some older releases (Ubuntu 22.04, for one) ship a CMake older than 3.24: install a newer one from
<https://cmake.org/download/>.

On macOS, the Xcode command line tools and, with [Homebrew](https://brew.sh), CMake and Ninja:

```sh
xcode-select --install
brew install cmake ninja
```

On Windows, Visual Studio's Build Tools with the C++ tools, and CMake:

```powershell
winget install Microsoft.VisualStudio.2022.BuildTools --override "--passive --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
winget install Kitware.CMake
```

A full Visual Studio with the "Desktop development with C++" workload serves as well. Haxeon finds it by itself: there
is no need to start a developer prompt.

## Install Haxeon

Download the release archive for your system from the [releases page](https://github.com/tritao/haxeon/releases):
`haxeon-VERSION-linux-x86_64.tar.gz`, `haxeon-VERSION-macos-arm64.tar.gz` or `haxeon-VERSION-windows-x86_64.zip`. An
archive holds one directory, which is all of Haxeon: the compiler, the runtime, the standard library and the first-party
packages ([Releases](../reference/RELEASES.md) lists what is in it). Unpack it anywhere and put its `bin` directory on
your `PATH`. On Linux and macOS:

```sh
tar -xzf haxeon-VERSION-linux-x86_64.tar.gz
export PATH="$PWD/haxeon-VERSION-linux-x86_64/bin:$PATH"
```

Add the `export` line, with the full path, to your shell's startup file (`~/.bashrc`, `~/.zshrc`) to keep it. On
Windows, in PowerShell:

```powershell
Expand-Archive haxeon-VERSION-windows-x86_64.zip -DestinationPath .
$env:Path = "$PWD\haxeon-VERSION-windows-x86_64\bin;$env:Path"
```

and add the `bin` directory to your user's `Path` in the system settings to keep it.

The directory can go anywhere, but keep it whole: `bin/haxeon` finds everything else from where it is. Haxeon never
writes into it; what it builds for all your projects goes under `~/.haxeon/cache`.

## Check the installation

```sh
haxeon --version
haxeon doctor
```

`haxeon doctor` checks that the release is complete, then looks for the toolchain the way a build does, with one line
for each part. On Linux, with everything installed, that part of its report reads:

```text
ok: C compiler (cc)
ok: C++ compiler (c++)
ok: CMake 3.28.3
ok: build tool (ninja)
ok: pkg-config
ok: GTK 3 development files (pkg-config gtk+-3.0)
ok: OpenGL development files (pkg-config gl)
ok: Fontconfig development files (pkg-config fontconfig)
```

A `missing:` line names what it did not find, and the end of the report prints the command above that installs it on
your system. [The doctor reference](../reference/cli/project.md#doctor) says what each check looks at.

## Debug in VS Code

Install the Haxeon extension and open a folder containing `haxeon.toml`. Set a breakpoint in a `.hx` file
and press **F5**. If prompted, choose **Haxeon**. The extension builds and starts the host development target
with its bundled debugger so you can step through the code and inspect the call stack and variables.

The debugger supports x64 Linux, Windows, and Intel macOS. If VS Code cannot find the CLI on its `PATH`,
set `haxeon.server.path` to the Haxeon executable. To attach to a local application instead, start it with
`haxeon run --debug-port 6112` and add a **Haxeon: Attach** configuration with the same port. Attaching to
an already running process requires the OS's native debugging permissions.

## Next

[Your first app](01-first-app.md) creates an app, runs it, changes it while it runs, and builds it for shipping.
