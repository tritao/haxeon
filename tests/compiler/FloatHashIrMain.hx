import compiler.Frontend;
import compiler.Compiler;
import compiler.runtime.CompilerIntrinsics;
import compiler.ir.IrInterpreter;

/** The reference interpreter and generated code use the same Float value hash. */
class FloatHashIrMain {
  static function main():Void {
    var source = 'interface Equatable {} interface Hashable extends Equatable {} '
      + 'struct Key implements Hashable { public final value:Float; public function new(value:Float) this.value=value; } '
      + 'function hash(value:Float):Int return haxeon.Hashing.hash(value); '
      + 'function main():Int { var a=new Key(1e100); var b=new Key(1e100); '
      + 'var z=new Key(0.0); var nz=new Key(-0.0); '
      + 'return haxeon.Hashing.hash(a)==haxeon.Hashing.hash(b) && haxeon.Hashing.hash(z)==haxeon.Hashing.hash(nz) '
      + '&& haxeon.Hashing.hash(1.5)==0x3ff80000 && haxeon.Hashing.hash(-1.5)==0xbff80000 ? 42 : 1; }';
    var interpreted = new IrInterpreter(Frontend.compile(source));
    if (interpreted.run("main") != 42) throw "Float hash differs in the IR interpreter";
    var positiveInfinity = haxe.io.FPHelper.i64ToDouble(0, 0x7ff00000);
    var negativeInfinity = haxe.io.FPHelper.i64ToDouble(0, 0xfff00000);
    var negativeNaN = haxe.io.FPHelper.i64ToDouble(1, 0xfff80000);
    if (interpreted.run("hash", [positiveInfinity]) != 2146435072
      || interpreted.run("hash", [negativeInfinity]) != -1048576
      || interpreted.run("hash", [negativeNaN]) != 0x7ff80000
      || interpreted.run("hash", [-0.0]) != 0) throw "IR Float hashing mishandled an IEEE edge value";
    var compiler = new Compiler(null, CompilerIntrinsics.configuration());
    compiler.addSourceRoot("stdlib");
    compiler.update("Other.hx", "class Other { public static function code():Int return 42; }");
    compiler.update("Main.hx", "function main():Int return Other.code();");
    if (GeneratedProgramRunner.exitCode(compiler.compile("Main")) != 42) throw "initial incremental program failed";
    compiler.update("Main.hx", 'import haxeon.Hashing; struct Key implements Hashable { public final value:Float; '
      + 'public function new(value:Float) this.value=value; } function main():Int '
      + 'return Hashing.hash(new Key(Math.POSITIVE_INFINITY)) == Hashing.hash(new Key(Math.POSITIVE_INFINITY)) ? Other.code() : 1;');
    if (GeneratedProgramRunner.exitCode(compiler.compile("Main")) != 42) throw "incremental Float hash did not load bit intrinsics";
    compiler.update("Other.hx", "class Other { public static function code():Int return 41; }");
    if (GeneratedProgramRunner.exitCode(compiler.compile("Main")) != 41) throw "cached Float hash lost its bit intrinsics";
    Sys.println("PASS: Float hashes work in the IR interpreter and incremental compilation");
  }
}
