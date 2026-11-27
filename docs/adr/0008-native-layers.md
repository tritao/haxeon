# 8. The native layers: the VM in the repository, one host library, NativeKit for apps

Date: 2026-11-27

## Status

Proposed. Section 3 (`std.fs` on the runtime's own natives) is the first step; the VM moves into the repository once the
work in flight on its fork has landed. It refines [ADR 0004](0004-runtime-library-and-backends.md) section 3 ("C only below
the object model") by saying which native code owns which host service.

## Context

Three native libraries give a Haxeon program what it needs from the host, and nothing says which one owns what:

| Layer | Where | What it holds |
|---|---|---|
| HashLink | `vendor/hashlink`, a submodule of the fork `tritao/hashlink` | the VM (bytecode, JIT, debugger), the collector and object model, and Haxe's `hl.*` natives in `src/std` (files, processes, sockets, threads, regular expressions, maps, strings) |
| Haxeon's runtime | `native/runtime`, one translation unit linked into every native program | strings, bytes, maps, reflection, files, processes, sockets, threads, directory watching, the profiler, the FFI call machinery |
| NativeKit | `vendor/nativekit`, a C ABI over C++, reached through `packages/*` | windows, WebViews, dialogs, input, graphics surfaces, notifications, and modules for audio, GPU, credentials and a filesystem |

What that costs:

- **Two definitions of one service.** Files are the runtime's `__sys_*` natives, which call HashLink's `hl_sys_*`, and
  NativeKit's filesystem module. Directory watching is `native/watch` and NativeKit's `nativekit_file_watch.h`. The
  runtime calls HashLink's `src/std` from 135 places.
- **Failures lose their reason.** HashLink's file natives answer `Bool`, so a caller cannot tell a missing file from a
  denied one, and [ERROR_MODEL.md](../design/ERROR_MODEL.md) wants the reason as a value.
- **The fork is ours, but lives apart.** It is 476 commits and about 40,000 lines ahead of where it left upstream
  (2026-09-03), with its own incremental collector, census, arenas, profiler and AArch64 JIT; upstream was never merged
  back, and changes are not sent upstream. Yet each change to it is a second repository, a second commit and a pin bump:
  213 of them since 2026-10-01, with per-worktree submodule clones and a VM to rebuild after each pin moves.

## Decision

### 1. Four layers, each with one owner

| Layer | Holds | Used by |
|---|---|---|
| **Engine** | bytecode loading, the JIT, the debugger | the HashLink VM |
| **Core** | the collector, types, objects, exceptions | the VM, HL/C and the C AOT backend (`hl.h`) |
| **Host library** | everything `std` needs from the operating system: files and directories (confined ones too), watching, processes, sockets, threads, time | every native target |
| **NativeKit** | what needs an application host or a device: windows, input, graphics, audio, GPU, credentials, system dialogs | packages an app depends on |

The rule between the last two: **what `std` needs belongs to the host library.** A program does not link an application
platform to read a file, and the compiler, a server and a command-line tool need the same files as an app does. NativeKit
stays opt-in and usable from any language, and keeps what only an app has.

The Wasm targets have none of these layers: their runtime is Haxeon source and the host's imports (ADR 0004), and they
implement the same `std` contracts (the in-memory filesystem implements `std.fs`).

### 2. The host library is Haxeon's runtime, not HashLink's `src/std`

The host library is `native/runtime`, with its own system calls. HashLink's `src/std` natives answer with Haxe's `hl.*`
semantics (a `Bool`, a thrown string) and would tie `std` to them; a change there is also a change in another layer's
code. The runtime stops calling them domain by domain, starting with files, and once nothing calls them HashLink is
built with its engine and core only.

### 3. `std.fs` first

Files are where the layers overlap most, so they move first ([ADR 0007](0007-standard-library-layout.md) section 8):

- the runtime's file natives make their own system calls and answer a status that `std.fs` maps to a `FileError` case;
- a confined directory (`std.fs.Root`) is resolved by the runtime too: NativeKit's filesystem module (`openat2` with
  `RESOLVE_BENEATH` on Linux, `O_RESOLVE_BENEATH` on macOS, handle-path checks on Windows) moves into it, with its tests,
  and `packages/filesystem` is deleted;
- `sys.FileSystem` and `sys.io.File` keep Haxe's behaviour for the compiler (ADR 0006), and later become adapters over
  `std.fs` in the compatibility package (ADR 0007 section 9).

Directory watching follows: `std.fs` takes the runtime's watcher, and the packages stop using NativeKit's file watch.

### 4. The VM lives in the repository

HashLink comes into this repository with its history (`git subtree add`, not squashed, so the fork's 476 commits keep
their blame), under `native/vm`, and the fork is archived. A change across the compiler, the runtime and the VM is one
commit; no pin moves, no worktree needs submodule clones of its own, and the published VM cannot fall behind a pin.
`git subtree pull` still takes an upstream change when one is wanted. `hashlink-debugger` stays a submodule: it is a
separate tool with its own releases.

It waits for the work in flight on the fork to land, since every session moves at once.

## Consequences

- One definition of each host service, and one place a failure's reason comes from.
- `std` does not depend on NativeKit, and Haxeon no longer uses NativeKit's filesystem module; whether NativeKit keeps
  it for other languages is NativeKit's decision.
- Scripts, CMake and CI that name `vendor/hashlink` change once, when the VM moves.
- The repository grows by the VM's history.
