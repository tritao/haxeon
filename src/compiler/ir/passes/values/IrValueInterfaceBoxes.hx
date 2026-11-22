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
import compiler.ir.pipeline.IrFunctionIndex;
import compiler.ir.pipeline.IrFunctionPass;
import compiler.ir.pipeline.IrFunctionStages;
import compiler.ir.reuse.IrFactReader;

/**
 * Reifies a value only at conversion to a runtime interface. Per function (`IrFunctionPass`): the rewrite reads what the program
 * declares of each object and interface its conversions name (`OBJECT`, `INTERFACE`) and asks for the boxes, unboxes, type tests,
 * casts and the type-id helper it calls; the box objects the helpers need are returned (`made`), not added to the objects given.
 */
class IrValueInterfaceBoxes implements IrFunctionPass {
	public static inline final BOX_PREFIX = "$value-interface-box:";
	public static inline final UNBOX_PREFIX = "$value-interface-unbox:";
	static inline final TYPE_ID = "$value-interface-object-type-id";

	/** The fact of an object name: 0 when it is no value object, 1 a value object, 2 one that implements interfaces. */
	static inline final OBJECT = 0;

	/** The fact of an interface name: 1 when the program declares it. */
	static inline final INTERFACE = 1;

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

	/** The box objects this run made, in the order it made them, for the caller to add to the program's objects. */
	public final made:Array<IrObject> = [];

	public function new(objects:Array<IrObject>, interfaces:Array<IrInterface>, ?existingFunctions:Array<IrFunction>) {
		this.objects = objects;
		this.existingFunctions = existingFunctions;
		objectMap = [for (object in objects) object.name => object];
		interfaceMap = [for (entry in interfaces) entry.name => entry];
	}

	/** Rewrites `functions` and adds the box objects it makes to `objects`. */
	public static function rewrite(functions:Array<IrFunction>, objects:Array<IrObject>, interfaces:Array<IrInterface>,
			?existingFunctions:Array<IrFunction>):Array<IrFunction> {
		var pass = new IrValueInterfaceBoxes(objects, interfaces, existingFunctions),
			result = IrFunctionStages.apply("value-interface-boxes", pass, functions);
		for (box in pass.made)
			objects.push(box);
		return result;
	}

	public function summarize(fn:IrFunction):Int
		return 0;

	public function prepare(functions:Array<IrFunction>, summaries:Array<Int>, names:IrFunctionIndex):Void {
		var existing = existingFunctions;
		functionMap = existing == null ? names : new IrFunctionIndex("value-interface-boxes",
			existing.concat(functions));
	}

	public function fact(kind:Int, key:String):Int {
		if (kind == INTERFACE)
			return interfaceMap.exists(key) ? 1 : 0;
		var object = objectMap.get(key);
		return object == null || !object.isValue ? 0 : object.interfaces.length == 0 ? 1 : 2;
	}

