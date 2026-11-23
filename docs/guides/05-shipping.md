# Shipping

This guide turns an app into something you can give to someone else: a desktop executable built ahead of time, an
Android package, and a WebAssembly module. The desktop (Linux, macOS, Windows) is the complete path today; the others are
described as far as they go, with what is not ready yet said plainly.

The example is the app [Your first app](01-first-app.md) ends with, in
[examples/05-shipping/my_app](examples/05-shipping/my_app/), without its runners (`linux/`, `macos/`, `windows/`), which
`haxeon create .` adds. The commands below are Linux's; each desktop section says what differs on macOS and Windows.

## What each platform has today

| Platform | What you can ship |
| --- | --- |
| Linux | An executable compiled ahead of time, with its libraries in one directory. |
| macOS | An app bundle (`my_app.app`) compiled ahead of time, with its libraries inside it. Not signed or notarized yet. |
| Windows | An `.exe` compiled ahead of time, with its DLLs in one directory. No installer yet. |
| Android | A debug APK, built from a Haxeon checkout. |
| Web | A `.wasm` module of a program that has no native packages. Apps that use `ui` cannot be built for the web yet. |

## The app's identity

An app is a project with an `[app]` section. Its name, identifier and version are the app's, not the package's, and every
platform's build reads them from here:

```toml
[app]
name = "My App"
id = "com.example.my_app"
version = "1.0.0"
platforms = ["linux", "macos", "windows"]
```

`id` is a reverse-domain name (`--org` of `haxeon create` gives its prefix); it is also the macOS bundle's identifier.
`platforms` lists the platforms the app has a runner for. [MANIFEST.md](../reference/MANIFEST.md) lists the section's fields.

## Desktop: a development build and a release build

A plain `haxeon build` makes a development build: the app's runner (`linux/` on Linux, a CMake project) links the HashLink VM
into an executable, and the compiled program sits beside it as `my_app.hl`, which the VM compiles to machine code as it
loads it. That is what `haxeon run --watch` patches while the app runs.

To ship, build in release mode:

```sh
haxeon build --build-mode=release
```

A release build compiles the program ahead of time. The compiler writes the program as C (`build/host/main.c/`), and
the runner compiles that C with your C toolchain into the executable, with the VM's runtime linked in and no compiler at
run time. Nothing loads a module, so there is no `my_app.hl` beside it. The result is in `build/linux/app/`:

```text
build/linux/app/
  my_app                      the app
  libnativekit.so ...         the native libraries of the packages the app uses, with their symbolic links
  libnativekit_gpu.so ...
  libnativekit_ui.so ...
```

Run it there to check it:

```sh
build/linux/app/my_app
```

or through `haxeon`, which builds first:

```sh
haxeon run --build-mode=release
```

A release build cannot be watched or patched live; `haxeon run --build-mode=release --watch` says so and stops. Go back
to `haxeon run --watch` for development.

On macOS the release build is the bundle `build/macos/app/my_app.app`: the executable in `Contents/MacOS`, the
libraries in `Contents/Frameworks`, and the `Info.plist` made from `[app]`. On Windows `build/windows/app/` holds
`my_app.exe` and the libraries' DLLs; it is built with Visual Studio's C++ compiler (MSVC), and it is a Windows program,
which opens no console window when started from Explorer but prints to the terminal that starts it.

## What to distribute on Linux

Distribute the whole `build/linux/app/` directory. The executable finds its libraries in its own directory, wherever
that is, so the directory can be unpacked anywhere. Keep the symbolic links between the library files, as `tar` does:

```sh
tar -czf my_app-linux-x86_64.tar.gz -C build/linux app
```

On the other machine:

```sh
tar -xzf my_app-linux-x86_64.tar.gz
./app/my_app
```

