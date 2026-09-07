import compiler.Compiler;
import compiler.modules.ModuleState.SemanticDependencyKind;

class ResolvedSemanticDependencyMain {
	static function main():Void {
		var compiler = new Compiler();
		compiler.update("demo/Box.hx",
			"package demo; function seed():Int return 42; class Box { public var value:Int = seed(); public function read():Int return value; }");
		compiler.update("Main.hx",
			"import demo.Box; class Holder { public var box:Box; } function consume(box:Box):Int return box.value; function main():Int { var box:Box = new Box(); return box.read(); }");
		compiler.compile("Main");

		var dependencies = compiler.modules.get("Main").semanticDependencies.get("main"), resolved = 0, guessed = 0;
		for (dependency in dependencies)
			if (dependency.kind == SemanticDependencyKind.Body) {
				if (dependency.target == "demo.Box.read" && dependency.targetId == "demo.Box:member:Box.read")
					resolved++;
				if (dependency.target == "read")
					guessed++;
			}
		if (resolved != 1 || guessed != 0)
			throw 'Expected one resolved demo.Box.read edge and no textual read edge, got $dependencies';
		expectDependency(compiler.modules.get("Main").semanticDependencies.get("Main.consume"), SemanticDependencyKind.Signature, "demo.Box",
			"demo.Box:class:Box");
		expectDependency(compiler.modules.get("Main").semanticDependencies.get("Main.consume"), SemanticDependencyKind.Body, "demo.Box.value",
			"demo.Box:member:Box.value");
		expectDependency(compiler.modules.get("Main").semanticDependencies.get("Holder"), SemanticDependencyKind.Layout, "demo.Box", "demo.Box:class:Box");
		expectDependency(compiler.modules.get("demo.Box").semanticDependencies.get("demo.Box.value"), SemanticDependencyKind.Initializer, "demo.Box.seed",
			"demo.Box:function:seed");

		compiler.update("demo/Box.hx",
			"package demo; function seed():Int return 42; class Box { public var value:Int = seed(); public function read(?unused:Int = 0):Int return value; }");
		var changed = compiler.compile("Main");
		if (changed.retyped.indexOf("main") < 0)
			throw 'Resolved method signature dependency did not invalidate main: ${changed.retyped}';

		var collision = new Compiler();
		collision.update("left/Box.hx", "package left; class Box {}");
		collision.update("right/Box.hx", "package right; class Box {}");
		collision.update("LeftUse.hx", "function consume(box:left.Box):Int return 42;");
		collision.update("RightUse.hx", "function unused(box:right.Box):Int return 0;");
		collision.update("Main.hx", "import RightUse; function main():Int return LeftUse.consume(new left.Box());");
		collision.compile("Main");
		collision.update("right/Box.hx", "package right; class Box { public var added:Int; }");
		var unrelated = collision.compile("Main");
		if (unrelated.retyped.indexOf("LeftUse.consume") >= 0 || unrelated.retyped.indexOf("main") >= 0)
			throw 'Stable dependency IDs confused same-named declarations: ${unrelated.retyped}';
		Sys.println("PASS: resolved semantic dependencies");
	}

	static function expectDependency(dependencies:Array<compiler.modules.ModuleState.SemanticDependency>, kind:SemanticDependencyKind, target:String,
			targetId:String):Void {
		if (dependencies != null)
			for (dependency in dependencies)
				if (dependency.kind == kind && dependency.target == target && dependency.targetId == targetId)
					return;
		throw 'Missing resolved $kind dependency $target ($targetId): $dependencies';
	}
}
