import compiler.Provides.ProviderOperation;
import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.ir.IrFunction.IrFunctionKind;
import compiler.ir.TypeKey;
import compiler.ir.IrProviders;
import compiler.ir.IrTypeAwareWalk;

/** The type-aware reachability walk on small IR graphs (docs/REACHABILITY_WALK.md). */
class TypeAwareWalkMain {
	static function main():Void {
		dynamicSite();
		interfaceCall();
		typedOperation();
		inlineEnumOperations();
		nativeCreatedClass();
		Sys.println("PASS: type-aware walk: dynamic sites over created types, interface calls over created implementors, typed operations need a provider");
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}

	static function object(name:String, interfaces:Array<String>, methods:Array<String>):IrObject
		return {
			name: name,
			isValue: false,
			base: null,
			interfaces: interfaces,
			fields: [],
			methods: [for (method in methods) {name: method, functionName: name + "." + method}]
		};

	static function empty(name:String, kind:IrFunctionKind, ?arguments:Array<IrType>, result:IrType = Void):IrFunction {
		var builder = new IrBuilder();
		if (arguments != null)
			for (index in 0...arguments.length)
				builder.argument("a" + index, arguments[index]);
		if (result == Void)
			builder.returnValue(builder.constVoid());
		else
			builder.returnValue(builder.constNull(result));
		return new IrFunction(name, builder.arguments, result, builder.blocks, kind);
	}

	/** A dynamic equality site reaches the equality helper of a created enum and not the one of an enum nothing creates. */
	static function dynamicSite():Void {
		// `use` converts one enum to Dynamic and only has the other in its signature, so only the first is created. It is not a root:
		// the types in a root's signature are created by the root.
		var use = new IrBuilder();
		var created = use.argument("created", Enum("Seen")), spare = use.argument("spare", Enum("Unseen"));
		use.call("__dynamic_equal", [use.toDyn(created), use.toDyn(created)], Bool);
		use.returnValue(use.constVoid());
		var main = new IrBuilder();
		main.call("use", [], Void);
		main.returnValue(main.constInt(0));
		var program = new IrProgram("main");
		program.functions = [
			new IrFunction("main", main.arguments, I32, main.blocks, Ordinary),
			new IrFunction("use", use.arguments, Void, use.blocks, Ordinary),
			empty("$eq_Seen", EnumEquality(false), [Enum("Seen"), Enum("Seen")], Bool),
			empty("$eq_Unseen", EnumEquality(false), [Enum("Unseen"), Enum("Unseen")], Bool),
			empty("unusedHelper", Ordinary)
		];
		var result = IrTypeAwareWalk.run(program, {functions: ["main"], types: []});
		expect(result.reached.exists("main"), "main is reached");
		expect(result.reached.exists("$eq_Seen"), "the equality of a created enum is reached by a dynamic equality");
		expect(!result.reached.exists("$eq_Unseen"), "the equality of an enum nothing creates is not reached");
		expect(!result.reached.exists("unusedHelper"), "a function nothing calls is not reached");
		expect(result.providersReached == 1, "one provider reached, got " + result.providersReached);
		// A root can say a type exists.
		var rooted = IrTypeAwareWalk.run(program, {functions: ["main"], types: [Enum("Unseen")]});
		expect(rooted.reached.exists("$eq_Unseen"), "a type named by a root is created");
		expect(spare != null, "keeps the unused value in the test");
	}

