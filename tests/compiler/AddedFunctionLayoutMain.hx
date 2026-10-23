import compiler.Compiler;
import compiler.hl.HlCode;
import compiler.hl.patch.HlPatchReader;
import compiler.runtime.CompilerIntrinsics;

/**
 * A function an edit adds takes the slot after every slot the running module has, and never moves a native: code the edit
 * leaves alone still calls natives by the slots it was compiled with, ordinary C call dispatchers included.
 */
class AddedFunctionLayoutMain {
	static function main():Void {
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addFfiInterface("fixture.hxi",
			'interface Fixture @target("x86_64-linux-gnu") @library("fixture") {\n' +
			'\textern fn add(left: i32, right: i32) -> i32 @symbol("native_fixture_add");\n' + '}\n');
		var program = (extra:String, use:String) -> "import Fixture;\n"
			+ extra
			+ "function main():Int { return Fixture.add(1, 2)"
			+ use
			+ "; }\n";
		compiler.update("Main.hx", program("", ""));
		var before = compiler.compile("Main").module;
		if (natives(before).get("native_invoke_2") == null)
			throw "The program does not call C through a dispatch native";
		compiler.update("Main.hx", program("function helper():Int { return 39; }\n", " + helper()"));
		var after = compiler.compile("Main");
		if (after.requiresReload || after.patchBytes == null)
			throw 'Adding a function required a reload: ${[for (reason in after.reloadReasons) Std.string(reason)].join(", ")}';
		for (name => slot in natives(before))
			if (natives(after.module).get(name) != slot)
				throw 'Adding a function moved native $name from slot $slot to ${natives(after.module).get(name)}';
		var added = HlPatchReader.decode(after.patchBytes).addedFunctions;
		if (added.length != 1 || added[0].functionIndex != before.natives.length + before.functions.length)
			throw 'The added function does not take the next free slot ${before.natives.length + before.functions.length}: '
				+ [for (function_ in added) '${function_.name}@${function_.functionIndex}'].join(", ");
		Sys.println("PASS: added functions take the next free slot and leave natives in place");
	}

	static function natives(code:HlCode):Map<String, Int>
		return [for (native in code.natives) code.strings[native.name] => native.functionIndex];
}
