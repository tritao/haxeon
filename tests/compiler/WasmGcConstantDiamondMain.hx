import compiler.backend.wasm.WasmBackend;
import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.ir.IrVerifier;

/** Constant diamonds preserve Boolean normalization and extra-predecessor fallback. */
class WasmGcConstantDiamondMain {
  static function main():Void {
    var root = Sys.getEnv("TMPDIR");
    if (root == null || root == "") throw "TMPDIR is required";
    var temp = new sys.io.Process("mktemp", ["-d", root + "/wasm-gc-diamond.XXXXXX"]);
    var dir = StringTools.trim(temp.stdout.readAll().toString()), status = temp.exitCode();
    temp.close();
    if (status != 0 || dir == "") throw "Cannot create diamond test directory";
    var path = dir + "/test.wasm";
    try {
      for (extra in [false, true]) for (mode in 0...3) check(path, extra, mode);
    } catch (error:Dynamic) {
      if (sys.FileSystem.exists(path)) sys.FileSystem.deleteFile(path);
      sys.FileSystem.deleteDirectory(dir);
      throw error;
    }
    if (sys.FileSystem.exists(path)) sys.FileSystem.deleteFile(path);
    sys.FileSystem.deleteDirectory(dir);
    Sys.println("PASS: Wasm GC constant diamonds and extra-predecessor fallback");
  }

  static function check(path:String, extra:Bool, mode:Int):Void {
    var b = new IrBuilder();
    var condition = b.argument("condition", Bool), bypass = b.argument("bypass", Bool);
    var yes = b.createBlock(), no = b.createBlock(), join = b.createBlock();
    var extraBlock = extra ? b.createBlock() : null;
    if (extra) {
      var split = b.createBlock();
      b.branch(bypass, extraBlock, split);
      b.select(split);
    }
    b.branch(condition, yes, no);
    b.select(yes);
    var trueValue = mode == 1 ? 0 : mode == 2 ? 5 : 1, y = b.constInt(trueValue);
    b.jump(join);
    b.select(no);
    var falseValue = mode == 1 ? 1 : mode == 2 ? 9 : 0, n = b.constInt(falseValue);
    b.jump(join);
    var inputs:Array<IrPhiInput> = [{block: yes.id, value: y}, {block: no.id, value: n}];
    if (extra) {
      b.select(extraBlock);
      var e = b.constInt(13);
      b.jump(join);
      inputs.push({block: extraBlock.id, value: e});
    }
    b.select(join);
    b.returnValue(b.phi(I32, inputs));
    var p = new IrProgram("main");
    p.functions = [new IrFunction("main", b.arguments, I32, b.blocks, Ordinary)];
    IrVerifier.verify(p);
    sys.io.File.saveBytes(path, new WasmBackend().compile(p, {target: WasmGc, debugNames: true}).bytes);
    var js =
      'let e=new WebAssembly.Instance(new WebAssembly.Module(require("fs").readFileSync(process.argv[1]))).exports;'
      + 'for(let x of [0,1,2,-1])for(let bypass of [0,1]){'
      + 'let expected=(Number(process.argv[2])&&bypass)?13:(x?Number(process.argv[3]):Number(process.argv[4]));'
      + 'let got=e.main(x,bypass);if(got!==expected)throw Error("actual="+got+" expected="+expected)}';
    if (Sys.command("node", ["-e", js, path, extra ? "1" : "0",
      Std.string(trueValue), Std.string(falseValue)]) != 0) throw 'constant diamond failed: extra=$extra mode=$mode';
  }
}
