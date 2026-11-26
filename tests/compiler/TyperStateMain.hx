using compiler.compilation.BackendArtifact.BackendArtifacts;
import compiler.Compiler;
import compiler.core.Diagnostic.CompileError;
import compiler.runtime.CompilerIntrinsics;

/**
 * The typer's state a compiler session keeps across builds (docs/design/TYPER_STATE.md): each module's declaration keys and
 * names, and the names every module sees. A build that is not taken and a publication the host rejects leave each as the build
 * before them left it, or without a value, which the next build makes again; never the build's own. The build after either gives
 * a fresh build's module.
 */
class TyperStateMain {
	static final libSource = "class Lib { public static function add(a:Int, b:Int):Int return a + b; }";

	/** An edit that declares a type, which moves the names every module sees, and an inferred function. */
	static final widerLibSource =
		"class Lib { public static function add(a:Int, b:Int):Int return a + b; } class Extra { public static function seven() return 7; }";

	static final mainSource = "class Main { static function main():Int return Lib.add(40, 2); }";
	static final brokenMainSource = "class Main { static function main():Int return Lib.add(40, \"two\"); }";

	static function main():Void {
		var failures:Array<String> = [];
		notTaken(failures);
		rejected(failures);
		if (failures.length > 0)
			throw failures.join("\n");
		Sys.println("typer state: rollback ok");
	}

	/** A build that fails is not taken: the next build starts from the state the last taken one left. */
	static function notTaken(failures:Array<String>):Void {
		try {
			var compiler = newCompiler();
			compiler.compile("Main");
			var before = kept(compiler);
			compiler.update("Lib.hx", widerLibSource);
			compiler.update("Main.hx", brokenMainSource);
			var failed = try {
				compiler.compile("Main");
				false;
			} catch (error:CompileError) true;
			if (!failed)
				throw "the broken edit built";
			// What the next build does first (`SessionState.copyForCandidate`).
			var state = @:privateAccess compiler.state;
			state.queries.rollBack(state.committed);
			compareKept(before, kept(compiler));
			compiler.update("Lib.hx", libSource);
			compiler.update("Main.hx", mainSource);
			sameAsFresh(compiler.compile("Main"), [libSource, mainSource]);
		} catch (error:Dynamic) {
			failures.push('a build not taken: ${Std.string(error)}');
		}
	}

	/** A publication the host rejects returns the session to the state it published before. */
	static function rejected(failures:Array<String>):Void {
		try {
			var compiler = newCompiler();
			compiler.enablePublicationTracking();
			compiler.acknowledgePublication(compiler.compile("Main").revision);
			var before = kept(compiler);
			compiler.update("Lib.hx", widerLibSource);
			var published = compiler.compile("Main");
			if (kept(compiler).program == before.program)
				throw "the edit that declares a type kept the names every module sees";
			compiler.rejectPublication(published.revision);
			compareKept(before, kept(compiler));
			compiler.update("Lib.hx", libSource);
			sameAsFresh(compiler.compile("Main"), [libSource, mainSource]);
		} catch (error:Dynamic) {
			failures.push('a rejected publication: ${Std.string(error)}');
		}
	}

	/** What the session's database keeps of the typer's state, by module. */
	static function kept(compiler:Compiler):{keys:Map<String, Dynamic>, names:Map<String, Dynamic>, program:Dynamic} {
		var state = @:privateAccess compiler.state, keys:Map<String, Dynamic> = [], names:Map<String, Dynamic> = [];
		for (module in ["Lib", "Main"]) {
			var id = state.inputs.moduleId(module);
			keys.set(module, state.declarationKeys.kept(id));
			names.set(module, state.moduleNames.kept(id));
		}
		return {keys: keys, names: names, program: state.programNames.kept(0)};
	}

	/** Each value kept after the rollback is the one kept before, or none. */
	static function compareKept(before:{keys:Map<String, Dynamic>, names:Map<String, Dynamic>, program:Dynamic},
			after:{keys:Map<String, Dynamic>, names:Map<String, Dynamic>, program:Dynamic}):Void {
		for (module => value in after.keys)
			if (value != null && value != before.keys.get(module))
				throw 'the declaration keys of $module are the undone build\'s';
		for (module => value in after.names)
			if (value != null && value != before.names.get(module))
				throw 'the names of $module are the undone build\'s';
		if (after.program != null && after.program != before.program)
			throw "the names every module sees are the undone build's";
	}

	static function sameAsFresh(warm:compiler.Compiler.CompileResult, sources:Array<String>):Void {
		var fresh = newCompiler();
		fresh.update("Lib.hx", sources[0]);
		fresh.update("Main.hx", sources[1]);
		var freshBytes = fresh.compile("Main").artifact.hashLink().hashLinkBytes().flatten(),
			warmBytes = warm.artifact.hashLink().hashLinkBytes().flatten();
		if (warmBytes.compare(freshBytes) != 0)
			throw 'the build after the rollback differs from a fresh one (${warmBytes.length} and ${freshBytes.length} bytes)';
	}

	static function newCompiler():Compiler {
		var compiler = new Compiler(null, CompilerIntrinsics.configuration());
		compiler.livePatching = false;
		compiler.addSourceRoot("stdlib");
		compiler.update("Lib.hx", libSource);
		compiler.update("Main.hx", mainSource);
		return compiler;
	}
}
