using compiler.compilation.BackendArtifact.BackendArtifacts;
import compiler.CompileOptions;
import compiler.Compiler;
import compiler.Compiler.CompileResult;
import compiler.hl.HlWriter;
import compiler.runtime.CompilerIntrinsics;
import compiler.semantic.DeclarationFacts.FactAspect;

/**
 * A plain build in a reused compiler session gives the bytes of a fresh build of the same sources, and when nothing the IR pipeline
 * reads changed it does so without running a pass or lowering a function (`metrics.reuse`).
 *
 * The program has a generic class (`Box`), an enum (`Shape`), an enum abstract (`Level`), a library module and a user of them. Every scenario compiles it once,
 * applies an edit in the same session, compiles again, and compares the module with a fresh compiler's. An edit that changes the
 * program must not report a reused module; a build with no edit must. A compile that checks its reuse also assembles the reused result again
 * and compared inside the compiler, which throws on a difference.
 */
class WarmRebuildReuseMain {
	static final boxSource =
		"class Box<T> { public var value:T; public var spare:Int; public function new(value:T) this.value = value; public function get():T return value; }";
	static final shapeSource = "enum Shape { Circle(radius:Int); Square(side:Int); }";
	static final levelSource = "enum abstract Level(Int) to Int { var Low = 1; var High = 2; }";

	/** `step` is recursive so it is not inlined into `of` or `main`: a function nothing reaches is not in the module, and the scenarios below edit functions that are. */
	static final areaSource =
		"class Area { public static function of(shape:Shape):Int return step(shape, 0); static function step(shape:Shape, n:Int):Int return n > 0 ? step(shape, n - 1) : switch shape { case Circle(radius): 3 * radius * radius; case Square(side): side * side; }; }";

	static final libSource =
		"class Lib { public static function add(a:Int, b:Int):Int return a + b; public static function name():String return \"lib\"; public static function boxed():Int return new Box<Int>(3).get(); }";

	/**
	 * Field initializers register anonymous types (`{}`) when they are typed, which a warm build does not do again for an unchanged
	 * class. A static initializer is the only caller of a specialization (`Ops.first` for `Float`), which a warm build that keeps the
	 * class keeps with it.
	 */
	static final configSource =
		"class Config { public static var empty:Dynamic = {}; public static var ratio:Float = Ops.first([0.5]); public var data:Dynamic = {a: 1}; public function new() {} }";

	/** An anonymous type that only an optional parameter's element type names, which no body constructs. */
	static final encoderSource =
		"class Encoder { public static function encode(value:Int, ?sections:Array<{tag:Int, name:String}>):Int return sections == null ? value : value + sections.length; }";

	/**
	 * An abstract member nothing calls is typed to be checked, and the structural iterator it returns is not part of the program:
	 * a warm build that does not check it again lists the anonymous types a fresh one does.
	 */
	static final trailSource =
		"enum Step { Walk(n:Int); Stop; } abstract Trail(Array<Step>) from Array<Step> { public static function size(steps:Array<Step>):Int return steps.length; public function iterator():Iterator<Step> return this.iterator(); }";

	/**
	 * Bodies another module reads: an inline function expands in its caller, with the private functions it calls, and a generic
	 * function is specialized for its caller. Editing only a private helper behind them must change the caller as a fresh build does.
	 */
	static final opsSource =
		"class Ops { public static inline function twice(x:Int):Int return step(x) * 2 + bump(x); static inline function step(x:Int):Int return x + 1; static function bump(x:Int):Int return x + 3; public static function first<T>(xs:Array<T>):T return pick(xs); static function pick<T>(xs:Array<T>):T return xs[0]; }";

	/** The only caller of a specialization (`Ops.first` for `Array<Int>`), in a module that can leave the program and come back. */
	static final pairsSource = "class Pairs { public static function count():Int return Ops.first([[1, 2]]).length; }";

	/**
	 * Interfaces that become classes (`Source`, a type of the module `Pass`): a reader that only holds a `Source` and passes it on
	 * names the type without reading its members, yet holds it as another representation once it is a class.
	 */
	static final passSource =
		"interface Pass extends Source { function run():Int; } interface Source { function fact(kind:Int):Int; }";

