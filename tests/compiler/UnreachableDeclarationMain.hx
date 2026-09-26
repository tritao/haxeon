import compiler.Compiler;

/** Covers incremental builds after a module stops being reachable from the entry point. */
class UnreachableDeclarationMain {
	static final HOLDER = "enum Stage { A; B; }\n"
		+ "class Holder {\n"
		+ "  var stage:Stage = A;\n"
		+ "  public function new() {}\n"
		+ "  public function next():Int { stage = switch stage { case A: B; case B: A; }; return 1; }\n"
		+ "}";
	static final CAPTURE = "enum Mode { On; Off; }\n"
		+ "class Capture {\n"
		+ "  public function new() {}\n"
		+ "  static function apply(callback:Int->Int):Int return callback(1);\n"
		+ "  public function run():Int { var mode = On; return apply(function(value) return mode == On ? value : 0); }\n"
		+ "}";
	static final REFERENCED = "function main():Int return new Holder().next() + new Capture().run() + 40;";
	static final UNREFERENCED = "function main():Int return 42;";

	static function main():Void {
		var compiler = new Compiler();
		compiler.update("Holder.hx", HOLDER);
		compiler.update("Capture.hx", CAPTURE);
		compiler.update("Main.hx", REFERENCED);
		expectObjects(compiler.compile("Main"), ["Holder", "Capture"], true, "initial build");

		compiler.update("Main.hx", UNREFERENCED);
		expectObjects(compiler.compile("Main"), ["Holder", "Capture"], false, "build after dropping the last references");

		compiler.update("Main.hx", REFERENCED);
		expectObjects(compiler.compile("Main"), ["Holder", "Capture"], true, "build after restoring the references");

		compiler.update("Main.hx", UNREFERENCED);
		compiler.compile("Main");
		compiler.remove("Holder.hx");
		compiler.remove("Capture.hx");
		expectObjects(compiler.compile("Main"), ["Holder", "Capture"], false, "build after removing the unreachable modules");
		Sys.println("unreachable declaration builds passed");
	}

	static function expectObjects(result:compiler.Compiler.CompileResult, names:Array<String>, present:Bool, label:String):Void {
		var typeNames:Map<String, Bool> = [];
		for (type in result.module.types)
			switch type {
				case Object(name, _, _, _, _, _), Structure(name, _, _, _, _):
					typeNames.set(result.module.strings[name], true);
				default:
			}
		for (name in names)
			if (typeNames.exists(name) != present)
				throw '$label: object "$name" should ${present ? "be" : "not be"} in the module';
	}
}
