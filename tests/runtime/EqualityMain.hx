import compiler.Compiler;
import compiler.hl.HlWriter;
import compiler.runtime.CompilerIntrinsics;
import sys.io.File;

/** Builds a native fixture for equality selected by declared conformance. */
class EqualityMain {
	static function main():Void {
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addStandardLibrarySourceRoot("stdlib");
		compiler.update("Main.hx", 'import haxeon.Equality;
import haxeon.Hashing;
struct Point implements Hashable {
  public var x:Float;
  public var y:Float;
  public function new(x:Float, y:Float) { this.x = x; this.y = y; }
}
struct Record implements Equatable {
  public var label:String;
  public var point:Point;
  public function new(label:String, point:Point) { this.label = label; this.point = point; }
}
class Identity { public function new() {} }
enum Box<T> { Wrap(value:T); Empty; }
function main():Int {
  var first = new Record("arm", new Point(1.0, 2.0));
  var second = new Record("arm", new Point(1.0, 2.0));
  if (!Equality.equals(first, second) || first != second) return 1;
  second.point.y = 5.0;
  if (Equality.equals(first, second) || first == second) return 2;
  if (Equality.equals(Math.NaN, Math.NaN)) return 3;
  if (!Equality.equals(0.0, -0.0)) return 4;
  var absentLeft:Null<Record> = null;
  var absentRight:Null<Record> = null;
  if (!Equality.equals(absentLeft, absentRight)) return 5;
  absentRight = new Record("ready", new Point(1.0, 2.0));
  if (Equality.equals(absentLeft, absentRight)) return 6;
  var plainLeft = new Identity();
  var plainRight = new Identity();
  if (Equality.equals(plainLeft, plainRight) || !Equality.equals(plainLeft, plainLeft)) return 7;
  var dynamicLeft:Dynamic = [1, 2];
  var dynamicRight:Dynamic = [1, 2];
  if (Equality.equals(dynamicLeft, dynamicRight)) return 8;
  if (!Type.enumEq(Wrap(2), Wrap(2))) return 9;
  var map = new Map<Point, String>();
  map.set(new Point(4.0, 5.0), "point");
  if (map.get(new Point(4.0, 5.0)) != "point") return 10;
  if (Hashing.hash(new Point(0.0, 2.0)) != Hashing.hash(new Point(-0.0, 2.0))) return 11;
  return 42;
}');
		File.saveBytes(Sys.args()[0], HlWriter.encode(compiler.compile("Main").module).flatten());
	}
}
