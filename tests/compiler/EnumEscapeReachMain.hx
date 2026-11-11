import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.ir.IrEnumEscapeReach;
import compiler.ir.IrArrayFactory;

/** Both enum storage decisions consume the same reference, container and capture reach. */
@:access(compiler.ir.IrBuilder)
class EnumEscapeReachMain {
	static function object(name:String, fields:Array<IrObjectField>, ?base:String, ?interfaces:Array<String>):IrObject
		return {
			name: name,
			isValue: false,
			base: base,
			interfaces: interfaces == null ? [] : interfaces,
			methods: [],
			fields: fields
		};

	static function main():Void {
		var program = new IrProgram("main");
		program.objects = [
			object("Leaf", [{name: "tag", type: EnumTag("Tag")}, {name: "payload", type: Enum("Payload")}]),
			object("Branch", [{name: "children", type: Array(Obj("Leaf"))}]),
			object("Impl", [{name: "extra", type: EnumTag("DerivedTag")}], "Branch", ["ChildContract"]),
			object("Capture", [{name: "leaf", type: Obj("Leaf")}])
		];
		program.interfaces = [
			{name: "Contract", bases: [], methods: []},
			{name: "ChildContract", bases: ["Contract"], methods: []}
		];
		var builder = new IrBuilder(),
			receiver = builder.argument("receiver", Obj("Capture")),
			closure = builder.temporary(Function([], Void)),
			map = builder.argument("map", Abstract("probe-map"));
		builder.emit(InstanceClosure(closure, "capture", receiver));
		builder.call("__map_string_ref_set", [map, builder.constString("key"), builder.constNull(EnumTag("Tag"))], Void);
		builder.returnValue(builder.constVoid());
		program.functions = [new IrFunction("capture", builder.arguments, Void, builder.blocks, Ordinary)];
		program.staticFields = [{name: "Branch.staticPayload", type: Enum("StaticPayload")}];
		var reach = new IrEnumEscapeReach(program);
		for (root in [Obj("Branch"), Virtual("Contract"), Function([], Void)]) {
			var result = reach.collect([root], _ -> false);
			if (!result.exists("Tag") || !result.exists("Payload"))
				throw "Lost transitive enum reach: " + Std.string(root);
		}
		if (!reach.collect([Obj("Branch")], _ -> false).exists("DerivedTag"))
			throw "Lost derived-class field reach";
		if (!reach.collect([Virtual("Contract")], _ -> false).exists("StaticPayload"))
			throw "Lost inherited static layout";
		if (!reach.collect([Abstract("probe-map")], _ -> false).exists("Tag"))
			throw "Lost erased map contents";
		if (compiler.ir.IrArrayRuntimeNatives.isStorage("__array_user_extension"))
			throw "Array classification must fail closed";
		program.enums = [
			{name: "Tag", cases: [{name: "Only", params: []}]},
			{name: "Payload", cases: [{name: "Value", params: [I32]}]}
		];
		var escaped = new IrBuilder(),
			owner = escaped.argument("owner", Obj("Impl"));
		escaped.toDyn(owner);
		escaped.returnValue(escaped.constInt(42));
		program.functions.push(new IrFunction("escape", escaped.arguments, I32, escaped.blocks, Ordinary));
		var eligibility = new compiler.ir.IrInlineEnumEligibility(program, new compiler.ir.IrInlineEnumLayout(program.enums, program.objects, 64, HashLink));
		if (eligibility.allowed.exists("Payload"))
			throw "Inline eligibility ignored transitive escape";
		var projected = compiler.ir.IrClosedEnumTagAbi.run(program);
		if (!compiler.ir.IrVerifier.sameType(Lambda.find(projected.objects, entry -> entry.name == "Leaf").fields[0].type, EnumTag("Tag")))
			throw "Closed-tag ABI ignored the same transitive escape";
		var nativeRoots:Array<IrType> = [];
		IrEnumEscapeReach.addNativeRoot(nativeRoots, Abstract("probe-map"));
		if (nativeRoots.length != 0)
			throw "An opaque native handle exposed map contents";
		checkSharedValueGraph();
		checkUnknownArrayNative();
		checkFactory();
		checkInvalidFactory();
		Sys.println("PASS: shared enum escape reach and typed array factory");
	}

