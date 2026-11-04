package compiler.ir;

import compiler.ir.Ir;

/** Closed-world typed entry points for generic interface calls and bound methods. */
class IrTypedInterfaceDispatch {
	public static inline final PREFIX = "$typed-interface:";

	public static function callName(interfaceName:String, method:String, arguments:Array<IrType>, result:IrType):String {
		var signature = Std.string(arguments) + ":" + Std.string(result);
		return PREFIX + interfaceName + ":" + method + ":" + haxe.crypto.Sha256.encode(signature).substr(0, 32);
	}

	public static function generate(functions:Array<IrFunction>, objects:Array<IrObject>, interfaces:Array<IrInterface>):Void {
		var requests:Map<String, {arguments:Array<IrType>, result:IrType}> = [];
		function request(name:String, signature:{arguments:Array<IrType>, result:IrType}):Void {
			var previous = requests.get(name);
			if (previous != null && (!IrVerifier.sameType(previous.result, signature.result) || previous.arguments.length != signature.arguments.length))
				throw 'Conflicting typed interface dispatch "$name"';
			if (previous != null) for (index in 0...signature.arguments.length)
				if (!IrVerifier.sameType(previous.arguments[index], signature.arguments[index])) throw 'Conflicting typed interface dispatch "$name"';
			requests.set(name, signature);
		}
		for (fn in functions) for (block in fn.blocks) for (located in block.instructions) switch located.value {
			case Call(output, name, arguments) if (StringTools.startsWith(name, PREFIX)):
				request(name, {arguments: [for (argument in arguments) argument.type], result: output.type});
			case InstanceClosure(output, name, receiver) if (StringTools.startsWith(name, PREFIX)):
				switch output.type {
					case Function(arguments, result): request(name, {arguments: [receiver.type].concat(arguments), result: result});
					default: throw 'Invalid typed interface method reference "$name"';
				}
			default:
		}
		var byName:Map<String, IrObject> = [for (object in objects) object.name => object],
			byInterface:Map<String, IrInterface> = [for (entry in interfaces) entry.name => entry],
			byFunction:Map<String, IrFunction> = [for (fn in functions) fn.name => fn];
		function extendsInterface(actual:String, expected:String, visited:Map<String, Bool>):Bool {
			if (actual == expected) return true;
			if (visited.exists(actual)) return false;
			visited.set(actual, true);
			var entry = byInterface.get(actual);
			if (entry != null) for (base in entry.bases) if (extendsInterface(base, expected, visited)) return true;
			return false;
		}
		function implementsInterface(object:IrObject, name:String):Bool {
			var current:Null<IrObject> = object;
			while (current != null) {
				for (implemented in current.interfaces) if (extendsInterface(implemented, name, [])) return true;
				current = current.base == null ? null : byName.get(current.base);
			}
			return false;
		}
		function depth(object:IrObject):Int {
			var count = 0, current:Null<IrObject> = object;
			while (current != null) { count++; current = current.base == null ? null : byName.get(current.base); }
			return count;
		}
		function findMethod(object:IrObject, method:String):Null<IrFunction> {
			var current:Null<IrObject> = object;
			while (current != null) {
				for (entry in current.methods) if (entry.name == method) return byFunction.get(entry.functionName);
				current = current.base == null ? null : byName.get(current.base);
			}
			return null;
		}
		function isManagedReference(type:IrType):Bool {
			return switch type {
				case Obj(name): var object = byName.get(name); object == null || !object.isValue;
				case Nullable(I32 | I64 | F32 | F64 | Bool): true;
				case Nullable(inner): isManagedReference(inner);
				case Dyn | Virtual(_) | Enum(_) | Bytes | ManagedBytes | Array(_) | Function(_, _) | Iterator(_) | Abstract(_): true;
				default: false;
			};
		}
		function carriersCompatible(a:IrType, b:IrType):Bool
			return IrVerifier.sameType(a, b) || (isManagedReference(a) && isManagedReference(b));
		var names = [for (name in requests.keys()) name];
		names.sort(Reflect.compare);
		for (name in names) {
			var parts = name.substr(PREFIX.length).split(":"), signature = requests.get(name);
			if (parts.length != 3 || signature == null || signature.arguments.length == 0) throw 'Invalid typed interface dispatch "$name"';
			var interfaceName = parts[0], method = parts[1], receiverType = signature.arguments[0];
			if (!IrVerifier.sameType(receiverType, Virtual(interfaceName))) throw 'Invalid typed interface receiver for "$name"';
			var candidates = [for (object in objects) if (!object.isValue && implementsInterface(object, interfaceName)) object];
			candidates.sort((a, b) -> { var order = depth(b) - depth(a); return order == 0 ? Reflect.compare(a.name, b.name) : order; });
			var builder = new IrBuilder(), receiver = builder.argument("receiver", receiverType),
				arguments = [for (index in 1...signature.arguments.length) builder.argument('argument$index', signature.arguments[index])],
				dynamicReceiver = builder.toDyn(receiver);
			for (candidate in candidates) {
				var valueName = StringTools.startsWith(candidate.name, IrValueInterfaceBoxes.BOX_PREFIX)
					? candidate.name.substr(IrValueInterfaceBoxes.BOX_PREFIX.length) : null;
				var owner = valueName == null ? candidate : byName.get(valueName);
				var implementation = owner == null ? null : findMethod(owner, method);
				if (implementation == null || implementation.arguments.length != arguments.length + 1) continue;
				var matched = builder.createBlock(), next = builder.createBlock(), type = Obj(candidate.name);
				builder.branch(builder.call("__std_is_of_type", [dynamicReceiver, builder.typeValue(type)], Bool), matched, next);
				builder.select(matched);
				// Incompatible concrete carriers indicate an invalid erased cast. Do not emit a
				// boxing conversion in an unreachable branch of a value-specialized dispatcher.
				var compatible = true;
				for (index in 0...arguments.length)
					if (!carriersCompatible(arguments[index].type, implementation.arguments[index + 1].type)) compatible = false;
				if (!carriersCompatible(signature.result, implementation.result)) compatible = false;
				if (!compatible) {
					builder.throwValue(builder.toDyn(builder.constString('Invalid implementation for $interfaceName.$method')));
					builder.select(next);
					continue;
				}
				var concrete = builder.safeCast(dynamicReceiver, type),
					target = valueName == null ? concrete : builder.fieldGet(concrete, "value", Obj(valueName));
				var adapted = [for (index in 0...arguments.length)
					GenericOwnerErasure.convert(builder, arguments[index], implementation.arguments[index + 1].type, byName)];
				var result = builder.call(implementation.name, [target].concat(adapted), implementation.result);
				builder.returnValue((switch signature.result { case Void: true; default: false; })
					? result : GenericOwnerErasure.convert(builder, result, signature.result, byName));
				builder.select(next);
			}
			builder.throwValue(builder.toDyn(builder.constString('Invalid receiver for $interfaceName.$method')));
			functions.push(new IrFunction(name, builder.arguments, signature.result, builder.blocks));
		}
	}
}