	static final passClassSource =
		"class Pass extends Source { public function run():Int throw \"no run\"; } class Source { public function fact(kind:Int):Int throw \"no fact\"; }";

	static final factsSource =
		"import Pass; class Facts { public static function print(id:Int, source:Source):Int return source.fact(id) + 1; }";

	static final readerSource =
		"import Pass; class Reader { final source:Source; public function new(pass:Null<Pass>, ?given:Source) { var from:Null<Source> = given != null ? given : pass; if (from == null) throw \"no source\"; source = from; } public function read(kind:Int):Int return Facts.print(kind, source); }";

	static final stageSource =
		"import Pass; class Stage implements Pass { public function new() {} public function fact(kind:Int):Int return kind * 2; public function run():Int return new Reader(this).read(3); }";

	static final stageClassSource =
		"import Pass; class Stage extends Pass { public function new() {} override public function fact(kind:Int):Int return kind * 2; override public function run():Int return new Reader(this).read(3); }";

	/** A function whose result is a structure named through typedefs another module declares, and a caller that names none of them. */
	static final reportSource =
		"typedef Metrics = { final count:Int; final notes:Array<String>; } typedef Report = { final metrics:Metrics; final ok:Bool; }";

	static final driverSource =
		"class Driver { public static function report():Report return {metrics: {count: 1, notes: []}, ok: true}; }";

	/**
	 * A constructor whose class has a field of an enum type: the field's reflected equality is a helper typed in the context of the
	 * constructor (its class's first method) every build, also one that keeps the constructor's body.
	 */
	static final holderSource =
		"class Holder { public final shape:Shape; public function new(shape:Shape) { if (shape == null) throw new Failure(\"no shape\"); this.shape = shape; } }";

	static final failureSource =
		"class Failure extends haxe.Exception { public function new(message:String, ?previous:haxe.Exception) super(message, previous); }";

	static final mainSource =
		"class Main { static function main():Int { var total = Lib.add(1, 2) + Lib.boxed() + Area.of(Circle(2)) + Level.High; return total == 20 && Lib.name().length == 3 && new Config().data != null && Config.empty != null && Config.ratio > 0 && Encoder.encode(0) == 0 && Trail.size([Stop]) == 1 && Ops.twice(3) > 0 && Ops.first([5, 6]) > 0 && new Holder(Square(1)).shape != null && Pairs.count() == 2 && new Stage().run() == 7 && run() ? 42 : 1; } static function run():Bool { Driver.report(); return true; } }";

	static function initialSources():Map<String, String>
		return [
			"Box.hx" => boxSource,
			"Shape.hx" => shapeSource,
			"Level.hx" => levelSource,
			"Area.hx" => areaSource,
			"Lib.hx" => libSource,
			"Config.hx" => configSource,
			"Encoder.hx" => encoderSource,
			"Trail.hx" => trailSource,
			"Ops.hx" => opsSource,
			"Pairs.hx" => pairsSource,
			"Pass.hx" => passSource,
			"Facts.hx" => factsSource,
			"Reader.hx" => readerSource,
			"Stage.hx" => stageSource,
			"Report.hx" => reportSource,
			"Driver.hx" => driverSource,
			"Holder.hx" => holderSource,
			"Failure.hx" => failureSource,
			"Main.hx" => mainSource
		];

