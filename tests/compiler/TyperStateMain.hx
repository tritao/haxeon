using compiler.compilation.BackendArtifact.BackendArtifacts;
import compiler.Compiler;
import compiler.core.Diagnostic.CompileError;
import compiler.ir.model.IrSymbol;
import compiler.runtime.CompilerIntrinsics;

/**
 * The typer's state a compiler session keeps across builds (docs/design/TYPER_STATE.md): each module's declaration keys and
 * names, the names every module sees, and the generic owner specializations. A build that is not taken and a publication the host rejects leave each as the build
 * before them left it, or without a value, which the next build makes again; never the build's own. The build after either gives
 * a fresh build's module.
 */
typedef Kept = {
	final keys:Map<String, Dynamic>;
	final names:Map<String, Dynamic>;
	final program:Dynamic;
	final specializations:Map<String, Dynamic>;
}

class TyperStateMain {
	static final boxSource =
		"@:generic class Box<T> { public var value:T; public function new(value:T) this.value = value; public function get():T return value; }";

	static final libSource = "class Lib { public static function add(a:Int, b:Int):Int return a + b; } " + boxSource;

	/**
	 * An edit that declares a type, which moves the names every module sees, and an inferred function, and edits a method of the
	 * generic class, whose specialization is typed again.
	 */
	static final widerLibSource =
		"class Lib { public static function add(a:Int, b:Int):Int return a + b; } class Extra { public static function seven() return 7; } "
		+ StringTools.replace(boxSource, "return value;", "return this.value;");

	static final mainSource =
		"import Lib.Box; class Main { static function main():Int return Lib.add(new Box<Int>(40).get(), 2); }";
	static final brokenMainSource =
		"import Lib.Box; class Main { static function main():Int return Lib.add(new Box<Int>(40).get(), \"two\"); }";

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
			for (name => value in before.specializations)
				if (value == null)
					throw 'the session keeps no owner specialization $name';
			compiler.update("Lib.hx", widerLibSource);
			var published = compiler.compile("Main"), after = kept(compiler);
			if (after.program == before.program)
				throw "the edit that declares a type kept the names every module sees";
			for (name => value in after.specializations)
				if (value == before.specializations.get(name))
					throw 'the edit to the generic class kept its specialization $name';
			compiler.rejectPublication(published.revision);
			compareKept(before, kept(compiler));
			compiler.update("Lib.hx", libSource);
			sameAsFresh(compiler.compile("Main"), [libSource, mainSource]);
		} catch (error:Dynamic) {
			failures.push('a rejected publication: ${Std.string(error)}');
		}
	}

	/** What the session's database keeps of the typer's state, by module, and the owner specializations by name. */
	static function kept(compiler:Compiler):Kept {
		var state = @:privateAccess compiler.state,
			keys:Map<String, Dynamic> = [],
			names:Map<String, Dynamic> = [],
			specializations:Map<String, Dynamic> = [];
		for (module in ["Lib", "Main"]) {
			var id = state.inputs.moduleId(module);
			keys.set(module, state.declarationKeys.kept(id));
			names.set(module, state.moduleNames.kept(id));
		}
		var program = state.lastTypedProgram;
		if (program != null)
			for (classDecl in program.classes)
				if (classDecl.specializationOrigin != null)
					specializations.set(classDecl.name,
						state.ownerSpecializations.kept(IrSymbol.of(classDecl.name).id));
		if (!specializations.keys().hasNext())
			throw "the program has no owner specialization";
		return {
			keys: keys,
			names: names,
			program: state.programNames.kept(0),
			specializations: specializations
		};
	}

	/** Each value kept after the rollback is the one kept before, or none. */
	static function compareKept(before:Kept, after:Kept):Void {
		for (module => value in after.keys)
			if (value != null && value != before.keys.get(module))
				throw 'the declaration keys of $module are the undone build\'s';
		for (module => value in after.names)
			if (value != null && value != before.names.get(module))
				throw 'the names of $module are the undone build\'s';
		if (after.program != null && after.program != before.program)
			throw "the names every module sees are the undone build's";
		for (name => value in after.specializations)
			if (value != null && value != before.specializations.get(name))
				throw 'the owner specialization $name is the undone build\'s';
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
