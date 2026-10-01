// Host side of a Haxeon Wasm guest (wasm32 or wasm-gc) that shares linear memory with an Emscripten module.
//
// The guest imports only C-ABI functions: the host services in HaxeonHost.hxi, scalar runtime services
// ("std" and math), and the C functions of the libraries it binds through HXI. This script implements the
// first two and forwards the rest to the Emscripten module's exports, so a page never depends on how either
// backend lays out Haxe values. Load it as a classic script; it defines the global HaxeonWasmHost.
"use strict";

var HaxeonWasmHost = (() => {
  const CONTRACT_FIELDS = ["version", "pageSize", "hostBase", "hostLimit", "guestBase", "guestLimit", "memorySize"];

  /** The guest's linear-memory contract (the haxeon.memory.contract custom section), or null without one. */
  function memoryContract(module) {
    const sections = WebAssembly.Module.customSections(module, "haxeon.memory.contract");
    if (sections.length === 0) return null;
    const view = new DataView(sections[0]);
    return {
      version: view.getUint8(3), pageSize: view.getUint32(4, true), hostBase: view.getUint32(8, true),
      hostLimit: view.getUint32(12, true), guestBase: view.getUint32(16, true),
      guestLimit: view.getUint32(20, true), memorySize: view.getUint32(24, true)
    };
  }

  /**
   * Instantiates a guest module.
   *   emscripten  the initialized Emscripten Module whose memory, function table and C exports the guest uses
   *   memory      that module's WebAssembly.Memory
   *   contract    the host's memory contract; the guest's must match it field for field
   *   print       receives each complete line the guest prints (default console.log)
   *   wrap        optional (module, name, fn) => fn applied to each forwarded C function, e.g. to time calls
   *   allocate    optional size => address of shared memory for a host error message, with release(address);
   *   release     both default to the Emscripten module's malloc and free when it exports them
   * Returns {instance, exports, unavailable}, where unavailable lists the import modules the host could not
   * provide. Calling one of their functions throws haxeon.wasm.HostError into the guest, which Haxe code catches
   * like its own exceptions; a guest without exceptions gets a JavaScript Error, which stops it.
   */
  async function instantiate(source, {emscripten, memory, contract, print = line => console.log(line), wrap = null,
      allocate = emscripten && emscripten._malloc, release = emscripten && emscripten._free}) {
    const module = source instanceof WebAssembly.Module ? source
      : await WebAssembly.compileStreaming(source instanceof Response || source instanceof Promise ? source : fetch(source));
    const guestContract = memoryContract(module);
    if (contract && guestContract)
      for (const field of CONTRACT_FIELDS)
        if (guestContract[field] !== contract[field])
          throw new Error(`guest and host memory contracts differ in ${field}`);
    let exports = null, pending = "";
    const decoder = new TextDecoder();
    const cString = pointer => {
      const bytes = new Uint8Array(memory.buffer);
      let end = pointer;
      while (bytes[end] !== 0) end++;
      return decoder.decode(bytes.subarray(pointer, end));
    };
    const imports = {
      env: {memory},
      haxeon_host: {
        print: pointer => {
          pending += cString(pointer);
          let newline;
          while ((newline = pending.indexOf("\n")) >= 0) {
            print(pending.slice(0, newline));
            pending = pending.slice(newline + 1);
          }
        },
        date_now: () => Date.now(),
        // Native code calls the table entry as a C function; it forwards to the guest's exported entry.
        callback_create: (entry, signature, id) => {
          const target = exports[cString(entry)];
          if (typeof target !== "function")
            throw new Error(`the guest does not export callback entry ${cString(entry)}`);
          return emscripten.addFunction((...args) => target(id, ...args), cString(signature));
        },
        callback_close: index => emscripten.removeFunction(index)
      },
      std: {
        sys_time: () => Date.now() / 1000,
        sys_cpu_time: () => performance.now() / 1000,
        sys_thread_cpu_time: () => performance.now() / 1000,
        sys_process_memory: () => memory.buffer.byteLength,
        sys_getpid: () => 1,
        sys_sleep: () => {},
        sys_get_char: () => -1,
        sys_exit: () => {}
      },
      haxeon_runtime: {
        __math_ceil: Math.ceil, __math_floor: Math.floor, __math_round: Math.round,
        __math_is_finite: Number.isFinite, __math_is_nan: Number.isNaN,
        __math_fmod: (left, right) => left % right, __math_pow: Math.pow, __math_sqrt: Math.sqrt,
        __math_sin: Math.sin, __math_cos: Math.cos, __math_tan: Math.tan, __math_atan2: Math.atan2
      }
    };
    const encoder = new TextEncoder();
    // Throws `message` as a haxeon.wasm.HostError with the guest's exception tag when it can.
    const fail = message => {
      const tag = exports && exports.__haxeon_exception, create = exports && exports["haxeon.wasm.HostError.fromLinear"];
      if (tag && create && allocate && release) {
        const bytes = encoder.encode(message), address = allocate(bytes.length || 1);
        if (address) {
          let error;
          try {
            new Uint8Array(memory.buffer, address, bytes.length).set(bytes);
            error = create(address, bytes.length);
          } finally {
            release(address);
          }
          throw new WebAssembly.Exception(tag, [error]);
        }
      }
      throw new Error(message);
    };
    const unavailable = new Set();
    for (const entry of WebAssembly.Module.imports(module)) {
      if (entry.kind !== "function" || imports[entry.module]?.[entry.name]) continue;
      const table = imports[entry.module] ??= {};
      const hosted = emscripten["_" + entry.name];
      if (typeof hosted === "function" && !["haxeon_host", "std", "haxeon_runtime"].includes(entry.module)) {
        table[entry.name] = wrap ? wrap(entry.module, entry.name, hosted) : hosted;
        continue;
      }
      unavailable.add(entry.module);
      table[entry.name] = () => fail(`${entry.module}.${entry.name} is not available in this build`);
    }
    const instance = await WebAssembly.instantiate(module, imports);
    exports = instance.exports;
    return {instance, exports, unavailable: [...unavailable].sort()};
  }

  return {instantiate, memoryContract};
})();
