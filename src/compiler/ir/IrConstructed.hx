package compiler.ir;

import compiler.ir.Ir;
import compiler.semantic.SemanticSignature;

/**
 * What it means for a class to have instances: the one definition both reachability walks use (`IrReachabilityWalk`, the rapid type analysis
 * the Wasm builders run, and `IrTypeAwareWalk`, the prune). A class has instances once a reached function constructs it (`NewObject`) or a
 * reached native returns it; value classes, anonymous records and interface boxes are made in other ways (copies, literals, boxing), so they
 * always have; a name in no object table is a type only native code knows, which has instances too. `IrTypeAwareWalk` adds over-approximations
 * on top (a class it converts to Dynamic, a class in a signature).
 *
 * **The native contract.** A native constructs exactly the class its declaration returns, and no other: not a subclass of it, and not an argument's
 * class (an argument was constructed by its caller, which a walk sees). Native code that builds an instance of a class chosen at run time has to
 * be given that class, as a `Class<T>` or a type argument, which is a typed reference a walk counts as created. Audited on 2026-11-12: no runtime
 * native, std native or FFI native bound by the project allocates an object of a class its declaration does not name (`__reflect_copy` copies an
 * instance of its argument's own class, which its caller already constructed).
 */
class IrConstructed {
	/** Whether the class has instances without any function constructing them. `object` is its table entry, or null when there is none. */
	public static function withoutConstruction(typeName:String, object:Null<IrObject>):Bool
		return object == null || object.isValue || StringTools.startsWith(typeName, IrValueInterfaceBoxes.BOX_PREFIX)
			|| SemanticSignature.isAnonymousName(typeName);

	/** The class a native's result type names (an optional one too), or null when the result is not an object. */
	public static function resultClass(type:IrType):Null<String>
		return switch type {
			case Obj(name): name;
			case Nullable(inner): resultClass(inner);
			default: null;
		};

	/** The class each native, `IrNative` or `IrCNative`, returns an instance of, by native name. */
	public static function nativeResults(program:IrProgram):Map<String, String> {
		var results:Map<String, String> = [];
		for (native in program.natives) {
			var result = resultClass(native.result);
			if (result != null)
				results.set(native.name, result);
		}
		for (native in program.cNatives) {
			var result = resultClass(native.result);
			if (result != null)
				results.set(native.name, result);
		}
		return results;
	}

	/** The class this instruction makes an instance of: a `NewObject`, or a call of a native that returns an object. */
	public static function constructedBy(instruction:IrInstruction, nativeResults:Map<String, String>):Null<String>
		return switch instruction {
			case NewObject(_, typeName): typeName;
			case Call(_, target, _): nativeResults.get(target);
			default: null;
		};
}
