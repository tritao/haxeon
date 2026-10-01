import compiler.hl.HlWriter;
import compiler.Compiler;
import sys.io.File;

/**
 * A type named only as a cast's target loads its module, even when nothing else references it and
 * the casting module imports others; a cast to `Dynamic` or a type parameter names no module.
 */
class CastTypeMain {
	static final SHAPE = "package app; class Shape { public function new() {} public function size():Int return 0; }";
	static final CIRCLE = "package app; class Circle extends Shape { public function new() super(); override public function size():Int return 42; }";
	static final MEASURE = "package app; import app.Shape; class Measure { public static function of(shape:Shape):Int { var circle = (cast shape:Circle); var loose:Dynamic = (cast shape:Dynamic); return circle == null ? same(42) : circle.size() - 1; } static function same<T>(value:T):T return (cast value:T); }";
	static final MAIN = "package app; function main():Int return Measure.of(null);";

	static function main():Void {
		var compiler = new Compiler();
		compiler.update("app/Shape.hx", SHAPE);
		compiler.update("app/Circle.hx", CIRCLE);
		compiler.update("app/Measure.hx", MEASURE);
		compiler.update("app/Main.hx", MAIN);
		var result = compiler.compile("app.Main");
		File.saveBytes(Sys.args()[0], HlWriter.encode(result.module));
	}
}
