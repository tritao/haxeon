package compiler.ir;

import compiler.core.InternalError;
import compiler.core.Provides.ProviderOperation;
import compiler.core.Provides.ProviderOperations;
import compiler.ir.Ir;
import compiler.ir.SourceProvenance.Located;

/** A typed interface dispatcher a function calls: its name and the signature of the call. */
typedef IrTypedInterfaceRequest = {
	final name:String;
	final arguments:Array<IrType>;
	final result:IrType;
}

/** Closed-world typed entry points for value interface calls and specialized generic contracts. */
class IrTypedInterfaceDispatch {
	public static inline final PREFIX = "$typed-interface:";
	public static inline final ADAPTER_PREFIX = "$typed-interface-entry:";

	/** The same entry can be lowered through optional-flow and component-argument ABIs. */
	public static function originalEntryName(name:String):String {
		while (true) {
			if (StringTools.startsWith(name, IrScalarArguments.PREFIX)) name =
				name.substr(IrScalarArguments.PREFIX.length);
			else if (StringTools.startsWith(name, IrOptionalScalarFlow.PREFIX)) name =
				name.substr(IrOptionalScalarFlow.PREFIX.length);
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
	public static function rewriteValueCalls(functions:Array<IrFunction>, objects:Array<IrObject>,
			interfaces:Array<IrInterface>):Array<IrFunction>
		return IrFunctionStages.apply("typed-interface-calls", new IrTypedInterfaceCalls(objects, interfaces),
			functions);

	/**
	 * `rewriteValueCalls` on one body, in place: an interface call or method value that carries a value object (`values`, by
	 * name) calls its typed dispatcher. A method value is rewritten only for an interface in `contracts`.
	 */
	public static function rewriteBodyValueCalls(body:IrBody, values:Map<String, Bool>,
			contracts:Map<String, Bool>):Void {
		function isValue(type:IrType):Bool return switch type {
			case Obj(name): values.exists(name);
			default: false;
		};
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				switch body.opcode(row) {
					case IrOpcode.MethodCall:
						switch body.valueType(body.operand(row, 0)) {
							case Virtual(name):
								var output = body.valueType(body.output(row)), carriesValue = isValue(output);
								for (index in 1...body.operandCount(row))
									if (isValue(body.valueType(body.operand(row, index))))
										carriesValue = true;
								if (carriesValue)
									body.setOperation(row, IrOpcode.Call,
										IrSymbol.of(callName(name, body.symbol(row).name,
										[for (index in 1...body.operandCount(row)) body.valueType(body.operand(row,
										index))],
										output)).id);
							default:
						}
					case IrOpcode.InstanceClosure:
						var name = body.symbol(row).name, separator = name.lastIndexOf(".");
						if (!StringTools.startsWith(name, PREFIX) && separator >= 0
							&& contracts.exists(name.substr(0, separator)))
							switch [body.valueType(body.operand(row, 0)), body.valueType(body.output(row))] {
								case [Virtual(owner), Function(arguments, result)]
									if (isValue(result) || Lambda.exists(arguments, isValue)):
									body.setAux(row,
										IrSymbol.of(callName(owner, name.substr(separator + 1), arguments, result)).id);
								default:
							}
					default:
				}
				row = body.nextRow(row);
			}
		}
	}

	public static function callName(interfaceName:String, method:String, arguments:Array<IrType>,
			result:IrType):String {
		var signature = IrTypeIdentity.listText(arguments) + ":" + IrTypeIdentity.text(result);
		return PREFIX + interfaceName + ":" + method + ":" + haxe.crypto.Sha256.encode(signature).substr(0, 32);
	}

	/**
	 * The dispatchers `fn` calls or takes as a method value, as requests of a name and signature, in the order it names them: kept
	 * by the session for `fn`'s version with `lineage` (`IrStageMemos.interfaceRequests`), else read now.
	 */
	static function requestsOf(fn:IrFunction,
			lineage:Null<compiler.ir.IrStageMemo.IrLineage>):Array<IrTypedInterfaceRequest> {
		var version = lineage == null ? 0 : lineage.versionOf(fn);
		if (lineage == null || version == 0)
			return readRequests(fn);
		var memo = lineage.memos.interfaceRequests, known = memo.get(version);
		if (known == null) {
			known = readRequests(fn);
			memo.keep(version, known);
		} else if (lineage.checks) {
			var now = readRequests(fn), same = now.length == known.length;
			for (index in 0...now.length)
				if (same && !sameRequest(now[index], known[index]))
					same = false;
			if (!same)
				throw new InternalError('--check-reuse: the typed interface requests reused for ${fn.name} differ from its code');
		}
		return known;
	}

