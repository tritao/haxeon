import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.ir.IrReachability;

/**
 * `IrReachability.trimTables` writes a module from the reached program: a class a reached function names only through a type value stays, and an unreferenced
 * class, native and global go.
 */
class TrimTablesMain {
	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}

	static function object(name:String):IrObject
		return {
			name: name,
			isValue: false,
			base: null,
			interfaces: [],
			fields: [],
			methods: []
		};

	static function main():Void {
		var builder = new IrBuilder();
		builder.typeValue(Obj("Named"));
		builder.returnValue(builder.constInt(0));
		var program = new IrProgram("main");
		program.objects = [object("Named"), object("Unused")];
		program.natives = [{
			name: "unusedNative",
			library: "std",
			symbol: "unused_native",
			arguments: [],
			result: Void
		}];
		program.staticFields = [{name: "Unused.global", type: I32}];
		program.functions = [new IrFunction("main", builder.arguments, I32, builder.blocks, Ordinary)];
		var walk = IrReachability.walkWithGeneratedRuntimeRoots(program, "main", null, true);
		IrReachability.trimTables(program, walk);
		var names = [for (kept in program.objects) kept.name];
		expect(names.indexOf("Named") >= 0, 'A class named only by a type value was trimmed: $names');
		expect(names.indexOf("Unused") < 0, 'An unreferenced class stayed: $names');
		expect(program.natives.length == 0, "An uncalled native stayed");
		expect(program.staticFields.length == 0, "An unused global stayed");
		Sys.println("PASS: trimming the module tables keeps a class named by a type value and drops unreferenced classes, natives and globals");
	}
}
