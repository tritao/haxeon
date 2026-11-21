using compiler.compilation.BackendArtifact.BackendArtifacts;
import compiler.Compiler.CompileResult;
import compiler.core.FileVersion;
import compiler.hl.HlWriter;
import compiler.tools.CompilerArguments;
import compiler.tools.CompilerDriver;
import compiler.tools.CompilerSession;
import sys.FileSystem;
import sys.io.File;

class CompilerSessionMain {
	static function main():Void {
		var root = FileSystem.fullPath(".") + "/out/compiler-session-test-" + Std.random(0x3fffffff);
		FileSystem.createDirectory(root);
		var main = root + "/Main.hx",
			value = root + "/Value.hx",
			output = root + "/main.hl",
			fresh = root + "/fresh.hl";
		File.saveContent(main, "class Main { public static function main():Int { return Value.get(); } }");
		File.saveContent(value, "class Value { public static function get():Int { return 7; } }");
		var modeSession = new CompilerSession(),
			modeArgs = [
				"--target=hl",
				"--entry=Main",
				"--root=" + root,
				"--output=" + output,
				main,
				value
			];
		expect(CompilerArguments.parse(modeArgs.concat(["--live"])).buildMode == "development",
			"live builds must select development metadata");
		var rejectedReleaseLive = false;
		try CompilerArguments.parse(modeArgs.concat(["--live", "--build-mode=release"])) catch (_:Dynamic)
			rejectedReleaseLive = true;
		expect(rejectedReleaseLive, "live builds must reject an explicit release mode");
		expect(CompilerArguments.parse(modeArgs).buildMode == "development",
			"default builds must select development metadata");
		var release = CompilerDriver.compile(CompilerArguments.parse(modeArgs.concat(["--build-mode=release"])),
			_ -> {}, modeSession);
		expect(release.artifact.hashLink().module.debugSections.length == 1
			&& release.artifact.hashLink().module.debugSections[0].kind == HlWriter.FUNCTION_IDENTITIES
			&& release.artifact.hashLink().module.sourceSnapshots.length == 0,
			"release artifacts must retain names but omit development spans and snapshots");
		var development = CompilerDriver.compile(CompilerArguments.parse(modeArgs), _ -> {}, modeSession);
		expect(development.artifact.hashLink().module.debugSections.length == 3
			&& development.artifact.hashLink().module.sourceSnapshots.length > 0,
			"development artifacts must retain debug identities, spans and source snapshots");
		var releaseAgain = CompilerDriver.compile(CompilerArguments.parse(modeArgs.concat(["--build-mode=release"])),
			_ -> {}, modeSession);
		expect(releaseAgain.artifact.hashLink().module.debugSections.length == 1
			&& releaseAgain.artifact.hashLink().module.debugSections[0].kind == HlWriter.FUNCTION_IDENTITIES
			&& releaseAgain.artifact.hashLink().module.sourceSnapshots.length == 0,
			"a persistent session must honor changes to build mode");

		// `--session=reuse` (the default) builds on the session; `--session=fresh` starts it over, so the compile owes nothing to
		// the requests before it and types everything again, to the same bytes.
		var sessionArgs = modeArgs.concat(["--build-mode=release"]);
		var reused = CompilerDriver.compile(CompilerArguments.parse(sessionArgs), _ -> {}, modeSession),
			freshStart = CompilerDriver.compile(CompilerArguments.parse(sessionArgs.concat(["--session=fresh"])),
				_ -> {},
				modeSession);
		expect(reused.metrics.retypedFunctions == 0, "a reused session types nothing again");
		expect(freshStart.metrics.retypedFunctions > 0, "a fresh session types everything again");
		expect(HlWriter.encode(reused.artifact.hashLink().module).flatten()
			.compare(HlWriter.encode(freshStart.artifact.hashLink().module).flatten()) == 0,
			"a fresh session builds the same module");
		var rejectedMode = false;
		try CompilerArguments.parse(modeArgs.concat(["--session=sometimes"])) catch (_:Dynamic)
			rejectedMode = true;
		expect(rejectedMode, "an unknown session mode must be rejected");

		// Live mode: this block asserts that backend assembly reuses lowered functions between compiles, which only a
		// session that keeps its assembler history does. ArtifactBuildMain covers the default, history-free mode.
		var args = ["--target=hl", "--entry=Main", "--root=" + root, "--live", main, value],
			session = new CompilerSession();
		function compile()
			return CompilerDriver.compile(CompilerArguments.parse(args.concat(["--output=" + output])), _ -> {},
				session);
		function compareFresh(expected:Int):Void {
			CompilerDriver.compile(CompilerArguments.parse(args.concat(["--output=" + fresh])), _ -> {});
			var variable = Sys.systemName() == "Windows" ? "PATH" : Sys.systemName() == "Mac"
				? "DYLD_LIBRARY_PATH" : "LD_LIBRARY_PATH",
				separator = Sys.systemName() == "Windows" ? ";" : ":",
				previousPath = Sys.getEnv(variable),
				runtime = FileSystem.fullPath(Sys.getEnv("HAXEON_HASHLINK_DIR") + "/hl"
					+ (Sys.systemName() == "Windows" ? ".exe" : ""));
			Sys.putEnv(variable,
				FileSystem.fullPath("out")
				+ separator
				+ FileSystem.fullPath(Sys.getEnv("HAXEON_HASHLINK_DIR"))
				+ (previousPath == null ? "" : separator + previousPath));
			expect(Sys.command(runtime, [output]) == expected, "incremental bytecode must execute the edited program");
			expect(Sys.command(runtime, [fresh]) == expected, "fresh bytecode must execute the same program");
			Sys.putEnv(variable, previousPath);
			expect(Sys.getEnv(variable) == previousPath, "runtime library path must be restored exactly");
			expect(File.getContent(output + ".functions").indexOf("\tMain.main\n") >= 0,
				"incremental bytecode must publish its stable function map");
			expect(File.getContent(fresh + ".functions").indexOf("\tMain.main\n") >= 0,
				"fresh bytecode must publish its function map");
		}
		var initial = compile();
		var initialManifest = File.getContent(output + ".live.json"),
			initialStamp = File.getContent(output + ".live.stamp");
		var unchanged = compile();
		expect(unchanged.retyped.length == 0, "unchanged compilation reuses semantic state");
		expect(unchanged.unchanged && unchanged.revision == initial.revision,
			"unchanged live compilation must not advance the runtime revision");
		expect(File.getContent(output + ".live.json") == initialManifest
			&& File.getContent(output + ".live.stamp") == initialStamp,
			"an unchanged build must preserve the last runtime publication");
		var modified = false;
		var snapshotBuild = CompilerDriver.compile(CompilerArguments.parse(args.concat(["--output=" + output])),
			message -> {
				if (message == "reusing compiler session" && !modified) {
					modified = true;
					File.saveContent(value, "class Value { public static function get():Int { return 8; } }");
				}
			}, session);
		expect(modified && snapshotBuild.unchanged,
			"shape checks and compilation must use one source snapshot despite a mid-request write");
		var afterSnapshotWrite = compile();
		expect(!afterSnapshotWrite.unchanged
			&& afterSnapshotWrite.baseRevision == initial.revision, "the next request must see the mid-request write");
		compareFresh(8);
		var pendingPatch = File.getBytes(output + ".hlp"),
			patchManifest = File.getContent(output + ".live.json");
		expect(compile().unchanged
			&& File.getBytes(output + ".hlp").compare(pendingPatch) == 0
			&& File.getContent(output + ".live.json") == patchManifest,
			"an unchanged build must not delete a patch a live host has yet to consume");
		File.saveContent(value, 'class Value { public static function get():Int { return "unterminated; } }');
		var invalidSnapshot = false;
		try
			compile()
		catch (error:compiler.core.Diagnostic.CompileError) {
			invalidSnapshot = true;
			expect(error.diagnostic.span.file.path == "Value.hx", "a syntax error must name the module's source");
		}
		expect(invalidSnapshot, "a malformed source snapshot must be reported");
		File.saveContent(value, "class Value { public static function get():Int { return 8; } }");
		expect(compile().unchanged, "a failed source read must not poison the next request");
		File.saveContent(value, "class Value { public static function get():Int { return 6; } }");
		var writeFailed = false;
		try
			CompilerDriver.compile(CompilerArguments.parse(args.concat(["--output=" + root + "/missing/result.hl"])),
				_ -> {}, session)
		catch (_:Dynamic)
			writeFailed = true;
		expect(writeFailed, "artifact-write errors must be reported");
		// The failed build changed no state the next one starts from: it builds the module for 6 again, and an identical rebuild
		// after the failure still writes the output.
		FileSystem.deleteFile(output);
		compile();
		expect(FileSystem.exists(output), "a rebuild after a failed write must write the output");
		compareFresh(6);

		File.saveContent(value, "class Value { public static function get():Int { return 9; } }");
		var edited = compile();
		expect(edited.retyped.length > 0, "a source edit must retype affected modules");
		expect(edited.metrics.declarationMs == 0.0 && edited.metrics.shapeConnectionMs == 0.0
			&& edited.metrics.signatureTypingMs == 0.0,
			"an explicitly typed class-method body edit must reuse validated declarations");
		expect(File.getBytes(output).compare(HlWriter.encode(edited.artifact.hashLink().module).flatten()) == 0,
			"cached HashLink function encoding must match canonical serialization");
		// With inlining, Main.main contains Value.get, so it must be rebuilt when Value.get changes.
		var mainReused = functionByName(initial, "Main.main") == functionByName(edited, "Main.main");
		expect(!mainReused,
			"backend assembly must reuse functions from unchanged source files, except callers that inlined an edited callee");
		compareFresh(9);
		var lazy = root + "/Lazy.hx";
		File.saveContent(lazy, "class Lazy { public static function value():Int { return 23; } }");
		File.saveContent(main, "class Main { public static function main():Int { return Lazy.value(); } }");
		compile();
		var beforeLazy = File.getBytes(output);
		File.saveContent(lazy, "class Lazy { public static function value():Int { return 29; } }");
		compile();
		expect(beforeLazy.compare(File.getBytes(output)) != 0,
			"lazily loaded imports must be refreshed by module identity");
		compareFresh(29);
		File.saveContent(main, "class Main { public static function main():Int { return Value.get(); } }");
		File.saveContent(value,
			"class Value { public static function extra():Int { return 3; } public static function get():Int { return extra(); } }");
		compile();
		compareFresh(3);
		File.saveContent(value, "class Value { public static function get():Int { return missing; } }");
		var failed = false;
		try
			compile()
		catch (_:Dynamic) {
			failed = true;
			session.reset();
		}
		expect(failed, "compile errors must be reported");
		File.saveContent(value, "class Value { public static function get():Int { return 11; } }");
		compile();
		compareFresh(11);
		FileSystem.deleteFile(value);
		args.remove(value);
		failed = false;
		try
			compile()
		catch (_:Dynamic) {
			failed = true;
			session.reset();
		}
		expect(failed, "removed sources must not survive in the session");
		File.saveContent(main,
			"class Main { public static function main():Int { #if feature return 13; #else return 0; #end } }");
		args.push("--define=feature");
		compile();
		compareFresh(13);
		var hxi = root + "/fixture.hxi";
		File.saveContent(hxi, 'interface fixture @target("portable-abi64") @library("fixture") { const VALUE = 17; }');
		args.push("--ffi-interface=" + hxi);
		File.saveContent(main,
			"import fixture; import fixture.FixtureConstants; class Main { public static function main():Int { return FixtureConstants.VALUE; } }");
		compile();
		var beforeFfi = File.getBytes(output);
		File.saveContent(hxi, 'interface fixture @target("portable-abi64") @library("fixture") { const VALUE = 19; }');
		compile();
		expect(beforeFfi.compare(File.getBytes(output)) != 0, "FFI edits must replace projected modules");
		compareFresh(19);
		var generic = root + "/Generic.hx";
		File.saveContent(generic,
			"class Generic { static function identity<T>(v:T):Int { return 7; } public static function get():Int { var f = () -> identity(7); return f(); } }");
		args.push(generic);
		File.saveContent(main, "class Main { public static function main():Int { return Generic.get(); } }");
		compile();
		File.saveContent(main, "class Main { public static function main():Int { return Generic.get() + 1; } }");
		compile();
		compareFresh(8);
		File.saveContent(generic, File.getContent(generic).split("return 7;").join("return 11;"));
		compile();
		compareFresh(12);
		// A typedef, enum or abstract that changes shape changes the layout or the lowering of the classes that use it, though their
		// text is the same. The session keeps its compiler, and the warm build runs as a fresh build of the same sources does.
		var shape = root + "/Shape.hx",
			kind = root + "/Kind.hx",
			meters = root + "/Meters.hx",
			holder = root + "/Holder.hx",
			shapeMain = root + "/ShapeMain.hx";
		File.saveContent(shape, "typedef Shape = { var x:Int; }");
		File.saveContent(kind,
			"enum Kind { Small; Large; } class Kinds { public static function large():Kind return Large; }");
		File.saveContent(meters,
			"abstract Meters(Int) { public inline function new(value:Int) this = value; public function toInt():Int return this; }");
		File.saveContent(holder,
			"class Holder { public var values:Array<Shape> = []; public var kind:Kind = Kind.Kinds.large(); public var distance:Meters = new Meters(5); public function new() values.push({x: 3}); public function size():Int return values.length + values[0].x + distance.toInt() + switch kind { case Large: 20; case _: 10; }; }");
		File.saveContent(shapeMain,
			"class ShapeMain { public static function main():Int return new Holder().size(); }");
		var shapeArgs = [
			"--target=hl",
			"--entry=ShapeMain",
			"--root=" + root,
			"--live",
			shapeMain,
			holder,
			shape,
			kind,
			meters
		],
			shapeSession = new CompilerSession(),
			shapeMessages:Array<String> = [];
		var runtime = FileSystem.fullPath(Sys.getEnv("HAXEON_HASHLINK_DIR") + "/hl"
			+ (Sys.systemName() == "Windows" ? ".exe" : ""));
		var variable = Sys.systemName() == "Windows" ? "PATH" : Sys.systemName() == "Mac"
			? "DYLD_LIBRARY_PATH" : "LD_LIBRARY_PATH";
		var previousPath = Sys.getEnv(variable);
		Sys.putEnv(variable, FileSystem.fullPath("out")
			+ (Sys.systemName() == "Windows" ? ";" : ":")
			+ FileSystem.fullPath(Sys.getEnv("HAXEON_HASHLINK_DIR"))
			+ (previousPath == null ? "" : (Sys.systemName() == "Windows" ? ";" : ":") + previousPath));
		function shapeBuild(label:String):Void {
			shapeMessages = [];
			CompilerDriver.compile(CompilerArguments.parse(shapeArgs.concat(["--output=" + root + "/shape.hl"])),
				shapeMessages.push, shapeSession);
			CompilerDriver.compile(CompilerArguments.parse(shapeArgs.concat(["--output=" + root + "/shape-fresh.hl"])),
				_ -> {});
			expect(Sys.command(runtime, [root + "/shape-fresh.hl"]) == 29, '$label: the fresh program must execute');
			expect(Sys.command(runtime, [root + "/shape.hl"]) == 29,
				'$label: the warm program must run as the fresh one');
		}
		shapeBuild("the initial build");
		File.saveContent(shape, "typedef Shape = { var x:Int; @:optional var y:Int; }");
		shapeBuild("a typedef shape edit");
		expect(shapeMessages.indexOf("reusing compiler session") >= 0,
			"a typedef shape edit must keep the compiler session");
		File.saveContent(kind,
			"enum Kind { Tiny; Small; Large; } class Kinds { public static function large():Kind return Large; }");
		shapeBuild("an enum shape edit");
		expect(shapeMessages.indexOf("reusing compiler session") >= 0,
			"an enum shape edit must keep the compiler session");
		File.saveContent(meters,
			"abstract Meters(Float) { public inline function new(value:Int) this = value; public function toInt():Int return Std.int(this); }");
		shapeBuild("an abstract shape edit");
		expect(shapeMessages.indexOf("reusing compiler session") >= 0,
			"an abstract shape edit must keep the compiler session");
		File.saveContent(shape, "// enum in a comment\ntypedef Shape = { var x:Int; @:optional var y:Int; }");
		shapeBuild("a comment edit");
		expect(shapeMessages.indexOf("reusing compiler session") >= 0, "a comment edit must keep the compiler session");
		Sys.putEnv(variable, previousPath);
		checkReadGuard(root + "/Guarded.hx");
		for (path in FileSystem.readDirectory(root))
			FileSystem.deleteFile(root + "/" + path);
		FileSystem.deleteDirectory(root);
		Sys.println("PASS: compiler session reuse, edits, failure recovery, source removal, FFI/lazy imports, generic invalidation, typedef, enum and abstract shape edits, and the source read guard");
	}