	static function main():Void {
		var failures:Array<String> = [];
		attempt(failures, "second build without an edit", true, files -> {});
		attempt(failures, "second build without an edit, checked", true, files -> {}, true);
		edit(failures, "after a body edit",
			files -> files.set("Lib.hx", StringTools.replace(libSource, "return a + b;", "return a + b + 0;")));
		edit(failures, "after a signature edit",
			files -> files.set("Lib.hx",
			StringTools.replace(libSource, "add(a:Int, b:Int)", "add(a:Int, b:Int, c:Int = 0)")));
		edit(failures, "after a new generic specialization", files -> {
			files.set("Lib.hx",
				StringTools.replace(libSource, "return new Box<Int>(3).get();",
				"return new Box<Int>(3).get() + new Box<String>(\"x\").get().length - 1;"));
		});
		edit(failures, "after adding a function",
			files -> files.set("Lib.hx",
			StringTools.replace(libSource, "public static function name()",
			"public static function extra():Int return 7; public static function name()")));
		edit(failures, "after removing a module", files -> {
			files.remove("Area.hx");
			files.set("Main.hx", StringTools.replace(mainSource, " + Area.of(Circle(2))", " + 12"));
		});
		edit(failures,
			"after a new constant in a function early in the layout, which shifts the constant tables of the functions after it",
			files -> files.set("Box.hx",
			StringTools.replace(boxSource, "public function get():T return value;",
			"public function get():T { spare = spare + 123456789; return value; }")),
			true);
		edit(failures,
			"after a new function early in the layout, which shifts the function indices of the functions after it",
			files -> {
				files.set("Area.hx",
					StringTools.replace(areaSource, "public static function of(",
					"public static function again(shape:Shape, n:Int):Int return n > 0 ? again(shape, n - 1) : 7; public static function of("));
				files.set("Main.hx", StringTools.replace(mainSource, "Area.of(Circle(2))",
					"Area.of(Circle(2)) + Area.again(Circle(1), 0) - 7"));
			}, true);
		// The static fields keep their count and types, so the tables as the metadata leaves them differ only in a global's name.
		edit(failures, "after a static field with an initializer is renamed", files -> {
			files.set("Config.hx", StringTools.replace(configSource, "ratio", "share"));
			files.set("Main.hx", StringTools.replace(mainSource, "Config.ratio", "Config.share"));
		});
		edit(failures, "after a new string constant",
			files -> files.set("Lib.hx",
			StringTools.replace(libSource, "return \"lib\";",
			"return \"lib\";"
			+ " public static function shifted():String return \"a-constant-that-shifts-the-string-table\";")));
		// A reader's copy of an enum abstract's value is located where it reads it, so moving the abstract, down its file or along a
		// line, changes nothing the module holds: it is reused, and equals a fresh build's.
		for (check in [false, true]) {
			var checked = check ? ", checked" : "";
			attempt(failures, "after an enum abstract moved down its file" + checked, true,
				files -> files.set("Level.hx", "\n\n" + levelSource), check);
			attempt(failures, "after an enum abstract value moved along its line" + checked, true,
				files -> files.set("Level.hx",
				StringTools.replace(levelSource, "var High", "/* the higher level */ var High")),
				check);
		}
		edit(failures, "after an edit of a private inline function an inline function expands into",
			files -> files.set("Ops.hx", StringTools.replace(opsSource, "return x + 1;", "return x + 2;")));
		edit(failures, "after an edit of a private function an inline function calls",
			files -> files.set("Ops.hx", StringTools.replace(opsSource, "return x + 3;", "return x + 4;")));
		// The specializations of `Ops.first` and `Ops.pick` for `Int` lose their last caller: a fresh build does not make them.
		edit(failures, "after an edit removes the last call to a generic function's specialization",
			files -> files.set("Main.hx",
			StringTools.replace(mainSource, "Ops.first([5, 6]) > 0", "Ops.first([\"a\"]).length > 0")));
		// The specialization goes with the last module that calls it, and is made again when that module, unchanged, comes back.
		edit(failures, "after a module that calls a specialization comes back to the program",
			files -> files.set("Main.hx", mainSource), false,
			files -> files.set("Main.hx", StringTools.replace(mainSource, " && Pairs.count() == 2", "")));
		// Built as the command line builds, without the semantic index, whose refresh would type the reader's module again.
		edit(failures, "after interfaces become classes, which a reader names without reading their members", files -> {
			files.set("Pass.hx", passClassSource);
			files.set("Stage.hx", stageClassSource);
		}, false, null, false);
		edit(failures, "after an edit of a private generic function a generic function calls",
			files -> files.set("Ops.hx", StringTools.replace(opsSource, "return xs[0];", "return xs[xs.length - 1];")));
		edit(failures,
			"after an edit of a structure a function's result names through typedefs, which its caller does not name",
			files -> {
				files.set("Report.hx",
					StringTools.replace(reportSource, "final notes:Array<String>;", "final note:String;"));
				files.set("Driver.hx", StringTools.replace(driverSource, "notes: []", "note: \"\""));
			});
		// The constructor's callers must see the new optional argument even after a build that kept the caller's body and typed the
		// helpers of its class again.
		edit(failures, "after a signature edit of a constructor a kept constructor calls, after a body edit elsewhere",
			files -> files.set("Failure.hx",
			StringTools.replace(failureSource, "?previous:haxe.Exception)", "?previous:haxe.Exception, ?code:Int)")),
			false,
			files -> files.set("Lib.hx", StringTools.replace(libSource, "return a + b;", "return a + b + 0;")));
		liveFieldInitializer(failures);
		tryAfterEditAbove(failures);
		afterValidation(failures);
		linesInsertedAbove(failures);
		specializationOfAnEditedStructure(failures);
		if (failures.length > 0)
			throw failures.join("\n");
		Sys.println("PASS: a warm plain build equals a fresh one, and reuses its module when nothing changed");
	}

