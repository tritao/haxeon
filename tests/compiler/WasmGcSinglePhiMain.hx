import compiler.backend.wasm.WasmBackend;
import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.ir.IrVerifier;
class WasmGcSinglePhiMain {
  static function main():Void {
    var root = Sys.getEnv("TMPDIR");
    if (root == null || root == "") throw "TMPDIR is required";
    var temp = new sys.io.Process("mktemp", ["-d", root + "/wasm-gc-phi.XXXXXX"]);
    var dir = StringTools.trim(temp.stdout.readAll().toString());
    var status = temp.exitCode();
    temp.close();
    if (status != 0 || dir == "") throw "Cannot create Wasm phi test directory";
    try {
      loop(dir);
      GcPhiThrowProbe.run(dir);
    } catch (error:Dynamic) {
      cleanup(dir);
      throw error;
    }
    cleanup(dir);
  }
  static function cleanup(dir:String):Void {
    for (name in ["loop.wasm", "throw.wasm"]) {
      var path = dir + "/" + name;
      if (sys.FileSystem.exists(path)) sys.FileSystem.deleteFile(path);
    }
    sys.FileSystem.deleteDirectory(dir);
  }
  static function loop(dir:String) {
    var source:IrType = Function([], I32), target:IrType = Function([], I32), b = new IrBuilder();
    b.argument("receiver", source);
    var entry = b.currentBlock(), zero = b.constInt(0),
      first = b.constInt(1), second = b.constInt(2), header = b.createBlock(), body = b.createBlock(),
      done = b.createBlock(), yes = b.createBlock(), no = b.createBlock(), join = b.createBlock();
    b.jump(header);
    b.select(header);
    var indices:Array<IrPhiInput> = [{block: entry.id, value: zero}], sums:Array<IrPhiInput> = [{
      block: entry.id,
      value: zero
    }], index = b.phi(
      I32,
      indices
    ), sum = b.phi(
      I32,
      sums
    );
    var leftInputs:Array<IrPhiInput> = [{block: entry.id, value: first}], rightInputs:Array<IrPhiInput> = [{
      block: entry.id,
      value: second
    }];
    var left = b.phi(I32, leftInputs), right = b.phi(I32, rightInputs);
    b.branch(b.less(index, b.constInt(3)), body, done);
    b.select(body);
    b.branch(b.less(index, b.constInt(2)), yes, no);
    b.select(yes);
    var one = b.constInt(1);
    b.jump(join);
    b.select(no);
    var other = b.constInt(0);
    b.jump(join);
    b.select(join);
    var chosen = b.phi(I32, [{block: yes.id, value: one}, {block: no.id, value: other}]);
    var next = b.add(index, b.constInt(1)), nextSum = b.add(sum, chosen);
    indices.push({block: join.id, value: next});
    sums.push({block: join.id, value: nextSum});
    leftInputs.push({block: join.id, value: right});
    rightInputs.push({block: join.id, value: left});
    b.jump(header);
    b.select(done);
    b.returnValue(b.add(sum, b.add(b.mul(left, b.constInt(10)), right)));
    var callee = new IrBuilder();
    callee.returnValue(callee.constInt(9));
    var main = new IrBuilder(), c = main.staticClosure("callee", source);
    main.returnValue(main.call("probe", [c], I32));
    var p = new IrProgram("main");
    p.functions = [
      new IrFunction("main", main.arguments, I32, main.blocks, Ordinary),
      new IrFunction("callee", callee.arguments, I32, callee.blocks, Ordinary),
      new IrFunction("probe", b.arguments, I32, b.blocks, ClosureAdapter(source, target))
    ];
    IrVerifier.verify(p);
    var path = dir + "/loop.wasm";
    sys.io.File.saveBytes(path, new WasmBackend().compile(p, {target: WasmGc, debugNames: true}).bytes);
    var js =
      'let e=new WebAssembly.Instance(new WebAssembly.Module(require("fs").readFileSync(process.argv[1]))).exports;if(e.main()!==23)throw Error("bad loop result")';
    var code = Sys.command("node", ["-e", js, path]);
    sys.FileSystem.deleteFile(path);
    if (code != 0) throw "bad loop";
    Sys.println("PASS: CFG constant diamond in loop");
  }
}

