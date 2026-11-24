package compiler.ir.passes.values;

import compiler.core.InternalError;
import compiler.core.Provides.ProviderOperation;
import compiler.core.Provides.ProviderOperations;
import compiler.ir.model.Ir;
import compiler.ir.model.IrBuilder;
import compiler.ir.model.IrFunction;
import compiler.ir.model.IrSymbol;
import compiler.ir.model.IrTypeIdentity;
import compiler.ir.model.SourceProvenance.Located;
import compiler.ir.model.TypeKey;
import compiler.ir.passes.IrFunctionRewrite;
import compiler.ir.passes.objects.IrGenericOwnerErasure;
import compiler.ir.passes.objects.IrTypeHashDispatch;
import compiler.ir.pipeline.IrDerivedHelpers;
import compiler.ir.pipeline.IrFunctionIndex;
import compiler.ir.pipeline.IrFunctionPass;
import compiler.ir.pipeline.IrFunctionStages;
import compiler.ir.reuse.IrFactReader;

/**
 * Reifies a value only at conversion to a runtime interface. Per function (`IrFunctionPass`): the rewrite reads what the program
 * declares of each object and interface its conversions name (`OBJECT`, `INTERFACE`) and asks for the boxes, unboxes, type tests,
 * casts and the type-id helper it calls; the box objects the helpers need are returned (`made`), not added to the objects given.
 * The helpers are derived (`IrDerivedHelpers`): a box's methods read what the box is made of (`BOX_PLAN`), an interface cast the
 * values it tests (`CAST_PLAN`), the type-id helper the boxes it classifies (`TYPE_IDS`); the unboxes and type tests are made from
 * their names alone.
 */
@:nullSafety(Strict)
class IrValueInterfaceBoxes extends IrFunctionPass {
	public static inline final BOX_PREFIX = "$value-interface-box:";
	public static inline final UNBOX_PREFIX = "$value-interface-unbox:";
	static inline final TYPE_ID = "$value-interface-object-type-id";

	/** The fact of an object name: 0 when it is no value object, 1 a value object, 2 one that implements interfaces. */
	static inline final OBJECT = 0;

	/** The fact of an interface name: 1 when the program declares it. */
	static inline final INTERFACE = 1;

	// What the derived helpers read (`IrDerivedHelpers`), numbered apart from the rewrite's facts, which share the stage's name.

	/** The text of a box's methods (`boxPlan`), by value name. */
	static inline final BOX_PLAN = 10;

	/** The values an interface cast tests, by interface name. */
	static inline final CAST_PLAN = 11;

	/** The values whose boxes the type-id helper classifies. */
	static inline final TYPE_IDS = 12;

	// Helper kinds (`request`).
	static inline final BOX = 0;
	static inline final UNBOX = 1;
	static inline final TEST_INSTANCE = 2;
	static inline final TEST_EXACT = 3;
	static inline final CAST = 4;
	static inline final OBJECT_TYPE_ID = 5;

	final objects:Array<IrObject>;
	final existingFunctions:Null<Array<IrFunction>>;
	final objectMap:Map<String, IrObject>;
	final interfaceMap:Map<String, IrInterface>;
	var functionMap:Null<IrFunctionIndex> = null;
	final boxes:Map<String, String> = [];
	final unboxes:Map<String, String> = [];
	final typeTests:Map<String, String> = [];
	final interfaceCasts:Map<String, String> = [];
	final generated:Array<IrFunction> = [];
	var needsTypeId = false;
	final derived:IrDerivedHelpers;

	/** By value name, what its box's methods are made of (`boxPlan`); by interface name, the values its cast tests. */
	final boxPlans:Map<String, Array<BoxMethod>> = [];

	final castPlans:Map<String, Array<String>> = [];

	/** The box objects this run made, in the order it made them, for the caller to add to the program's objects. */
	public final made:Array<IrObject> = [];

