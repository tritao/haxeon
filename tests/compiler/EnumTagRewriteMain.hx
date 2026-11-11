import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrEnumTagLowering;
import compiler.ir.IrEnumTagStorage;
import compiler.ir.IrFunction;
import compiler.ir.IrOperands;
import compiler.ir.IrVerifier;

/** Tag storage rewrites only the values and escapes that change representation. */
@:access(compiler.ir.IrBuilder)
@:access(compiler.ir.IrInlineEnumEligibility)
class EnumTagRewriteMain {
	static function plain(name:String, index:Int):IrFunction {
		var b = new IrBuilder();
		b.returnValue(b.add(b.constInt(index), b.constInt(42)));
		return new IrFunction(name, b.arguments, I32, b.blocks, Ordinary);
	}

	static function main():Void {
		for (size in [1000, 4000]) {
			var p = new IrProgram("plain0"), originals = [for (i in 0...size) plain("plain" + i, i)];
			p.enums = [{name: "Mode", cases: [{name: "Off", params: []}, {name: "On", params: []}]}];
			p.functions = originals.copy();
			var b = new IrBuilder(), mode = b.argument("mode", Enum("Mode")), number = b.argument("number", I32);
			b.add(number, b.constInt(1));
			b.returnValue(mode);
			var mixed = new IrFunction("mixed",
				b.arguments, Enum("Mode"), b.blocks, Ordinary), scalar = b.blocks[0].instructions[0];
			p.functions.push(mixed);
			var descriptor = new IrBuilder();
			descriptor.returnValue(descriptor.typeValue(Function([Enum("Mode")], Array(Enum("Mode")))));
			p.functions.push(new IrFunction("descriptor", descriptor.arguments, TypeRef, descriptor.blocks, Ordinary));
			var escape = new IrBuilder(), input = escape.argument("mode", Enum("Mode"));
			escape.constInt(7);
			escape.call("accept", [input], Void);
			escape.returnValue(escape.constInt(42));
			p.functions.push(new IrFunction("escape", escape.arguments, I32, escape.blocks, Ordinary));
			p.natives = [{name: "accept", library: "test", symbol: "accept", arguments: [Dyn], result: Void}];

			IrEnumTagLowering.run(p);
			for (i in 0...size) if (p.functions[i]
				!= originals[i]) throw "An unrelated numeric function was copied by tag lowering";
			var changed = p.functions[size];
			if (changed == mixed || changed.arguments[1] != number
				|| changed.blocks[0].instructions[0] != scalar || !IrVerifier.sameType(
					changed.arguments[0].type,
					EnumTag("Mode")
				)) throw "Tag lowering copied unaffected values or failed to rewrite the changed argument";
			switch p.functions[size + 1].blocks[0].instructions[0].value {
				case TypeValue(_, type):
					if (!IrVerifier.sameType(type, Function([EnumTag("Mode")],
						Array(EnumTag("Mode"))))) throw "A descriptor-only tag use was skipped";
				default:
					throw "Missing descriptor";
			}
			IrEnumTagLowering.escapes(p);
			IrVerifier.verify(p);
			var escaped = p.functions[size + 2],
				count = p.functions.length, before = escaped.blocks[0].instructions.copy();
			IrEnumTagLowering.escapes(p);
			if (p.functions.length != count) throw "Repeated escape lowering duplicated helpers";
			for (i in 0...before.length) if (escaped.blocks[0].instructions[i]
				!= before[i]) throw "An already-lowered escape was rebuilt";
			if (new compiler.ir.IrInterpreter(p).run() != 42) throw "Selective rewriting changed unrelated execution";
		}

		// An arbitrary number of nominal tags must not enlarge the payload escape graph.
		var tagProgram = new IrProgram("main");
		tagProgram.functions = [plain("main", 0)];
		tagProgram.enums = [for (index in 0...4096)
			{name: "Tag" + index, cases: [{name: "Only", params: []}]}];
		tagProgram.enums.push({name: "Payload", cases: [{name: "Some", params: [I32]}]});
		var planner = new compiler.ir.IrInlineEnumLayout(tagProgram.enums, [], 64,
			compiler.ir.IrValueLaneLayout.IrValueLaneTarget.HashLink);
		var eligibility = new compiler.ir.IrInlineEnumEligibility(tagProgram, planner);
		if (eligibility.words != 1 || eligibility.allowed.exists("Tag0") || !eligibility.allowed.exists("Payload"))
			throw "Payload-free tags entered the payload escape graph";
		tagProgram.enums.pop();
		eligibility = new compiler.ir.IrInlineEnumEligibility(tagProgram, planner);
		if (eligibility.words != 0 || eligibility.allowed.keys().hasNext())
			throw "A tags-only program needs no payload eligibility scan";

		var edge = new IrValue(10, "edge", EnumTag("Missing")), output = new IrValue(11, "phi", I32);
		var instruction = Phi(output, [{block: 0, value: edge}]), seen = 0;
		IrOperands.anyValue(instruction, function(value) {
			seen++;
			return false;
		}
		);
		if (seen != 2) throw "Value visitor skipped the phi output or its edge use";
		var bad = new IrBuilder();
		bad.emit(instruction);
		bad.returnValue(bad.constInt(42));
		var malformed = new IrProgram("main");
		malformed.functions = [new IrFunction("main", bad.arguments, I32, bad.blocks, Ordinary)];
		var message = "";
		try IrEnumTagStorage.verify(malformed) catch (error:Dynamic) message = Std.string(error);
		if (message.indexOf('requires a payload-free enum "Missing"')
			< 0) throw "Allocation-free verification skipped an invalid phi edge type";
		Sys.println("PASS: 1,000/4,000 unrelated functions retain their IR; escapes are stable; descriptor and phi checks remain complete");
	}
}