class GcPhiThrowProbe {
  public static function run(dir:String) {
    for (mode in 0...3) for (raw in [0, 2]) for (extraPath in [false, true]) {
      var source:IrType = Function([], I32), target:IrType = Function([Bool], I32), b = new IrBuilder();
      b.argument("receiver", source);
      var condition = b.argument("condition", Bool);
      var extra = b.argument("extra", Bool);
      var yes = b.createBlock(), no = b.createBlock(), join = b.createBlock(), split = b.createBlock(),
        handler = b.createBlock(), after = b.createBlock(), throwBlock = b.createBlock(), diamond = b.createBlock();
      var where = compiler.ir.SourceProvenance.generated("phi-exception");
      b.currentBlock().instructions.push(new compiler.ir.SourceProvenance.Located(
        BeginTry(handler.id, after.id, false),
        where
      ));
      b.jump(split);
      b.select(split);
      b.branch(extra, throwBlock, diamond);
      b.select(throwBlock);
      b.throwValue(b.toDyn(b.constInt(17)));
      b.select(diamond);
      b.branch(condition, yes, no);
      b.select(yes);
      var y = b.constInt(mode == 1 ? 0 : mode == 2 ? 5 : 1);
      b.jump(join);
      b.select(no);
      var n = b.constInt(mode == 1 ? 1 : mode == 2 ? 9 : 0);
      b.jump(join);
      b.select(join);
      var value = b.phi(I32, [{block: yes.id, value: y}, {block: no.id, value: n}]);
      join.instructions.push(new compiler.ir.SourceProvenance.Located(EndTry(handler.id, false), where));
      b.jump(after);
      b.select(handler);
      handler.instructions.push(new compiler.ir.SourceProvenance.Located(
        Catch(new IrValue(1000000, "caught", Dyn)),
        where
      ));
      b.returnValue(b.constInt(99));
      b.select(after);
      b.returnValue(value);
      var main = new IrBuilder();
      var chosen = raw != 0, rawBool = main.argument("raw", Bool);
      var c = main.staticClosure("callee", source), result = main.call(
        "probe",
        [c, rawBool, main.constBool(extraPath)],
        I32
      );
      main.returnValue(result);
      var callee = new IrBuilder();
      callee.returnValue(callee.constInt(7));
      var p = new IrProgram("main");
      p.functions = [
        new IrFunction("main", main.arguments, I32, main.blocks, Ordinary),
        new IrFunction("callee", callee.arguments, I32, callee.blocks, Ordinary),
        new IrFunction("probe", b.arguments, I32, b.blocks, ClosureAdapter(source, target))
      ];
      IrVerifier.verify(p);
      var path = dir + "/throw.wasm";
      sys.io.File.saveBytes(path, new WasmBackend().compile(p, {target: WasmGc, debugNames: true}).bytes);
      var expected = extraPath
        ? 99 : chosen ? (mode == 1 ? 0 : mode == 2 ? 5 : 1) : (mode == 1 ? 1 : mode == 2 ? 9 : 0);
      var js =
        'let e=new WebAssembly.Instance(new WebAssembly.Module(require("fs").readFileSync(process.argv[1]))).exports;let x=e.main(Number(process.argv[3]));if(x!==Number(process.argv[2])) throw Error("actual="+x+" expected="+process.argv[2]);';
      var code = Sys.command("node", ["-e", js, path, Std.string(expected), Std.string(raw)]);
      sys.FileSystem.deleteFile(path);
      if (code != 0) throw 'mode=$mode chosen=$chosen';
    }
    Sys.println("PASS: constant diamonds and thrown exception");
  }
}