	/** In a session `helpers` derives the helpers (`IrDerivedHelpers`); without, they are made. */
	public function new(objects:Array<IrObject>, interfaces:Array<IrInterface>, ?existingFunctions:Array<IrFunction>,
			?helpers:IrDerivedHelpers) {
		this.objects = objects;
		this.existingFunctions = existingFunctions;
		objectMap = [for (object in objects) object.name => object];
		interfaceMap = [for (entry in interfaces) entry.name => entry];
		derived = helpers ?? new IrDerivedHelpers(STAGE);
		derived.print = print;
	}

	/** The text of what a helper reads (`IrDerivedHelpers`). */
	function print(kind:Int, key:String):String
		return switch kind {
			case BOX_PLAN: boxPlanText(boxPlans.get(key) ?? []);
			case CAST_PLAN: (castPlans.get(key) ?? []).join("\n");
			case _:
				var boxed = [for (value in boxes.keys()) value];
				boxed.sort(Reflect.compare);
				boxed.join("\n");
		};

	public static inline final STAGE = "value-interface-boxes";

	/** Rewrites `functions` and adds the box objects it makes to `objects`. */
	public static function rewrite(functions:Array<IrFunction>, objects:Array<IrObject>, interfaces:Array<IrInterface>,
			?existingFunctions:Array<IrFunction>):Array<IrFunction> {
		var pass = new IrValueInterfaceBoxes(objects, interfaces, existingFunctions),
			result = IrFunctionStages.apply(STAGE, pass, functions);
		for (box in pass.made)
			objects.push(box);
		return result;
	}

	/**
	 * `rewrite` of functions a stage generated besides `existing`, in the stage `stage`: with `lineage` each function's rewrite is
	 * derived from its version and what it read (`IrFunctionStages.derived`), and so are the helpers, made with `builder`
	 * past the encode point.
	 */
	public static function rewriteDerived(stage:String, functions:Array<IrFunction>, objects:Array<IrObject>,
			interfaces:Array<IrInterface>, existing:Array<IrFunction>,
			lineage:Null<compiler.ir.reuse.IrStageMemo.IrLineage>, checks:Bool,
			builder:compiler.ir.model.IrBodyBuilder):Array<IrFunction> {
		var pass = new IrValueInterfaceBoxes(objects, interfaces, existing,
			new IrDerivedHelpers(stage, lineage, checks, builder));
		pass.functionMap = new IrFunctionIndex(stage, existing.concat(functions));
		var rewritten = [
			for (fn in functions)
				IrFunctionStages.derived(stage, fn.name, pass, lineage == null ? 0 : lineage.versionOf(fn), lineage,
				checks, builder, reader -> pass.transform(fn, 0, reader))
		];
		var result = pass.finish(rewritten);
		for (box in pass.made)
			objects.push(box);
		return result;
	}

	override public function summarize(fn:IrFunction):Int
		return 0;

	override public function prepare(functions:Array<IrFunction>, summaries:Array<Int>, names:IrFunctionIndex):Void {
		var existing = existingFunctions;
		functionMap = existing == null ? names : new IrFunctionIndex(STAGE,
			existing.concat(functions));
	}

	override public function fact(kind:Int, key:String):Int {
		if (kind == INTERFACE)
			return interfaceMap.exists(key) ? 1 : 0;
		var object = objectMap.get(key);
		return object == null || !object.isValue ? 0 : object.interfaces.length == 0 ? 1 : 2;
	}

	override public function request(kind:Int, type:IrType, name:Null<String>):Void {
		var name = switch type {
			case Obj(name), Virtual(name): name;
			default: "";
		};
		switch kind {
			case BOX:
				boxFor(name);
			case UNBOX:
				unboxFor(name);
			case TEST_INSTANCE:
				typeTestFor(name, false);
			case TEST_EXACT:
				typeTestFor(name, true);
			case CAST:
				interfaceCastFor(name);
			case OBJECT_TYPE_ID:
				needsTypeId = true;
			default:
				throw new InternalError('Unknown value interface helper kind $kind');
		}
	}

