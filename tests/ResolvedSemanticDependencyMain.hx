import compiler.Compiler;
import compiler.modules.ModuleState.SemanticDependencyKind;

class ResolvedSemanticDependencyMain {
	static function main():Void {
		var compiler = new Compiler();
		compiler.update("demo/Box.hx", "package demo; class Box { public function read():Int return 42; }");
		compiler.update("Main.hx", "import demo.Box; function main():Int { var box:Box = new Box(); return box.read(); }");
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

		compiler.update("demo/Box.hx", "package demo; class Box { public function read(?unused:Int = 0):Int return 42; }");
		var changed = compiler.compile("Main");
		if (changed.retyped.indexOf("main") < 0)
			throw 'Resolved method signature dependency did not invalidate main: ${changed.retyped}';
		Sys.println("PASS: resolved semantic dependencies");
	}
}
