package compiler.ir;

import compiler.core.Provides.ProviderOperation;
import compiler.core.Provides.ProviderOperations;
import compiler.ir.Ir;
import compiler.ir.Ir.IrObjectTools;
import compiler.ir.SourceProvenance.Located;

/**
 * A class's method table maps each method name to one slot, and every call through the slot passes its arguments and takes
 * its result in one physical signature: the lowered signature of the slot's topmost declaration. An override can lower to
 * another one when it specializes a generic base: `connector(name:Int):Int` over `connector(name:T):T`, whose `T` erases to
 * `Dyn`. Calling such an override through the slot handed it a box where it expected an Int, and took its Int back as a
 * box.
 *
 * The slot of such an override gets a bridge with the slot's signature, which converts the arguments, calls the override
 * directly and converts its result back. A virtual call made with the override's own types, through a receiver of its
 * class or below, goes through a call adapter that converts to and from the slot's signature around the virtual call.
 * Direct calls of the override keep its own signature.
 */
class IrOverrideBridges {
	public static inline final BRIDGE_PREFIX = "$override-bridge:";
	public static inline final CALL_PREFIX = "$override-call:";

	public static function apply(functions:Array<IrFunction>, objects:Array<IrObject>):{
		functions:Array<IrFunction>,
		objects:Array<IrObject>
	} {
		var byName = [for (object in objects) object.name => object],
			index = new IrFunctionIndex("override-bridges", functions),
			bridges:Array<IrFunction> = [],
			bridged:Map<String, Bool> = [];
		function signatureOf(object:IrObject, method:String):Null<IrFunction> {
			var root:Null<IrFunction> = null, current:Null<IrObject> = object;
			while (current != null) {
				for (entry in current.methods)
					if (entry.name == method) {
						var fn = index.get(entry.functionName.name);
						if (fn != null)
							root = fn;
					}
				current = current.base == null ? null : byName.get(current.base);
			}
			return root;
		}
		var rewritten = [for (object in objects) {
			if (object.base == null || object.methods.length == 0) object;
			else {
				var changed = false, methods = [for (entry in object.methods) {
					var implementation = index.get(entry.functionName.name),
						root = signatureOf(byName.get(object.base), entry.name);
					if (implementation == null || root == null || sameSignature(implementation, root)) entry;
					else {
						var name = BRIDGE_PREFIX + implementation.name;
						if (!bridged.exists(name)) {
							bridged.set(name, true);
							bridges.push(bridge(name, implementation, root, byName));
						}
						changed = true;
						{
							name:entry.name, functionName:compiler.ir.IrSymbol.of(name)
						};
					}
				}];
				changed ? IrObjectTools.withMethods(object, methods) : object;
			}
		}];
		if (bridges.length == 0)
			return {functions: functions, objects: objects};
		var rewrittenByName = [for (object in rewritten) object.name => object],
			adapters:Map<String, IrFunction> = [];
		function slotSignature(receiver:IrType, method:String):Null<IrFunction>
			return switch receiver {
				case Obj(name) if (byName.exists(name)): signatureOf(byName.get(name), method);
				default: null;
			};
		function replacement(located:Located<IrInstruction>):Null<Array<Located<IrInstruction>>>
			return switch located.value {
				case MethodCall(output, receiver, method, arguments, terminal):
					var slot = slotSignature(receiver.type, method);
					if (slot == null || callMatches(slot, arguments, output.type)) null;
					else {
						var argumentTypes = [for (argument in arguments) argument.type],
							name = callAdapterName(receiver.type, method, argumentTypes, output.type);
						if (!adapters.exists(name))
							adapters.set(name, callAdapter(name, receiver.type, method, argumentTypes, output.type,
								slot, rewrittenByName));
						[
							new Located(Call(output, IrSymbol.of(name), [receiver].concat(arguments)),
								located.provenance)
						];
					}
				default: null;
			};
		var result = [for (fn in functions) IrFunctionRewrite.instructions(fn, replacement)];
		var names = [for (name in adapters.keys()) name];
		names.sort(Reflect.compare);
		for (name in names)
			result.push(adapters.get(name));
		return {functions: result.concat(bridges), objects: rewritten};
	}

