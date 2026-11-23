# Shipping

This guide turns an app into something you can give to someone else: a desktop executable built ahead of time, an
Android package, and a WebAssembly module. Desktop on Linux is the complete path today; the others are described as far
as they go, with what is not ready yet said plainly.

The example is the app `haxeon create` makes, in [examples/05-shipping](examples/05-shipping/). Every step below was run
on Linux.

## What each platform has today

| Platform | What you can ship |
| --- | --- |
| Linux | An executable compiled ahead of time, with its libraries in one directory. |
| macOS, Windows | Programs build and run with `haxeon run`, but the app template has no runner for them yet, so there is no app executable to ship. The runners are being added. |
| Android | A debug APK, built from a Haxeon checkout. |
| Web | A `.wasm` module of a program that has no native packages. Apps that use `ui` cannot be built for the web yet. |

## The app's identity

An app is a project with an `[app]` section. Its name, identifier and version are the app's, not the package's, and every
platform's build reads them from here:

```toml
[app]
name = "Hello"
id = "org.example.hello"
version = "1.0.0"
platforms = ["linux"]
```

`id` is a reverse-domain name (`--org` of `haxeon create` gives its prefix). `platforms` lists the platforms the app has a
runner for. [MANIFEST.md](../reference/MANIFEST.md) lists the section's fields.

## Desktop: a development build and a release build

A plain `haxeon build` makes a development build: the app's runner (`linux/`, a CMake project) links the HashLink VM
into an executable, and the compiled program sits beside it as `hello.hl`, which the VM compiles to machine code as it
loads it. That is what `haxeon run --watch --live` patches while the app runs.

To ship, build in release mode:

```sh
haxeon build --build-mode=release
```

A release build compiles the program ahead of time. The compiler writes the program as C (`build/host/main.c/`), and
the runner compiles that C with your C toolchain into the executable, with the VM's runtime linked in and no compiler at
run time. Nothing loads a module, so there is no `hello.hl` beside it. The result is in `build/linux/app/`:

```text
build/linux/app/
  hello                       the app
  libnativekit.so ...         the native libraries of the packages the app uses, with their symbolic links
  libnativekit_gpu.so ...
  libnativekit_ui.so ...
```

Run it there to check it:

```sh
build/linux/app/hello
```

or through `haxeon`, which builds first:

```sh
haxeon run --build-mode=release
```

A release build cannot be watched or patched live; `haxeon run --build-mode=release --watch` says so and stops. Go back
to `haxeon run --watch --live` for development.

## What to distribute on Linux

Distribute the whole `build/linux/app/` directory. The executable finds its libraries in its own directory, wherever
that is, so the directory can be unpacked anywhere. Keep the symbolic links between the library files, as `tar` does:

```sh
tar -czf hello-linux-x86_64.tar.gz -C build/linux app
```

On the other machine:

```sh
tar -xzf hello-linux-x86_64.tar.gz
./app/hello
```

The executable itself needs only the system's C library. The UI package's libraries use the desktop's own GTK 3, OpenGL
and Fontconfig, which desktop Linux distributions install; on a minimal system, install those packages. Build on the
oldest distribution you want to support: a program built against a newer C library than the one on the machine does
not start there.

The executable, the libraries and their versions are your app's: there is no Haxeon installation to ship.

## The runner is yours

`linux/CMakeLists.txt` is an ordinary CMake project that `haxeon create` wrote and that you commit. `haxeon build`
generates a fragment (`build/generated/linux/haxeon.cmake`) that names the program and the native packages, then builds
the runner. Once a build has written the fragment, CMake alone builds the same app, which is what an IDE or a packaging
script can use:

```sh
cmake -S linux -B build/linux-cmake -DCMAKE_BUILD_TYPE=Release
cmake --build build/linux-cmake
```

The runner is where packaging that is particular to your app belongs, such as install rules or a desktop entry. The
template has neither yet, and the `icon` of `[app]` is not used by the Linux runner yet.

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
3. Run `build/linux/app/hello` once from a copy of the directory somewhere else.
4. Archive `build/linux/app/` with `tar`.

## Next

- [CLI.md](../reference/CLI.md): every `haxeon build` option.
- [RELEASES.md](../reference/RELEASES.md): what a Haxeon release archive holds, and what it needs on the machine that
  builds your app.
