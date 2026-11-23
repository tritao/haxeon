import compiler.Compiler;
import compiler.core.Diagnostic.CompileError;
import compiler.runtime.CompilerIntrinsics;
import compiler.semantic.Invalidation.InvalidatedArtifact;
import compiler.semantic.Invalidation.InvalidationKind;

class InvalidationMain {
	static function main():Void {
		var compiler = new Compiler();
		compiler.update("Leaf.hx", "function value():Int return 42;");
		compiler.update("Middle.hx", "function value():Int return Leaf.value();");
		compiler.update("Main.hx", "function main():Int return Middle.value() + Inferring.value();");
		compiler.update("Inferred.hx", "function value():Int return 1;");
		compiler.update("Inferring.hx", "function value() return Inferred.value();");
		compiler.compile("Main");
		var noOp = compiler.compile("Main");
		expect(noOp.invalidations.length == 0, "no-op compilation reported invalidations");

		compiler.update("Leaf.hx", "function value(?offset:Int = 0):Int return 42 + offset;");
		var changed = compiler.compile("Main");
		expect(changed.metrics.invalidatedArtifacts == changed.invalidations.length,
			"invalidation artifact metric disagreed with details");
		expect(changed.metrics.invalidationReasons >= changed.metrics.invalidatedArtifacts,
			"invalidation reason metric was incomplete");
		expectReason(changed.invalidations, "Leaf.value", SignatureChanged, "Leaf.value");
		expectReason(changed.invalidations, "Middle.value", DependencySignature, "Leaf.value");
		// A caller is retyped with its callee's new signature, as Haxe types it again; its own signature stays, so its callers
		// are not.
		expectInvalidated(changed.invalidations, ["Leaf.value", "Middle.value"]);

		// A changed body leaves its callers alone.
		compiler.update("Middle.hx", "function value():Int return Leaf.value() + 1;");
		expectInvalidated(compiler.compile("Main").invalidations, ["Middle.value"]);

		// A signature changes with its callee's when it is inferred, and then its callers are retyped in turn.
		compiler.update("Inferred.hx", "function value(?offset:Int = 0):Int return 1 + offset;");
		var inferred = compiler.compile("Main");
		expectReason(inferred.invalidations, "Inferring.value", DependencySignature, "Inferred.value");
		expectReason(inferred.invalidations, "main", DependencySignature, "Inferring.value");
		expectInvalidated(inferred.invalidations, ["Inferred.value", "Inferring.value", "main"]);

		var structural = new Compiler();
		structural.update("model/Value.hx", "package model; class Value {}");
		structural.update("Main.hx", "class Holder { public var value:model.Value; } function main():Int return 0;");
		structural.compile("Main");
		structural.update("model/Value.hx", "package model; class Value { public var changed:Int; }");
		var layout = structural.compile("Main");
		expectReason(layout.invalidations, "Holder", StructuralDependency, "model.Value");

		// An argument renamed with its uses is a signature change: a build that kept the validated signature would type the new
		// body against the old name.
		var renamed = new Compiler();
		renamed.update("Lib.hx", "function twice(value:Int):Int return value * 2;");
		renamed.update("Main.hx", "function main():Int return Lib.twice(21);");
		renamed.compile("Main");
		renamed.update("Lib.hx", "function twice(input:Int):Int return input * 2;");
		renamed.compile("Main");

		compiler.update("Leaf.hx", "function value(:Int return 0;");
		try {
			compiler.compile("Main");
			throw "broken edit compiled";
		} catch (_:CompileError) {}
		compiler.update("Leaf.hx", "function value(?offset:Int = 0):Int return 42 + offset;");
		var recovered = compiler.compile("Main");
		for (artifact in recovered.invalidations)
			for (reason in artifact.reasons)
				expect(reason.cause.indexOf("broken") < 0, "failed candidate leaked an invalidation reason");

		// An edit that changes no meaning retypes nothing. Purity is inferred twice: over the signature table typing resolves
		// calls against, and by the drift check that compares a cached body's answers with a fresh inference. Inferred over
		// a different table, the second called functions pure that the first did not (`MessagePackReader.readFloat` among
		// them), so cached bodies looked drifted on every edit.
		var wire = new Compiler();
		CompilerIntrinsics.register(wire);
		wire.addStandardLibrarySourceRoot("stdlib");
		var wireSource = sys.io.File.getContent("tests/programs/messagepack-wire.hx");
		wire.update("messagepack-wire.hx", wireSource);
		wire.compile("messagepack-wire");
		wire.update("messagepack-wire.hx", wireSource + "\n// a comment\n");
		var commented = wire.compile("messagepack-wire");
		expect(commented.retyped.length == 0, "a comment-only edit retyped " + commented.retyped);

		// The typer counts a generated flags helper as pure. The drift check must count it the same way, or a body that calls one
		// looks drifted whenever purity is inferred again: on every edit anywhere.
		var flags = new Compiler();
		CompilerIntrinsics.register(flags);
		flags.addStandardLibrarySourceRoot("stdlib");
		flags.update("Perm.hx", "enum abstract Perm(Int) implements Flags { var Read = 1; var Write = 2; }");
		// A call the typer knows is pure keeps what a check narrowed: `name` stays a String across `contains`.
		flags.update("Uses.hx", "class Uses { var name:Null<String> = \"a\"; public function new() {}\n"
			+ "public function allowed(p:Perm):Int { if (name != null && p.contains(Perm.Read)) return name.length; return 0; } }");
		var flagsMain = (value:Int) -> "function other():Int return " + value + ";\n"
			+ "function main():Int return new Uses().allowed(Perm.Read) + other();";
		flags.update("Main.hx", flagsMain(1));
		flags.compile("Main");
		flags.update("Main.hx", flagsMain(2));
		var flagsEdit = flags.compile("Main");
		for (name in flagsEdit.retyped)
			expect(!StringTools.startsWith(name, "Uses."), "an edit elsewhere retyped a caller of a flags helper: "
				+ flagsEdit.retyped);

		// A lambda is retyped with the function it is written in, and only then: editing `run` retypes the lambda inside it, while
		// editing `other` leaves it alone.
		var closures = new Compiler();
		var closureSource = (body:String, otherValue:Int) -> "function apply(f:Int->Int, x:Int):Int return f(x);\n"
			+ "function run(a:Int):Int { return apply(function(v:Int):Int return "
			+ body
			+ ", 1); }\n"
			+ "function other():Int return "
			+ otherValue
			+ ";\n"
			+ "function main():Int return run(1) + other();";
		closures.update("Main.hx", closureSource("v + a", 1));
		closures.compile("Main");
		closures.update("Main.hx", closureSource("v * a", 1));
		var lambdaEdit = closures.compile("Main");
		expect(Lambdas.among(lambdaEdit.retyped, "Main.run") == 1,
			"editing a function retypes the lambda inside it: " + lambdaEdit.retyped);
		closures.update("Main.hx", closureSource("v * a", 2));
		var otherEdit = closures.compile("Main");
		expect(Lambdas.among(otherEdit.retyped, "Main.run") == 0,
			"editing another function leaves the lambda alone: " + otherEdit.retyped);

		Sys.println("PASS: structured invalidation reasons");
	}

	static function expectReason(invalidations:Array<InvalidatedArtifact>, artifact:String, kind:InvalidationKind,
			cause:String):Void {
		for (entry in invalidations)
			if (entry.artifact == artifact)
				for (reason in entry.reasons)
					if (reason.kind == kind && reason.cause == cause)
						return;
		throw 'Missing invalidation $artifact <- $kind($cause): $invalidations';
	}

	/** That `invalidations` are of exactly the artifacts `expected`. */
	static function expectInvalidated(invalidations:Array<InvalidatedArtifact>, expected:Array<String>):Void {
		var names = [for (entry in invalidations) entry.artifact];
		names.sort(Reflect.compare);
		expected.sort(Reflect.compare);
		expect(names.join(",") == expected.join(","), 'invalidated $names, expected $expected: $invalidations');
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}

/** Counts the lambdas written in a function among `names`. */
private class Lambdas {
	public static function among(names:Array<String>, owner:String):Int {
		var count = 0;
		for (name in names)
			if (compiler.semantic.LambdaName.enclosing(name) == owner)
				count++;
		return count;
	}
}
