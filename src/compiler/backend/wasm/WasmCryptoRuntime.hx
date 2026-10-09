package compiler.backend.wasm;

import compiler.ir.Ir.IrProgram;
import compiler.backend.wasm.WasmModule.WasmModule;

/** Object-model-neutral C kernels linked through the existing C ABI, on both browser backends. */
class WasmCryptoRuntime {
  public static inline var LIBRARY = "haxeon_crypto";
  static var runtime:Null<haxe.io.Bytes>;

  public static function link(module:WasmModule, functions:Map<String, Int>, program:IrProgram, used:Map<String, Bool>):Void {
    var needed = [for (native in program.cNatives) if (native.library == LIBRARY && used.exists(native.name)) native];
    if (needed.length == 0) return;
    if (runtime == null) runtime = sys.io.File.getBytes("stdlib/haxeon/wasm/crypto-runtime.wasm");
    var exports = WasmRuntimeLinker.link(module, runtime, name -> { throw 'Unexpected crypto guest import "$name"'; return 0; });
    for (native in needed) {
      var index = exports.get(native.symbol);
      if (index == null) throw 'Unknown built-in crypto kernel "${native.symbol}"';
      var type = module.functionType(index);
      if (native.symbol != "haxeon_sha256" || type.parameters.length != 6 || type.results.length != 0)
        throw 'Invalid crypto kernel signature "${native.symbol}"';
      for (parameter in type.parameters)
        if (parameter != compiler.backend.wasm.WasmTypes.WasmValueType.I32)
          throw 'Invalid crypto kernel argument "${native.symbol}"';
      functions.set(native.name, index);
    }
  }
}