	/**
	 * An edit is built in a warm session twice: as it is, and checking its reuse, which also lowers every function afresh and compares.
	 * `before` is an edit built in the session first. `indexSemantics` is the builds' (`Compiler.compile`).
	 */
	static function edit(failures:Array<String>, label:String, change:Map<String, String>->Void,
			shifts:Bool = false, ?before:Map<String, String>->Void, indexSemantics:Bool = true):Void {
		attempt(failures, label, false, change, false, shifts, before, indexSemantics);
		attempt(failures, label + ", checked", false, change, true, shifts, before, indexSemantics);
	}

	static function attempt(failures:Array<String>, label:String, expectReuse:Bool, change:Map<String, String>->Void,
			?check:Bool = false,
			?shifts:Bool = false, ?before:Map<String, String>->Void, indexSemantics:Bool = true):Void {
		try {
			var files = initialSources(), compiler = newCompiler(files);
			compiler.options = new CompileOptions({checkReuse: check});
			var first = compiler.compile("Main", null, indexSemantics);
			if (before != null)
				first = rebuild(compiler, files, before, indexSemantics);
			var warm = rebuild(compiler, files, change, indexSemantics),
				freshCompiler = newCompiler(files),
				fresh = freshCompiler.compile("Main");
			var reuse = warm.metrics.reuse;
			// A checked build assembles the module again to compare it, so it reports the IR as the only reused part.
			var wanted = expectReuse ? (check ? "ir" : "ir+module") : null;
			if (expectReuse && reuse != wanted)
				throw 'expected reuse "$wanted" but the build reported "$reuse"';
			if (!expectReuse && StringTools.startsWith(reuse, "ir"))
				throw 'the build reused "$reuse" after an edit';
			if (shifts && warm.metrics.movedFunctions == 0)
				throw "the edit shifts the tables but no linked function was given other indices";
			if (!expectReuse && warm.metrics.linkedFunctions == 0)
				throw "no function was linked from the last build's lowering after an edit";
			var warmTypes = anonymousTypes(compiler),
				freshTypes = anonymousTypes(freshCompiler);
			if (warmTypes != freshTypes)
				throw 'the warm typed program lists other anonymous types than a fresh one\nwarm:  $warmTypes\nfresh: $freshTypes';
			var warmBytes = HlWriter.encode(warm.artifact.hashLink().module).flatten(),
				freshBytes = HlWriter.encode(fresh.artifact.hashLink().module).flatten();
			if (warmBytes.compare(freshBytes) != 0)
				throw 'the warm module differs from a fresh one (${warmBytes.length} and ${freshBytes.length} bytes)';
			if (expectReuse && !check && warm.artifact.hashLink().module != first.artifact.hashLink().module)
				throw "a reused build did not return the earlier module";
		} catch (error:Dynamic) {
			failures.push('$label: ${Std.string(error)}');
		}
	}

	/** Applies `change` to `files` and to `compiler`'s session, and builds again. */
	static function rebuild(compiler:Compiler, files:Map<String, String>, change:Map<String, String>->Void,
			indexSemantics:Bool = true):CompileResult {
		var before = [for (path in files.keys()) path];
		change(files);
		for (path => text in files)
			compiler.update(path, text);
		for (path in before)
			if (!files.exists(path))
				compiler.remove(path);
		// A session that is asked to build again registers its source roots again, which is what makes the compiler build rather than
		// return its last result.
		compiler.addSourceRoot("stdlib");
		return compiler.compile("Main", null, indexSemantics);
	}