	override public function transform(fn:IrFunction, summary:Int, reader:IrFactReader):IrFunction {
		// The function's type values and next free value id are only worked out when an instruction needs them.
		var typesOfCurrent:Null<Map<Int, IrType>> = null, next = -1;
		function types():Map<Int, IrType> {
			var known = typesOfCurrent;
			if (known == null) {
				known = [];
				for (block in fn.blocks) for (located in block.instructions) switch located.value {
					case TypeValue(out, type): known.set(out.id, type);
					default:
				}
				typesOfCurrent = known;
			}
			return known;
		}
		function freshId():Int {
			if (next < 0)
				next = fn.nextValueId();
			return next++;
		}
		function objectKind(type:IrType):Int
			return switch type {
				case Obj(name): reader.read(OBJECT, name);
				default: 0;
			};
		function valueName(type:IrType):String
			return switch type {
				case Obj(name): name;
				default: throw new InternalError("A value interface conversion names no object");
			};
		function replacement(located:Located<IrInstruction>):Null<Array<Located<IrInstruction>>>
			return switch located.value {
				case Call(out, callTarget,
					arguments) if (callTarget.name == "__dynamic_object_type_id" && (fn.name != TYPE_ID)):
					reader.request(OBJECT_TYPE_ID, Void);
					[new Located(Call(out, IrSymbol.of(TYPE_ID), arguments), located.provenance)];
				case Call(out, intrinsic,
					arguments) if ((intrinsic.name == "__std_is_of_type" || intrinsic.name == "__std_is_exact_type")
					&& arguments.length == 2 && types().exists(arguments[1].id)):
					var type = types().get(arguments[1].id);
					if (type == null || objectKind(type) != 2) null;
					else {
						var exact = intrinsic.name == "__std_is_exact_type", name = valueName(type);
						reader.request(exact ? TEST_EXACT : TEST_INSTANCE, type);
						[new Located(Call(out, IrSymbol.of(typeTestName(name, exact)), [arguments[0]]),
							located.provenance)];
					}
				case ToVirtual(out, input):
					if (objectKind(input.type) == 0) null;
					else {
						reader.request(BOX, input.type);
						var name = BOX_PREFIX + valueName(input.type),
							box = new IrValue(freshId(), "$interface-box", Obj(name));
						[
							new Located(NewObject(box, name), located.provenance),
							new Located(FieldSet(box, "value", input), located.provenance),
							new Located(ToVirtual(out, box), located.provenance)
						];
					}
				case SafeCast(out, input):
					var interfaceName = switch [out.type, input.type] {
						case [Virtual(name), Dyn]: name;
						default: null;
					};
					if (interfaceName != null && reader.read(INTERFACE, interfaceName) == 1) {
						reader.request(CAST, out.type);
						[new Located(Call(out, IrSymbol.of(CAST_PREFIX + interfaceName), [input]), located.provenance)];
					} else {
						var kind = switch [out.type, input.type] {
							case [Obj(_), Virtual(_) | Dyn]: objectKind(out.type);
							default: 0;
						};
						if (kind != 2) null;
						else {
							var erased = input, instructions:Array<Located<IrInstruction>> = [];
							if ((switch (input.type) {
								case Dyn: false;
								default: true;
							})) {
								erased = new IrValue(freshId(), "$interface-erased", Dyn);
								instructions.push(new Located(ToDyn(erased, input), located.provenance));
							}
							reader.request(UNBOX, out.type);
							instructions.push(new Located(Call(out, IrSymbol.of(UNBOX_PREFIX + valueName(out.type)),
								[erased]), located.provenance));
							instructions;
						}
					}
				default: null;
			};
		return IrFunctionRewrite.instructions(fn, replacement);
	}

	static inline final CAST_PREFIX = "$value-interface-cast:";

	static function typeTestName(valueName:String, exact:Bool):String
		return "$value-interface-type-test:" + (exact ? "exact:" : "instance:") + valueName;

