package compiler.ir.gen;

import compiler.core.InternalError;
import compiler.core.Provides.ProviderOperation;
import compiler.core.Provides.ProviderOperations;
import compiler.ir.model.Ir;
import compiler.ir.model.IrBuilder;
import compiler.ir.model.IrFunction;
import compiler.ir.model.TypeKey;
import compiler.ir.passes.objects.IrGenericOwnerErasure;
import compiler.ir.pipeline.IrFunctionIndex;
import compiler.ir.verify.IrVerifier;

/**
 * Method values (`var f = b.name`), bound to their receiver with virtual dispatch, as in Haxe: the method that runs is the one of
 * the receiver's class (or the class implementing the interface), with that method's own default arguments.
 *
 * IR generation names a method value's closure target `$method-reference:<owner>:<member>:<receiver type>:<closure type>`, and
 * this pass gives each such target a function: it calls `member` on its first argument by dynamic dispatch, adapting the closure's
 * arguments and result to the method's ABI. Two values of one method of one object are the same function bound to the same
 * receiver, so they compare equal (`Reflect.compareMethods`).
 */
class IrMethodReferences {
	static inline final PREFIX = "$method-reference:";

	/** Whether `name` is a method reference's closure target. */
	public static inline function isReference(name:String):Bool
		return StringTools.startsWith(name, PREFIX);

	/** The closure target of a method value of `owner.member` on a receiver of `receiver`, as a closure of type `closure`. */
	public static function name(owner:String, member:String, receiver:String, closure:String):String
		return PREFIX + '$owner:$member:$receiver:$closure';

	/**
	 * The owner and member a method reference target is for, or null when `target` is not one. The owner and member have no colon;
	 * the types after them may (`class:Promise<Array<String>>`), which is why only the first two components are read.
	 */
	public static function of(target:String):Null<{owner:String, member:String}> {
		if (!StringTools.startsWith(target, PREFIX))
			return null;
		var parts = target.substr(PREFIX.length).split(":");
		return parts.length < 3 ? null : {owner: parts[0], member: parts[1]};
	}

	/** Gives each method reference the program makes its function, before value-field lowering and generic owner erasure. */
	public static function generate(functions:Array<IrFunction>, objects:Array<IrObject>,
			?lineage:compiler.ir.reuse.IrStageMemo.IrLineage):Void {
		var requests:Map<String, {receiver:IrType, closure:IrType}> = [];
		for (fn in functions)
			for (request in IrGenericOwnerErasure.requestsOf(fn, lineage))
				if (request.kind == IrGenericOwnerErasure.METHOD_REFERENCE) {
					var name = request.name, receiver = request.arguments[0], previous = requests.get(name);
					if (previous != null
						&& (!IrVerifier.sameType(previous.receiver, receiver)
						|| !IrVerifier.sameType(previous.closure, request.result)))
						throw new InternalError('Conflicting method reference "$name"');
					requests.set(name, {receiver: receiver, closure: request.result});
				}
		var byName = [for (object in objects) object.name => object],
			byFunction = new IrFunctionIndex("method-references", functions),
			names = [for (name in requests.keys()) name];
		names.sort(Reflect.compare);
		for (name in names) {
			var reference = of(name),
				request = requests.get(name);
			if (reference == null || request == null)
				throw new InternalError('Invalid method reference "$name"');
			var owner = reference.owner, member = reference.member, signature = switch request.closure {
				case Function(arguments, result): {arguments: arguments, result: result};
				default: throw new InternalError('Method reference "$name" is not a function');
			}, builder = new IrBuilder(), receiver = builder.argument("receiver", request.receiver),
				arguments = [for (index in 0...signature.arguments.length) builder.argument('argument$index',
				signature.arguments[index])];
			var result:IrValue;
			switch request.receiver {
				// A receiver of an erased generic owner: its operations dispatch to the physical owner (IrGenericOwnerErasure).
				case Dyn:
					result = builder.call(IrGenericOwnerErasure.erasedCallName(owner, member),
						[receiver].concat(arguments),
						signature.result);
				// An interface: the implementing class's method, called through the interface's contract.
				case Virtual(_):
					result = builder.methodCall(receiver, member, arguments, signature.result);
				case Obj(className):
					var object = byName.get(className),
						method = object == null ? null : IrGenericOwnerErasure.findMethod(object, member, byName,
							byFunction);
					if (method == null || method.arguments.length != arguments.length + 1)
						throw new InternalError('Missing target for method reference "$name"');
					var adapted = [for (index in 0...arguments.length) IrGenericOwnerErasure.convert(builder,
						arguments[index],
						method.arguments[index + 1].type, byName)];
					var called = builder.methodCall(receiver, member, adapted, method.result);
					result = (switch (signature.result) {
						case Void: true;
						default: false;
					}) ? called : IrGenericOwnerErasure.convert(builder, called, signature.result, byName);
				default: throw new InternalError('Invalid receiver for method reference "$name"');
			}
			builder.returnValue(result);
			functions.push(new IrFunction(name, builder.arguments, signature.result, builder.blocks,
				Provider(TypeKey.of(request.receiver),
				ProviderOperations.detailed(ProviderOperation.MethodReference, name))));
		}
	}
}
