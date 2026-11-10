package compiler.ir;

import compiler.Provides;

/**
 * The table of generated helpers: which function serves which operation on which type. A generator states it when it creates the
 * function (`IrFunction.provides`), so the table is an index over the functions, not a second thing to keep in step with them.
 *
 * Nothing reads the table yet except `check`. It exists so that the passes that today recognize a helper by the prefix of its name
 * (the hand-kept lists in `FrontendCompilation.generatedHelpersStillCalled`, `WasmScalarAbi`, `IrScalarArguments`,
 * `IrOptionalScalarFlow`, `EnumEqualityGenerator.isEqualityName` and `HashGenerator.isHashName`, and the prefix scans of
 * `IrEnumDynamicDispatch`, `IrValueDynamicDispatch` and `IrTypedInterfaceDispatch`) can ask it instead, and the lists be deleted.
 * That is the next step (ADR 0003 section 13): do not add another prefix list in the meantime.
 */
class IrProviders {
	/**
	 * `$`-named functions that are not helpers for a type, by name prefix: a lambda, an adapter, a clone of another function made for
	 * a calling convention, a specialization of a generic, a marker the backends read. Everything else starting with `$` must say what it
	 * serves. This is the one list that remains; it names families of derived functions, which have no type to be keyed by.
	 */
	static final derivedPrefixes = [
		"$enum-interface:", "$keypath.compose:", "$lambda:", "$lambda-env:", "$function-adapter:", "$iteration-adapter:", "$generic:", "$scalar-arguments:", "$optional-scalar:", "$nullable-scalar:arguments:",
		"$scalar-closure:", "$word:", "$lane:", "$lane-runtime:", "$lane-storage:", "$value-dynamic-equal", "$enum-dynamic-equal", "$enum-dynamic-reflect", "$value-interface-object-type-id", "$hl:", "$wasm", "$type-dependency:", "$to-string", "$fresh-constructor:",
		"$receiver-readonly:", "$haxeon"
	];

	public static function isDerivedName(name:String):Bool {
		for (prefix in derivedPrefixes)
			if (StringTools.startsWith(name, prefix))
				return true;
		return false;
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
	 * HAXEON_CHECK_REUSE=1: every function whose name starts with `$` is a provider or a derived function, and no two functions
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
					if (StringTools.startsWith(fn.name, "$") && !isDerivedName(fn.name))
						return 'function "${fn.name}" is named like a generated helper but does not say what it serves';
			}
		return null;
	}
}