	override public function finish(functions:Array<IrFunction>):Array<IrFunction> {
		var functionMap = index();
		if (needsTypeId && !functionMap.exists(TYPE_ID)) {
			// The physical class of an interface box is an implementation detail.
			// Equality classifies it as the enclosed struct, just as casts and type
			// tests above do, without unboxing or allocating a temporary value.
			var values = [for (object in objects) if (object.isValue && object.interfaces.length > 0) object.name];
			for (value in values) boxFor(value);
			var boxed = [for (value in boxes.keys()) value];
			boxed.sort(Reflect.compare);
			generated.push(derived.make(TYPE_ID, reader -> {
				reader.read(TYPE_IDS, "");
				var byId:Map<Int, Array<String>> = [];
				for (value in boxed) {
					var hash = IrTypeIdentity.id(Obj(BOX_PREFIX + value)), group = byId.get(hash);
					if (group == null) byId.set(hash, group = []);
					group.push(value);
				}
				var builder = new IrBuilder(),
					input = builder.argument("value", Dyn),
					physical = builder.call("__dynamic_object_type_id", [input], I32),
					missing = builder.createBlock();
				IrTypeHashDispatch.emit(builder, physical, [for (id in byId.keys()) id], function(id) {
					for (value in byId.get(id) ?? []) {
						var matched = builder.createBlock(), next = builder.createBlock();
						builder.branch(builder.call("__std_is_exact_type",
							[input, builder.typeValue(Obj(BOX_PREFIX + value))], Bool), matched, next);
						builder.select(matched);
						builder.returnValue(builder.constInt(IrTypeIdentity.id(Obj(value))));
						builder.select(next);
					}
					builder.jump(missing);
				}, missing);
				builder.select(missing);
				builder.returnValue(physical);
				new IrFunction(TYPE_ID, builder.arguments, I32, builder.blocks, GeneratedHelper);
			}));
		}
		return functions.concat(generated);
	}

	/** The functions the helpers must not be made again for (`prepare`). */
	function index():IrFunctionIndex {
		var known = functionMap;
		if (known == null)
			throw new InternalError("Value interface boxes made a helper before they were prepared");
		return known;
	}

	function boxFor(valueName:String):String {
		var existing = boxes.get(valueName);
		if (existing != null) return existing;
		var value = objectMap.get(valueName);
		if (value == null || !value.isValue) throw new InternalError('Missing value layout "$valueName"');
		var boxName = BOX_PREFIX + valueName;
		boxes.set(valueName, boxName);
		if (objectMap.exists(boxName)) return boxName;
		var plan = boxPlan(valueName, value), methods:Array<IrObjectMethod> = [];
		boxPlans.set(valueName, plan);
		for (method in plan) {
			var wrapper = boxName + "." + method.name;
			methods.push({name: method.name, functionName: compiler.ir.model.IrSymbol.of(wrapper)});
			generated.push(derived.make(wrapper, reader -> {
				reader.read(BOX_PLAN, valueName);
				boxMethod(valueName, wrapper, method);
			}));
		}
		var box:IrObject = {
			name: boxName,
			isValue: false,
			base: null,
			interfaces: value.interfaces.copy(),
			fields: [{name: "value", type: Obj(valueName)}],
			methods: methods
		};
		made.push(box);
		objectMap.set(boxName, box);
		return boxName;
	}

	/** The methods of the box of `value`, in name order: each interface contract and the value method it calls. */
	function boxPlan(valueName:String, value:IrObject):Array<BoxMethod> {
		var contracts:Map<String, IrInterfaceMethod> = [], visited:Map<String, Bool> = [];
		function collect(name:String):Void {
			if (visited.exists(name)) return;
			visited.set(name, true);
			var entry = interfaceMap.get(name);
			if (entry == null) throw new InternalError('Missing interface "$name"');
			for (base in entry.bases) collect(base);
			for (method in entry.methods) contracts.set(method.name, method);
		}
		for (name in value.interfaces) collect(name);
		// Reflection of an interface box exposes the value's other methods too.
		for (method in value.methods) if (!contracts.exists(method.name)) {
			var fn = index().get(method.functionName.name);
			if (fn != null && fn.arguments.length > 0)
				contracts.set(method.name, {
					name: method.name,
					arguments: [for (argument in fn.arguments.slice(1)) argument.type],
					result: fn.result
				});
		}
		var methodNames = [for (methodName in contracts.keys()) methodName];
		methodNames.sort(Reflect.compare);
		return [for (methodName in methodNames) {
			var found = contracts.get(methodName);
			if (found == null) throw new InternalError('Missing interface contract "$methodName"');
			var contract:IrInterfaceMethod = found;
			var implementation:Null<IrFunction> = null;
			for (method in value.methods) if (method.name == methodName) implementation =
				index().get(method.functionName.name);
			if (implementation == null)
				throw new InternalError('Missing implementation of "$valueName.$methodName"');
			if (implementation.arguments.length != contract.arguments.length + 1)
				throw new InternalError('Invalid interface implementation "$valueName.$methodName"');
			{
				name:methodName,
					contract:contract,
					implementation:implementation.name,
					arguments:[for (argument in implementation.arguments) argument.type],
					result:implementation.result
			};
		}];
	}

