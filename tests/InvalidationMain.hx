import compiler.Compiler;
import compiler.Diagnostic.CompileError;
import compiler.semantic.Invalidation.InvalidatedArtifact;
import compiler.semantic.Invalidation.InvalidationKind;

class InvalidationMain {
	static function main():Void {
		var compiler = new Compiler();
		compiler.update("Leaf.hx", "function value():Int return 42;");
		compiler.update("Middle.hx", "function value():Int return Leaf.value();");
		compiler.update("Main.hx", "function main():Int return Middle.value();");
		compiler.compile("Main");
		var noOp = compiler.compile("Main");
		expect(noOp.invalidations.length == 0, "no-op compilation reported invalidations");

		compiler.update("Leaf.hx", "function value(?offset:Int = 0):Int return 42 + offset;");
		var changed = compiler.compile("Main");
		expect(changed.metrics.invalidatedArtifacts == changed.invalidations.length, "invalidation artifact metric disagreed with details");
		expect(changed.metrics.invalidationReasons >= changed.metrics.invalidatedArtifacts, "invalidation reason metric was incomplete");
		expectReason(changed.invalidations, "Leaf.value", SignatureChanged, "Leaf.value");
		expectReason(changed.invalidations, "Middle.value", DependencySignature, "Leaf.value");
		expectReason(changed.invalidations, "main", DependencySignature, "Middle.value");

		var structural = new Compiler();
		structural.update("model/Value.hx", "package model; class Value {}");
		structural.update("Main.hx", "class Holder { public var value:model.Value; } function main():Int return 0;");
		structural.compile("Main");
		structural.update("model/Value.hx", "package model; class Value { public var changed:Int; }");
		var layout = structural.compile("Main");
		expectReason(layout.invalidations, "Holder", StructuralDependency, "model.Value");

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

		Sys.println("PASS: structured invalidation reasons");
	}

	static function expectReason(invalidations:Array<InvalidatedArtifact>, artifact:String, kind:InvalidationKind, cause:String):Void {
		for (entry in invalidations)
			if (entry.artifact == artifact)
				for (reason in entry.reasons)
					if (reason.kind == kind && reason.cause == cause)
						return;
		throw 'Missing invalidation $artifact <- $kind($cause): $invalidations';
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
