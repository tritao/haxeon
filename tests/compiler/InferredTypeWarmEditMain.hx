using compiler.compilation.BackendArtifact.BackendArtifacts;

import compiler.CompileOptions;
import compiler.Compiler;
import compiler.abi.PatchPlanner.AbiChange;
import compiler.hl.HlWriter;
import compiler.runtime.CompilerIntrinsics;

/**
 * A warm build after an edit that changes an inferred declaration type gives the bytes of a fresh build of the same sources.
 *
 * An unannotated function's result and an unannotated field's type come from its body or initializer, so an edit there can change
 * the type every reader was typed against, though no annotation changed. The readers live in other modules, which the edit leaves
 * alone: only the compiler's invalidation can find them (step 2.5, `LAZY_DECLARATION_TYPING.md`, "Invalidation").
 */
class InferredTypeWarmEditMain {
	static final libSource =
		"class Lib {
		public static function value() return 1;
		public static function same() return 2;
		public static function annotated():Int return 3;
		public static function scale() return 2;
		public static function count() return 4;
	}";

	static final otherSource = "class Other { public static var x = 1; }";
	static final boxSource = "class Box { public var v = 1; public function new() {} }";
	static final middleSource =
		"class Middle { public static var y = Other.x; public static var a = Lib.annotated(); public static var z = Lib.count(); public static var list = [for (i in 0...2) i * 2]; }";

	static final mainSource =
		"class Main {
		static function main():Int {
			var v = Lib.value();
			var s = Lib.same();
			var y = Middle.y;
			var a = Middle.a;
			var z = Middle.z;
			var list = Middle.list;
			var scaleOf = Lib.scale;
			var g = scaleOf();
			var b = new Box().v;
			Sys.println(Std.string(v) + ' ' + Std.string(s) + ' ' + Std.string(y) + ' ' + Std.string(a) + ' ' + Std.string(g) + ' ' + Std.string(b) + ' ' + Std.string(z) + ' ' + Std.string(list) + ' ' + Std.string(0.5));
			return 0;
		}
	}";

	static function initialSources():Map<String, String>
		return [
			"Lib.hx" => libSource,
			"Other.hx" => otherSource,
			"Middle.hx" => middleSource,
			"Box.hx" => boxSource,
			"Main.hx" => mainSource
		];

	static function main():Void {
		var failures:Array<String> = [];
		edit(failures, "an unannotated function's body changes its result, read from another module",
			files -> files.set("Lib.hx", StringTools.replace(libSource, "value() return 1;", "value() return 1.5;")));
		edit(failures, "an unannotated function's body changes, its result stays the same",
			files -> files.set("Lib.hx", StringTools.replace(libSource, "same() return 2;", "same() return 3;")));
		edit(failures, "a field initialized from another field changes type, read from a third module",
			files -> files.set("Other.hx", "class Other { public static var x = 1.5; }"));
		edit(failures, "the change goes back", files -> {
			files.set("Lib.hx", StringTools.replace(libSource, "value() return 1;", "value() return 1.5;"));
			files.set("Other.hx", "class Other { public static var x = 1.5; }");
		}, files -> {
			files.set("Lib.hx", libSource);
			files.set("Other.hx", otherSource);
		});
		edit(failures, "a field initialized from an annotated function whose result type changes",
			files -> files.set("Lib.hx",
			StringTools.replace(libSource, "annotated():Int return 3;", "annotated():Float return 3.5;")));
		edit(failures, "an unannotated function read as a value changes its result",
			files -> files.set("Lib.hx", StringTools.replace(libSource, "scale() return 2;", "scale() return 2.5;")));
		edit(failures, "an instance field's initializer changes its type",
			files -> files.set("Box.hx", StringTools.replace(boxSource, "v = 1;", "v = 1.5;")));
		edit(failures, "a field initialized from an unannotated function whose body changes its result",
			files -> files.set("Lib.hx", StringTools.replace(libSource, "count() return 4;", "count() return 4.5;")));
		edit(failures, "a comprehension field's element type changes",
			files -> files.set("Middle.hx", StringTools.replace(middleSource, "i * 2]", "i * 0.5]")));
		breakThenFix(failures, "an edit makes two fields need each other's type, the next removes the cycle",
			files -> files.set("Other.hx", "class Other { public static var x = Middle.y + 1; }"),
			files -> files.set("Other.hx", "class Other { public static var x = 1.5; }"));
		breakThenFix(failures, "an edit breaks an unannotated field, the next fixes it with another type",
			files -> files.set("Other.hx", "class Other { public static var x = missing; }"),
			files -> files.set("Other.hx", "class Other { public static var x = 1.5; }"));
		breakThenFix(failures, "an edit breaks an unannotated function, the next fixes it with another result type",
			files -> files.set("Lib.hx",
			StringTools.replace(libSource, "value() return 1;", "value() return missing;")),
			files -> files.set("Lib.hx", StringTools.replace(libSource, "value() return 1;", "value() return 1.5;")));
		// Live: an inferred type that changes behaves as if its annotation had been edited.
		live(failures, "live: an inferred result changes", files -> files.set("Lib.hx",
			StringTools.replace(libSource, "value() return 1;", "value() return 1.5;")), null);
		live(failures, "live: an inferred static field type changes",
			files -> files.set("Other.hx", "class Other { public static var x = 1.5; }"),
			GlobalLayoutChanged("Middle.y"));
		live(failures, "live: an inferred instance field type changes",
			files -> files.set("Box.hx", StringTools.replace(boxSource, "v = 1;", "v = 1.5;")),
			ObjectFieldTypeChanged("Box.v"));
		if (failures.length > 0)
			throw failures.join("\n");
		Sys.println("PASS: a warm build after an edit that changes an inferred type equals a fresh one");
	}

	/**
	 * Builds the program, applies `change` (then `again`, if given, as a second warm build) in the same session and builds again; the
	 * warm module must be the fresh one's bytes.
	 */
	static function edit(failures:Array<String>, label:String, change:Map<String, String>->Void,
			?again:Map<String, String>->Void):Void {
		// A command-line build keeps no semantic index, so the readers of a declaration are known only from what typing recorded.
		for (indexSemantics in [true, false])
			editBuilds(failures, label + (indexSemantics ? "" : " (no semantic index)"), change, again, indexSemantics);
	}

	static function editBuilds(failures:Array<String>, label:String, change:Map<String, String>->Void,
			again:Null<Map<String, String>->Void>, indexSemantics:Bool):Void {
		try {
			var files = initialSources(), compiler = newCompiler(files);
			compiler.compile("Main", null, indexSemantics);
			var steps = again == null ? [change] : [change, again];
			for (step in steps) {
				step(files);
				for (path => text in files)
					compiler.update(path, text);
				// A session asked to build again registers its source roots again, which is what makes it build rather than return
				// its last result.
				compiler.addSourceRoot("stdlib");
				var warm = HlWriter.encode(compiler.compile("Main", null, indexSemantics).artifact.hashLink().module)
					.flatten(),
					fresh = HlWriter.encode(newCompiler(files).compile("Main").artifact.hashLink().module).flatten();
				if (warm.compare(fresh) != 0)
					throw 'the warm module differs from a fresh one (${warm.length} and ${fresh.length} bytes)';
			}
		} catch (error:Dynamic) {
			failures.push('$label: ${Std.string(error)}');
		}
	}

	/** `broken` makes the program fail, warm as fresh; `fixed` then gives the fresh build's bytes. */
	static function breakThenFix(failures:Array<String>, label:String, broken:Map<String, String>->Void,
			fixed:Map<String, String>->Void):Void {
		try {
			var files = initialSources(), compiler = newCompiler(files);
			compiler.compile("Main");
			broken(files);
			for (path => text in files)
				compiler.update(path, text);
			compiler.addSourceRoot("stdlib");
			var rejected = try {
				compiler.compile("Main");
				false;
			} catch (_:compiler.core.Diagnostic.CompileError) true;
			if (!rejected)
				throw "the warm build accepts the broken edit";
			fixed(files);
			for (path => text in files)
				compiler.update(path, text);
			compiler.addSourceRoot("stdlib");
			var warm = HlWriter.encode(compiler.compile("Main").artifact.hashLink().module).flatten(),
				fresh = HlWriter.encode(newCompiler(files).compile("Main").artifact.hashLink().module).flatten();
			if (warm.compare(fresh) != 0)
				throw 'the warm module differs from a fresh one (${warm.length} and ${fresh.length} bytes)';
		} catch (error:Dynamic) {
			failures.push('$label: ${Std.string(error)}');
		}
	}

	/**
	 * A live session: the edit patches, with the readers of the changed type among the changed functions, or reloads for `reload`
	 * when the changed type is part of the runtime layout.
	 */
	static function live(failures:Array<String>, label:String, change:Map<String, String>->Void,
			reload:Null<AbiChange>):Void {
		try {
			var files = initialSources(), compiler = newCompiler(files);
			compiler.livePatching = true;
			compiler.compile("Main");
			change(files);
			for (path => text in files)
				compiler.update(path, text);
			var result = compiler.compile("Main");
			if (reload == null) {
				if (result.requiresReload || result.artifact.hashLink().patchBytes == null)
					throw 'expected a patch, got a reload (${result.reloadReasons})';
				if (result.regenerated.indexOf("Main.main") < 0)
					throw 'the reader Main.main was not regenerated: ${result.regenerated}';
			} else {
				var found = false;
				for (reason in result.reloadReasons)
					if (Type.enumEq(reason, reload))
						found = true;
				if (!result.requiresReload || !found)
					throw 'expected a reload for $reload, got ${result.requiresReload ? Std.string(result.reloadReasons) : "a patch"}';
			}
		} catch (error:Dynamic) {
			failures.push('$label: ${Std.string(error)}');
		}
	}

	static function newCompiler(files:Map<String, String>):Compiler {
		var compiler = new Compiler(null, CompilerIntrinsics.configuration());
		compiler.livePatching = false;
		compiler.options = new CompileOptions({checkReuse: true});
		compiler.addSourceRoot("stdlib");
		for (path => text in files)
			compiler.update(path, text);
		return compiler;
	}
}
