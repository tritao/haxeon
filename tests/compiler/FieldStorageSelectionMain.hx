import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.ir.IrNullableScalarFields;
import compiler.ir.IrOptionalFieldStorage;
import compiler.compilation.AllocationMeter;

class FieldStorageSelectionMain {
	static function main():Void {
		for (count in [0, 400])
			for (inherited in [false, true]) {
				var p = new IrProgram("main");
				p.objects = [
					{
						name: "Value",
						isValue: true,
						base: null,
						interfaces: [],
						methods: [],
						fields: [{name: "n", type: I32}]
					},
					{
						name: "Holder",
						isValue: false,
						base: null,
						interfaces: [],
						methods: [],
						fields: [
							{name: "maybe", type: Nullable(Obj("Value"))},
							{name: "narrow", type: Nullable(I32), nullableScalarStorage: {size: 1, signed: true}}
						]
					},
					{
						name: "Derived",
						isValue: false,
						base: "Holder",
						interfaces: [],
						methods: [],
						fields: []
					}
				];
				var b = new IrBuilder(),
					owner = b.argument("owner", Obj(inherited ? "Derived" : "Holder")),
					n = b.argument("n", Nullable(I32));
				b.fieldSet(owner, "narrow", n);
				b.fieldGet(owner, "maybe", Nullable(Obj("Value")));
				b.returnValue(b.constInt(42));
				p.functions.push(new IrFunction("main", b.arguments, I32, b.blocks));
				for (i in 0...count) {
					b = new IrBuilder();
					var v = b.argument("n", I32);
					for (j in 0...100)
						v = b.add(v, b.constInt(j));
					b.returnValue(v);
					p.functions.push(new IrFunction("f" + i, b.arguments, I32, b.blocks));
				}
				var original = p.functions.copy(),
					before = AllocationMeter.sample();
				var optional = new IrOptionalFieldStorage(p.objects);
				p.functions = optional.rewrite(p.functions);
				p.objects = optional.physicalObjects(p.objects);
				p.functions = new IrNullableScalarFields(p.objects).rewrite(p.functions);
				var bytes = AllocationMeter.sample().bytes - before.bytes;
				if (bytes > 1024 * 1024)
					throw 'Unrelated field rewrites allocated $bytes bytes, expected less than 1 MiB';
				for (i in 1...original.length)
					if (original[i] != p.functions[i])
						throw "An unrelated function lost its identity";
				compiler.ir.IrVerifier.verify(p);
			}
		checkDiagnostics();
		Sys.println("PASS: optional and nullable field lowering skips unrelated bodies and retains diagnostics");
	}

	static function checkDiagnostics():Void {
		var declarations:Array<IrObject> = [
			{
				name: "Value",
				isValue: true,
				base: null,
				interfaces: [],
				methods: [],
				fields: [{name: "n", type: I32}]
			},
			{
				name: "Holder",
				isValue: false,
				base: null,
				interfaces: [],
				methods: [],
				fields: [{name: "maybe", type: Nullable(Obj("Value"))}]
			}
		];
		var b = new IrBuilder(), owner = b.argument("owner", Obj("Holder"));
		b.call(IrOptionalFieldStorage.copyName("Holder", "missing", "Holder", "maybe"), [owner, owner], Void);
		b.returnValue(b.constInt(42));
		var fn = new IrFunction("badCopy", b.arguments, I32, b.blocks), caught = false;
		try {
			new IrOptionalFieldStorage(declarations).rewrite([fn]);
		} catch (error:Dynamic) {
			if (Std.string(error).indexOf("Incompatible optional field copy") < 0)
				throw error;
			caught = true;
		}
		if (!caught)
			throw "Invalid optional copies must still be diagnosed";
		declarations[1].fields.push({name: "narrow", type: Nullable(I32), nullableScalarStorage: {size: 4, signed: true}});
		b = new IrBuilder();
		owner = b.argument("owner", Obj("Holder"));
		var value = b.argument("value", Nullable(I32));
		b.fieldSet(owner, "narrow", value);
		b.returnValue(b.constInt(42));
		caught = false;
		try {
			new IrNullableScalarFields(declarations).rewrite([new IrFunction("badWidth", b.arguments, I32, b.blocks)]);
		} catch (error:Dynamic) {
			if (Std.string(error).indexOf("Invalid nullable scalar width") < 0)
				throw error;
			caught = true;
		}
		if (!caught)
			throw "Invalid nullable widths must still be diagnosed";
	}
}
