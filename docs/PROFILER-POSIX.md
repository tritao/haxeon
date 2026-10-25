# Native instrumentation on Linux and macOS

Status: design proposal, October 2026. Nothing here has been built or run.
Claims marked **(unverified)** come from memory or from secondary sources and
need a check before anyone relies on them. Everything else cites a primary
source or this repository.

The goal is feature parity with Windows x64 (see `PROFILER.md`, "Native code
(Windows x64)"): every native function we compile instrumented automatically,
calls into code we do not compile recorded at the boundary, and samples that
walk through native code. The hooks are only part of that. [Parity beyond the
hooks](#parity-beyond-the-hooks) lists the rest of what Linux and macOS lack
today.

## Summary recommendation

| Piece | Linux x86-64 / arm64 | macOS arm64 / x86-64 |
| --- | --- | --- |
| Function hooks | Clang `-finstrument-functions-after-inlining`; GCC `-finstrument-functions` plus header excludes | Apple clang `-finstrument-functions-after-inlining` |
| Hook library | `hlprof_hooks.o`: plain C with hidden visibility, finds libhl through `dlsym` | same file |
| Fallback | `-finstrument-functions` with exclude lists, or XRay on clang only | `-finstrument-functions` |
| Boundary hooks | GOT patching of our own objects, found by `dl_iterate_phdr` and matched by relocation symbol name; the `dlopen` import is hooked to trigger a refresh | GOT rebinding (fishhook-style) of our own images through the indirect symbol table, plus `_dyld_register_func_for_add_image` |
| Boundary fallback | `-Wl,--wrap` at link time, or `LD_AUDIT` | none needed |
| Stubs | 1024 stubs built in `.text`, so nothing is generated at run time | same; this avoids `MAP_JIT` |
| GPU | wrap `vkGet*ProcAddr` (the import, plus results returned through `dlsym`) | same for MoltenVK; swizzle Metal and CAMetalLayer methods with `method_setImplementation` |
| Naming | runtime streams module path, load bias and build-id with each new pc; `hlprof-live export` runs `llvm-symbolizer` offline (`addr2line` fallback); `dladdr` stays as the in-process fallback | same, with a `dsymutil` dSYM for each instrumented module; fallback `atos` |

The `__cyg_profile_func_*` ABI is an ordinary C call. The compiler saves live
registers around it like any other call. So, unlike `_penter`/`_pexit`, the
hooks need no assembly on any of the four targets, and one C file serves all
of them. Text-patching schemes are rejected as the primary method: XRay,
`-fpatchable-function-entry` and `-pg -mfentry` all need code pages rewritten at
run time. That clashes with macOS code signing on arm64 and with SELinux
`execmod`. XRay also needs a compiler-rt runtime that Apple clang may not ship.

## What exists today

Read from the worktree.

- **Function hooks.** `prof_penter.c` and `prof_penter_x64.asm` are MSVC x64
  only. `hlprof_penter_on` points at a nonzero dummy until `resolve()` finds
  `libhl.dll`. It retries at most once a millisecond. After that it points at
  `hl_prof_on`. The key is the hook's return address.
- **Gating.** `NativeToolchain.instrumenting()` and
  `NativeCMakeProvider.instrumentArguments()` gate on Windows + MSVC (+ x64).
  `cmake/haxeon-instrument.cmake` returns early unless `MSVC` and 64-bit. Its
  source regex covers `c|cc|cpp|cxx|c++`, not `m`/`mm`.
- **Boundary hooks.** `prof_boundary.c` compiles to stubs (`hl_prof_boundary_install`
  and friends) everywhere except `HL_WIN && HL_64 && _MSC_VER`.
- **Recorder.** `hl_prof_enter_native(key)` puts the key in the lock-free
  native-key set and queues it, then calls `write_enter(key,false)`, which is
  eligible for short-call dropping. `hl_prof_enter_blocking` keeps the record
  and publishes the held run. `hl_prof_exit` takes back a held short call.
  None of this is Windows-specific.
- **Symbol naming on Linux/macOS.** `profile.c` `stream_native_symbol_locked`
  uses only `dladdr`. When `dli_sname` is NULL it returns without writing
  **any** record, not even a location record. Otherwise it writes
  `NATIVE_SYMBOL(pc, dli_saddr, dli_fname, dli_sname)` and
  `NATIVE_LOCATION(pc, dli_fbase, size 0, line 0)`. Sampled native frames go
  through the same function.
  - `dladdr` sees only the dynamic symbol table. That leaves static and
    `-fvisibility=hidden` functions unnamed on glibc. On macOS it reports the
    nearest preceding exported symbol, which can be wrong. **(unverified for
    both; from memory of glibc `elf/dl-addr.c` and Apple's dladdr(3); the Linux
    man page only says unmatched lookups give NULL.)**
  - There is no libbacktrace, libdw, DWARF or atos path. `hlprof-live.c` names
    native keys only from these events.
- **Missing pieces.** `vendor/hashlink/src` has no `pthread_atfork` handling.
  macOS `MAP_JIT` / `pthread_jit_write_protect_np` handling already exists in
  `gc.c` for the JIT.

## Linux

### Function hooks

**Recommended: `-finstrument-functions-after-inlining` on Clang.**

- Clang marks the function, and LLVM's `EntryExitInstrumenter` inserts
  `__cyg_profile_func_enter(this_fn, call_site)` at entry and the exit call
  before each `ret`.
  - The plain `-finstrument-functions` variant is added *before* the inliner,
    in `buildModuleSimplificationPipeline`
    (`EntryExitInstrumenterPass(/*PostInlining=*/false)`).
  - The `-after-inlining` variant uses the `...-inlined` attributes and the
    post-inline pass. So only code that stays a call is probed. That matches
    MSVC `/Gh` and the Haxe pass.
- Key: use `this_fn`, the exact function start, instead of a return address.
  The recorder accepts any pc as a key.

**GCC (no post-inlining variant).**

- GCC documents that "this instrumentation is also done for functions
  expanded inline in other functions". In C++ every inlined
  `std::vector::operator[]` would cost a hook pair.
- Mitigation:
  `-finstrument-functions-exclude-file-list=/usr/include,/c++/,<vendor dirs>`.
  It matches the file of each function's *definition* by substring, which
  removes header templates.
- `-finstrument-functions-exclude-function-list=` also exists. It uses
  substring match on the user-visible name.
- Recommend Clang when both are available and support GCC with this caveat
  documented.

**Cost when off.**

- The hook body is `if (!*hooks_on) return;` behind a direct call. There is no
  PLT if the hook is hidden (see Build integration).
- Two calls, two loads and two predictable branches per pair. That is about
  1–3 ns, plus the cost of an instrumented leaf no longer being a leaf.
  **(unverified estimate; prototype step 2 measures it.)**

**Cost when on.** The hook calls `hl_prof_enter_native(this_fn)` or
`hl_prof_exit()`. That is the same ~16 ns per pair as Windows plus one extra
call level.

**Scoping.** Per-source flags work the same way as `/Gh /GH`. Hooks, libhl and
anything the hooks call must be compiled without the flag and carry
`__attribute__((no_instrument_function))`, which both compilers honour.

**Exceptions.**

- Clang inserts the exit only before `ret` (and before a `musttail` call). A
  C++ exception unwinding through a frame skips its exit, exactly as on
  Windows. The Haxe catch's `UNWIND` restores the depth.
- GCC wraps the whole body in a `TRY_FINALLY_EXPR`, so its exit hook runs
  during unwinding too. A source comment still carries a TODO about ignoring
  exceptions. Depth stays paired in that case, and the runtime's `t->depth`
  accounting already copes with both.
- glibc thread cancellation unwinds the same way.

**Finding libhl.**

- Mirror `resolve()`. Try `dlsym(RTLD_DEFAULT, "hl_prof_on")`, which finds
  libhl when the `hl` executable links it. Then fall back to
  `dlopen("libhl.so", RTLD_NOLOAD | RTLD_LAZY)` plus `dlsym`, which finds a
  libhl a host loaded `RTLD_LOCAL` without loading anything.
- Throttle retries with `clock_gettime(CLOCK_MONOTONIC_COARSE)` once a
  millisecond.
- Weak undefined references are rejected:
  - they bind once, at load, so they miss a libhl that is `dlopen`ed later;
  - on macOS they need link-time knowledge of libhl.
- Tools a build runs keep working: in them the hook never resolves and stays
  on the throttled slow path, as on Windows.

**Alternatives considered.**

| Method | Off cost | Exit hook | Linux | macOS | Why not primary |
| --- | --- | --- | --- | --- | --- |
| XRay `-fxray-instrument` | NOP sled, near zero | yes (entry, exit, tail) | x86-64, arm64 | Clang driver accepts macOS x86-64/arm64; compiler-rt lists `osx` | Clang only. A default 200-instruction or loop threshold must be overridden (`-fxray-instruction-threshold=1`). Needs the runtime linked into the executable. DSOs need `-fxray-shared` (LLVM 20+, x86-64 then arm64). Patching rewrites text. Apple clang shipping the runtime is **(unverified)**. |
| `-fpatchable-function-entry=N,M` | NOPs | no (entry only) | GCC and Clang | Clang | We would write the patcher; exits would need return-address hijacking, which fights CET and PAC shadow stacks. |
| `-pg` (`-mfentry`, `-mrecord-mcount`, `-mnop-mcount`, `-minstrument-return`) | NOP with `-mnop-mcount` | x86 GCC only (`-minstrument-return`) | x86-centric | `-pg` on Darwin believed unsupported **(unverified)** | Arch-specific asm ABI, exits only on x86 GCC. |

XRay is the fallback only if the off cost of `__cyg` proves too high for a
Linux and Clang project.

### Boundary hooks

**Recommended: GOT patching of our own objects.** At install, and after every
`dlopen`, run `dl_iterate_phdr`. For each object that is ours:

1. Find `PT_DYNAMIC` and read `DT_SYMTAB`, `DT_STRTAB`, `DT_JMPREL`/`DT_PLTRELSZ`
   (`R_X86_64_JUMP_SLOT`, `R_AARCH64_JUMP_SLOT`) and `DT_RELA`/`DT_RELASZ`
   (`R_*_GLOB_DAT`; `-fno-plt` code uses these).
2. For each relocation whose symbol name is in the hook table, compute the
   slot as `dlpi_addr + r_offset`. Save the slot's current value as `real`,
   and write the stub.
   - Match by **name**, ignoring the symbol version, not by address.
     - With lazy binding an unbound `JUMP_SLOT` holds the PLT stub's address,
       not the target.
     - Versioned symbols (`pthread_cond_wait@GLIBC_2.3.2`) differ from what
       `dlsym` returns.
   - Overwriting a lazy slot is safe: the resolver only writes slots on the
     path we have replaced.
   - Also accept an address match against `dlsym` results, for parity with
     `extra=`.
3. RELRO pages, which include the GOT under `-z relro -z now`, are read-only
   after relocation. `mprotect` the page `PROT_READ|PROT_WRITE`, store with a
   single aligned 8-byte write (atomic on both architectures), then restore.
   Serialize under the hook lock.

"Ours" means the main program (empty `dlpi_name`, so read `/proc/self/exe`)
and any object not under `/usr/`, `/lib`, `/lib64`, `/snap/`, excluding
`linux-vdso`. That is the analogue of `is_own_module`.

**Module loads.**

- There is no `LoadLibrary` notification, so hook `dlopen` and `dlmopen` in our
  own GOTs, the same way the Windows code hooks `LoadLibrary*`, and refresh
  after a successful call.
- Compare `dlpi_adds`, a counter `dl_iterate_phdr` provides since glibc 2.4, at
  each refresh and at session start, to also catch loads made by system
  libraries.
- `r_debug`/`_dl_debug_state` is a debugger interface and is rejected.

**Alternatives.**

- `LD_PRELOAD` interposition:
  - covers every caller, including system libraries, which is broader than
    Windows parity;
  - needs the environment variable at launch and leaks it to child processes;
  - cannot add `extra=` names at run time.
- `dlsym(RTLD_NEXT)` is only how an interposer finds the real function. We
  already have the real pointer from the slot.
- `-Wl,--wrap=sym` is static, needs a `__wrap_` per function and covers only
  objects linked with it. It is a reasonable fallback, because we own the link
  flags, but `extra=` would need a rebuild.
- `LD_AUDIT` `la_symbind64` can return "a different value … to direct control to
  an alternate location" for bindings from objects that `la_objopen` flags
  `LA_FLG_BINDFROM`. It covers `dlopen` too.
  - It needs the variable at launch.
  - Whether it is called under `BIND_NOW` on older glibc is **(unverified)**.
    glibc 2.35 is believed to have fixed it.
  - It is a second fallback.

**Stubs and thunk.**

- Generate the 1024 stubs statically in a `.S` file: `mov $i, %r11d; jmp
  common` on x86-64, and `mov w17, #i; b common` on arm64, where `x16`/`x17`
  are the intra-procedure scratch registers. That needs no RWX memory. The key
  stays the stub address, so `hl_prof_boundary_name` is unchanged.
- The thunk (GNU as):
  - **x86-64 SysV.** Save `rdi rsi rdx rcx r8 r9 rax` (`al` counts vector
    registers for varargs) and `xmm0`–`xmm7`. Copy 12 stack arguments. Return
    `rax rdx xmm0 xmm1`.
  - **AArch64.** Save `x0`–`x8` (`x8` is the indirect result) and `q0`–`q7`.
    Copy 12 stack slots. Return `x0 x1 q0`–`q3`.
- The thunk **must carry CFI** (`.cfi_*`). glibc cancellation and C++
  exceptions unwind through it, and a missing EXIT is then tolerated as on
  Windows.

**Curated blocking set (Linux).**

| Kind | Calls |
| --- | --- |
| Threads | `pthread_join`, `pthread_cond_wait`, `pthread_cond_timedwait`, `pthread_cond_clockwait`, `sem_wait`, `sem_timedwait`, `sem_clockwait` |
| Sleep | `nanosleep`, `clock_nanosleep`, `usleep`, `sleep` |
| Polling | `poll`, `ppoll`, `select`, `pselect`, `epoll_wait`, `epoll_pwait`, `epoll_pwait2` |
| File I/O | `read`, `write`, `pread`, `pwrite`, `readv`, `writev`, `fsync`, `fdatasync`, `open`, `openat` |
| Network | `recv`, `recvfrom`, `recvmsg`, `send`, `sendto`, `sendmsg`, `accept`, `accept4`, `connect`, `getaddrinfo` |
| Processes | `waitpid`, `waitid`, `wait4`, `posix_spawn`, `posix_spawnp`, `system`, `popen`, `pclose` |
| C streams | `fopen`, `fread`, `fwrite`, `fflush`, `fclose` |

- **futex.** `syscall` gets a dedicated C wrapper that records only when
  `n == SYS_futex` (or `SYS_futex_waitv`) and forwards six `long`s.
- **`fork`, `vfork`, `exec*`.** Do not hook them. A forked child inherits
  `hl_prof_on` without a consumer thread. libhl needs a
  `pthread_atfork` child handler that clears it whether or not hooks exist.
  This is a pre-existing gap.
- **C++, libstdc++.**
  - Exported waits: `_ZNSt18condition_variable4waitERSt11unique_lockISt5mutexE`,
    `_ZNSt6thread4joinEv`, `_ZNSt11this_thread11__sleep_for…`.
  - Mangled names are **(unverified)**; check with `nm -D libstdc++.so.6`.
  - Header-inline waits reach `pthread_cond_clockwait`/`nanosleep` directly
    from our code and are already covered.

**Vulkan.**

- Hook the `vkGetInstanceProcAddr`/`vkGetDeviceProcAddr` imports and the
  listed `vk*` imports, as on Windows.
- Also hook our `dlsym` import and wrap results named `vkGet*ProcAddr`. volk,
  SDL and GLFW load the loader dynamically.
- An implicit layer (JSON manifest plus `VK_INSTANCE_LAYERS`) is a heavier
  fallback.

## macOS

### Function hooks

- Apple clang supports `-finstrument-functions` (believed; standard Clang
  driver flag). `-finstrument-functions-after-inlining` has been upstream
  since LLVM 6; whether every Apple clang carries it is **(unverified)**, and
  prototype step 1 checks it.
- The hook file is the same as on Linux. Use `dlopen("libhl.dylib",
  RTLD_NOLOAD)` for the fallback lookup.
- Third-party code on Apple silicon is `arm64`, not `arm64e`, so `this_fn` is
  unsigned. Wrap it in `ptrauth_strip` under `__arm64e__` anyway.
- XRay: the Clang driver accepts `-fxray-instrument` for macOS x86-64/arm64,
  and compiler-rt sets `XRAY_SUPPORTED_OS osx`. Patching signed `__TEXT` pages
  on arm64 is likely fatal under code signing **(unverified)**. Rejected.

### Boundary hooks

**Recommended: rebind our own images' GOTs, fishhook style.**

- Register `_dyld_register_func_for_add_image`. It is called for existing and
  future images.
- For each image that is ours, walk `__DATA`/`__DATA_CONST` sections of type
  `S_NON_LAZY_SYMBOL_POINTERS` (`__got`, `__auth_got`) and
  `S_LAZY_SYMBOL_POINTERS` (older binaries).
- Map each slot through the indirect symbol table (`reserved1`, `LC_DYSYMTAB`)
  to a name. Match it after stripping the leading `_` and any `$…` suffix,
  such as `$NOCANCEL` or `$DARWIN_EXTSN` **(unverified for arm64)**.
- Also match by value against `dlsym` results.
- "Ours" means not in the shared cache and not under `/System` or `/usr/lib`.

**Chained fixups** (`LC_DYLD_CHAINED_FIXUPS`, the default for deployment
targets of macOS 12 / iOS 15 and later).

- dyld binds everything at launch; there are no lazy binds.
- `__got` still holds final pointers after load. Rewriting it after load
  therefore still works, provided ld still emits indirect-symbol entries for
  `__got`. That is believed true but **(unverified)**; prototype step 6 checks
  it. Value matching covers the case where it does not.
- Nothing replaces fishhook as an Apple API. The options are to rebind after
  load, to interpose, or to wrap.

**`__DATA_CONST`.**

- It is read-only after fixups.
- fishhook uses `vm_protect(…, VM_PROT_READ|VM_PROT_WRITE|VM_PROT_COPY)`, which
  [fishhook #97](https://github.com/facebook/fishhook/issues/97) reports
  failing with `KERN_PROTECTION_FAILURE` on macOS 14.
- Use `mprotect(PROT_READ|PROT_WRITE)` on our own pages and restore them
  afterwards. If that also fails, link instrumented modules with the linker
  option that disables `__DATA_CONST` (ld64's `-no_data_const` existing is
  **(unverified)**).

**PAC.**

- Our modules are `arm64`. Their `__got` slots are plain pointers, and the
  thunk calls `real` with `blr`.
- Never copy raw pointers out of `arm64e` system memory. Use `dlsym` and
  `method_getImplementation`, which return pointers callable in the caller's
  ABI.
- fishhook issues [#89](https://github.com/facebook/fishhook/issues/89) and
  [#80](https://github.com/facebook/fishhook/issues/80) show what breaks for
  `arm64e` callers.

**DYLD_INTERPOSE** (`__DATA,__interpose`) is rejected.

- It needs `DYLD_INSERT_LIBRARIES`, which the hardened runtime ignores without
  `com.apple.security.cs.allow-dyld-environment-variables`, and which SIP
  strips for protected binaries **(from memory; Apple's page did not render)**.
- It affects every caller.

**W^X.** Static stubs in `__TEXT` avoid `MAP_JIT`,
`pthread_jit_write_protect_np` and the `allow-jit` entitlement entirely. The
thunk is a `.S` file with `_`-prefixed symbols. On arm64 Darwin, variadic
arguments go on the stack, which the 12-slot copy covers, and `x18` is
reserved, so leave it alone.

**Curated set (macOS).**

| Kind | Calls |
| --- | --- |
| Same as Linux | `pthread_*`, sleep, `poll`, `select`, `read`, `write`, socket calls, `posix_spawn`, `waitpid`, `system`, C streams |
| Darwin-specific | `kevent`, `kevent64`, `mach_msg`, `semaphore_wait`, `dispatch_semaphore_wait`, `dispatch_group_wait`, `dispatch_sync` |

- No `epoll`.
- libc++ exports `std::condition_variable::wait`, `__do_timed_wait`,
  `std::thread::join` and `this_thread::sleep_for` (`__ZNSt3__1…` mangled
  names **(unverified)**).

**Metal / CAMetalLayer.**

- Hook the `MTLCreateSystemDefaultDevice` and `MTLCopyAllDevices` imports.
- On the first device, swizzle with `method_setImplementation`, using
  `stub_for(original IMP)`. An IMP is a C function `(self, _cmd, …)`, so the
  generic thunk serves as the IMP.
  - Swizzle `newCommandQueue` on the device's concrete class.
  - Wrap the queue's `commandBuffer` and `commandBufferWithUnretainedReferences`.
    On first sight, swizzle the returned buffer's concrete class
    (`object_getClass`): `commit`, `waitUntilCompleted`, `waitUntilScheduled`,
    `presentDrawable:`.
- Swizzle `-[CAMetalLayer nextDrawable]` (a public class). On its first result
  swizzle the drawable class's `present`, `presentAtTime:` and
  `presentAfterMinimumDuration:`.
- Name the keys `MTLCommandBuffer::commit` and so on, by protocol, not by
  private class.

**Vulkan (MoltenVK)** works as on Linux.

## Shared pieces

- **`prof_hooks.c`.** Shared by Linux and macOS, it replaces `prof_penter.c`
  there and defines `__cyg_profile_func_enter`/`exit`. It is compiled `-O2
  -fPIC -fvisibility=hidden -fno-instrument-functions` with
  `no_instrument_function` on every function, so each module calls its own
  copy directly with no PLT and no cross-module interposition.
- **`prof_boundary_posix.c`.** It holds the stub table, descriptors, the
  config parser for `HL_PROF_BOUNDARY` (same syntax), Vulkan wrappers and the
  `syscall` wrapper. It splits into `got_elf.c` and `got_macho.c` scanners and
  a `metal.m` file. Most of the Windows file (`stub_for`, `vk_hooked`, config)
  moves to a shared part unchanged.
- **Assembly.** `prof_boundary_sysv_x64.S` and `prof_boundary_arm64.S` hold
  the thunk and 1024 stubs, with CFI.
- **Recorder.** Unchanged. `hl_prof_enter_native`, `hl_prof_enter_blocking`,
  `hl_prof_exit`, `hl_prof_may_wait` and the `boundary_busy` TLS (as
  `__thread`) behave as on Windows.

## Symbolization

| Option | In-process | Gives statics and inlines | Cost and risk |
| --- | --- | --- | --- |
| `dladdr` (today) | yes | no: exported only | Free, but wrong or missing for most instrumented code |
| libbacktrace (BSD; ELF and Mach-O) | consumer thread | yes | Adds DWARF parsing and memory to every recorded process |
| libdw | consumer thread | yes | LGPL/GPL, Linux only |
| atos / CoreSymbolication | subprocess / private API | yes | macOS only; CoreSymbolication is private |
| **Offline in `hlprof-live export`** | no | yes, with `--inlines` | Needs the module files at export time |

**Recommended: offline symbolization in the exporter.**

- **Runtime.** On the first sight of a native key, always write
  `NATIVE_LOCATION`, even when `dladdr` finds no symbol. Today it writes
  nothing. Add a module event (new id, once per module):
  - path;
  - load bias: `dlpi_addr`, or the dyld slide;
  - mapped size;
  - ELF `NT_GNU_BUILD_ID` or Mach-O `LC_UUID`.

  Keep the `dladdr` name as a provisional name.
- **Exporter.** Group unresolved pcs by module and compute the file address,
  `pc - bias`. Note that `dli_fbase` is not the bias for non-PIE executables,
  and on macOS the file address is `pc - slide`. Then stream the addresses
  through one `llvm-symbolizer --output-style=JSON --inlines` process per
  export (`--obj=<path>`, or `--build-id`, plus `--dsym-hint` on macOS).
  Fall back to `addr2line -f -C -i -e`, or to `atos -o <dSYM> -l <load>` on
  macOS. Verify the build-id or UUID before trusting a file that might have
  been rebuilt.
- **Why.** This keeps DWARF parsing off the recorded process. It matches the
  "naming never runs inside the hooked call" rule, and it is how Perfetto and
  Tracy-style tools work. The capture stays valid offline as long as the
  binaries or debug files are kept.
- **Debug info.**
  - Linux: `-g1` (GCC) or `-gline-tables-only` (Clang), not stripped, with
    `-Wl,--build-id`.
  - macOS: same flags plus `dsymutil` per module. Whether llvm-symbolizer
    follows the Mach-O debug map to `.o` files is **(unverified)**, so
    produce dSYMs.
- The DbgHelp path on Windows is unchanged.

## Build integration

`cmake/haxeon-instrument.cmake`:

- Replace the `MSVC`-only guard with a per-compiler flag set:
  - MSVC x64: as today.
  - `CMAKE_C_COMPILER_ID` `Clang`/`AppleClang`:
    `-finstrument-functions-after-inlining`, global `-gline-tables-only`.
  - `GNU`: `-finstrument-functions
    -finstrument-functions-exclude-file-list=/usr/include,/c++/`, global `-g1`.
- Extend the source regex with `m|mm` on Apple.
- Link the hooks as an **object file**, not an archive. `add_link_options`
  puts it before the objects, so GNU ld would never extract archive members.
  Use `target_link_libraries(${target} PRIVATE "${HAXEON_INSTRUMENT_HOOKS}")`
  in the deferred pass instead.
- Linux: add `-Wl,--build-id`.
- macOS: add a `POST_BUILD` `dsymutil $<TARGET_FILE:t>` per shared or
  executable target.

`NativeToolchain.hx`:

- `instrumenting()` accepts Windows+MSVC+x64, Linux with GCC/Clang, and macOS
  with Clang. How the toolchain record exposes the compiler family is
  **(unverified)**.
- `compileArguments` adds the same flags in the non-MSVC branch.
- `sharedArguments` appends the hooks object, plus `--build-id` on Linux.
- `instrumentHooks()` returns `.tools/hashlink/hlprof_hooks.o` off Windows.

`NativeCMakeProvider.instrumentArguments`: drop the Windows guard; the CMake
script chooses the flags.

HashLink's `CMakeLists.txt`:

- Non-Windows builds compile `prof_hooks.c` as an `OBJECT` library and install
  its object into `.tools/hashlink`.
- Add `prof_boundary_posix.c`, the `.S` thunk and, on Apple, `metal.m` to
  `hl`.
- The `#else` stubs in `prof_boundary.c` move to `HL_WIN && !_MSC_VER` only.

Docs: update `PROFILER.md` "Native code" and `PROFILING.md` Instrumentation and
Boundary calls.

## Risks and unknowns

- **Off cost.** The off cost of `__cyg` hooks versus MSVC `_penter` is
  unmeasured. GCC's pre-inlining instrumentation may make C++ captures much
  larger; excludes and `minCallMicros` mitigate it.
- **Writing `__DATA_CONST` on macOS 14+** (fishhook #97) is the biggest
  macOS unknown.
- **Indirect symbol entries under chained fixups.** Their presence on
  current ld-prime output is **(unverified)**.
- **Missing exits.** Exceptions, cancellation and `longjmp` through
  instrumented C/C++ leave exits missing (Clang), as on Windows. Haxe catches
  repair the depth.
- **Fork.** A forked child keeps `hl_prof_on` set with no consumer and may
  hang. This is pre-existing; add an atfork handler.
- **Calls the GOT never sees.** Calls made through `dlsym` pointers, other than
  Vulkan's, and statically linked libc functions bypass GOT hooks, as
  `GetProcAddress` does on Windows.
- **Metal private classes.** Swizzling a private concrete class can break
  across OS releases. Name by protocol and swizzle defensively, checking
  `respondsToSelector:`.
- **Exporter dependency.** `llvm-symbolizer` may be missing. Ship it with the
  toolchain or fall back to `addr2line`/`atos`, then to `dladdr` names.

## Parity beyond the hooks

The hooks above give instrumented and boundary calls. Windows also has the
following, which Linux and macOS lack today (read from the runtime, October
2026):

- **Mixed-mode samples.** Built for Linux and macOS: see "Native frames in
  samples" in `PROFILER.md`. The sampler keeps every frame of the
  frame-pointer chain, marks a broken chain with an `[unwind gap]` frame, and
  Haxeon builds native packages with frame pointers. Still open:
  - On macOS arm64, `get_thread_frameptr` returns NULL, so the walk falls
    back to scanning the stack for managed return addresses. Read
    `__ss.__fp` (`x29`) there.
  - Functions that are not exported are named from the image's ELF symbol
    table at export time. Inlined frames, file and line need DWARF (see
    Symbolization), C++ names are not demangled, and macOS images (Mach-O)
    are not read.
  - The HashLink JIT on aarch64 must keep a frame-pointer chain through JIT
    frames and its native-call trampolines **(unverified)**. Only Linux
    x86-64 has run `test-profiler-mixed-stack.sh`.
- **Probe cost on arm64.** On x86-64 the JIT tests `hl_prof_on` inline and
  branches over the probe call (`jit_emit.c`), so a probe costs about 0.5 ns
  while nothing records. The aarch64 JIT (`jit_aarch64_emit.c`) has no such
  test and calls the native every time. Apple silicon needs the same inline
  test for parity.
- **System thread names on macOS.** The recorder reads names of threads the
  runtime does not know from `/proc/self/task/<tid>/comm` on Linux. macOS has
  no equivalent today, so a native thread that names itself is named only
  through its own `hl_thread_set_name` record. To read them, enumerate the
  task's threads with `task_threads`, map each with
  `pthread_from_mach_thread_np` and read it with `pthread_getname_np`, or use
  `proc_pidinfo(PROC_PIDTHREADID64INFO)` for `pth_name` **(unverified)**.
- **Thread-start wrappers.** The exporter leaves the C++ runtime's
  thread-start wrapper out of a thread's stack for MSVC (`std::thread::_Invoke`)
  and libc++ (`std::__thread_proxy`). libstdc++'s `execute_native_thread_routine`
  and `std::thread::_State_impl<...>::_M_run` are missing.
- **Own-module test.** The path prefixes in "Boundary hooks" miss systems
  that install libraries elsewhere: `/nix/store`, `/opt/homebrew`,
  `/usr/local/Cellar`, Flatpak runtimes. Test against the directories of the
  dynamic loader's system libraries (the directory of `libc.so.6` from
  `dladdr`, the dyld shared cache with `_dyld_shared_cache_contains_path`) in
  addition to fixed prefixes.
- **Fork.** libhl has no `pthread_atfork` handler on any platform. A child
  that keeps running instrumented code after `fork` without `exec` keeps
  recording with no consumer thread, and waits forever once its pool fills.
  Clear `hl_prof_on` and the session in the child.
- **Tests.** `tests/integration/test-profiler-native-instrument.sh` runs on
  Windows only. Each platform needs it, plus a boundary-call test and a
  mixed-mode sampling test.

## Prototype plan

Each step is small, and each has its own test.

1. **Flag probe.** Compile a 3-function C++ file with each compiler and
   flag, using `-S`. **Test:** `__cyg_profile_func_enter` appears only in
   non-inlined functions with `-after-inlining`, and the flag works on Apple
   clang.
2. **Hooks object.** Build `prof_hooks.c` and a fake `libhl` exporting
   `hl_prof_on`, `hl_prof_enter_native` and `hl_prof_exit`, then run an
   instrumented `fib(32)`.
   **Tests:**
   - The counts match.
   - The binary runs without libhl, staying on the throttled path.
   - The per-pair off cost is measured against an uninstrumented build.
3. **Recorder integration.** Run a `native.sources` package under `haxeon run
   --profile instrument`. **Test:** `hlprof-live export` shows nested native
   slices with `dladdr` names for exported functions.
4. **Module records and offline naming.** **Test:** a `static` function and an
   inlined frame are named from `llvm-symbolizer`, a build-id mismatch is
   reported, and with no symbolizer the export falls back to `dladdr` names.
5. **ELF GOT patcher.** Use a small `.so` calling `nanosleep` and
   `pthread_cond_wait`, linked with `-z now` and with lazy binding, `-fno-plt`
   and default, on x86-64 and arm64. **Tests:**
   - Slices are named `libc!nanosleep`.
   - A `dlopen`ed library is patched after load.
   - The original is restored when patching is disabled.
   - The thunk passes an 8-double plus 10-int argument test function and a
     struct return.
6. **Mach-O rebinding.** Same test on macOS 14/15, built with deployment
   targets 11 and 13 (with and without chained fixups). **Tests:**
   - `mprotect` on `__DATA_CONST` succeeds.
   - Indirect-symbol names exist for `__got`.
   - Value matching works when they do not.
7. **Thunk unwinding.** **Tests:**
   - A C++ exception thrown through a hooked `extra=` function is caught
     correctly by the caller.
   - `pthread_cancel` of a thread in a hooked `pthread_cond_wait` completes.
8. **Curated set.** Run a program using `std::condition_variable`,
   `std::thread::join`, `sleep_for`, `poll`/`epoll_wait`/`kevent` and
   `syscall(SYS_futex)`. **Test:** each appears as a boundary slice that is
   never dropped.
9. **Vulkan and Metal.** Use a triangle sample with volk (Linux) and a
   CAMetalLayer view (macOS). **Test:** submit/present and
   `commit`/`nextDrawable`/`present` slices appear once per frame.
10. **CMake.** Configure a third-party CMake project, such as a small lib with
    a subdirectory. **Tests:**
    - Only included sources carry the flag (`compile_commands.json`).
    - Every shared target links the hooks object.
    - dSYMs exist on macOS.
11. **Mixed-mode samples.** Use a Haxe program calling a native library that
    calls back into Haxe, built with frame pointers. **Test:** a sample taken
    in the callback holds Haxe, native and Haxe frames in order, on Linux
    x86-64, Linux arm64 and macOS arm64.
12. **arm64 probe test.** Run `fib(32)` instrumented and not recording on
    aarch64. **Test:** the cost per call is within 1 ns of an uninstrumented
    build, as on x86-64.
13. **macOS thread names.** Start a native thread that names itself with
    `pthread_setname_np`. **Test:** the trace shows the name without a
    `hl_thread_set_name` call.
14. **Fork.** Fork a child that keeps running instrumented code while a
    session records. **Test:** the child neither records nor hangs, and the
    parent's capture is unaffected.
15. **Parity run.** Run the exosuit editor's driven capture on Linux and
    macOS. **Test:** the checks used on Windows (no unnamed threads, no
    incomplete slices, native slices nested under Haxe frames, boundary
    slices for its waits and presents) hold.

## Sources

- GCC instrumentation options (`-finstrument-functions`, exclude lists, `-fpatchable-function-entry`, `-pg`): https://gcc.gnu.org/onlinedocs/gcc/Instrumentation-Options.html
- GCC x86 options (`-mfentry`, `-mrecord-mcount`, `-mnop-mcount`, `-minstrument-return`): https://gcc.gnu.org/onlinedocs/gcc/x86-Options.html
- GCC try/finally wrapping of the exit hook (original patch and comment): https://gcc.gnu.org/ml/gcc-patches/2003-12/msg00961.html ; GIMPLE cleanups: https://gcc.gnu.org/onlinedocs/gccint/Cleanups.html
- Clang command-line reference (`-finstrument-functions-after-inlining`, `-fxray-*`): https://clang.llvm.org/docs/ClangCommandLineReference.html
- LLVM EntryExitInstrumenter (exit only before `ret`): https://github.com/llvm/llvm-project/blob/main/llvm/lib/Transforms/Utils/EntryExitInstrumenter.cpp
- LLVM pass pipeline (pre-inline placement): https://github.com/llvm/llvm-project/blob/main/llvm/lib/Passes/PassBuilderPipelines.cpp
- Clang CodeGen attributes for `__cyg_profile_*`: https://github.com/llvm/llvm-project/blob/main/clang/lib/CodeGen/CodeGenFunction.cpp
- XRay docs: https://llvm.org/docs/XRay.html ; driver support matrix: https://github.com/llvm/llvm-project/blob/main/clang/lib/Driver/XRayArgs.cpp ; compiler-rt config: https://github.com/llvm/llvm-project/blob/main/compiler-rt/cmake/config-ix.cmake
- XRay DSO support: https://lists.llvm.org/pipermail/cfe-commits/Week-of-Mon-20241021/635608.html ; AArch64: https://llvm.googlesource.com/llvm-project/+/1adca7af21f1d8cc12b0f1c33db8ab869b36ae48
- dl_iterate_phdr(3): https://man7.org/linux/man-pages/man3/dl_iterate_phdr.3.html
- dladdr(3): https://man7.org/linux/man-pages/man3/dladdr.3.html
- rtld-audit(7) (`la_symbind64`, `LA_FLG_BINDFROM`): https://man7.org/linux/man-pages/man7/rtld-audit.7.html
- fishhook source: https://github.com/facebook/fishhook/blob/main/fishhook.c ; issues #97, #89, #80: https://github.com/facebook/fishhook/issues
- dyld chained fixups header: https://git.saurik.com/apple/dyld.git/blob/HEAD:/include/mach-o/fixup-chains.h ; format change explained (secondary): https://emergetools.com/blog/posts/iOS15LaunchTime
- Apple hardened runtime DYLD entitlement (page did not render; content from memory): https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.allow-dyld-environment-variables
- Apple JIT on Apple silicon (`MAP_JIT`, `pthread_jit_write_protect_np`; did not render): https://developer.apple.com/documentation/apple-silicon/porting-just-in-time-compilers-to-apple-silicon
- llvm-symbolizer: https://llvm.org/docs/CommandGuide/llvm-symbolizer.html
- Repository: `docs/PROFILER.md`, `docs/PROFILING.md`, `vendor/hashlink/src/{prof.c,profile.c,prof_penter.c,prof_penter_x64.asm,prof_boundary.c,prof_boundary_x64.asm}`, `vendor/hashlink/tools/hlprof-live.c`, `cmake/haxeon-instrument.cmake`, `src/build/native/{NativeToolchain,NativeCMakeProvider}.hx`.
