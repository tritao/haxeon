import compiler.Compiler;
import compiler.Diagnostic.CompileError;
import compiler.hl.HlWriter;
import compiler.runtime.CompilerIntrinsics;
import sys.io.File;

/** Exercises metadata-driven arithmetic and comparisons on numeric abstracts. */
class AbstractOperatorsMain {
	static function main():Void {
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addSourceRoot("stdlib");
		compiler.update("Main.hx", 'abstract Millimetres(Float) from Float to Float {
  public inline function new(value:Float) this = value;
  @:op(A + B) public static function add(a:Millimetres, b:Millimetres):Millimetres return new Millimetres((a : Float) + (b : Float));
  @:op(A - B) public static function subtract(a:Millimetres, b:Millimetres):Millimetres return new Millimetres((a : Float) - (b : Float));
  @:op(A * B) public static function scale(a:Millimetres, factor:Float):Millimetres return new Millimetres((a : Float) * factor);
  @:op(A / B) public static function divide(a:Millimetres, factor:Float):Millimetres return new Millimetres((a : Float) / factor);
  @:op(-A) public static function negate(a:Millimetres):Millimetres return new Millimetres(-(a : Float));
  @:op(A < B) public static function less(a:Millimetres, b:Millimetres):Bool return (a : Float) < (b : Float);
  @:op(A <= B) public static function lessEqual(a:Millimetres, b:Millimetres):Bool return (a : Float) <= (b : Float);
  @:op(A > B) public static function greater(a:Millimetres, b:Millimetres):Bool return (a : Float) > (b : Float);
  @:op(A >= B) public static function greaterEqual(a:Millimetres, b:Millimetres):Bool return (a : Float) >= (b : Float);
  @:op(A == B) public static function equal(a:Millimetres, b:Millimetres):Bool return (a : Float) == (b : Float);
  @:op(A != B) public static function unequal(a:Millimetres, b:Millimetres):Bool return (a : Float) != (b : Float);
}
abstract Count(Int) from Int to Int {
  public inline function new(value:Int) this = value;
  @:op(A + B) public static function add(a:Count, b:Count):Count return new Count((a : Int) + (b : Int));
  @:op(-A) public static function negate(a:Count):Count return new Count(-(a : Int));
  @:op(A < B) public static function less(a:Count, b:Count):Bool return (a : Int) < (b : Int);
}
function main():Int {
  var a = new Millimetres(3.0);
  var b = new Millimetres(2.0);
  if (((a + b) : Float) != 5.0 || ((a - b) : Float) != 1.0) return 1;
  if (((a * 4.0) : Float) != 12.0 || ((a / 2.0) : Float) != 1.5) return 2;
  if (((-a) : Float) != -3.0) return 3;
  if (!(b < a) || !(b <= a) || !(a > b) || !(a >= b)) return 4;
  if (!(a == a) || !(a != b)) return 5;
  var x = new Count(20);
  var y = new Count(22);
  if (((x + y) : Int) != 42 || ((-x) : Int) != -20 || !(x < y)) return 6;
  return 42;
}');
		File.saveBytes(Sys.args()[0], HlWriter.encode(compiler.compile("Main").module));
		rejectBadComparison();
		rejectAmbiguousOperator();
	}

	static function rejectBadComparison():Void {
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.update("Main.hx",
			'abstract Value(Int) { public inline function new(value:Int) this = value; @:op(A < B) public static function less(a:Value, b:Value):Int return 1; } function main():Int return new Value(1) < new Value(2) ? 42 : 0;');
		try {
			compiler.compile("Main");
			throw "comparison operator with Int result was accepted";
		} catch (error:CompileError) {
			if (error.diagnostic.message != 'Abstract comparison operator "<" must return Bool')
				throw error;
		}
	}

	static function rejectAmbiguousOperator():Void {
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.update("Main.hx",
			'abstract First(Int) { public inline function new(value:Int) this = value; @:op(A + B) public static function add(a:First, b:Second):Int return 1; } abstract Second(Int) { public inline function new(value:Int) this = value; @:op(A + B) public static function add(a:First, b:Second):Int return 2; } function main():Int return new First(1) + new Second(2);');
		try {
			compiler.compile("Main");
			throw "ambiguous abstract operator was accepted";
		} catch (error:CompileError) {
			if (error.diagnostic.message != 'Ambiguous abstract operator "+" between "First.add" and "Second.add"')
				throw error;
		}
	}
}