	/** An interface call reaches the implementations of created implementors only. */
	/**
	 * A class only native code makes: the result type of a called native (an `IrNative`, or an `IrCNative` that becomes a `CNativeCall` at the end of
	 * assembly) is created, so the override of a method on a subclass the native returns is reached, and a native nothing calls creates nothing.
	 */
	static function nativeCreatedClass():Void {
		for (kind in ["native", "cnative"]) {
			var builder = new IrBuilder();
			var handle = builder.call("makeHandle", [], Obj("Base"));
			builder.methodCall(handle, "update", [], I32);
			builder.returnValue(builder.constInt(0));
			var base = object("Base", [], ["update"]), derived = object("Derived", [], ["update"]);
			var program = new IrProgram("main");
			program.objects = [
				base,
				{
					name: "Derived",
					isValue: false,
					base: "Base",
					interfaces: [],
					fields: [],
					methods: derived.methods
				},
				object("Unrelated", [], ["update"])
			];
			program.functions = [
				new IrFunction("main", builder.arguments, I32, builder.blocks, Ordinary),
				empty("Base.update", Ordinary, [Obj("Base")], I32),
				empty("Derived.update", Ordinary, [Obj("Derived")], I32),
				empty("Unrelated.update", Ordinary, [Obj("Unrelated")], I32)
			];
			// The native is declared to return the base class, and native code may return any subclass of it: the base and its subclasses are
			// created, so the override on `Derived` is reached; an unrelated class is not.
			if (kind == "native")
				program.natives = [{name: "makeHandle", library: "lib", symbol: "make", arguments: [], result: Obj("Base")}];
			else
				program.cNatives = [
					{
						name: "makeHandle",
						library: "lib",
						symbol: "make",
						signature: "",
						pointerOwnership: "none",
						pointerRelease: null,
						pointerLength: null,
						pointerNullable: false,
						arguments: [],
						argumentModes: [],
						result: Obj("Base")
					}
				];
			var result = IrTypeAwareWalk.run(program, {functions: ["main"], types: []});
			expect(result.createdClasses.exists("Base"), kind + ": the result type of a called native is created");
			expect(result.reached.exists("Base.update"), kind + ": the method of the class a native returns is reached");
			expect(result.reached.exists("Derived.update"), kind + ": the override on a subclass of the declared result is reached");
			expect(!result.reached.exists("Unrelated.update"), kind + ": an unrelated class is not reached");
			// A native declared to return the subclass creates it.
			program.natives = [for (native in program.natives) {name: native.name, library: native.library, symbol: native.symbol, arguments: [], result: Obj("Derived")}];
			program.cNatives = [
				for (native in program.cNatives) {
					name: native.name,
					library: native.library,
					symbol: native.symbol,
					signature: "",
					pointerOwnership: "none",
					pointerRelease: null,
					pointerLength: null,
					pointerNullable: false,
					arguments: [],
					argumentModes: [],
					result: Obj("Derived")
				}
			];
			var subclass = IrTypeAwareWalk.run(program, {functions: ["main"], types: []});
			expect(subclass.createdClasses.exists("Derived"), kind + ": a native's subclass result is created");
			expect(subclass.reached.exists("Derived.update"), kind + ": the override on a class only native code makes is reached");
			// No call, no creation.
			var idle = new IrBuilder();
			idle.returnValue(idle.constInt(0));
			program.functions[0] = new IrFunction("main", idle.arguments, I32, idle.blocks, Ordinary);
			expect(!IrTypeAwareWalk.run(program, {functions: ["main"], types: []}).createdClasses.exists("Derived"),
				kind + ": a native nothing calls creates nothing");
		}
	}

	static function interfaceCall():Void {
		var builder = new IrBuilder();
		var instance = builder.newObject("Used");
		var virtual = builder.toVirtual(instance, Virtual("Shape"));
		builder.methodCall(virtual, "area", [], I32);
		builder.returnValue(builder.constInt(0));
		var program = new IrProgram("main");
		program.interfaces = [{name: "Shape", bases: [], methods: [{name: "area", arguments: [], result: I32}]}];
		program.objects = [object("Used", ["Shape"], ["area"]), object("Idle", ["Shape"], ["area"])];
		program.functions = [
			new IrFunction("main", builder.arguments, I32, builder.blocks, Ordinary),
			empty("Used.area", Ordinary, [Obj("Used")], I32),
			empty("Idle.area", Ordinary, [Obj("Idle")], I32)
		];
		var result = IrTypeAwareWalk.run(program, {functions: ["main"], types: []});
		expect(result.reached.exists("Used.area"), "the implementation of a created implementor is reached");
		expect(!result.reached.exists("Idle.area"), "the implementation of an implementor nothing creates is not reached");
		// Once the second implementor is created by a root, its implementation is reached too: the edge is re-derived as types grow.
		var grown = IrTypeAwareWalk.run(program, {functions: ["main"], types: [Obj("Idle")]});
		expect(grown.reached.exists("Idle.area"), "a created implementor's implementation is reached when the root creates it");
		// Keeping the methods of a created class, as reflection by name needs, reaches the ones nothing calls.
		program.objects = [object("Used", ["Shape"], ["area", "spare"]), object("Idle", ["Shape"], ["area"])];
		program.functions.push(empty("Used.spare", Ordinary, [Obj("Used")], I32));
		expect(!IrTypeAwareWalk.run(program, {functions: ["main"], types: []}).reached.exists("Used.spare"), "an uncalled method is not reached");
		expect(IrTypeAwareWalk.run(program, {functions: ["main"], types: []}, null, false, true).reached.exists("Used.spare"),
			"every method of a created class is reached when asked");
	}