The executable itself needs only the system's C library. The UI package's libraries use the desktop's own GTK 3, OpenGL
and Fontconfig, which desktop Linux distributions install. The machine that builds the app needs their development
files as well, which `haxeon doctor` checks ([Get started](00-get-started.md) installs them). Build on the
oldest distribution you want to support: a program built against a newer C library than the one on the machine does
not start there.

The executable, the libraries and their versions are your app's: there is no Haxeon installation to ship.

## What to distribute on macOS and Windows

On macOS, distribute `my_app.app`, for example zipped with `ditto -c -k --keepParent build/macos/app/my_app.app
my_app.zip`. The build signs it only as the linker does, so on another Mac it opens after the user allows it in System
Settings; signing it with your Developer ID and notarizing it is not done for you yet. On Windows, distribute the whole
`build/windows/app/` directory: the executable finds its DLLs beside it. The machine that runs it needs the Microsoft
Visual C++ runtime, which most Windows machines have; an installer is not made for you yet.

## The runner is yours

`linux/CMakeLists.txt` (and `macos/`, `windows/` beside it) is an ordinary CMake project that `haxeon create` wrote and
that you commit. `haxeon build`
generates a fragment (`build/generated/linux/haxeon.cmake`) that names the program and the native packages, then builds
the runner. Once a build has written the fragment, CMake alone builds the same app, which is what an IDE or a packaging
script can use:

```sh
cmake -S linux -B build/linux-cmake -DCMAKE_BUILD_TYPE=Release
cmake --build build/linux-cmake
```

The runner is where packaging that is particular to your app belongs, such as install rules or a desktop entry. The
macOS runner has the bundle's `Info.plist.in`, and the Windows runner the version resource (`app.rc.in`, where an icon
goes) and the manifest (`app.manifest`). The runners use no icon yet: the `icon` of `[app]` is not read by them. A
Windows app is a Windows program; one that wants a console window of its own, such as a server with a log, sets
`WIN32_EXECUTABLE` off in `windows/CMakeLists.txt`, as the comment there shows.

## Android

An Android build compiles the app and its packages' native libraries, and packages them with Haxeon's Android host, for
`arm64-v8a` and `x86_64`, into a debug APK:

```sh
haxeon build --target android
haxeon run --target android
```

The APK is `build/android/app-debug.apk`; `run` installs it on a connected device or emulator and starts it, and
`haxeon devices` lists them. What this needs and what it does not do yet:

- It runs from a Haxeon checkout, with the Android SDK and NDK under the checkout's `.tools/android-sdk`; `haxeon doctor`
  reports whether they are there. A release archive does not build for Android yet.
- The Android project is the checkout's (`android/`), not one of your app's, so the manifest and resources are not
  yours to change. The package name and launcher label come from the `[android]` section (`applicationId`, `label`).
- It makes debug APKs only. A signed release APK or an App Bundle for a store is not available yet.

[ANDROID.md](../reference/ANDROID.md) has the details, including live editing on a device.

## The web

`haxeon build --target wasm32` compiles a program to a WebAssembly module, `build/wasm32/main.wasm`. `haxeon run` does
not run it, and the page that loads it is yours to write, with the host script the SDK ships
(`stdlib/haxeon/wasm/haxeon-host.js`).

An app that uses `ui`, or any package with C or C++ code, cannot be built for the web by `haxeon` yet: the build stops
with `Package nativekit cannot be built for wasm32`, because Haxeon does not yet compile a package's native code with
Emscripten. A web runner, with the app's own page, is planned.

## Checklist

1. Set `name`, `id` and `version` in `[app]`.
2. `haxeon build --build-mode=release`.
3. Run `build/linux/app/my_app` once from a copy of the directory somewhere else.
4. Archive `build/linux/app/` with `tar`.

## Next

- [CLI.md](../reference/CLI.md): every `haxeon build` option.
- [RELEASES.md](../reference/RELEASES.md): what a Haxeon release archive holds, and what it needs on the machine that
  builds your app.
