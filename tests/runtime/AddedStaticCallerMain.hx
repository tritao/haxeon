import compiler.hl.HlWriter;
import compiler.Compiler;
import compiler.runtime.CompilerIntrinsics;
import runtime.PatchSet;
import runtime.Runtime;

/** An edit adding a static function that existing methods of the same class start calling patches the module. */
class AddedStaticCallerMain {
	static function main():Void {
		var program = (extra:String, label:String) -> "class Panel {\n"
			+ "  var keys:Array<String>;\n"
			+ "  public function new() keys = [\"t:1\", \"t:2\", \"a:3\"];\n"
			+ "  static function plural(count:Int, noun:String):String return count + \" \" + noun + (count == 1 ? \"\" : \"s\");\n"
			// The library code the edit uses is already part of the program, as it is in an application.
			+ "  public function terminals():String return '(${keys.filter(function(key) return StringTools.startsWith(key, \"t:\")).length} of ${keys.length})';\n"
			+ extra
			+ "  public function menu():String return " + label + ";\n"
			+ "  public function header():String return " + label + ";\n"
			+ "}\n"
			+ "function main():Int {\n"
			+ "  var panel = new Panel();\n"
			+ "  return panel.menu().length + panel.header().length;\n"
			+ "}\n";
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addSourceRoot("stdlib");
		compiler.update("Main.hx", program("", "plural(keys.length, \"Item\")"));
		var build = compiler.compile("Main"),
			live = Runtime.load(HlWriter.encode(build.module), build.runtimeIdentity),
			mainId = build.functionIds.get("main");
		if (Runtime.callInt(live, mainId) != 14)
			throw "The program did not run correctly before the edit";
		compiler.update("Main.hx", program("  static function closeLabel(keys:Array<String>):String {\n"
			+ "    var terminals = keys.filter(function(key) return StringTools.startsWith(key, \"t:\")).length;\n"
			+ "    return \"Close \" + plural(keys.length, terminals == keys.length ? \"Terminal\" : \"Item\") + ' ($terminals)';\n"
			+ "  }\n", "closeLabel(keys)"));
		var changed = compiler.compile("Main");
		if (changed.requiresReload || changed.patchBytes == null)
			throw 'The edit required a reload (requiresReload ${changed.requiresReload}, patch ${changed.patchBytes != null}): '
				+ [for (reason in changed.reloadReasons) Std.string(reason)].join(", ");
		Runtime.patchSet(live, new PatchSet(build.revision, changed.revision, changed.patchBytes, changed.changedFunctions));
		// "Close 3 Items (2)" twice.
		var result = Runtime.callInt(live, mainId);
		if (result != 34)
			throw 'The patched module returned $result instead of 34';
		// Undoing the edit removes the function again, which patches too.
		compiler.update("Main.hx", program("", "plural(keys.length, \"Item\")"));
		var undone = compiler.compile("Main");
		if (undone.requiresReload || undone.patchBytes == null)
			throw 'Removing the function required a reload: ' + [for (reason in undone.reloadReasons) Std.string(reason)].join(", ");
		Runtime.patchSet(live, new PatchSet(changed.revision, undone.revision, undone.patchBytes, undone.changedFunctions));
		result = Runtime.callInt(live, mainId);
		if (result != 14)
			throw 'After removing the function the patched module returned $result instead of 14';
		var fresh = Runtime.load(HlWriter.encode(undone.module), undone.runtimeIdentity);
		result = Runtime.callInt(fresh, undone.functionIds.get("main"));
		Runtime.dispose(fresh);
		if (result != 14)
			throw 'After removing the function the full module returned $result instead of 14';
		Runtime.dispose(live);
		Sys.println("PASS: adding a static function that existing methods call, and removing it again, patch the running module");
	}
}