	/** A typed operation reaches the row of its subject, and a missing row is an error. */
	static function typedOperation():Void {
		var builder = new IrBuilder();
		var value = builder.argument("tag", EnumTag("Color"));
		builder.intrinsic(EnumTagBox(EnumTag("Color")), [value], Dyn);
		builder.returnValue(builder.constVoid());
		var main = new IrFunction("main", builder.arguments, Void, builder.blocks, Ordinary);
		var program = new IrProgram("main");
		program.functions = [main];
		var bare = IrTypeAwareWalk.run(program, {functions: ["main"], types: []}, null, true);
		expect(bare.missingProviders.length == 1, "a typed operation with no row is reported once, got " + bare.missingProviders.length);
		expect(bare.demanded.exists(ProviderOperation.EnumTagBox + "\n" + TypeKey.of(EnumTag("Color")).toString()), "the demand is recorded");
		expect(IrProviders.checkTypedOperations(program.functions) != null, "the check names the missing provider");
		// The first walk, before the producers have run, only collects the demand.
		expect(IrTypeAwareWalk.run(program, {functions: ["main"], types: []}).missingProviders.length == 0,
			"without requireProviders a missing row is not an error");
		program.functions.push(empty("$box_Color", EnumTagAdapter(EnumTag("Color"), true), [EnumTag("Color")], Dyn));
		program.functions.push(empty("$other", EnumTagAdapter(EnumTag("Shade"), true), [EnumTag("Shade")], Dyn));
		var served = IrTypeAwareWalk.run(program, {functions: ["main"], types: []}, null, true);
		expect(served.missingProviders.length == 0, "no problem when the row exists");
		expect(served.reached.exists("$box_Color"), "the provider of the subject is reached");
		expect(!served.reached.exists("$other"), "the provider of another subject is not");
		expect(IrProviders.checkTypedOperations(program.functions) == null, "the check passes with the row");
		program.functions.push(empty("$helper", Ordinary));
		expect(IrTypeAwareWalk.kindlessHelpers(program).join(",") == "$helper", "a $ function with no kind is listed");
	}

	/** The inline enum boundary operations name the box or the unbox helper of the enum, not both. */
	static function inlineEnumOperations():Void {
		var builder = new IrBuilder();
		var payload = builder.argument("payload", I32);
		builder.intrinsic(InlineEnumBox(Enum("Opt")), [payload], Dyn);
		builder.returnValue(builder.constVoid());
		var program = new IrProgram("main");
		program.functions = [new IrFunction("main", builder.arguments, Void, builder.blocks, Ordinary)];
		var helper = function(name:String, detail:String):IrFunction {
			var fn = empty(name, Ordinary, [I32], Dyn);
			return new IrFunction(name, fn.arguments, Dyn, fn.blocks,
				Provider(TypeKey.of(Enum("Opt")), compiler.Provides.ProviderOperations.detailed(ProviderOperation.InlineEnumHelper, detail)));
		};
		var missing = IrTypeAwareWalk.run(program, {functions: ["main"], types: []}, null, true);
		expect(missing.missingProviders.length == 1, "an inline enum box with no helper is reported");
		expect(IrProviders.checkTypedOperations(program.functions) != null, "the check names the missing inline enum helper");
		program.functions.push(helper("$unbox_Opt", "unbox"));
		expect(IrTypeAwareWalk.run(program, {functions: ["main"], types: []}, null, true).missingProviders.length == 1,
			"the unbox helper does not answer a box");
		program.functions.push(helper("$box_Opt", "box"));
		var served = IrTypeAwareWalk.run(program, {functions: ["main"], types: []}, null, true);
		expect(served.missingProviders.length == 0 && served.reached.exists("$box_Opt"), "the box helper answers the box");
		expect(!served.reached.exists("$unbox_Opt"), "the unbox helper is not reached by a box");
		expect(IrProviders.checkTypedOperations(program.functions) == null, "the check passes with the box helper");
	}
}
