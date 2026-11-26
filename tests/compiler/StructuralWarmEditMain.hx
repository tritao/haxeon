using compiler.compilation.BackendArtifact.BackendArtifacts;

import compiler.Compiler;
import compiler.runtime.CompilerIntrinsics;

/**
 * A warm build after a typedef, enum or abstract changes shape gives the bytes of a fresh build of the same sources.
 *
 * The edited declaration lives in its own module, and the classes that use it are in modules the edit leaves alone: their fields,
 * signatures and bodies name the type, so the edit changes their layout or their lowering without changing their text. Only the
 * compiler's own invalidation can find them; no session resets on a shape edit.
 */
class StructuralWarmEditMain {
	static final shapeSource = "typedef Shape = { var x:Int; }";
	static final numberSource = "typedef Number = Int;";
	static final colorSource = "enum Color { Red; Green; }";
	static final pairSource = "typedef Pair = Shape;";
	static final meterSource =
		"abstract Meters(Int) from Int { public inline function new(value:Int) this = value; public function toInt():Int return this; }";
	static final modeSource = "enum abstract Mode(Int) to Int { var Fast = 1; var Slow = 2; }";

	static final holderSource =
		"class Holder {
		public var shapes:Array<Shape> = [];
		public var number:Number;
		public var distance:Meters;
		public var pair:Pair;
		public function new() { number = 2; distance = 5; shapes.push({x: 3}); pair = {x: 4}; }
		public function first():Shape return shapes[0];
		public function total():Int return Std.int(number) + Std.int(shapes[0].x) + distance.toInt() + Std.int(pair.x);
	}";

	static final paintSource =
		"class Paint {
		public static function code(color:Color):Int return switch color { case Red: 1; case _: 2; };
		public static function pick():Color return Green;
		public static function speed(mode:Mode):Int return mode;
	}";

	static final mainSource =
		"class Main {
		static function main():Int {
			var holder = new Holder();
			return holder.total() + Std.int(holder.first().x) + Paint.code(Paint.pick()) + Paint.speed(Fast);
		}
	}";

	static function initialSources():Map<String, String>
		return [
			"Shape.hx" => shapeSource,
			"Number.hx" => numberSource,
			"Color.hx" => colorSource,
			"Pair.hx" => pairSource,
			"Meters.hx" => meterSource,
			"Mode.hx" => modeSource,
			"Holder.hx" => holderSource,
			"Paint.hx" => paintSource,
			"Main.hx" => mainSource
		];

	static function main():Void {
		var failures:Array<String> = [];
		edit(failures, "a typedef gains a field",
			files -> files.set("Shape.hx", "typedef Shape = { var x:Int; @:optional var y:Int; }"));
		edit(failures, "a typedef field changes type",
			files -> files.set("Shape.hx", "typedef Shape = { var x:Float; }"));
		edit(failures, "a typedef names another type", files -> files.set("Number.hx", "typedef Number = Float;"));
		edit(failures, "a typedef that another typedef names changes shape",
			files -> files.set("Shape.hx", "typedef Shape = { var x:Int; var ?z:String; }"));
		edit(failures, "an enum gains a case", files -> files.set("Color.hx", "enum Color { Blue; Red; Green; }"));
		edit(failures, "an enum case gains an argument",
			files -> {
				files.set("Color.hx", "enum Color { Red; Green(shade:Int); }");
				files.set("Paint.hx", StringTools.replace(paintSource, "return Green;", "return Green(4);"));
			});
		edit(failures, "an abstract changes its underlying type",
			files -> files.set("Meters.hx",
			"abstract Meters(Float) from Int { public inline function new(value:Int) this = value; public function toInt():Int return Std.int(this); }"));
		edit(failures, "an enum abstract changes a value",
			files -> files.set("Mode.hx", "enum abstract Mode(Int) to Int { var Fast = 7; var Slow = 2; }"));
		reject(failures, "a typedef loses the field an unchanged class reads",
			files -> files.set("Shape.hx", "typedef Shape = { var y:Int; }"));
		reject(failures, "an enum loses the case an unchanged class names",
			files -> files.set("Color.hx", "enum Color { Red; }"));
		reject(failures, "an abstract loses the conversion an unchanged class relies on",
			files -> files.set("Meters.hx", StringTools.replace(meterSource, " from Int", "")));
		if (failures.length > 0)
			throw failures.join("\n");
		Sys.println("PASS: a warm build after a typedef, enum or abstract shape edit equals a fresh one");
	}

	/** Builds the program, applies `change` in the same session and builds again; the warm module must be the fresh one's bytes. */
	static function edit(failures:Array<String>, label:String, change:Map<String, String>->Void):Void {
		try {
			var files = initialSources(), compiler = newCompiler(files);
			compiler.compile("Main");
			change(files);
			for (path => text in files)
				compiler.update(path, text);
			// A session asked to build again registers its source roots again, which is what makes it build rather than return its
			// last result.
			compiler.addSourceRoot("stdlib");
			var warm = compiler.compile("Main").artifact.hashLink().hashLinkBytes().flatten(),
				fresh = newCompiler(files).compile("Main").artifact.hashLink().hashLinkBytes().flatten();
			if (warm.compare(fresh) != 0)
				throw 'the warm module differs from a fresh one (${warm.length} and ${fresh.length} bytes)';
		} catch (error:Dynamic) {
			failures.push('$label: ${Std.string(error)}');
		}
	}

	/** An edit that breaks a class it leaves alone: the warm build must report the error a fresh build reports. */
	static function reject(failures:Array<String>, label:String, change:Map<String, String>->Void):Void {
		try {
			var files = initialSources(), compiler = newCompiler(files);
			compiler.compile("Main");
			change(files);
			for (path => text in files)
				compiler.update(path, text);
			compiler.addSourceRoot("stdlib");
			var warm = failure(() -> compiler.compile("Main")),
				fresh = failure(() -> newCompiler(files).compile("Main"));
			if (fresh == null)
				throw "a fresh build accepts the edit";
			if (warm != fresh)
				throw 'the warm build reports ${warm == null ? "no error" : '"$warm"'} where a fresh one reports "$fresh"';
		} catch (error:Dynamic) {
			failures.push('$label: ${Std.string(error)}');
		}
	}

	static function failure(build:() -> Dynamic):Null<String> {
		try
			build()
		catch (error:compiler.core.Diagnostic.CompileError)
			return Std.string(error);
		return null;
	}

	static function newCompiler(files:Map<String, String>):Compiler {
		var compiler = new Compiler(null, CompilerIntrinsics.configuration());
		compiler.livePatching = false;
		compiler.addSourceRoot("stdlib");
		for (path => text in files)
			compiler.update(path, text);
		return compiler;
	}
}
