import compiler.backend.wasm.WasmBackend;
import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;

/** Dynamic null checks keep both equality semantics and host-reference traps. */
class WasmGcDynamicNullMain {
  static function main():Void {
    var root = Sys.getEnv("TMPDIR");
    if (root == null || root == "") throw "TMPDIR is required";
    var temp = new sys.io.Process("mktemp", ["-d", root + "/wasm-gc-null.XXXXXX"]),
      dir = StringTools.trim(temp.stdout.readAll().toString()), status = temp.exitCode();
    temp.close();
    if (status != 0 || dir == "") throw "Cannot create Wasm null test directory";
    var path = dir + "/test.wasm";
    try {
      for (nullFirst in [false, true]) {
        var builder = new IrBuilder(), value = builder.argument("value", Dyn), nil = builder.constNull(Dyn);
        builder.returnValue(nullFirst ? builder.equal(nil, value) : builder.equal(value, nil));
        var program = new IrProgram("main");
        program.functions = [new IrFunction("main", builder.arguments, Bool, builder.blocks, Ordinary)];
        sys.io.File.saveBytes(path, new WasmBackend().compile(program, {target: WasmGc, debugNames: true}).bytes);
        var js =
          'let e=new WebAssembly.Instance(new WebAssembly.Module(require("fs").readFileSync(process.argv[1]))).exports;'
          + 'if(e.main(null)!==1||e.main(42)!==0)throw Error("wrong null result");'
          + 'for(let v of [{},"x"]){let trapped=false;try{e.main(v)}catch(e){if(e instanceof WebAssembly.RuntimeError)trapped=true;else throw e}if(!trapped)throw Error("host trap removed")}';
        if (Sys.command("node", ["-e", js, path]) != 0) throw "Wasm GC Dynamic null comparison changed behavior";
      }
    } catch (error:Dynamic) {
      if (sys.FileSystem.exists(path)) sys.FileSystem.deleteFile(path);
      sys.FileSystem.deleteDirectory(dir);
      throw error;
    }
    if (sys.FileSystem.exists(path)) sys.FileSystem.deleteFile(path);
    sys.FileSystem.deleteDirectory(dir);
    Sys.println("PASS: Wasm GC Dynamic null comparisons preserve host traps");
  }
}