	static function checkSharedValueGraph():Void {
		var program = new IrProgram("main");
		// Each pair points to the same next shape. A path-local visited set expands
		// this graph exponentially; shared reach must visit each declaration once.
		for (index in 0...32)
			program.enums.push({
				name: "Shared" + index,
				cases: [
					{name: "Pair", params: [Enum("Shared" + (index + 1)), Enum("Shared" + (index + 1))]}
				]
			});
		program.enums.push({name: "Shared32", cases: [{name: "End", params: []}]});
		var reached = new IrEnumEscapeReach(program).collect([Enum("Shared0")], _ -> false);
		for (index in 0...33)
			if (!reached.exists("Shared" + index))
				throw "Lost shared value graph leaf " + index;
	}

	static function checkUnknownArrayNative():Void {
		var program = new IrProgram("main"), builder = new IrBuilder();
		program.enums = [{name: "Tag", cases: [{name: "Only", params: []}]}];
		program.natives = [
			{
				name: "__array_user_extension",
				library: "probe",
				symbol: "array_extension",
				arguments: [Array(EnumTag("Tag")), Dyn],
				result: Void
			}
		];
		var array = builder.argument("array", Array(EnumTag("Tag"))),
			tag = builder.argument("tag", EnumTag("Tag"));
		builder.call("__array_user_extension", [array, tag], Void);
		builder.returnValue(builder.constVoid());
		program.functions = [new IrFunction("main", builder.arguments, Void, builder.blocks, Ordinary)];
		compiler.ir.IrEnumTagLowering.escapes(program);
		var adapted = false;
		for (block in program.functions[0].blocks)
			for (located in block.instructions)
				switch located.value {
					case Call(_, "__array_user_extension", arguments):
						adapted = compiler.ir.IrVerifier.sameType(arguments[1].type, Dyn);
					default:
				}
		if (!adapted)
			throw "An unknown array-prefixed native bypassed tag escape adaptation";
	}

	static function checkFactory():Void {
		var program = new IrProgram("main"), builder = new IrBuilder();
		program.enums = [{name: "Tag", cases: [{name: "Only", params: []}]}];
		var array = builder.call(IrArrayFactory.NAME, [builder.constInt(3)], Array(EnumTag("Tag")));
		// No erased allocation, descriptor or adjacent instruction protocol exists to match.
		builder.constString("unrelated instruction");
		var size = builder.temporary(I32);
		builder.emit(ArraySize(size, array));
		builder.returnValue(size);
		program.functions = [new IrFunction("main", [], I32, builder.blocks, Ordinary)];
		compiler.ir.IrVerifier.verify(program);
		if (new compiler.ir.IrInterpreter(program).run("main") != 3)
			throw "Semantic array factory interpreter result";
		program = compiler.ir.IrClosedEnumTagAbi.run(program);
		IrArrayFactory.lower(program);
		var found = false;
		for (fn in program.functions)
			for (block in fn.blocks)
				for (located in block.instructions)
					switch located.value {
						case Call(out, "__array_alloc_i32", arguments):
							found = arguments.length == 1 && compiler.ir.IrVerifier.sameType(out.type, Array(I32));
						case Call(_, IrArrayFactory.NAME, _):
							throw "Logical factory survived allocation emission";
						case TypeValue(_, _), ToDyn(_, _), SafeCast(_, _):
							throw "Closed tag allocation acquired a descriptor or erase/cast";
						default:
					}
		if (!found)
			throw "Closed tag factory did not emit the I32 allocator";
	}

	static function checkInvalidFactory():Void {
		var invalid = new IrBuilder(), program = new IrProgram("main");
		invalid.call(IrArrayFactory.NAME, [], Array(I32));
		invalid.returnValue(invalid.constInt(0));
		program.functions = [new IrFunction("main", [], I32, invalid.blocks, Ordinary)];
		var rejected = false;
		try
			compiler.ir.IrVerifier.verify(program)
		catch (error:Dynamic) {
			if (Std.string(error) != "IR verification failed for main: Invalid typed array factory signature")
				throw error;
			rejected = true;
		}
		if (!rejected)
			throw "Verifier accepted an invalid typed array factory";
	}
}
