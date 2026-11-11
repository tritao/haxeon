package compiler.ir;

import compiler.Provides;
import compiler.Provides.ProviderOperation;
import compiler.ir.Ir;

/**
 * The table of generated helpers: which function serves which operation on which type. A generator states it when it creates the
 * function (its `IrFunction.kind`), so the table is an index over the functions, not a second thing to keep in step with them.
 *
 * The passes that need to know what a generated function is (the scalar call ABI of the HashLink and Wasm backends, the optional-scalar
 * flow, the dispatchers, the typing-time liveness of shared helpers) ask this table through the functions below; none of them
 * recognizes a helper by the prefix of its name any more. Do not add a prefix list: give the generator's operation a place here.
 * A function that serves no type declares what it is by another kind (a lambda, a clone, an adapter, a helper).
 */
class IrProviders {
	/** The operation without the detail words after its first colon. */
	public static function base(operation:String):String {
		var colon = operation.indexOf(":");
		return colon < 0 ? operation : operation.substr(0, colon);
	}

	/** Whether a call to `fn` may pass an optional-scalar alias as an argument: `$` functions that do not keep it. */
	public static function passesAliases(fn:IrFunction):Bool
		return switch fn.kind {
			case Provider(subject, operation):
				switch base(operation) {
					case ProviderOperation.Equals: !subject.isEnum();
					case ProviderOperation.Hash: true;
					default: false;
				}
			case SourceLambda, GenericSpecialization: true;
			default: false;
		};

	/** Whether `fn` is the equality helper of a value type, or a copy of one made for the scalar call ABI. */
	public static function isValueEquality(fn:IrFunction, byName:Map<String, IrFunction>):Bool {
		var current = fn;
		while (current != null) {
			switch current.kind {
				case Provider(subject, operation):
					return base(operation) == ProviderOperation.Equals && !subject.isEnum();
				case ScalarArguments:
				default:
					return false;
			}
			var original = IrScalarArguments.originalName(current.name);
			current = original == null ? null : byName.get(original);
		}
		return false;
	}

	/**
	 * The provider operation a typed instruction asks for, and the type it asks it of: the walk reaches the row `(subject, operation)`,
	 * and `checkTypedOperations` requires it to exist. Null for an intrinsic that needs no helper.
	 */
	public static function typedOperation(operation:IrIntrinsic):Null<{subject:TypeKey, operation:ProviderOperation}>
		return switch operation {
			case EnumDynamicBox(type): {subject: TypeKey.of(type), operation: ProviderOperation.BoxDynamic};
			case EnumDynamicView(type): {subject: TypeKey.of(type), operation: ProviderOperation.ViewDynamic};
			case EnumTagBox(type): {subject: TypeKey.of(type), operation: ProviderOperation.EnumTagBox};
			case EnumTagUnbox(type): {subject: TypeKey.of(type), operation: ProviderOperation.EnumTagUnbox};
		};

	/**
	 * HAXEON_CHECK_REUSE=1, once the producers of the typed operations have run: every typed operation in `functions` has a provider row.
	 * Returns the first problem found (function, operation, type), or null.
	 */
	public static function checkTypedOperations(functions:Array<IrFunction>):Null<String> {
		var served:Map<String, Bool> = [];
		for (fn in functions)
			switch fn.provides {
				case Serves(type, operation):
					served.set(base(operation) + "\n" + type.toString(), true);
				case None:
			}
		for (fn in functions)
			for (block in fn.blocks)
				for (located in block.instructions)
					switch located.value {
						case Intrinsic(_, operation, _):
							var typed = typedOperation(operation);
							if (typed != null && !served.exists(base(typed.operation) + "\n" + typed.subject.toString()))
								return '"${fn.name}" asks for ${typed.operation} of ${typed.subject.toString()}, which no function provides';
						default:
					}
		return null;
	}

	/** (type key, operation) to function name, for every helper in `functions`. */
	public static function rows(functions:Array<IrFunction>):Map<String, String> {
		var result:Map<String, String> = [];
		for (fn in functions)
			switch fn.provides {
				case Serves(type, operation):
					result.set(row(type, operation), fn.name);
				case None:
			}
		return result;
	}

	/** A newline, not a NUL, between the parts: HashLink compares map keys as C strings, so a NUL would end the key. */
	public static function row(type:TypeKey, operation:String):String
		return operation + "\n" + type.toString();

	/**
	 * HAXEON_CHECK_REUSE=1: every function whose name starts with `$` declares what it is (a kind other than `Ordinary`), and no two functions
	 * serve the same operation on the same type. Returns the first problem found, or null.
	 */
	public static function check(functions:Array<IrFunction>):Null<String> {
		var seen:Map<String, String> = [];
		for (fn in functions)
			switch fn.provides {
				case Serves(type, operation):
					var key = row(type, operation), earlier = seen.get(key);
					if (earlier != null && earlier != fn.name)
						return 'functions "$earlier" and "${fn.name}" both serve "$operation" for "$type"';
					seen.set(key, fn.name);
				case None:
					if (StringTools.startsWith(fn.name, "$") && (switch fn.kind {
						case Ordinary: true;
						default: false;
					}))
						return 'function "${fn.name}" is named like a generated helper but does not say what it is';
			}
		return null;
	}
}
