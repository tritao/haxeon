// Host side of a Haxeon Wasm guest (wasm32 or wasm-gc) that shares linear memory with an Emscripten module.
//
// The guest imports only C-ABI functions: the host services in HaxeonHost.hxi, scalar runtime services
// ("std" and math), and the C functions of the libraries it binds through HXI. This script implements the
// first two and forwards the rest to the Emscripten module's exports, so a page never depends on how either
// backend lays out Haxe values. Load it as a classic script; it defines the global HaxeonWasmHost.
"use strict";

var HaxeonWasmHost = (() => {
  /**
   * Thrown from the guest's Sys.exit, carrying its status as `code`. It unwinds the guest, which is how a Wasm program
   * stops running: instantiate's caller catches it where it would otherwise see main return. Haxe's own try/catch in the
   * guest never sees it, because the guest catches only its own exception tag.
   */
  class HaxeonExit extends Error {
    constructor(code) {
      super(`Sys.exit(${code})`);
      this.name = "HaxeonExit";
      this.code = code;
    }
  }

  const CONTRACT_FIELDS = ["version", "pageSize", "hostBase", "hostLimit", "guestBase", "guestLimit", "memorySize"];

  /**
   * The runtime's scalar services a guest imports from "haxeon_runtime" (math and the monotonic clock): they use no
   * memory, so any host gives them as they are, a test harness included.
   */
  function scalarRuntime() {
    return {
      __sys_monotonic_time: () => performance.now() / 1000,
      __math_ceil: Math.ceil, __math_floor: Math.floor, __math_round: Math.round,
      __math_is_nan: Number.isNaN,
      __math_fmod: (left, right) => left % right, __math_pow: Math.pow, __math_sqrt: Math.sqrt,
      __math_sin: Math.sin, __math_cos: Math.cos, __math_tan: Math.tan, __math_atan2: Math.atan2,
      __math_log: Math.log, __math_exp: Math.exp, __math_abs: Math.abs, __math_min: Math.min, __math_max: Math.max
    };
  }

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
   *   printError  receives each stderr line (default console.error); stream flush emits partial lines
   *   args        the strings the guest's Sys.args() returns (default none); a wasm32 guest that reads them needs allocate
   *   wrap        optional (module, name, fn) => fn applied to each forwarded C function, e.g. to time calls
   *   allocate    optional size => address of shared memory for native arenas and host errors, with release(address);
   *   release     both default to the Emscripten module's malloc and free when it exports them
   * Returns {instance, exports, unavailable}, where unavailable lists the import modules the host could not
   * provide. Calling one of their functions throws haxeon.wasm.HostError into the guest, which Haxe code catches
   * like its own exceptions; a guest without exceptions gets a JavaScript Error, which stops it.
   */
  async function instantiate(source, {emscripten, memory, contract, print = line => console.log(line), printError = line => console.error(line), wrap = null,
      args = [], allocate = emscripten && emscripten._malloc, release = emscripten && emscripten._free}) {
    const module = source instanceof WebAssembly.Module ? source
      : await WebAssembly.compileStreaming(source instanceof Response || source instanceof Promise ? source : fetch(source));
    const guestContract = memoryContract(module);
    if (contract && guestContract)
      for (const field of CONTRACT_FIELDS)
        if (guestContract[field] !== contract[field])
          throw new Error(`guest and host memory contracts differ in ${field}`);
    let exports = null;
    const pending = ["", ""], sinks = [print, printError];
    const decoder = new TextDecoder();
    const cString = pointer => {
      const bytes = new Uint8Array(memory.buffer);
      let end = pointer;
      while (bytes[end] !== 0) end++;
      // TextDecoder rejects SharedArrayBuffer-backed views. Copy the C string
      // to a stable snapshot; worker-owned native memory may be shared.
      return decoder.decode(bytes.slice(pointer, end));
    };
    const writeOutput = (pointer, error) => {
      const stream = error ? 1 : 0;
      pending[stream] += cString(pointer);
      let newline;
      while ((newline = pending[stream].indexOf("\n")) >= 0) {
        sinks[stream](pending[stream].slice(0, newline));
        pending[stream] = pending[stream].slice(newline + 1);
      }
    };
    const flushOutput = error => {
      const stream = error ? 1 : 0;
      if (pending[stream].length) {
        sinks[stream](pending[stream]);
        pending[stream] = "";
      }
    };
    const imports = {
      env: {memory},
      haxeon_host: {
        print: pointer => writeOutput(pointer, 0),
        write_output: writeOutput,
        flush_output: flushOutput,
        date_now: () => Date.now(),
        // JavaScript's offset is UTC minus local time; the guest's is local time minus UTC.
        date_timezone_offset: time => -new Date(time).getTimezoneOffset(),
        argument_count: () => args.length,
        argument: index => {
          if (!(index >= 0 && index < args.length)) return fail(`Argument ${index} is out of range`);
          return argumentAddress(index);
        },
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
        sys_exit: code => { throw new HaxeonExit(code); }
      },
      haxeon_runtime: Object.assign(scalarRuntime(), {
        native_alloc: size => {
          if (size <= 0) return fail("Native memory allocation size must be positive");
          if (typeof allocate !== "function") return fail("The host does not provide native memory allocation");
          const address = allocate(size);
          if (!address) return fail("Native memory allocation failed");
          return address;
        },
        native_free: address => {
          if (!address) return;
          if (typeof release !== "function") return fail("The host does not provide native memory release");
          release(address);
        }
      })
    };
    const encoder = new TextEncoder();
    // Each argument is written once, NUL-terminated, where it stays while the guest runs.
    const argumentAddresses = [];
    const argumentAddress = index => {
      if (argumentAddresses[index] === undefined) {
        if (typeof allocate !== "function") return fail("The host does not provide memory for the program's arguments");
        const bytes = encoder.encode(String(args[index]) + "\0"), address = allocate(bytes.length);
        if (!address) return fail("Allocating the program's arguments failed");
        new Uint8Array(memory.buffer, address, bytes.length).set(bytes);
        argumentAddresses[index] = address;
      }
      return argumentAddresses[index];
    };
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
      const hosted = emscripten?.["_" + entry.name];
      if (typeof hosted === "function" && !["haxeon_host", "std", "haxeon_runtime"].includes(entry.module)) {
        table[entry.name] = wrap ? wrap(entry.module, entry.name, hosted) : hosted;
        continue;
      }
      unavailable.add(entry.module);
      table[entry.name] = () => fail(`${entry.module}.${entry.name} is not available in this build`);
    }
    const instance = await WebAssembly.instantiate(module, imports);
    exports = instance.exports;
    memory ??= exports.memory;
    return {instance, exports, unavailable: [...unavailable].sort()};
  }

  function emscriptenContract(Module, hostMemory) {
    const contract = {
      version: Module["_nkui_haxeon_memory_contract_version"](),
      pageSize: Module["_nkui_haxeon_memory_contract_page_size"](),
      hostBase: Module["_nkui_haxeon_memory_contract_host_base"](),
      hostLimit: Module["_nkui_haxeon_memory_contract_host_limit"](),
      guestBase: Module["_nkui_haxeon_memory_contract_guest_base"](),
      guestLimit: Module["_nkui_haxeon_memory_contract_guest_limit"](),
      memorySize: Module["_nkui_haxeon_memory_contract_memory_size"]()
    };
    const status = Module["_nkui_haxeon_memory_contract_status"]();
    if (contract.version !== 1)
      throw new Error("unsupported memory contract version " + contract.version);
    if (status !== 0)
      throw new Error("native heap crossed the Haxeon guest boundary");
    if (contract.hostBase !== 0 || contract.hostLimit !== contract.guestBase ||
        contract.guestBase >= contract.guestLimit || contract.guestLimit !== contract.memorySize ||
        contract.pageSize !== 65536 || contract.memorySize % contract.pageSize !== 0)
      throw new Error("native memory partition is invalid");
    if (!hostMemory || hostMemory.buffer.byteLength !== contract.memorySize)
      throw new Error("shared memory size does not match the Haxeon contract");
    return contract;
  }


  async function instantiateEmscripten(url, imports, onBytes = () => {}) {
    const response = await fetch(url);
    if (!response.ok)
      throw new Error(`Could not fetch ${url}: HTTP ${response.status}`);
    const bytes = await response.arrayBuffer();
    onBytes(bytes);
    const {instance} = await WebAssembly.instantiate(bytes, imports);
    const memory = Object.values(instance.exports).find(value => value instanceof WebAssembly.Memory);
    return {instance, memory};
  }

  /**
   * Publishes the app's state ("ready", "stopped" or "failed") on the page's root element and, when the page is
   * embedded, to a same-origin parent, so an embedding page can reveal or replace the app without app-specific code.
   */
  function announce(state) {
    document.documentElement.dataset.haxeonApp = state;
    if (window.parent !== window && location.origin !== "null")
      window.parent.postMessage({type: "haxeon-app", state}, location.origin);
  }

  /** Schedules the single platform loop registered by the guest's main. */
  function runApp(exports, {onPresented, onFrame, onStopped, onError} = {}) {
    const tick = exports["haxeon.platform.BrowserHost.tick"];
    if (typeof tick !== "function")
      throw new Error("The app is missing its platform tick export");
    let presented = false;
    function advance() {
      try {
        const status = tick();
        if (status === 2) {
          announce("stopped");
          onStopped?.();
          return;
        }
        if (status === 1) {
          if (!presented) {
            presented = true;
            announce("ready");
            onPresented?.();
          }
          onFrame?.(exports);
        }
        requestAnimationFrame(advance);
      } catch (error) {
        announce("failed");
        if (onError) onError(error);
        else throw error;
      }
    }
    requestAnimationFrame(advance);
  }

  /** Loads the SDK's WebGL2 host and starts a managed app on its canvas. */
  async function mountApp(module, canvas, callbacks) {
    try {
      return await loadAndRun(module, canvas, callbacks);
    } catch (error) {
      announce("failed");
      throw error;
    }
  }

  async function loadAndRun(module, canvas, callbacks) {
    const hostUrl = new URL("./ui/nativekit_ui_haxeon.js", document.baseURI);
    let memory;
    const emscripten = await new Promise((resolve, reject) => {
      window.Module = {
        canvas,
        instantiateWasm(imports, receiveInstance) {
          instantiateEmscripten(new URL("nativekit_ui_haxeon.wasm", hostUrl), imports)
            .then(result => {
              memory = result.memory;
              receiveInstance(result.instance);
            }).catch(reject);
          return {};
        },
        onRuntimeInitialized() { resolve(window.Module); },
        onAbort(reason) { reject(new Error(reason)); }
      };
      const script = document.createElement("script");
      script.src = hostUrl;
      script.onerror = () => reject(new Error("Could not load the WebGL2 UI host"));
      document.head.append(script);
    });
    const contract = emscriptenContract(emscripten, memory);
    const guest = await instantiate(module, {emscripten, memory, contract});
    guest.exports.main();
    runApp(guest.exports, callbacks);
    return guest.exports;
  }

  return {instantiate, scalarRuntime, memoryContract, emscriptenContract, instantiateEmscripten, runApp, mountApp,
    HaxeonExit};
})();