	/**
	 * A live build of a program without static initializers, after a class another module's field initializer constructs gains an
	 * initialized field: its initializers are the field's migration alone, and the entry calls no `__init`, as there is none.
	 */
	static function liveFieldInitializer(failures:Array<String>):Void {
		try {
			var compiler = new Compiler(null, CompilerIntrinsics.configuration());
			compiler.livePatching = true;
			compiler.addSourceRoot("stdlib");
			compiler.update("model/Value.hx",
				"package model; class Value { public var kept:Int = 1; public function new() {} }");
			compiler.update("Main.hx",
				"class Holder { public var value = new model.Value(); public function new() {} }\n"
				+ "function kept(holder:Holder):Int return holder.value.kept;\n"
				+ "function holds(holder:Holder):Bool return holder.value != null;\n"
				+ "function main():Int return kept(new Holder()) + (holds(new Holder()) ? 1 : 0);");
			compiler.compile("Main");
			compiler.update("model/Value.hx",
				"package model; class Value { public var kept:Int = 1; public var changed:Int = 0; public function new() {} }");
			compiler.addSourceRoot("stdlib");
			compiler.compile("Main");
		} catch (error:Dynamic) {
			failures.push('a live build after a class gains an initialized field: ${Std.string(error)}');
		}
	}

	/**
	 * A try expression's local is named within the function it is written in, so an edit above that function in the same file
	 * leaves the function's IR, and its lambda's, as they were: neither is generated again, a live build does not patch them, and
	 * a plain build equals a fresh one.
	 */
	static function tryAfterEditAbove(failures:Array<String>):Void {
		var guardSource = "class Guard {\n\tpublic static function above(n:Int):Int return n + 1;\n"
			+ "\tpublic static function parse(text:String):Int { var length = try text.length catch (error:Dynamic) -1; "
			+ "var nested = () -> try length * 2 catch (error:Dynamic) 0; return length + nested(); }\n}";
		var edited = StringTools.replace(guardSource, "return n + 1;", "return n + 1 + n * 0;");
		for (live in [false, true])
			try {
				var files = [
					"Guard.hx" => guardSource,
					"Main.hx"
						=> "class Main { static function main():Int return Guard.above(1) + Guard.parse(\"abc\"); }"
				];
				var compiler = newCompiler(files);
				compiler.livePatching = live;
				compiler.compile("Main");
				var warm = rebuild(compiler, files, files -> files.set("Guard.hx", edited));
				if (warm.regenerated.indexOf("Guard.above") < 0)
					throw 'the edited function was not generated again: ${warm.regenerated}';
				for (name in warm.regenerated)
					if (StringTools.contains(name, "Guard.parse"))
						throw 'an edit above the try expressions generated $name again: ${warm.regenerated}';
				if (live) {
					var ids = warm.artifact.hashLink().functionIds;
					for (name in ids.keys())
						if (StringTools.contains(name, "Guard.parse")
							&& warm.changedFunctions.indexOf(ids.get(name)) >= 0)
							throw 'the patch carries $name';
				} else {
					var warmBytes = HlWriter.encode(warm.artifact.hashLink().module).flatten(),
						freshBytes =
							HlWriter.encode(newCompiler(files).compile("Main").artifact.hashLink().module).flatten();
					if (warmBytes.compare(freshBytes) != 0)
						throw 'the warm module differs from a fresh one (${warmBytes.length} and ${freshBytes.length} bytes)';
				}
			} catch (error:Dynamic) {
				failures.push('an edit above a function with try expressions${live ? ", live" : ""}: ${Std.string(error)}');
			}
	}

