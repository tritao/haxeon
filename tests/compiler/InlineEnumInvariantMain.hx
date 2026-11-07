import compiler.Compiler;
import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.ir.IrVerifier;

/** A missed physical rewrite must fail even when it occurs in an unselected cached body. */
class InlineEnumInvariantMain {
	static function copy(program:IrProgram):IrProgram {
		var result = new IrProgram(program.entryPoint);
		result.objects = program.objects.copy();
		result.enums = program.enums.copy();
		result.interfaces = program.interfaces.copy();
		result.staticFields = program.staticFields.copy();
		result.natives = program.natives.copy();
		result.cNatives = program.cNatives.copy();
		result.functions = program.functions.copy();
		return result;
	}

	static function main():Void {
		for (target in ["hl", "wasm32", "wasm-gc"])
			for (inlineEnabled in [false, true]) {
				var c = new Compiler(null, compiler.runtime.CompilerIntrinsics.configuration());
				c.addSourceRoot("stdlib");
				c.configure("enum-invariant-" + target + inlineEnabled, "enum-invariant",
					compiler.tools.CompilerDriver.targetDefines(target).concat(["haxeon-inline=" + (inlineEnabled ? 1 : 0)]));
				c.update("Main.hx",
					'enum E { Code(value:Int); } function main():Int { var values:Array<E>=[Code(42)]; return switch values[0] { case Code(value): value; }; }');
				var base = c.compile("Main").ir,
					declaration:Null<IrEnum> = null;
				for (entry in base.enums)
					if (entry.name == "E")
						declaration = entry;
				if (declaration == null || declaration.inlineStorage == null)
					throw "Expected selected source enum";
				IrVerifier.verify(base);
				var containers = copy(base), valid = new IrBuilder();
				valid.argument("array", Nullable(Array(Enum("E"))));
				valid.argument("iterator", Iterator(Enum("E")));
				valid.returnValue(valid.constInt(42));
				containers.functions.push(new IrFunction("logicalHandles", valid.arguments, I32, valid.blocks));
				containers.objects.push({
					name: "LogicalHandles",
					isValue: false,
					base: null,
					interfaces: [],
					methods: [],
					fields: [{name: "callback", type: Function([Array(Enum("E")), Iterator(Enum("E"))], I32)}]
				});
				IrVerifier.verify(containers);
				for (kind in 0...14) {
					var bad = copy(base),
						b = new IrBuilder(),
						result:IrType = I32,
						name = "forgedEnumUse";
					switch kind {
						case 0:
							b.constNull(Enum("E"));
						case 1:
							b.equal(new IrValue(1000, "left", Enum("E")), new IrValue(1001, "right", Enum("E")));
						case 2:
							b.phi(Obj(declaration.inlineStorage), [{block: 0, value: new IrValue(1000, "incoming", Enum("E"))}]);
						case 3:
							b.argument("callback", Function([Nullable(Enum("E"))], Array(Enum("E"))));
						case 4:
							result = Array(Function([Enum("E")], I32));
						case 5:
							bad.objects.push({
								name: "ForgedHolder",
								isValue: false,
								base: null,
								interfaces: [],
								methods: [],
								fields: [{name: "value", type: Nullable(Enum("E"))}]
							});
						case 6:
							bad.staticFields.push({name: "forgedGlobal", type: Function([], Enum("E"))});
						case 7:
							bad.interfaces.push({name: "ForgedContract", bases: [], methods: [{name: "accept", arguments: [Enum("E")], result: Void}]});
						case 8:
							bad.natives.push({
								name: "__array_unhandled_ref",
								library: "test",
								symbol: "forged",
								arguments: [],
								result: Enum("E")
							});
						case 9:
							b.call("__std_is_of_type", [b.constNull(Dyn), b.typeValue(Enum("E"))], Bool);
						case 10:
							b.returnValue(b.typeValue(Enum("E")));
							result = TypeRef;
						case 12:
							bad.cNatives.push({
								name: "forged_c",
								library: "test",
								symbol: "forged_c",
								signature: "v_p",
								pointerOwnership: "borrowed",
								pointerRelease: null,
								pointerLength: null,
								pointerNullable: false,
								arguments: [Function([Enum("E")], I32)],
								argumentModes: [Value],
								result: Void
							});
						case 13:
							b.argument("callbacks", Iterator(Function([Enum("E")], Void)));
						case 11:
							name = "$inline-enum:helper:not-an-escape:E";
							b.constNull(Enum("E"));
					}
					if (kind != 10)
						b.returnValue(b.constInt(42));
					bad.functions.push(new IrFunction(name, b.arguments, result, b.blocks));
					var error = "";
					try
						IrVerifier.verifyFunctions(bad, ["main" => true])
					catch (failure:Dynamic)
						error = Std.string(failure);
					if (error.indexOf('IR inline enum "E" retains nominal value storage') < 0)
						throw 'Missing invariant for $target inline=$inlineEnabled case=$kind: $error';
				}
			}
		Sys.println("PASS: inline enum operands, outputs, phis, fields, signatures and non-array descriptors fail closed on all targets/inlining modes");
	}
}
