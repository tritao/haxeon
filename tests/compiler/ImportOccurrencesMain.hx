using compiler.compilation.BackendArtifact.BackendArtifacts;
import compiler.Compiler;
import compiler.core.Diagnostic.CompileError;

/** Each written import retains its own alias when a module is retyped. */
class ImportOccurrencesMain {
	static final planner = 'package probe; class Planner { public static function plan():Int return 40; '
		+ 'public static function fingerprint(value:Int):Int return value + 2; }';
	static final aliases = 'import probe.Planner as P; import probe.Planner as Q; ';
	static final aliasOnly = aliases + 'function main():Int return P.plan() + Q.plan() - 38;';
	static final both = aliases + 'import probe.Planner; function main():Int return Planner.fingerprint(P.plan());';
	static final missing = aliases + 'function main():Int return Planner.fingerprint(P.plan());';

	static function compiler(source:String):Compiler {
		var c = new Compiler();
		c.livePatching = false;
		c.update("probe/Planner.hx", planner);
		c.update("Main.hx", source);
		return c;
	}

	static function main():Void {
		var warm = compiler(aliasOnly);
		warm.compile("Main");
		warm.update("Main.hx", both);
		var added = warm.compile("Main"), cold = compiler(both).compile("Main");
		if (added.artifact.hashLink().hashLinkBytes().flatten()
			.compare(cold.artifact.hashLink().hashLinkBytes().flatten()) != 0)
			throw "Adding the unaliased import differs between warm and cold builds";
		warm.update("Main.hx", missing);
		try {
			warm.compile("Main");
			throw "Removing the unaliased import still resolved its bare name";
		} catch (error:CompileError) {
			if (error.diagnostic.code != "E1007") throw error;
		}
		warm.update("Main.hx", both);
		var restored = warm.compile("Main");
		if (restored.artifact.hashLink().hashLinkBytes().flatten()
			.compare(cold.artifact.hashLink().hashLinkBytes().flatten()) != 0)
			throw "Restoring the import differs from a cold build";
		Sys.println("PASS: aliased and unaliased imports remain distinct across warm edits");
	}
}