	/**
	 * A validation types an unsaved edit on a copy of the state and drops it (`Compiler.validate`): what its units read is written
	 * to the session's database but never committed, so the next build starts from the records the last taken build left, and
	 * equals a fresh one.
	 */
	static function afterValidation(failures:Array<String>):Void {
		try {
			var files = initialSources(), compiler = newCompiler(files);
			compiler.compile("Main");
			var facts = compiler.state.declarationFacts,
				unit = facts.existing(FactAspect.Unit, "Lib.add"),
				kept = facts.unitRecord(unit);
			if (kept == null)
				throw "Lib.add has no record";
			var validation = compiler.validate("Lib.hx",
				StringTools.replace(libSource, "return a + b;", "return a + b + 0;"),
				"Main");
			if (!validation.valid)
				throw "the validated edit does not type";
			var validated = facts.unitRecord(unit);
			if (validated == kept)
				throw "the validation did not record what the edited Lib.add read";
			var warm = rebuild(compiler, files, files -> files.set("Area.hx", areaSource + "\n")),
				fresh = newCompiler(files).compile("Main");
			if (facts.unitRecord(unit) == validated)
				throw "a build kept what a validation that was not taken recorded";
			var warmBytes = HlWriter.encode(warm.artifact.hashLink().module).flatten(),
				freshBytes = HlWriter.encode(fresh.artifact.hashLink().module).flatten();
			if (warmBytes.compare(freshBytes) != 0)
				throw 'the warm module differs from a fresh one (${warmBytes.length} and ${freshBytes.length} bytes)';
		} catch (error:Dynamic) {
			failures.push('after a validation of an unsaved edit: ${Std.string(error)}');
		}
	}

	/**
	 * Positions count from their declarations, so lines inserted above a function leave its IR as it was: it is not generated
	 * again, a live build does not patch it, and a plain build equals a fresh one. Code the inliner copied from a callee counts
	 * from the callee's declaration, so lines inserted above the callee change none of its callers. A function whose code holds its
	 * line as a value, the `haxe.PosInfos` a trace passes, is generated again, as its code changed.
	 */
	static function linesInsertedAbove(failures:Array<String>):Void {
		var movedSource = "class Moved {\n\tpublic static function above(n:Int):Int return n + 1;\n"
			+ "\tpublic static function below(n:Int):Int { var total = 0; for (i in 0...n) total += i; "
			+ "var add = (x:Int) -> x + total; return add(n) + new Callee(n).value; }\n"
			+ "\tpublic static function traced(n:Int):Int { trace(\"traced\"); return n; }\n}";
		var calleeSource =
			"class Callee {\n\tpublic final value:Int;\n\tpublic function new(value:Int) this.value = value * 2;\n}";
		var userSource = "class User { public static function use(n:Int):Int return new Callee(n).value + 1; }";
		var mainSource =
			"class Main { static function main():Int return Moved.above(1) + Moved.below(3) + Moved.traced(2) + User.use(4); }";
		function calls(result:CompileResult, caller:String, callee:String):Bool {
			for (fn in result.ir.functions)
				if (fn.name == caller)
					for (block in fn.blocks)
						for (located in block.instructions)
							switch located.value {
								case Call(_, target, _) if (target.name == callee):
									return true;
								default:
							}
			return false;
		}
		var edits = [
			{
				label: "lines inserted above a function",
				path: "Moved.hx",
				text: StringTools.replace(movedSource, "\tpublic static function below",
					"\t// a comment\n\n\tpublic static function below"),
				kept: ["Moved.below", "User.use", "Callee.new"],
				changed: ["Moved.traced"]
			},
			{
				label: "lines inserted above an inlined callee",
				path: "Callee.hx",
				text: "// a comment\n\n" + calleeSource,
				kept: ["Callee.new", "User.use", "Moved.below"],
				changed: []
			}
		];
		for (edit in edits)
			for (live in [false, true])
				try {
					var files = [
						"Moved.hx" => movedSource,
						"Callee.hx" => calleeSource,
						"User.hx" => userSource,
						"Main.hx" => mainSource
					];
					var compiler = newCompiler(files);
					compiler.livePatching = live;
					var first = compiler.compile("Main");
					if (!live && calls(first, "User.use", "Callee.new"))
						throw "the fixture's constructor is not inlined into its caller";
					var warm = rebuild(compiler, files, files -> files.set(edit.path, edit.text));
					for (name in warm.regenerated)
						for (kept in edit.kept)
							if (name == kept || StringTools.contains(name, kept + ":"))
								throw 'lines inserted above generated $name again: ${warm.regenerated}';
					for (name in edit.changed)
						if (warm.regenerated.indexOf(name) < 0)
							throw '$name holds its line as a value but was not generated again: ${warm.regenerated}';
					if (live) {
						var ids = warm.artifact.hashLink().functionIds;
						for (name in ids.keys())
							for (kept in edit.kept)
								if ((name == kept || StringTools.contains(name, kept + ":"))
									&& warm.changedFunctions.indexOf(ids.get(name)) >= 0)
									throw 'the patch carries $name';
						for (name in edit.changed)
							if (warm.changedFunctions.indexOf(ids.get(name)) < 0)
								throw 'the patch does not carry $name, whose line changed';
					}
					if (!live) {
						var warmBytes = HlWriter.encode(warm.artifact.hashLink().module).flatten(),
							freshBytes =
								HlWriter.encode(newCompiler(files).compile("Main").artifact.hashLink().module)
								.flatten();
						if (warmBytes.compare(freshBytes) != 0)
							throw 'the warm module differs from a fresh one (${warmBytes.length} and ${freshBytes.length} bytes)';
					}
				} catch (error:Dynamic) {
					failures.push('${edit.label}${live ? ", live" : ""}: ${Std.string(error)}');
				}
	}

