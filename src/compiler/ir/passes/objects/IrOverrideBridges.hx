package compiler.ir.passes.objects;

import compiler.ir.model.IrBuilder;
import compiler.ir.reuse.IrFactReader;
import compiler.ir.reuse.IrStageFacts;
import compiler.ir.model.IrFunction;
import compiler.ir.pipeline.IrFunctionIndex;
import compiler.ir.pipeline.IrFunctionPass;
import compiler.ir.passes.IrFunctionRewrite;
import compiler.ir.pipeline.IrFunctionStages;
import compiler.ir.model.IrSymbol;
import compiler.ir.model.IrTypeIdentity;
import compiler.ir.model.TypeKey;
import compiler.core.Provides.ProviderOperation;
import compiler.core.Provides.ProviderOperations;
import compiler.ir.model.Ir;
import compiler.ir.model.Ir.IrObjectTools;
import compiler.ir.model.SourceProvenance.Located;

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
@:nullSafety(Strict)
class IrOverrideBridges extends IrFunctionPass {
	public static inline final BRIDGE_PREFIX = "$override-bridge:";
	public static inline final CALL_PREFIX = "$override-call:";

	/**
	 * The program-wide fact a rewrite reads: 0 when no slot needs a bridge, so no call changes. With bridges it is not stated per
	 * call (`IrStageFacts.UNKNOWN`): every function is rewritten again, and the call adapters are made as the rewrites meet the calls.
	 */
	static inline final BRIDGED = 0;

	/** The objects, with the slots of the bridged overrides pointing at their bridges after `prepare`. */
	public var objects(default, null):Array<IrObject>;

	var byName:Map<String, IrObject> = [];
	var index:Null<IrFunctionIndex> = null;
	var bridges:Array<IrFunction> = [];
	var rewrittenByName:Map<String, IrObject> = [];
	var adapters:Map<String, IrFunction> = [];

	public function new(objects:Array<IrObject>)
		this.objects = objects;

	public static function apply(functions:Array<IrFunction>, objects:Array<IrObject>):{
		functions:Array<IrFunction>,
		objects:Array<IrObject>
	} {
		var pass = new IrOverrideBridges(objects), result = IrFunctionStages.apply("override-bridges", pass, functions);
		return {functions: result, objects: pass.objects};
	}

	function signatureOf(object:Null<IrObject>, method:String):Null<IrFunction> {
		var root:Null<IrFunction> = null, current:Null<IrObject> = object, functions = index;
		while (current != null && functions != null) {
			for (entry in current.methods)
				if (entry.name == method) {
					var fn = functions.get(entry.functionName.name);
					if (fn != null)
						root = fn;
				}
			current = current.base == null ? null : byName.get(current.base);
		}
		return root;
	}

	override public function summarize(fn:IrFunction):Int
		return 0;

	override public function prepare(functions:Array<IrFunction>, summaries:Array<Int>, names:IrFunctionIndex):Void {
		byName = [for (object in objects) object.name => object];
		var functionIndex = names, bridged:Map<String, Bool> = [];
		index = functionIndex;
		var rewritten = [for (object in objects) {
			var base = object.base;
			if (base == null || object.methods.length == 0) object;
			else {
				var changed = false, methods = [for (entry in object.methods) {
					var implementation = functionIndex.get(entry.functionName.name),
						root = signatureOf(byName.get(base), entry.name);
					if (implementation == null || root == null) entry;
					else if (sameSignature(implementation, root)) entry;
					else {
						var name = BRIDGE_PREFIX + implementation.name;
						if (!bridged.exists(name)) {
							bridged.set(name, true);
							bridges.push(bridge(name, implementation, root, byName));
						}
						changed = true;
						{
							name:entry.name, functionName:compiler.ir.model.IrSymbol.of(name)
						};
					}
				}];
				changed ? IrObjectTools.withMethods(object, methods) : object;
			}
		}];
		if (bridges.length == 0)
			return;
		rewrittenByName = [for (object in rewritten) object.name => object];
		objects = rewritten;
	}

	override public function fact(kind:Int, key:String):Int
		return bridges.length == 0 ? 0 : IrStageFacts.UNKNOWN;

	override public function transform(fn:IrFunction, summary:Int, reader:IrFactReader):IrFunction {
		if (reader.read(BRIDGED, "") == 0)
			return fn;
		return IrFunctionRewrite.instructions(fn, adapted);
	}

	function slotSignature(receiver:IrType, method:String):Null<IrFunction>
		return switch receiver {
			case Obj(name): signatureOf(byName.get(name), method);
			default: null;
		};

	function adapted(located:Located<IrInstruction>):Null<Array<Located<IrInstruction>>>
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

	override public function request(kind:Int, type:IrType, name:Null<String>):Void {}

	override public function finish(functions:Array<IrFunction>):Array<IrFunction> {
		if (bridges.length == 0)
			return functions;
		var made = [for (name => adapter in adapters) {
			name: name, adapter: adapter
		}];
		made.sort((a, b) -> Reflect.compare(a.name, b.name));
		for (entry in made)
			functions.push(entry.adapter);
		return functions.concat(bridges);
	}

	/** One adapter per receiver class, method and caller signature. */
	static function callAdapterName(receiver:IrType, method:String, arguments:Array<IrType>, result:IrType):String {
		var signature = IrTypeIdentity.text(receiver) + ":" + IrTypeIdentity.listText(arguments) + ":"
			+ IrTypeIdentity.text(result);
		return CALL_PREFIX + method + ":" + compiler.core.TextDigest.sha256(signature).substr(0, 32);
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
					IrGenericOwnerErasure.convert(builder, arguments[index], implementation.arguments[index + 1].type,
					objects)
			],
			result = builder.call(implementation.name, [receiver].concat(adapted), implementation.result);
		builder.returnValue(isVoid(root.result) ? builder.constVoid() : IrGenericOwnerErasure.convert(builder, result,
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
					IrGenericOwnerErasure.convert(builder, arguments[index], slot.arguments[index + 1].type, objects)
			],
			result = builder.methodCall(receiver, method, adapted, slot.result);
		builder.returnValue(isVoid(resultType) ? builder.constVoid() : IrGenericOwnerErasure.convert(builder, result,
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