	/** The text of what a box's methods are made of: their contracts and the signatures and conversions of what they call. */
	function boxPlanText(plan:Array<BoxMethod>):String {
		var parts:Array<String> = [];
		for (method in plan) {
			parts.push('method ${method.name} ${method.implementation} ${IrTypeIdentity.text(method.result)}');
			for (argument in method.contract.arguments)
				parts.push('contract ${IrTypeIdentity.text(argument)}');
			parts.push('returns ${IrGenericOwnerErasure.conversionText(method.contract.result, objectMap)}');
			for (argument in method.arguments)
				parts.push('takes ${IrGenericOwnerErasure.conversionText(argument, objectMap)}');
		}
		return parts.join("\n");
	}

	/** The box method `wrapper` of the value `valueName`, which calls the value's method through the contract. */
	function boxMethod(valueName:String, wrapper:String, method:BoxMethod):IrFunction {
		var contract = method.contract,
			boxName = BOX_PREFIX + valueName,
			builder = new IrBuilder(),
			receiver = builder.argument("this", Obj(boxName)),
			arguments = [for (index in 0...contract.arguments.length) builder.argument('argument$index',
				contract.arguments[index])],
			payload = builder.fieldGet(receiver, "value", Obj(valueName));
		var adapted = [for (index in 0...arguments.length)
			IrGenericOwnerErasure.convert(builder, arguments[index], method.arguments[index + 1], objectMap)];
		var result = builder.call(method.implementation, [payload].concat(adapted), method.result);
		builder.returnValue((switch (contract.result) {
			case Void: true;
			default: false;
		}) ? result : IrGenericOwnerErasure.convert(builder, result, contract.result, objectMap));
		return new IrFunction(wrapper, builder.arguments, contract.result, builder.blocks,
			Provider(TypeKey.of(Obj(valueName)),
			ProviderOperations.detailed(ProviderOperation.InterfaceBox, method.name)));
	}

	function unboxFor(valueName:String):String {
		var existing = unboxes.get(valueName);
		if (existing != null) return existing;
		var boxName = boxFor(valueName), name = UNBOX_PREFIX + valueName;
		unboxes.set(valueName, name);
		if (index().exists(name)) return name;
		// Made of its name alone.
		generated.push(derived.make(name, _ -> {
			var builder = new IrBuilder(),
				input = builder.argument("value", Dyn),
				boxed = builder.createBlock(),
				direct = builder.createBlock();
			builder.branch(builder.call("__std_is_of_type", [input, builder.typeValue(Obj(boxName))], Bool), boxed,
				direct);
			builder.select(boxed);
			builder.returnValue(builder.fieldGet(builder.safeCast(input, Obj(boxName)), "value", Obj(valueName)));
			builder.select(direct);
			builder.returnValue(builder.safeCast(input, Obj(valueName)));
			new IrFunction(name, builder.arguments, Obj(valueName), builder.blocks,
				Provider(TypeKey.of(Obj(valueName)), ProviderOperation.InterfaceUnbox));
		}));
		return name;
	}