	public function request(kind:Int, type:IrType):Void {
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

	public function transform(fn:IrFunction, summary:Int, reader:IrFactReader):IrFunction {
		// The function's type values and next free value id are only worked out when an instruction needs them.
		var typesOfCurrent:Null<Map<Int, IrType>> = null, next = -1;
		function types():Map<Int, IrType> {
			if (typesOfCurrent == null) {
				typesOfCurrent = [];
				for (block in fn.blocks) for (located in block.instructions) switch located.value {
					case TypeValue(out, type): typesOfCurrent.set(out.id, type);
					default:
				}
			}
			return typesOfCurrent;
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
					if (objectKind(type) != 2) null;
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

	public function finish(functions:Array<IrFunction>):Array<IrFunction> {
		var functionMap = index();
		if (needsTypeId && !functionMap.exists(TYPE_ID)) {
			// The physical class of an interface box is an implementation detail.
			// Equality classifies it as the enclosed struct, just as casts and type
			// tests above do, without unboxing or allocating a temporary value.
			var values = [for (object in objects) if (object.isValue && object.interfaces.length > 0) object.name];
			for (value in values) boxFor(value);
			var byId:Map<Int, Array<String>> = [];
			for (value in boxes.keys()) {
				var hash = IrTypeIdentity.id(Obj(boxes.get(value))), group = byId.get(hash);
				if (group == null) byId.set(hash, group = []);
				group.push(value);
			}
			for (group in byId) group.sort(Reflect.compare);
			var builder = new IrBuilder(),
				input = builder.argument("value", Dyn),
				physical = builder.call("__dynamic_object_type_id", [input], I32),
				missing = builder.createBlock();
			IrTypeHashDispatch.emit(builder, physical, [for (id in byId.keys()) id], function(id) {
				for (value in byId.get(id)) {
					var matched = builder.createBlock(), next = builder.createBlock();
					builder.branch(builder.call("__std_is_exact_type",
						[input, builder.typeValue(Obj(boxes.get(value)))], Bool), matched, next);
					builder.select(matched);
					builder.returnValue(builder.constInt(IrTypeIdentity.id(Obj(value))));
					builder.select(next);
				}
				builder.jump(missing);
			}, missing);
			builder.select(missing);
			builder.returnValue(physical);
			generated.push(new IrFunction(TYPE_ID, builder.arguments, I32, builder.blocks, GeneratedHelper));
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
		var boxName = BOX_PREFIX + valueName,
			methods:Array<IrObjectMethod> = [],
			contracts:Map<String, IrInterfaceMethod> = [],
			visited:Map<String, Bool> = [];
		boxes.set(valueName, boxName);
		if (objectMap.exists(boxName)) return boxName;
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
		for (methodName in methodNames) {
			var contract = contracts.get(methodName);
			if (contract == null) throw new InternalError('Missing interface contract "$methodName"');
			var implementation:Null<IrFunction> = null;
			for (method in value.methods) if (method.name == methodName) implementation =
				index().get(method.functionName.name);
			if (implementation == null)
				throw new InternalError('Missing implementation of "$valueName.$methodName"');
			var wrapper = boxName + "." + methodName,
				builder = new IrBuilder(),
				receiver = builder.argument("this", Obj(boxName)),
				arguments = [for (index in 0...contract.arguments.length) builder.argument('argument$index',
					contract.arguments[index])],
				payload = builder.fieldGet(receiver, "value", Obj(valueName));
			if (implementation.arguments.length != arguments.length + 1)
				throw new InternalError('Invalid interface implementation "$valueName.$methodName"');
			var adapted = [for (index in 0...arguments.length)
				IrGenericOwnerErasure.convert(builder, arguments[index], implementation.arguments[index + 1].type,
				objectMap)];
			var result = builder.call(implementation.name, [payload].concat(adapted), implementation.result);
			builder.returnValue((switch (contract.result) {
				case Void: true;
				default: false;
			}) ? result : IrGenericOwnerErasure.convert(builder, result, contract.result, objectMap));
			methods.push({name: methodName, functionName: compiler.ir.model.IrSymbol.of(wrapper)});
			generated.push(new IrFunction(wrapper, builder.arguments, contract.result, builder.blocks,
				Provider(TypeKey.of(Obj(valueName)),
				ProviderOperations.detailed(ProviderOperation.InterfaceBox, methodName))));
		}
		methods.sort((a, b) -> Reflect.compare(a.name, b.name));
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
	function unboxFor(valueName:String):String {
		var existing = unboxes.get(valueName);
		if (existing != null) return existing;
		var boxName = boxFor(valueName),
			name = UNBOX_PREFIX + valueName,
			builder = new IrBuilder(),
			input = builder.argument("value", Dyn),
			boxed = builder.createBlock(),
			direct = builder.createBlock();
		unboxes.set(valueName, name);
		if (index().exists(name)) return name;
		builder.branch(builder.call("__std_is_of_type", [input, builder.typeValue(Obj(boxName))], Bool), boxed,
			direct);
		builder.select(boxed);
		builder.returnValue(builder.fieldGet(builder.safeCast(input, Obj(boxName)), "value", Obj(valueName)));
		builder.select(direct);
		builder.returnValue(builder.safeCast(input, Obj(valueName)));
		generated.push(new IrFunction(name, builder.arguments, Obj(valueName), builder.blocks,
			Provider(TypeKey.of(Obj(valueName)), ProviderOperation.InterfaceUnbox)));
		return name;
	}
	function typeTestFor(valueName:String, exact:Bool):String {
		var key = (exact ? "exact:" : "instance:") + valueName, existing = typeTests.get(key);
		if (existing != null) return existing;
		var name = "$value-interface-type-test:" + key,
			boxName = boxFor(valueName),
			intrinsic = exact ? "__std_is_exact_type" : "__std_is_of_type",
			builder = new IrBuilder(),
			input = builder.argument("value", Dyn),
			matched = builder.createBlock(),
			boxed = builder.createBlock();
		typeTests.set(key, name);
		if (index().exists(name)) return name;
		builder.branch(builder.call(intrinsic, [input, builder.typeValue(Obj(valueName))], Bool), matched, boxed);
		builder.select(matched);
		builder.returnValue(builder.constBool(true));
		builder.select(boxed);
		builder.returnValue(builder.call(intrinsic, [input, builder.typeValue(Obj(boxName))], Bool));
		generated.push(new IrFunction(name, builder.arguments, Bool, builder.blocks,
			Provider(TypeKey.of(Obj(valueName)),
			ProviderOperations.detailed(ProviderOperation.InterfaceTypeTest, exact ? "exact" : "instance"))));
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
		var name = "$value-interface-cast:" + interfaceName,
			builder = new IrBuilder(),
			input = builder.argument("value", Dyn);
		interfaceCasts.set(interfaceName, name);
		if (index().exists(name)) return name;
		for (valueName in candidates) {
			var existingBox = builder.createBlock(),
				checkValue = builder.createBlock(),
				matched = builder.createBlock(),
				next = builder.createBlock(),
				boxName = boxFor(valueName);
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
		generated.push(new IrFunction(name, builder.arguments, Virtual(interfaceName), builder.blocks,
			Provider(TypeKey.of(Virtual(interfaceName)), ProviderOperation.InterfaceCast)));
		return name;
	}
}