	/**
	 * A generic class specialized for a structure is another specialization once the structure's fields change. The old one's
	 * lambdas (`ObjectMap.keyValueIterator`'s) name it, but they belong to its methods and do not keep it: the warm build has
	 * only what a fresh one has.
	 */
	static function specializationOfAnEditedStructure(failures:Array<String>):Void {
		var files = [
			"Key.hx" => "typedef Key = { final name:String; final a:Int; }",
			"Info.hx" => "class Info { public final n:Int; public function new(n:Int) this.n = n; }",
			"Table.hx"
				=> "class Table { public final types = new haxe.ds.ObjectMap<Key, Info>(); public function new() {} }",
			"Main.hx"
				=> "class Main { static function main():Int { var table = new Table(), key:Key = {name: \"x\", a: 1}; "
				+ "table.types.set(key, new Info(41)); var total = 0; for (k => v in table.types) total += k.a + v.n; "
				+ "trace([for (k in table.types.keys()) k.name]); return total; } }"
		];
		for (check in [false, true])
			try {
				var compiler = newCompiler(files);
				compiler.options = new CompileOptions({checkReuse: check});
				compiler.compile("Main");
				var warm = rebuild(compiler, files, files -> {
					files.set("Key.hx", "typedef Key = { final name:String; final a:Int; final b:Int; }");
					files.set("Main.hx", StringTools.replace(files.get("Main.hx"), "a: 1}", "a: 1, b: 0}"));
				}),
					freshCompiler = newCompiler(files),
					fresh = freshCompiler.compile("Main");
				var warmClasses = specializedClasses(compiler), freshClasses = specializedClasses(freshCompiler);
				if (warmClasses != freshClasses)
					throw 'the warm typed program has other specializations than a fresh one\nwarm:  $warmClasses\nfresh: $freshClasses';
				var warmBytes = HlWriter.encode(warm.artifact.hashLink().module).flatten(),
					freshBytes = HlWriter.encode(fresh.artifact.hashLink().module).flatten();
				if (warmBytes.compare(freshBytes) != 0)
					throw 'the warm module differs from a fresh one (${warmBytes.length} and ${freshBytes.length} bytes)';
			} catch (error:Dynamic) {
				failures.push('after an edit of a structure a generic class is specialized for${check ? ", checked" : ""}: '
					+ Std.string(error));
			}
	}

	/** The specialized classes of the last typed program and the types the generic owners are named for, sorted. */
	static function specializedClasses(compiler:Compiler):String {
		var program = compiler.lastTypedProgram;
		if (program == null)
			throw "no typed program";
		var names = [for (entry in program.classes) if (entry.specializationOrigin != null) entry.name],
			aliases = [for (key in program.genericOwnerAliases.keys()) key];
		names.sort(Reflect.compare);
		aliases.sort(Reflect.compare);
		return names.concat(aliases).join("\n");
	}

	/** The names of the anonymous types of the last typed program, sorted: a warm program lists what a fresh one does. */
	static function anonymousTypes(compiler:Compiler):String {
		var program = compiler.lastTypedProgram;
		if (program == null)
			throw "no typed program";
		return [for (entry in program.anonymousTypes) entry.name].join("\n");
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
