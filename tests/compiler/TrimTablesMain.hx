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
		// A native call whose declared signature names classes that no value of the function has the type of.
		builder.call("calledNative", [builder.constNull(Dyn)], Dyn);
		builder.returnValue(builder.constInt(0));
		var program = new IrProgram("main");
		program.objects = [object("Named"), object("Unused"), object("Declared"), object("Returned")];
		program.natives = [
			{
				name: "unusedNative",
				library: "std",
				symbol: "unused_native",
				arguments: [],
				result: Void
			},
			{
				name: "calledNative",
				library: "std",
				symbol: "called_native",
				arguments: [Obj("Declared")],
				result: Obj("Returned")
			}
		];
		program.staticFields = [{name: "Unused.global", type: I32}];
		program.functions = [new IrFunction("main", builder.arguments, I32, builder.blocks, Ordinary)];
		var walk = IrReachability.walkWithGeneratedRuntimeRoots(program, "main", null, true);
		IrReachability.trimTables(program, walk);
		var names = [for (kept in program.objects) kept.name];
		expect(names.indexOf("Named") >= 0, 'A class named only by a type value was trimmed: $names');
		expect(names.indexOf("Unused") < 0, 'An unreferenced class stayed: $names');
		expect(names.indexOf("Declared") >= 0 && names.indexOf("Returned") >= 0, 'A class named only by the signature of a kept native was trimmed: $names');
		expect([for (native in program.natives) native.name].join(",") == "calledNative", "An uncalled native stayed or the called one went");
		var broken = new IrProgram("main");
		broken.functions = [];
		broken.natives = program.natives;
		var named = false;
		try
			IrReachability.checkTables(broken)
		catch (error:Dynamic)
			named = Std.string(error).indexOf('names class "Declared"') >= 0;
		expect(named, "The table check did not name the class a native signature needs");
		expect(program.staticFields.length == 0, "An unused global stayed");
		Sys.println("PASS: trimming the module tables keeps a class named by a type value and keeps a class named by the signature of a kept native, and drops unreferenced classes, natives and globals");
	}
}
