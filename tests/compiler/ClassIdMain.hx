import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrClassIds;
import compiler.ir.IrFunction;
import compiler.ir.IrInterpreter;

/** `ClassId` and the persistent class ids (docs/INTERFACE_VALUES.md): the instruction verifies, round trips and runs, and the ids are stable. */
class ClassIdMain {
	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}

	static function main():Void {
		ids();
		instruction();
		Sys.println("PASS: class ids are deterministic, persistent and never reused; ClassId verifies, round trips and interprets");
	}

	static function ids():Void {
		// Cold: by name, whatever order the classes arrive in.
		var first = IrClassIds.assign(null, ["Gamma", "Alpha", "Beta"]), second = IrClassIds.assign(null, ["Beta", "Gamma", "Alpha"]);
		for (name in ["Alpha", "Beta", "Gamma"])
			expect(first.ids.get(name) == second.ids.get(name), "a cold build assigns the same ids whatever the order of the classes");
		expect(first.ids.get("Alpha") == 0 && first.ids.get("Beta") == 1 && first.ids.get("Gamma") == 2, "ids follow the name order");
		// Warm: a class keeps its id, a new class takes the next one (by name among the new), a removed class leaves a hole.
		var edited = IrClassIds.assign(first, ["Gamma", "Beta", "Delta", "Aardvark"]);
		expect(edited.ids.get("Gamma") == 2 && edited.ids.get("Beta") == 1, "a class keeps its id");
		expect(edited.ids.get("Aardvark") == 3 && edited.ids.get("Delta") == 4, "new classes take the next ids in name order, not before the existing ones");
		var live = IrClassIds.liveIds(edited, ["Gamma", "Beta", "Delta", "Aardvark"]);
		expect(!live.exists("Alpha"), "a removed class has no live id");
		// A removed class that comes back is not given its old id's neighbours, and a later class never takes a burnt id.
		var later = IrClassIds.assign(edited, ["Gamma", "Beta", "Delta", "Aardvark", "Omega"]);
		expect(later.ids.get("Omega") == 5 && later.next == 6, "the next id only grows");
		var again = IrClassIds.assign(IrClassIds.assign(null, ["Alpha"]), ["Beta"]);
		expect(again.ids.get("Alpha") == 0 && again.ids.get("Beta") == 1, "an id given earlier in the session is not reused");
	}

	static function program():IrProgram {
		var builder = new IrBuilder();
		var object = builder.newObject("Widget");
		var id = builder.classId(object);
		builder.returnValue(id);
		var program = new IrProgram("main");
		program.objects = [{name: "Widget", isValue: false, base: null, interfaces: [], fields: [], methods: []}];
		program.functions = [new IrFunction("main", builder.arguments, I32, builder.blocks, Ordinary)];
		program.classIds = ["Widget" => 7];
		return program;
	}

	static function instruction():Void {
		var original = program();
		compiler.ir.IrVerifier.verify(original);
		expect(new IrInterpreter(original).run("main") == 7, "the interpreter returns the class id of the object's class");
		var decoded = compiler.ir.codec.CanonicalIrCodec.decode(compiler.ir.codec.CanonicalIrCodec.encode(original));
		expect(compiler.ir.codec.IrFunctionStateEquality.same(original.functions[0], decoded.functions[0]), "ClassId survives the canonical IR codec");
		// An id of a type that is not an I32 is refused.
		var bad = new IrBuilder();
		var made = bad.newObject("Widget");
		bad.classIdAs(made, Bool);
		bad.returnValue(bad.constInt(0));
		var broken = program();
		broken.functions = [new IrFunction("main", bad.arguments, I32, bad.blocks, Ordinary)];
		var refused = false;
		try
			compiler.ir.IrVerifier.verify(broken)
		catch (error:Dynamic)
			refused = true;
		expect(refused, "a class id whose output is not an I32 is refused");
	}
}