	@:processWide("a shared empty list of requests, only ever read")
	static final NO_REQUESTS:Array<IrTypedInterfaceRequest> = [];

	static function sameRequest(left:IrTypedInterfaceRequest, right:IrTypedInterfaceRequest):Bool {
		if (left.name != right.name || left.arguments.length != right.arguments.length
			|| !IrVerifier.sameType(left.result, right.result))
			return false;
		for (index in 0...left.arguments.length)
			if (!IrVerifier.sameType(left.arguments[index], right.arguments[index]))
				return false;
		return true;
	}

	/** Reads the dispatcher requests of `fn` (`requestsOf`). A function read past the encode point is its body; one before it, its objects. */
	static function readRequests(fn:IrFunction):Array<IrTypedInterfaceRequest> {
		var found:Null<Array<IrTypedInterfaceRequest>> = null;
		function request(name:String, arguments:Array<IrType>, result:IrType):Void {
			if (found == null)
				found = [];
			found.push({name: name, arguments: arguments, result: result});
		}
		function closureRequest(name:String, output:IrType, receiver:IrType):Void
			switch output {
				case Function(arguments, result): request(name, [receiver].concat(arguments), result);
				default: throw new InternalError('Invalid typed interface method reference "$name"');
			}
		var body = fn.body;
		if (body != null)
			for (block in 0...body.blockCount()) {
				var row = body.firstRow(block);
				while (row >= 0) {
					var opcode = body.opcode(row);
					if (opcode == IrOpcode.Call || opcode == IrOpcode.InstanceClosure) {
						var name = body.symbol(row).name;
						if (StringTools.startsWith(name, PREFIX)) {
							if (opcode == IrOpcode.Call)
								request(name, [for (index in 0...body.operandCount(row))
									body.valueType(body.operand(row, index))], body.valueType(body.output(row)));
							else
								closureRequest(name, body.valueType(body.output(row)),
									body.valueType(body.operand(row, 0)));
						}
					}
					row = body.nextRow(row);
				}
			}
				else
				for (block in fn.blocks)
					for (located in block.instructions)
						switch located.value {
							case Call(output, name, arguments) if (StringTools.startsWith(name.name, PREFIX)):
								request(name.name, [for (argument in arguments) argument.type], output.type);
							case InstanceClosure(output, name, receiver) if (StringTools.startsWith(name.name, PREFIX)):
								closureRequest(name.name, output.type, receiver.type);
							default:
						}
		return found == null ? NO_REQUESTS : found;
	}