	/** A source read once is kept only when no write overlapped the read: the file's version must not move across it. */
	static function checkReadGuard(path:String):Void {
		File.saveContent(path, "class Guarded {}");
		expect(FileVersion.readSource(path) == "class Guarded {}", "a source nothing writes is read once");
		var writes = 0;
		var settled = FileVersion.unchangedRead(path, file -> {
			var text = File.getContent(file);
			if (writes++ == 0)
				File.saveContent(file, "class Guarded { static var edited = 1; }");
			return text;
		}, 4);
		expect(writes == 2 && settled == "class Guarded { static var edited = 1; }",
			"a source written during its read must be read again");
		// The same size, written after the clock moved on: only a fine modification time tells the versions apart.
		var sameSize = FileVersion.unchangedRead(path, file -> {
			var text = File.getContent(file);
			if (text == "class Guarded { static var edited = 1; }") {
				Sys.sleep(0.02);
				File.saveContent(file, "class Guarded { static var edited = 2; }");
			}
			return text;
		}, 4);
		expect(sameSize == "class Guarded { static var edited = 2; }",
			"a same-size write during a read must be detected");
		var always = FileVersion.unchangedRead(path, file -> {
			var text = File.getContent(file);
			File.saveContent(file, text + " ");
			return text;
		}, 4);
		expect(always == null, "a source written during every read must be refused");
		var refused = false;
		try
			FileVersion.readSource(path + ".missing")
		catch (_:Dynamic)
			refused = true;
		expect(refused, "a missing source must fail its read");
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}

	static function functionByName(result:CompileResult, name:String):compiler.hl.HlFunction {
		var index = result.artifact.hashLink().functionIndices.get(name);
		for (fn in result.artifact.hashLink().module.functions)
			if (fn.functionIndex == index)
				return fn;
		throw 'Missing lowered function "$name"';
	}
}
