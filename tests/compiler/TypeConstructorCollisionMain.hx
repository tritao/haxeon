import compiler.Compiler;
import compiler.runtime.CompilerIntrinsics;

/** Covers enum constructor aliases not shadowing visible class type names. */
class TypeConstructorCollisionMain {
	static function main():Void {
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.update("nativekit/ui/core/DockNode.hx",
			"package nativekit.ui.core; enum DockNode { Empty; Tabs(ids:Array<String>, active:String); "
			+ "Split(first:DockNode, second:DockNode); }");
		compiler.update("nativekit/ui/widgets/Tabs.hx",
			"package nativekit.ui.widgets; class Tabs { public function new() {} }");
		compiler.update("nativekit/ui/widgets/Workspace.hx",
			"package nativekit.ui.widgets; import nativekit.ui.core.DockNode; class Workspace { "
			+ "public function make():DockNode return DockNode.Tabs([], 'active'); "
			+ "public function render(node:DockNode):Void { switch (node) { "
			+ "case DockNode.Empty: new Tabs(); case DockNode.Tabs(_, _): new Tabs(); "
			+ "case DockNode.Split(_, _): new Tabs(); } } }");
		compiler.update("Main.hx",
			"import nativekit.ui.core.DockNode; import nativekit.ui.widgets.Tabs; "
			+ "import nativekit.ui.widgets.Workspace; function main():Void { "
			+ "var node:DockNode = DockNode.Tabs([], 'active'); new Workspace().make(); }");
		compiler.analyze("Main");
		Sys.println("PASS: enum constructor aliases preserve visible class types");
	}
}