	public static function generate(functions:Array<IrFunction>, objects:Array<IrObject>,
			interfaces:Array<IrInterface>, ?lineage:compiler.ir.IrStageMemo.IrLineage):Void {
		var requests:Map<String, {arguments:Array<IrType>, result:IrType}> = [];
		function request(name:String, signature:{arguments:Array<IrType>, result:IrType}):Void {
			var previous = requests.get(name);
			if (previous != null && (!IrVerifier.sameType(previous.result, signature.result)
				|| previous.arguments.length != signature.arguments.length))
				throw new InternalError('Conflicting typed interface dispatch "$name"');
			if (previous != null) for (index in 0...signature.arguments.length)
				if (!IrVerifier.sameType(previous.arguments[index], signature.arguments[index]))
				throw new InternalError('Conflicting typed interface dispatch "$name"');
			requests.set(name, signature);
		}
		for (fn in functions)
			for (found in requestsOf(fn, lineage))
				request(found.name, {arguments: found.arguments, result: found.result});
		var byName:Map<String, IrObject> = [for (object in objects) object.name => object],
			byInterface:Map<String, IrInterface> = [for (entry in interfaces) entry.name => entry],
			byFunction = new IrFunctionIndex("typed-interface-dispatch", functions),
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
			while (current != null) {
				count++;
				current = current.base == null ? null : byName.get(current.base);
			}
			return count;
		}
		function findMethod(object:IrObject, method:String):Null<IrFunction> {
			var current:Null<IrObject> = object;
			while (current != null) {
				for (entry in current.methods) if (entry.name == method) return byFunction.get(entry.functionName.name);
				IrEntryPrune.noteMethodLookup(current.name, method);
				current = current.base == null ? null : byName.get(current.base);
			}
			return null;
		}
		function isManagedReference(type:IrType):Bool {
			return switch type {
				case Obj(name): var object = byName.get(name);
					object == null || !object.isValue;
				case Nullable(I32 | I64 | F32 | F64 | Bool): true;
				case Nullable(inner): isManagedReference(inner);
				case Dyn | Virtual(_) | Enum(_) | Bytes | ManagedBytes | Array(_) | Function(_,
					_) | Iterator(_) | Abstract(_): true;
				default: false;
			};
		}
		function carriersCompatible(a:IrType, b:IrType):Bool
			return IrVerifier.sameType(a, b) || (isManagedReference(a) && isManagedReference(b));
		var names = [for (name in requests.keys()) name];
		names.sort(Reflect.compare);
		for (name in names) {
			var parts = name.substr(PREFIX.length).split(":"), signature = requests.get(name);
			if (parts.length != 3 || signature == null
				|| signature.arguments.length == 0) throw new InternalError('Invalid typed interface dispatch "$name"');
			var interfaceName = parts[0], method = parts[1], receiverType = signature.arguments[0];
			if (!IrVerifier.sameType(receiverType, Virtual(interfaceName)))
				throw new InternalError('Invalid typed interface receiver for "$name"');
			var existing = byFunction.get(name);
			if (existing != null) {
				if (!IrVerifier.sameType(existing.result, signature.result)
					|| existing.arguments.length != signature.arguments.length)
					throw new InternalError('Conflicting typed interface dispatch "$name"');
				for (index in 0...signature.arguments.length)
					if (!IrVerifier.sameType(existing.arguments[index].type, signature.arguments[index]))
						throw new InternalError('Conflicting typed interface dispatch "$name"');
			}
			var candidates =
				[for (object in objects) if (!object.isValue && implementsInterface(object, interfaceName)) object];
			candidates.sort((a, b) -> {
				var order = depth(b) - depth(a);
				return order == 0 ? Reflect.compare(a.name, b.name) : order;
			});
			var builder = new IrBuilder(),
				receiver = builder.argument("receiver", receiverType),
				arguments = [for (index in 1...signature.arguments.length) builder.argument('argument$index',
					signature.arguments[index])],
				dynamicReceiver = builder.toDyn(receiver);
			for (candidate in candidates) {
				var valueName = StringTools.startsWith(candidate.name, IrValueInterfaceBoxes.BOX_PREFIX)
					? candidate.name.substr(IrValueInterfaceBoxes.BOX_PREFIX.length) : null;
				var owner = valueName == null ? candidate : byName.get(valueName);
				var implementation = owner == null ? null : findMethod(owner, method);
				if (implementation == null || implementation.arguments.length != arguments.length + 1) continue;
				var entryName = adapterName(name, candidate.name),
					entry = new IrBuilder(),
					dynamicValue = entry.argument("receiver", Dyn),
					entryArgs = [for (index in 0...arguments.length) entry.argument('argument$index',
						arguments[index].type)];
				var compatible = true;
				for (index in 0...entryArgs.length)
					if (!carriersCompatible(entryArgs[index].type, implementation.arguments[index + 1].type))
						compatible = false;
				if (!carriersCompatible(signature.result, implementation.result)) compatible = false;
				if (!compatible)
					entry.throwValue(entry.toDyn(entry.constString('Invalid implementation for $interfaceName.$method')));
				else {
					var concrete = entry.safeCast(dynamicValue, Obj(candidate.name)),
						target = valueName == null ? concrete : entry.fieldGet(concrete, "value", Obj(valueName)),
						adapted = [for (index in 0...entryArgs.length)
							GenericOwnerErasure.convert(entry, entryArgs[index],
							implementation.arguments[index + 1].type, byName)],
						result = entry.call(implementation.name, [target].concat(adapted), implementation.result);
					entry.returnValue((switch signature.result {
						case Void: true;
						default: false;
					}) ? result : GenericOwnerErasure.convert(entry, result, signature.result, byName));
				}
				var entryFunction = new IrFunction(entryName, entry.arguments, signature.result, entry.blocks,
					Provider(TypeKey.of(Obj(candidate.name)),
					ProviderOperations.detailed(ProviderOperation.TypedInterfaceEntry, entryName))),
					entryIndex = functionIndices.get(entryName);
				if (entryIndex == null) {
					functionIndices.set(entryName, functions.length);
					functions.push(entryFunction);
				} else functions[entryIndex] = entryFunction;
				var matched = builder.createBlock(), next = builder.createBlock();
				builder.branch(builder.call("__std_is_of_type", [
					dynamicReceiver,
					builder.typeValue(Obj(candidate.name))
				], Bool), matched, next);
				builder.select(matched);
				builder.returnValue(builder.call(entryName, [dynamicReceiver].concat(arguments), signature.result));
				builder.select(next);
			}
			builder.throwValue(builder.toDyn(builder.constString('Invalid receiver for $interfaceName.$method')));
			var generated = new IrFunction(name, builder.arguments, signature.result, builder.blocks,
				Provider(TypeKey.of(Virtual(interfaceName)),
				ProviderOperations.detailed(ProviderOperation.DynamicDispatch, name)));
			if (existing == null) functions.push(generated);
			else {
				var index = functionIndices.get(name);
				if (index == null) throw new InternalError('Missing typed interface dispatcher index "$name"');
				functions[index] = generated;
			}
		}
	}
}

