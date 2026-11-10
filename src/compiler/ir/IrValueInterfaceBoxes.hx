package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.SourceProvenance.Located;

/** Reifies a value only at conversion to a runtime interface. */
class IrValueInterfaceBoxes {
	public static inline final BOX_PREFIX = "$value-interface-box:";
	public static inline final UNBOX_PREFIX = "$value-interface-unbox:";
	static inline final TYPE_ID = "$value-interface-object-type-id";

	public static function rewrite(functions:Array<IrFunction>, objects:Array<IrObject>, interfaces:Array<IrInterface>, ?existingFunctions:Array<IrFunction>):Array<IrFunction> {
		var objectMap:Map<String, IrObject> = [for (object in objects) object.name => object],
			functionMap:Map<String, IrFunction> = [for (fn in (existingFunctions == null ? functions : existingFunctions.concat(functions))) fn.name => fn],
			interfaceMap:Map<String, IrInterface> = [for (entry in interfaces) entry.name => entry],
			boxes:Map<String, String> = [], unboxes:Map<String, String> = [], typeTests:Map<String, String> = [],
			interfaceCasts:Map<String, String> = [], generated:Array<IrFunction> = [];
		function boxFor(valueName:String):String {
			var existing = boxes.get(valueName);
			if (existing != null) return existing;
			var value = objectMap.get(valueName);
			if (value == null || !value.isValue) throw 'Missing value layout "$valueName"';
			var boxName = BOX_PREFIX + valueName, methods:Array<IrObjectMethod> = [],
				contracts:Map<String, IrInterfaceMethod> = [], visited:Map<String, Bool> = [];
			boxes.set(valueName, boxName);
			if (objectMap.exists(boxName)) return boxName;
			function collect(name:String):Void {
				if (visited.exists(name)) return;
				visited.set(name, true);
				var entry = interfaceMap.get(name);
				if (entry == null) throw 'Missing interface "$name"';
				for (base in entry.bases) collect(base);
				for (method in entry.methods) contracts.set(method.name, method);
			}
			for (name in value.interfaces) collect(name);
			// Reflection of an interface box exposes the value's other methods too.
			for (method in value.methods) if (!contracts.exists(method.name)) {
				var fn = functionMap.get(method.functionName);
				if (fn != null && fn.arguments.length > 0)
					contracts.set(method.name, {name: method.name, arguments: [for (argument in fn.arguments.slice(1)) argument.type], result: fn.result});
			}
			var methodNames = [for (methodName in contracts.keys()) methodName];
			methodNames.sort(Reflect.compare);
			for (methodName in methodNames) {
				var contract = contracts.get(methodName);
				if (contract == null) throw 'Missing interface contract "$methodName"';
				var implementation:Null<IrFunction> = null;
				for (method in value.methods) if (method.name == methodName) implementation = functionMap.get(method.functionName);
				if (implementation == null) throw 'Missing implementation of "$valueName.$methodName"';
				var wrapper = boxName + "." + methodName, builder = new IrBuilder(), receiver = builder.argument("this", Obj(boxName)),
					arguments = [for (index in 0...contract.arguments.length) builder.argument('argument$index', contract.arguments[index])],
					payload = builder.fieldGet(receiver, "value", Obj(valueName));
				if (implementation.arguments.length != arguments.length + 1) throw 'Invalid interface implementation "$valueName.$methodName"';
				var adapted = [for (index in 0...arguments.length)
					GenericOwnerErasure.convert(builder, arguments[index], implementation.arguments[index + 1].type, objectMap)];
				var result = builder.call(implementation.name, [payload].concat(adapted), implementation.result);
				builder.returnValue((switch (contract.result) { case Void: true; default: false; }) ? result : GenericOwnerErasure.convert(builder, result, contract.result, objectMap));
				methods.push({name: methodName, functionName: wrapper});
				generated.push(new IrFunction(wrapper, builder.arguments, contract.result, builder.blocks, Ordinary));
			}
			methods.sort((a, b) -> Reflect.compare(a.name, b.name));
			var box:IrObject = {name: boxName, isValue: false, base: null, interfaces: value.interfaces.copy(),
				fields: [{name: "value", type: Obj(valueName)}], methods: methods};
			objects.push(box);
			objectMap.set(boxName, box);
			return boxName;
		}
		function unboxFor(valueName:String):String {
			var existing = unboxes.get(valueName);
			if (existing != null) return existing;
			var boxName = boxFor(valueName), name = UNBOX_PREFIX + valueName,
				builder = new IrBuilder(), input = builder.argument("value", Dyn), boxed = builder.createBlock(), direct = builder.createBlock();
			unboxes.set(valueName, name);
			if (functionMap.exists(name)) return name;
			builder.branch(builder.call("__std_is_of_type", [input, builder.typeValue(Obj(boxName))], Bool), boxed, direct);
			builder.select(boxed);
			builder.returnValue(builder.fieldGet(builder.safeCast(input, Obj(boxName)), "value", Obj(valueName)));
			builder.select(direct);
			builder.returnValue(builder.safeCast(input, Obj(valueName)));
			generated.push(new IrFunction(name, builder.arguments, Obj(valueName), builder.blocks, Ordinary));
			return name;
		}
		function typeTestFor(valueName:String, exact:Bool):String {
			var key = (exact ? "exact:" : "instance:") + valueName, existing = typeTests.get(key);
			if (existing != null) return existing;
			var name = "$value-interface-type-test:" + key, boxName = boxFor(valueName),
				intrinsic = exact ? "__std_is_exact_type" : "__std_is_of_type", builder = new IrBuilder(),
				input = builder.argument("value", Dyn), matched = builder.createBlock(), boxed = builder.createBlock();
			typeTests.set(key, name);
			if (functionMap.exists(name)) return name;
			builder.branch(builder.call(intrinsic, [input, builder.typeValue(Obj(valueName))], Bool), matched, boxed);
			builder.select(matched);
			builder.returnValue(builder.constBool(true));
			builder.select(boxed);
			builder.returnValue(builder.call(intrinsic, [input, builder.typeValue(Obj(boxName))], Bool));
			generated.push(new IrFunction(name, builder.arguments, Bool, builder.blocks, Ordinary));
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
			var name = "$value-interface-cast:" + interfaceName, builder = new IrBuilder(), input = builder.argument("value", Dyn);
			interfaceCasts.set(interfaceName, name);
			if (functionMap.exists(name)) return name;
			for (valueName in candidates) {
				var existingBox = builder.createBlock(), checkValue = builder.createBlock(), matched = builder.createBlock(), next = builder.createBlock(),
					boxName = boxFor(valueName);
				builder.branch(builder.call("__std_is_of_type", [input, builder.typeValue(Obj(boxName))], Bool), existingBox, checkValue);
				builder.select(existingBox);
				builder.returnValue(builder.safeCast(input, Virtual(interfaceName)));
				builder.select(checkValue);
				builder.branch(builder.call("__std_is_of_type", [input, builder.typeValue(Obj(valueName))], Bool), matched, next);
				builder.select(matched);
				var payload = builder.safeCast(input, Obj(valueName)), box = builder.newObject(boxName);
				builder.fieldSet(box, "value", payload);
				builder.returnValue(builder.toVirtual(box, Virtual(interfaceName)));
				builder.select(next);
			}
			builder.returnValue(builder.safeCast(input, Virtual(interfaceName)));
			generated.push(new IrFunction(name, builder.arguments, Virtual(interfaceName), builder.blocks, Ordinary));
			return name;
		}
		var rewritten:Array<IrFunction> = [], needsTypeId = false;
		for (fn in functions) {
			var next = nextId(fn), changed = false, blocks:Array<IrBlock> = [], types:Map<Int, IrType> = [];
			for (block in fn.blocks) for (located in block.instructions) switch located.value {
				case TypeValue(out, type): types.set(out.id, type);
				default:
			}
			for (block in fn.blocks) {
				var target = new IrBlock(block.id);
				for (located in block.instructions) switch located.value {
					case Call(out, "__dynamic_object_type_id", arguments) if (fn.name != TYPE_ID):
						target.instructions.push(new Located(Call(out, TYPE_ID, arguments), located.provenance));
						needsTypeId = true; changed = true;
					case Call(out, intrinsic, arguments) if ((intrinsic == "__std_is_of_type" || intrinsic == "__std_is_exact_type")
						&& arguments.length == 2 && types.exists(arguments[1].id)):
						var object = switch types.get(arguments[1].id) { case Obj(name): objectMap.get(name); default: null; };
						if (object == null || !object.isValue || object.interfaces.length == 0) target.instructions.push(located);
						else {
							target.instructions.push(new Located(Call(out, typeTestFor(object.name, intrinsic == "__std_is_exact_type"), [arguments[0]]), located.provenance));
							changed = true;
						}
					case ToVirtual(out, input):
						var object = switch input.type { case Obj(name): objectMap.get(name); default: null; };
						if (object == null || !object.isValue) target.instructions.push(located);
						else {
							var name = boxFor(object.name), box = new IrValue(next++, "$interface-box", Obj(name));
							target.instructions.push(new Located(NewObject(box, name), located.provenance));
							target.instructions.push(new Located(FieldSet(box, "value", input), located.provenance));
							target.instructions.push(new Located(ToVirtual(out, box), located.provenance));
							changed = true;
						}
					case SafeCast(out, input):
						var interfaceName = switch [out.type, input.type] { case [Virtual(name), Dyn]: name; default: null; };
						if (interfaceName != null && interfaceMap.exists(interfaceName)) {
							target.instructions.push(new Located(Call(out, interfaceCastFor(interfaceName), [input]), located.provenance));
							changed = true;
							continue;
						}
						var object = switch [out.type, input.type] {
							case [Obj(name), Virtual(_) | Dyn]: objectMap.get(name);
							default: null;
						};
						if (object == null || !object.isValue || object.interfaces.length == 0) target.instructions.push(located);
						else {
							var erased = input;
							if ((switch (input.type) { case Dyn: false; default: true; })) {
								erased = new IrValue(next++, "$interface-erased", Dyn);
								target.instructions.push(new Located(ToDyn(erased, input), located.provenance));
							}
							target.instructions.push(new Located(Call(out, unboxFor(object.name), [erased]), located.provenance));
							changed = true;
						}
					default: target.instructions.push(located);
				}
				target.terminator = block.terminator;
				blocks.push(target);
			}
			rewritten.push(changed ? fn.withBlocks(blocks) : fn);
		}
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
			var builder = new IrBuilder(), input = builder.argument("value", Dyn),
				physical = builder.call("__dynamic_object_type_id", [input], I32), missing = builder.createBlock();
			IrTypeHashDispatch.emit(builder, physical, [for (id in byId.keys()) id], function(id) {
				for (value in byId.get(id)) {
					var matched = builder.createBlock(), next = builder.createBlock();
					builder.branch(builder.call("__std_is_exact_type", [input, builder.typeValue(Obj(boxes.get(value)))], Bool), matched, next);
					builder.select(matched); builder.returnValue(builder.constInt(IrTypeIdentity.id(Obj(value))));
					builder.select(next);
				}
				builder.jump(missing);
			}, missing);
			builder.select(missing); builder.returnValue(physical);
			generated.push(new IrFunction(TYPE_ID, builder.arguments, I32, builder.blocks, Ordinary));
		}
		return rewritten.concat(generated);
	}

	static function nextId(fn:IrFunction):Int {
		var max = -1;
		for (argument in fn.arguments) if (argument.id > max) max = argument.id;
		for (block in fn.blocks) for (located in block.instructions) {
			var output = IrOperands.output(located.value);
			if (output != null && output.id > max) max = output.id;
		}
		return max + 1;
	}
}
