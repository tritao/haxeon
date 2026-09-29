import compiler.Compiler;
import compiler.hl.HlWriter;
import compiler.runtime.CompilerIntrinsics;
import sys.io.File;

/** Builds a native fixture for compiler-generated structural equality. */
class EqualityMain {
	static function main():Void {
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addSourceRoot("stdlib");
		compiler.update("Main.hx", 'import haxeon.Equality;
typedef Point = { x:Float, y:Float };
enum Motion { Stopped; Steps(values:Array<Int>); }
enum Box<T> { Wrap(value:T); }
enum Chain { End; Link(value:Int, next:Null<Chain>); }
abstract Millimetres(Float) from Float to Float { public inline function new(value:Float) this = value; }
typedef Sample = { label:String, point:Point, motions:Array<Motion>, weights:Map<String, Int> };
typedef Maybe = { @:optional note:String; };
typedef StrictArray = { values:Array<Int>; };
class Base { public function new() {} }
class Derived extends Base { public function new() { super(); } }
function main():Int {
  var first:Sample = { label: "arm", point: { x: 1.0, y: 2.0 }, motions: [Steps([3, 4]), Stopped], weights: ["a" => 1, "b" => 2] };
  var second:Sample = { label: "arm", point: { x: 1.0, y: 2.0 }, motions: [Steps([3, 4]), Stopped], weights: ["b" => 2, "a" => 1] };
  if (!Equality.equals(first, second)) return 1;
  second.point.y = 5.0;
  if (Equality.equals(first, second)) return 2;
  second.point.y = 2.0;
  second.motions = [Steps([3, 5]), Stopped];
  if (Equality.equals(first, second)) return 3;
  second.motions = [Steps([3, 4]), Stopped];
  second.weights.set("b", 9);
  if (Equality.equals(first, second)) return 4;
  if (Equality.equals(Math.NaN, Math.NaN)) return 5;
  if (!Equality.equals(0.0, -0.0)) return 6;
  var left:Null<Array<Int>> = null;
  var right:Null<Array<Int>> = null;
  if (!Equality.equals(left, right)) return 7;
  right = [1];
  if (Equality.equals(left, right)) return 8;
  var absentLeft:Maybe = {};
  var absentRight:Maybe = {};
  if (!Equality.equals(absentLeft, absentRight)) return 9;
  absentRight.note = "ready";
  if (Equality.equals(absentLeft, absentRight)) return 10;
  var boxLeft:Box<Array<Int>> = Wrap([1, 2]);
  var boxRight:Box<Array<Int>> = Wrap([1, 2]);
  if (!Equality.equals(boxLeft, boxRight)) return 11;
  var chainLeft:Chain = Link(1, Link(2, End));
  var chainRight:Chain = Link(1, Link(2, End));
  if (!Equality.equals(chainLeft, chainRight)) return 12;
  if (Equality.equals([1, 2], [1])) return 13;
  var bytesLeft = haxe.io.Bytes.ofString("abc");
  var bytesRight = haxe.io.Bytes.ofString("abc");
  if (!Equality.equals(bytesLeft, bytesRight)) return 14;
  var distanceLeft = new Millimetres(12.5);
  var distanceRight = new Millimetres(12.5);
  if (!Equality.equals(distanceLeft, distanceRight)) return 15;
  var strictLeft:StrictArray = { values: null };
  var strictRight:StrictArray = { values: null };
  if (!Equality.equals(strictLeft, strictRight)) return 16;
  strictRight.values = [1];
  if (Equality.equals(strictLeft, strictRight)) return 17;
  if (!Std.isExactType(new Base(), Base)) return 18;
  if (Std.isExactType(new Derived(), Base)) return 19;
  if (!Std.isExactType(new Derived(), Derived)) return 20;
  return 42;
}');
		File.saveBytes(Sys.args()[0], HlWriter.encode(compiler.compile("Main").module));
	}
}