	function typeTestFor(valueName:String, exact:Bool):String {
		var key = (exact ? "exact:" : "instance:") + valueName, existing = typeTests.get(key);
		if (existing != null) return existing;
		var name = "$value-interface-type-test:" + key, boxName = boxFor(valueName);
		typeTests.set(key, name);
		if (index().exists(name)) return name;
		// Made of its name alone.
		generated.push(derived.make(name, _ -> {
			var intrinsic = exact ? "__std_is_exact_type" : "__std_is_of_type",
				builder = new IrBuilder(),
				input = builder.argument("value", Dyn),
				matched = builder.createBlock(),
				boxed = builder.createBlock();
			builder.branch(builder.call(intrinsic, [input, builder.typeValue(Obj(valueName))], Bool), matched, boxed);
			builder.select(matched);
			builder.returnValue(builder.constBool(true));
			builder.select(boxed);
			builder.returnValue(builder.call(intrinsic, [input, builder.typeValue(Obj(boxName))], Bool));
			new IrFunction(name, builder.arguments, Bool, builder.blocks,
				Provider(TypeKey.of(Obj(valueName)),
				ProviderOperations.detailed(ProviderOperation.InterfaceTypeTest, exact ? "exact" : "instance")));
		}));
		return name;
	}

	function interfaceCastFor(interfaceName:String):String {
		var existing = interfaceCasts.get(interfaceName);
		if (existing != null) return existing;
		function extendsInterface(name:String, visited:Map<String, Bool>):Bool {
			if (name == interfaceName) return true;
			if (visited.exists(name)) return false;
			visited.set(name, true);
			var entry = interfaceMap.get(name);
			if (entry != null) for (base in entry.bases) if (extendsInterface(base, visited)) return true;
			return false;
		}
		var candidates:Array<String> = [];
		for (object in objects) if (object.isValue) {
			var matches = false;
			for (name in object.interfaces) if (extendsInterface(name, [])) matches = true;
			if (matches) candidates.push(object.name);
		}
		candidates.sort(Reflect.compare);
		var name = CAST_PREFIX + interfaceName;
		interfaceCasts.set(interfaceName, name);
		if (index().exists(name)) return name;
		castPlans.set(interfaceName, candidates);
		// The boxes join the program whether or not the cast is made again.
		var boxNames = [for (valueName in candidates) boxFor(valueName)];
		generated.push(derived.make(name, reader -> {
			reader.read(CAST_PLAN, interfaceName);
			var builder = new IrBuilder(), input = builder.argument("value", Dyn);
			for (index in 0...candidates.length) {
				var valueName = candidates[index],
					boxName = boxNames[index],
					existingBox = builder.createBlock(),
					checkValue = builder.createBlock(),
					matched = builder.createBlock(),
					next = builder.createBlock();
				builder.branch(builder.call("__std_is_of_type", [input, builder.typeValue(Obj(boxName))], Bool),
					existingBox, checkValue);
				builder.select(existingBox);
				builder.returnValue(builder.safeCast(input, Virtual(interfaceName)));
				builder.select(checkValue);
				builder.branch(builder.call("__std_is_of_type", [input, builder.typeValue(Obj(valueName))], Bool),
					matched, next);
				builder.select(matched);
				var payload = builder.safeCast(input, Obj(valueName)), box = builder.newObject(boxName);
				builder.fieldSet(box, "value", payload);
				builder.returnValue(builder.toVirtual(box, Virtual(interfaceName)));
				builder.select(next);
			}
			builder.returnValue(builder.safeCast(input, Virtual(interfaceName)));
			new IrFunction(name, builder.arguments, Virtual(interfaceName), builder.blocks,
				Provider(TypeKey.of(Virtual(interfaceName)), ProviderOperation.InterfaceCast));
		}));
		return name;
	}
}

/** A method of a value's interface box (`IrValueInterfaceBoxes.boxPlan`): the contract it fills and the value method it calls. */
private typedef BoxMethod = {
	final name:String;
	final contract:IrInterfaceMethod;
	final implementation:String;
	final arguments:Array<IrType>;
	final result:IrType;
}
