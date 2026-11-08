package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.SourceProvenance.Located;

/** Closed-world typed entry points for value interface calls and specialized generic contracts. */
class IrTypedInterfaceDispatch {
	public static inline final PREFIX = "$typed-interface:";
	public static inline final ADAPTER_PREFIX = "$typed-interface-entry:";

	/** The same entry can be lowered through optional-flow and component-argument ABIs. */
	public static function originalEntryName(name:String):String {
		while (true) {
			if (StringTools.startsWith(name, IrScalarArguments.PREFIX)) name = name.substr(IrScalarArguments.PREFIX.length);
			else if (StringTools.startsWith(name, IrOptionalScalarFlow.PREFIX)) name = name.substr(IrOptionalScalarFlow.PREFIX.length);
			else return name;
		}
	}

	/** Dispatch entries stay outlined so a backend can use its class method table. */
	public static function isDispatchEntry(name:String):Bool
		return StringTools.startsWith(originalEntryName(name), PREFIX);

	public static function isAdapterEntry(name:String):Bool
		return StringTools.startsWith(originalEntryName(name), ADAPTER_PREFIX);

	public static function adapterName(dispatch:String, object:String):String
		return ADAPTER_PREFIX + dispatch.length + ":" + dispatch + ":" + object.length + ":" + object;


	/** Select the value ABI after physical value layouts are known, including nongeneric contracts. */
	public static function rewriteValueCalls(functions:Array<IrFunction>, objects:Array<IrObject>, interfaces:Array<IrInterface>):Array<IrFunction> {
		var values:Map<String, Bool> = [for (object in objects) if (object.isValue) object.name => true],
			contracts:Map<String, Bool> = [for (entry in interfaces) entry.name => true];
		function isValue(type:IrType):Bool return switch type { case Obj(name): values.exists(name); default: false; };
		function valueSignature(arguments:Array<IrType>, result:IrType):Bool
			return isValue(result) || Lambda.exists(arguments, isValue);
		var rewritten:Array<IrFunction> = [];
		for (fn in functions) {
			var blocks:Array<IrBlock> = [], changed = false;
			for (block in fn.blocks) {
				var target = new IrBlock(block.id);
				for (located in block.instructions) {
					var replaced = false;
					var instruction = switch located.value {
						case MethodCall(output, receiver, method, arguments, _):
							switch receiver.type {
								case Virtual(name):
									var carriesValue = isValue(output.type);
									for (argument in arguments) if (isValue(argument.type)) carriesValue = true;
									if (!carriesValue) located.value;
									else {
										replaced = true;
										Call(output, callName(name, method, [for (argument in arguments) argument.type], output.type), [receiver].concat(arguments));
									}
								default: located.value;
							}
						case InstanceClosure(output, name, receiver) if (!StringTools.startsWith(name, PREFIX)):
							var separator = name.lastIndexOf(".");
							if (separator < 0 || !contracts.exists(name.substr(0, separator))) located.value;
							else switch [receiver.type, output.type] {
								case [Virtual(owner), Function(arguments, result)] if (valueSignature(arguments, result)):
									replaced = true;
									InstanceClosure(output, callName(owner, name.substr(separator + 1), arguments, result), receiver);
								default: located.value;
							}
						default: located.value;
					};
					if (!replaced) target.instructions.push(located);
					else { changed = true; target.instructions.push(new Located(instruction, located.provenance)); }
				}
				target.terminator = block.terminator;
				blocks.push(target);
			}
			rewritten.push(changed ? new IrFunction(fn.name, fn.arguments, fn.result, blocks, fn.debugBindings, fn.inlineHint, fn.retention) : fn);
		}
		return rewritten;
	}

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
			byFunction:Map<String, IrFunction> = [for (fn in functions) fn.name => fn],
			functionIndices:Map<String, Int> = [for (index in 0...functions.length) functions[index].name => index];
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
			var existing = byFunction.get(name);
			if (existing != null) {
				if (!IrVerifier.sameType(existing.result, signature.result) || existing.arguments.length != signature.arguments.length)
					throw 'Conflicting typed interface dispatch "$name"';
				for (index in 0...signature.arguments.length)
					if (!IrVerifier.sameType(existing.arguments[index].type, signature.arguments[index])) throw 'Conflicting typed interface dispatch "$name"';
			}
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
				var entryName = adapterName(name, candidate.name), entry = new IrBuilder(),
					dynamicValue = entry.argument("receiver", Dyn),
					entryArgs = [for (index in 0...arguments.length) entry.argument('argument$index', arguments[index].type)];
				var compatible = true;
				for (index in 0...entryArgs.length)
					if (!carriersCompatible(entryArgs[index].type, implementation.arguments[index + 1].type)) compatible = false;
				if (!carriersCompatible(signature.result, implementation.result)) compatible = false;
				if (!compatible) entry.throwValue(entry.toDyn(entry.constString('Invalid implementation for $interfaceName.$method')));
				else {
					var concrete = entry.safeCast(dynamicValue, Obj(candidate.name)),
						target = valueName == null ? concrete : entry.fieldGet(concrete, "value", Obj(valueName)),
						adapted = [for (index in 0...entryArgs.length)
							GenericOwnerErasure.convert(entry, entryArgs[index], implementation.arguments[index + 1].type, byName)],
						result = entry.call(implementation.name, [target].concat(adapted), implementation.result);
					entry.returnValue((switch signature.result { case Void: true; default: false; }) ? result :
						GenericOwnerErasure.convert(entry, result, signature.result, byName));
				}
				var entryFunction = new IrFunction(entryName, entry.arguments, signature.result, entry.blocks),
					entryIndex = functionIndices.get(entryName);
				if (entryIndex == null) {
					functionIndices.set(entryName, functions.length);
					functions.push(entryFunction);
				} else functions[entryIndex] = entryFunction;
				var matched = builder.createBlock(), next = builder.createBlock();
				builder.branch(builder.call("__std_is_of_type", [dynamicReceiver, builder.typeValue(Obj(candidate.name))], Bool), matched, next);
				builder.select(matched);
				builder.returnValue(builder.call(entryName, [dynamicReceiver].concat(arguments), signature.result));
				builder.select(next);
			}
			builder.throwValue(builder.toDyn(builder.constString('Invalid receiver for $interfaceName.$method')));
			var generated = new IrFunction(name, builder.arguments, signature.result, builder.blocks);
			if (existing == null) functions.push(generated);
			else {
				var index = functionIndices.get(name);
				if (index == null) throw 'Missing typed interface dispatcher index "$name"';
				functions[index] = generated;
			}
		}
	}
}