	/** One adapter per receiver class, method and caller signature. */
	static function callAdapterName(receiver:IrType, method:String, arguments:Array<IrType>, result:IrType):String {
		var signature = IrTypeIdentity.text(receiver) + ":" + IrTypeIdentity.listText(arguments) + ":"
			+ IrTypeIdentity.text(result);
		return CALL_PREFIX + method + ":" + haxe.crypto.Sha256.encode(signature).substr(0, 32);
	}

	static function sameSignature(implementation:IrFunction, root:IrFunction):Bool {
		if (implementation.arguments.length != root.arguments.length
			|| !IrTypeIdentity.same(implementation.result, root.result))
			return false;
		// The receiver is each declaration's own class; the slot's contract is the rest.
		for (index in 1...implementation.arguments.length)
			if (!IrTypeIdentity.same(implementation.arguments[index].type, root.arguments[index].type))
				return false;
		return true;
	}

	static function callMatches(slot:IrFunction, arguments:Array<IrValue>, result:IrType):Bool {
		if (arguments.length + 1 != slot.arguments.length)
			return true; // not a call of this slot's contract; leave it to the verifier
		for (index in 0...arguments.length)
			if (!IrTypeIdentity.same(arguments[index].type, slot.arguments[index + 1].type))
				return false;
		return (switch result {
			case Void: true;
			default: false;
		}) || IrTypeIdentity.same(result, slot.result);
	}

	/** The slot entry for `implementation`: `root`'s signature, with `implementation`'s own receiver. */
	static function bridge(name:String, implementation:IrFunction, root:IrFunction,
			objects:Map<String, IrObject>):IrFunction {
		var builder = new IrBuilder(),
			receiver = builder.argument("receiver", implementation.arguments[0].type),
			arguments = [
				for (index in 1...root.arguments.length)
					builder.argument('argument$index', root.arguments[index].type)
			],
			adapted = [
				for (index in 0...arguments.length)
					GenericOwnerErasure.convert(builder, arguments[index], implementation.arguments[index + 1].type,
					objects)
			],
			result = builder.call(implementation.name, [receiver].concat(adapted), implementation.result);
		builder.returnValue(isVoid(root.result) ? builder.constVoid() : GenericOwnerErasure.convert(builder, result,
			root.result, objects));
		return new IrFunction(name, builder.arguments, root.result, builder.blocks,
			Provider(TypeKey.of(implementation.arguments[0].type),
			ProviderOperations.detailed(ProviderOperation.OverrideBridge, implementation.name)));
	}

	/** A virtual call of `method` made with the caller's types, converted to and from the slot's signature. */
	static function callAdapter(name:String, receiverType:IrType, method:String, argumentTypes:Array<IrType>,
			resultType:IrType, slot:IrFunction,
			objects:Map<String, IrObject>):IrFunction {
		var builder = new IrBuilder(),
			receiver = builder.argument("receiver", receiverType),
			arguments = [
				for (index in 0...argumentTypes.length)
					builder.argument('argument${index + 1}', argumentTypes[index])
			],
			adapted = [
				for (index in 0...arguments.length)
					GenericOwnerErasure.convert(builder, arguments[index], slot.arguments[index + 1].type, objects)
			],
			result = builder.methodCall(receiver, method, adapted, slot.result);
		builder.returnValue(isVoid(resultType) ? builder.constVoid() : GenericOwnerErasure.convert(builder, result,
			resultType, objects));
		return new IrFunction(name, builder.arguments, resultType, builder.blocks,
			Provider(TypeKey.of(receiverType),
			ProviderOperations.detailed(ProviderOperation.OverrideBridge, "call:" + method)));
	}

	static inline function isVoid(type:IrType):Bool
		return switch type {
			case Void: true;
			default: false;
		};
}
