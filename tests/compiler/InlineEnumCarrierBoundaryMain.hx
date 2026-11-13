import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.ir.IrVerifier;
import compiler.ir.IrValueLaneReference;
import compiler.ir.IrHlScalarRef;
import compiler.ir.IrScalarArguments;

/** Private payload references may cross only a verified scalar ABI. */
class InlineEnumCarrierBoundaryMain {
	static function tempRoot():String {
		var root = Sys.getEnv("TMPDIR");
		return root == null ? "/tmp" : root;
	}

	static final uniqueStem = "InlineEnumCarrierBoundaryMain-" + Std.random(0x7fffffff) + "-";

	static function reject(label:String, build:IrProgram->Void, expected:String):Void {
		var p = new IrProgram("main");
		build(p);
		var message = "";
		try
			IrVerifier.verify(p)
		catch (error:Dynamic)
			message = Std.string(error);
		if (message.indexOf(expected) < 0)
			throw label + ": expected " + expected + ", got " + message;
		Sys.println("PASS: rejects " + label);
	}

	static function main():Void {
		reject("ordinary carrier argument", function(p) {
			var b = new IrBuilder();
			b.argument("value", IrValueLaneReference.type());
			b.returnValue(b.constInt(42));
			p.functions = [new IrFunction("main", b.arguments, I32, b.blocks, Ordinary)];
		}, "A value lane reference cannot cross an ordinary function boundary");
		reject("scalar function returning a carrier", function(p) {
			p.entryPoint = IrScalarArguments.PREFIX + "bad";
			var b = new IrBuilder();
			b.returnValue(b.constNull(IrValueLaneReference.type()));
			p.functions = [
				new IrFunction(p.entryPoint, b.arguments, IrValueLaneReference.type(), b.blocks, Ordinary)
			];
		}, "A value lane reference cannot be returned");
		for (name in ["nativeEscape", IrScalarArguments.PREFIX + "fakeNative"])
			reject(name, function(p) {
				p.natives = [
					{
						name: name,
						library: "test",
						symbol: "escape",
						arguments: [IrValueLaneReference.type()],
						result: Void
					}
				];
				var b = new IrBuilder();
				b.call(name, [b.constNull(IrValueLaneReference.type())], Void);
				b.returnValue(b.constInt(42));
				p.functions = [new IrFunction("main", b.arguments, I32, b.blocks, Ordinary)];
			}, "A value lane reference cannot escape its operation");
		reject("wrong private argument signature", function(p) {
			var name = IrScalarArguments.PREFIX + "typed",
				callee = new IrBuilder();
			callee.argument("value", I32);
			callee.returnValue(callee.constVoid());
			var b = new IrBuilder();
			b.call(name, [b.constNull(IrValueLaneReference.type())], Void);
			b.returnValue(b.constInt(42));
			p.functions = [
				new IrFunction("main", b.arguments, I32, b.blocks, Ordinary),
				new IrFunction(name, callee.arguments, Void, callee.blocks, Ordinary)
			];
		}, "Wrong IR argument type");
		reject("wrong scalar load element", function(p) {
			var b = new IrBuilder(),
				pointer = b.call(IrHlScalarRef.ADDRESS, [b.constInt(42)], IrHlScalarRef.type(I32));
			b.call(IrHlScalarRef.LOAD, [pointer], IrValueLaneReference.type());
			b.returnValue(b.constInt(42));
			p.functions = [new IrFunction("main", b.arguments, I32, b.blocks, Ordinary)];
		}, "Invalid scalar reference intrinsic");
		for (array in [false, true])
			reject(array ? "scalar enum storage array boxed as Dynamic" : "scalar enum storage boxed as Dynamic", function(p) {
				var name = "$inline-enum:Scalar";
				p.objects = [
					{
						name: name,
						isValue: true,
						base: null,
						interfaces: [],
						methods: [],
						fields: [{name: "tag", type: I32}, {name: "scalar0", type: I32}]
					}
				];
				var b = new IrBuilder(),
					value = array ? b.argument("array", Array(Obj(name))) : b.newObject(name);
				b.returnValue(b.toDyn(value));
				p.functions = [new IrFunction("main", b.arguments, Dyn, b.blocks, Ordinary)];
			}, "requires a logical Dynamic adapter");
		for (nested in [false, true])
			reject(nested ? "nested carrier record boxed as Dynamic" : "carrier record boxed as Dynamic", function(p) {
				var packet:IrObject = {
					name: "Packet",
					isValue: true,
					base: null,
					interfaces: [],
					methods: [],
					fields: [{name: "reference0", type: IrValueLaneReference.type()}]
				};
				var outer:IrObject = {
					name: "Outer",
					isValue: true,
					base: null,
					interfaces: [],
					methods: [],
					fields: [{name: "packet", type: Obj("Packet")}]
				};
				p.objects = [packet, outer];
				var b = new IrBuilder(), value = b.newObject("Packet");
				b.fieldSet(value, "reference0", b.constNull(IrValueLaneReference.type()));
				if (nested) {
					var wrapper = b.newObject("Outer");
					b.fieldSet(wrapper, "packet", value);
					value = wrapper;
				}
				b.returnValue(b.toDyn(value));
				p.functions = [new IrFunction("main", b.arguments, Dyn, b.blocks, Ordinary)];
			}, "requires a logical Dynamic adapter");
		reject("carrier record recovered from Dynamic without an adapter", function(p) {
			p.objects = [
				{
					name: "Packet",
					isValue: true,
					base: null,
					interfaces: [],
					methods: [],
					fields: [{name: "reference0", type: IrValueLaneReference.type()}]
				}
			];
			var b = new IrBuilder();
			b.safeCast(b.constNull(Dyn), Obj("Packet"));
			b.returnValue(b.constInt(42));
			p.functions = [new IrFunction("main", b.arguments, I32, b.blocks, Ordinary)];
		}, "requires a logical cast adapter");
		reject("negative slot namespace", function(p) {
			var b = new IrBuilder();
			b.returnValue(b.constInt(42));
			p.functions = [
				new IrFunction("main", b.arguments, I32, b.blocks, ValueArraySlot(-1, Obj("Packet"), Read(0, [], false)))
			];
		}, "Invalid value-array slot namespace");
		reject("negative slot index", function(p) {
			var b = new IrBuilder();
			b.returnValue(b.constInt(42));
			p.functions = [
				new IrFunction("main", b.arguments, I32, b.blocks, ValueArraySlot(0, Obj("Packet"), Read(-1, [], false)))
			];
		}, "Invalid value-array slot");
		for (wrongPath in [false, true])
			reject(wrongPath ? "forged lane field path" : "wrong lane array signature", function(p) {
				var element:IrType = Obj("Packet");
				var packet:IrObject = {
					name: "Packet",
					isValue: true,
					base: null,
					interfaces: [],
					methods: [],
					fields: [
						{name: "optional", type: Nullable(I32)},
						{name: "value", type: I32},
						{name: "owner", type: IrValueLaneReference.type()}
					]
				};
				var objects = compiler.ir.IrObjectTable.of([packet.name => packet]),
					shape = new compiler.ir.IrValueLaneLayout(objects, 64, HashLink).shape(element);
				var helpers = new compiler.ir.IrValueArraySlotHelpers(0, element, shape),
					slot = helpers.slot(["owner"]),
					name = helpers.getter(slot);
				var b = new IrBuilder();
				b.argument("array", Array(wrongPath ? element : Dyn));
				b.argument("index", I32);
				b.returnValue(b.constNull(IrValueLaneReference.type()));
				p.entryPoint = name;
				p.objects = [packet];
				p.functions = [
					new IrFunction(name, b.arguments, IrValueLaneReference.type(), b.blocks,
						ValueArraySlot(0, element, Read(slot, wrongPath ? ["value"] : ["owner"], true)))
				];
			}, "Invalid lane carrier accessor signature");
	}
}