/**
 * `IrTypedInterfaceDispatch.rewriteValueCalls` per function (`IrFunctionPass`): the rewrite reads, for each object a call's types
 * name, whether it is a value object (`VALUE`), and for each method value's interface whether it is one (`CONTRACT`).
 */
class IrTypedInterfaceCalls implements IrFunctionPass {
	static inline final VALUE = 0;
	static inline final CONTRACT = 1;

	final values:Map<String, Bool>;
	final contracts:Map<String, Bool>;

	public function new(objects:Array<IrObject>, interfaces:Array<IrInterface>) {
		values = [for (object in objects) if (object.isValue) object.name => true];
		contracts = [for (entry in interfaces) entry.name => true];
	}

	public function summarize(fn:IrFunction):Int
		return 0;

	public function prepare(functions:Array<IrFunction>, summaries:Array<Int>):Void {}

	public function fact(kind:Int, key:String):Int
		return (kind == VALUE ? values : contracts).exists(key) ? 1 : 0;

	public function transform(fn:IrFunction, summary:Int, reader:IrFactReader):IrFunction {
		function isValue(type:IrType):Bool return switch type {
			case Obj(name): reader.read(VALUE, name) == 1;
			default: false;
		};
		function valueSignature(arguments:Array<IrType>, result:IrType):Bool
			return isValue(result) || Lambda.exists(arguments, isValue);
		function replacement(located:Located<IrInstruction>):Null<Array<Located<IrInstruction>>>
			return switch located.value {
				case MethodCall(output, receiver, method, arguments, _):
					switch receiver.type {
						case Virtual(name):
							var carriesValue = isValue(output.type);
							for (argument in arguments) if (isValue(argument.type)) carriesValue = true;
							if (!carriesValue) null;
							else [new Located(Call(output,
								IrSymbol.of(IrTypedInterfaceDispatch.callName(name, method,
								[for (argument in arguments) argument.type], output.type)),
								[receiver].concat(arguments)),
								located.provenance)];
						default: null;
					}
				case InstanceClosure(output, target, receiver)
					if (!StringTools.startsWith(target.name, IrTypedInterfaceDispatch.PREFIX)):
					var name = target.name, separator = name.lastIndexOf(".");
					if (separator < 0 || reader.read(CONTRACT, name.substr(0, separator)) == 0) null;
					else switch [receiver.type, output.type] {
						case [Virtual(owner), Function(arguments, result)] if (valueSignature(arguments, result)):
							[new Located(InstanceClosure(output,
								IrSymbol.of(IrTypedInterfaceDispatch.callName(owner, name.substr(separator + 1),
								arguments, result)), receiver), located.provenance)];
						default: null;
					}
				default: null;
			};
		return IrFunctionRewrite.instructions(fn, replacement);
	}

	public function request(type:IrType):Void {}

	public function finish(functions:Array<IrFunction>):Array<IrFunction>
		return functions;
}
